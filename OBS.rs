//! OBS.rs - Study/break timer protocol (Rust port of OBS.sh)
//!
//! Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
//! progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
//! use as Text sources in OBS Studio. OBS.sh is the reference implementation;
//! see docs/port-spec.md for the behavior contract and README.md for usage.
//!
//! Requirements: Rust 1.70+ (standard library only - the POSIX calls it needs
//! are declared via extern "C" against the libc every Rust binary links),
//! bash (to load the bash-syntax config file).
//!
//! Build: rustc -O -o OBS OBS.rs
//! Usage: ./OBS [options] <rounds> <study_minutes> <break_minutes>
//! Stop:  Ctrl+C, or press 'q' while a phase is running
//! Theme: press Alt+T while a phase is running (see --list-themes)

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Minimal libc surface (no external crates; Rust links libc by default)
// ---------------------------------------------------------------------------
use std::os::raw::{c_char, c_int, c_long, c_uint, c_ulong, c_void};

#[repr(C)]
struct Tm {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: *const c_char,
}

#[repr(C)]
struct Timeval {
    tv_sec: i64,
    tv_usec: i64,
}

#[repr(C)]
struct FdSet {
    fds_bits: [u64; 16],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Termios {
    c_iflag: c_uint,
    c_oflag: c_uint,
    c_cflag: c_uint,
    c_lflag: c_uint,
    c_line: u8,
    c_cc: [u8; 32],
    c_ispeed: c_uint,
    c_ospeed: c_uint,
}

extern "C" {
    fn select(nfds: c_int, readfds: *mut FdSet, writefds: *mut FdSet,
             exceptfds: *mut FdSet, timeout: *mut Timeval) -> c_int;
    fn read(fd: c_int, buf: *mut c_void, count: usize) -> isize;
    fn kill(pid: i32, sig: c_int) -> c_int;
    fn sigaction(signum: c_int, act: *const SigAction, oldact: *mut SigAction)
        -> c_int;
    fn localtime_r(time: *const i64, result: *mut Tm) -> *mut Tm;
    fn strftime(s: *mut c_char, max: usize, format: *const c_char,
                tm: *const Tm) -> usize;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
    fn isatty(fd: c_int) -> c_int;
    fn nanosleep(req: *const Timeval, rem: *mut Timeval) -> c_int;
}

#[repr(C)]
struct SigAction {
    sa_handler: usize,
    sa_mask: [u64; 16],
    sa_flags: c_int,
    sa_restorer: *mut c_void,
}

const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const SIGHUP: c_int = 1;
const SIG_IGN: usize = 1;
const TCGETS: c_ulong = 0x5401;
const TCSETS: c_ulong = 0x5402;
const ECHO: c_uint = 0o10;
const ICANON: c_uint = 0o2;
const VMIN: usize = 6;
const VTIME: usize = 5;

const STDIN_FD: c_int = 0;

// ---------------------------------------------------------------------------
// Color themes
// ---------------------------------------------------------------------------
const THEMES: [(&str, &str, &str); 12] = [
    ("Purple", "\x1b[1;35m", "\x1b[0;35m"),
    ("Ocean", "\x1b[1;36m", "\x1b[0;34m"),
    ("Forest", "\x1b[1;32m", "\x1b[0;32m"),
    ("Sunset", "\x1b[1;33m", "\x1b[0;31m"),
    ("Rose", "\x1b[1;95m", "\x1b[0;31m"),
    ("Gold", "\x1b[1;93m", "\x1b[0;33m"),
    ("Mono", "\x1b[1;37m", "\x1b[0;37m"),
    ("Ice", "\x1b[1;96m", "\x1b[0;36m"),
    ("Ember", "\x1b[1;91m", "\x1b[0;31m"),
    ("Neon", "\x1b[1;92m", "\x1b[0;96m"),
    ("Cobalt", "\x1b[1;34m", "\x1b[0;36m"),
    ("Cherry", "\x1b[1;91m", "\x1b[0;35m"),
];

const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const NC: &str = "\x1b[0m";

const LOGO: &str = " /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \\  $$$$/
| $$__/|______/ \\  $$ $$/ | $$__/     >$$  $$
| $$             \\  $$$/  | $$       /$$/\\  $$
| $$$$$$$$        \\  $/   | $$$$$$$$| $$  \\ $$
|________/         \\_/    |________/|__/  |__/";

const DEFAULT_QUOTE_LIST: [&str; 5] = [
    "Focused effort beats scattered hours",
    "Every round finished is progress made",
    "Consistency beats intensity",
    "Start now, figure out the rest along the way",
    "A short break now means sharper focus next round",
];

const WEEKDAYS: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday",
    "Thursday", "Friday", "Saturday"];

const TERM_BAR_WIDTH: usize = 24;
const BOX_INNER: usize = 62;

// ---------------------------------------------------------------------------
// Mutable program state (mirrors the reference's global variables)
// ---------------------------------------------------------------------------
struct State {
    prog: String,
    start_time: SystemTime,
    primary: &'static str,
    secondary: &'static str,
    theme_name: &'static str,
    theme_index: usize,
    theme_notice_until: i64,

    env_alert_sound: String,
    env_sink_name: String,
    env_state_dir: String,
    env_max_log_bytes: String,
    env_quotes: String,
    env_theme: String,

    dir: PathBuf,
    alert_sound: String,
    sink_name: String,
    state_dir: String,
    max_log_bytes: i64,
    file_bar_width: usize,
    non_tty_enter_timeout: i64,
    alert_pid: i32,
    quote_list: Vec<String>,
    points: i64,
    last_date: String,

    config_file: String,
    dry_run: bool,
    use_alert: bool,
    use_sink: bool,
    rounds: i64,
    study_min: i64,
    break_min: i64,
    cli_theme: String,
    duration_unit: &'static str,
    seconds_per_unit: i64,
    config_theme: String,
    config_quotes: String,
    config_loaded: String,

    date_file: PathBuf,
    day_file: PathBuf,
    session_file: PathBuf,
    timer_file: PathBuf,
    log_file: PathBuf,
    progress_file: PathBuf,
    points_file: PathBuf,
    message_file: PathBuf,
    next_file: PathBuf,
    overlay_file: PathBuf,
    theme_file: PathBuf,

    session_text: String,
    remaining_str: String,
    pct: i64,
    next_text: String,
    message_text: String,
    last_day: String,
    state_ready: bool,
    state_finalized: bool,
    in_cleanup: bool,

    phase_label: String,
    phase_subtitle: String,
    phase_next: String,
    phase_total: i64,
    phase_elapsed: i64,
    phase_paused: bool,
    phase_skipped: bool,
    phase_start: i64,
    phase_paused_total: i64,
    phase_pause_at: i64,

    stdin_is_tty: bool,
    term_saved: Option<Termios>,
    key: String,
    key_read: bool,
}

static IN_CLEANUP: AtomicBool = AtomicBool::new(false);
static mut STATE_PTR: *mut State = std::ptr::null_mut();

fn state() -> &'static mut State {
    unsafe { &mut *STATE_PTR }
}

fn new_state(prog: String) -> State {
    let start_time = SystemTime::now();
    State {
        prog,
        start_time,
        primary: THEMES[0].1,
        secondary: THEMES[0].2,
        theme_name: THEMES[0].0,
        theme_index: 0,
        theme_notice_until: 0,

        env_alert_sound: std::env::var("ALERT_SOUND").unwrap_or_default(),
        env_sink_name: std::env::var("SINK_NAME").unwrap_or_default(),
        env_state_dir: std::env::var("STATE_DIR").unwrap_or_default(),
        env_max_log_bytes: std::env::var("MAX_LOG_BYTES").unwrap_or_default(),
        env_quotes: std::env::var("QUOTES").unwrap_or_default(),
        env_theme: std::env::var("THEME").unwrap_or_default(),

        dir: std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()))
            .unwrap_or_else(|| PathBuf::from(".")),
        alert_sound: match std::env::var("HOME") {
            Ok(h) if !h.is_empty() => format!("{}/Videos/Alarm/n_alarm.mp3", h),
            _ => String::new(),
        },
        sink_name: "OBS_Alert_Sink".to_string(),
        state_dir: String::new(),
        max_log_bytes: 1048576,
        file_bar_width: 20,
        non_tty_enter_timeout: 300,
        alert_pid: 0,
        quote_list: DEFAULT_QUOTE_LIST.iter().map(|s| s.to_string()).collect(),
        points: 0,
        last_date: String::new(),

        config_file: String::new(),
        dry_run: false,
        use_alert: true,
        use_sink: true,
        rounds: 0,
        study_min: 0,
        break_min: 0,
        cli_theme: String::new(),
        duration_unit: "minutes",
        seconds_per_unit: 60,
        config_theme: String::new(),
        config_quotes: String::new(),
        config_loaded: String::new(),

        date_file: PathBuf::new(),
        day_file: PathBuf::new(),
        session_file: PathBuf::new(),
        timer_file: PathBuf::new(),
        log_file: PathBuf::new(),
        progress_file: PathBuf::new(),
        points_file: PathBuf::new(),
        message_file: PathBuf::new(),
        next_file: PathBuf::new(),
        overlay_file: PathBuf::new(),
        theme_file: PathBuf::new(),

        session_text: String::new(),
        remaining_str: "00:00:00".to_string(),
        pct: 0,
        next_text: String::new(),
        message_text: String::new(),
        last_day: String::new(),
        state_ready: false,
        state_finalized: false,
        in_cleanup: false,

        phase_label: String::new(),
        phase_subtitle: String::new(),
        phase_next: String::new(),
        phase_total: 0,
        phase_elapsed: 0,
        phase_paused: false,
        phase_skipped: false,
        phase_start: 0,
        phase_paused_total: 0,
        phase_pause_at: 0,

        stdin_is_tty: false,
        term_saved: None,
        key: String::new(),
        key_read: false,
    }
}

impl State {
    fn now_seconds(&self) -> i64 {
        self.start_time.elapsed().map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }

    fn set_theme(&mut self, i: usize) {
        self.theme_index = i;
        self.theme_name = THEMES[i].0;
        self.primary = THEMES[i].1;
        self.secondary = THEMES[i].2;
    }

    fn theme_index_of(&self, want: &str) -> Option<usize> {
        if want.is_empty() {
            return None;
        }
        THEMES.iter().position(|t| t.0.eq_ignore_ascii_case(want))
    }

    fn save_theme(&self) {
        if !self.theme_file.as_os_str().is_empty() {
            let _ = std::fs::write(&self.theme_file,
                                   format!("{}\n", self.theme_name));
        }
    }

    fn cycle_theme(&mut self) {
        self.set_theme((self.theme_index + 1) % THEMES.len());
        self.save_theme();
        self.theme_notice_until = self.now_seconds() + 3;
        let name = self.theme_name;
        self.log_event(&format!("Theme changed to: {}", name));
    }

    fn fmt_hms(total: i64) -> String {
        format!("{:02}:{:02}:{:02}", total / 3600, (total % 3600) / 60,
                total % 60)
    }

    fn make_bar(filled: usize, width: usize, fill: &str, empty: &str,
                head: &str) -> String {
        let mut bar = String::new();
        for i in 0..width {
            if i < filled {
                if !head.is_empty() && i + 1 == filled {
                    bar.push_str(head);
                } else {
                    bar.push_str(fill);
                }
            } else {
                bar.push_str(empty);
            }
        }
        bar
    }

    // -----------------------------------------------------------------------
    // Help and argument parsing
    // -----------------------------------------------------------------------
    fn help_text(&self) -> String {
        format!(
            "Usage: {} [options] <rounds> <study_minutes> <break_minutes>\n\
             \n\
             Runs a Pomodoro-style study/break loop and writes the live state to text\n\
             files that OBS Studio can display as \"Text (read from file)\" sources.\n\
             \n\
             Options:\n\
             \x20 -h, --help          Show this help and exit\n\
             \x20 -c, --config FILE   Load settings from FILE (bash syntax)\n\
             \x20 -d, --dry-run       Treat the durations as seconds (fast testing)\n\
             \x20 -n, --no-alert      Disable the audio alert\n\
             \x20 -s, --no-sink       Don't create or use the OBS virtual audio sink\n\
             \x20 -t, --theme NAME    Use a color theme (see --list-themes)\n\
             \x20     --list-themes   Show the available color themes and exit\n\
             \n\
             Arguments:\n\
             \x20 rounds             1-50   number of study rounds\n\
             \x20 study_minutes      1-600  length of a study phase\n\
             \x20 break_minutes      1-120  length of a break phase\n\
             \n\
             Examples:\n\
             \x20 {} 5 50 10           # 5 rounds, 50 min study, 10 min break\n\
             \x20 {} --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break\n\
             \x20 {} --theme Ocean 5 50 10\n\
             \n\
             Keys (while a phase is running):\n\
             \x20 p / space   pause and resume the current phase\n\
             \x20 s           skip the rest of the current phase\n\
             \x20 q           quit the session\n\
             \x20 Alt+T       switch to the next color theme\n\
             \n\
             Environment overrides:\n\
             \x20 ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME\n\
             \n\
             Config file (first one that exists):\n\
             \x20 --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config\n",
            self.prog, self.prog, self.prog, self.prog)
    }

    fn print_help(&self, code: i32, to_stderr: bool) -> ! {
        let text = self.help_text();
        if to_stderr {
            eprint!("{}", text);
        } else {
            print!("{}", text);
        }
        std::process::exit(code);
    }

    fn usage_error(&self) -> ! {
        self.print_help(1, true)
    }

    fn parse_args(&mut self, argv: &[String]) {
        let mut args: Vec<String> = argv.to_vec();
        let mut pos: Vec<String> = Vec::new();
        while let Some(a) = args.first().cloned() {
            if a == "-h" || a == "--help" {
                self.print_help(0, false);
            } else if a == "-c" || a == "--config" {
                if args.len() < 2 {
                    eprintln!("Error: {} needs a file argument", a);
                    self.usage_error();
                }
                self.config_file = args[1].clone();
                args.drain(0..2);
            } else if a == "-d" || a == "--dry-run" {
                self.dry_run = true;
                args.remove(0);
            } else if a == "-n" || a == "--no-alert" {
                self.use_alert = false;
                args.remove(0);
            } else if a == "-s" || a == "--no-sink" {
                self.use_sink = false;
                args.remove(0);
            } else if a == "-t" || a == "--theme" {
                if args.len() < 2 {
                    eprintln!("Error: {} needs a theme name", a);
                    self.usage_error();
                }
                self.cli_theme = args[1].clone();
                args.drain(0..2);
            } else if a == "--list-themes" {
                self.print_theme_list();
                std::process::exit(0);
            } else if a == "--" {
                args.remove(0);
                pos.extend(args.drain(..));
                break;
            } else if a.starts_with('-') {
                eprintln!("Error: unknown option: {}", a);
                self.usage_error();
            } else {
                pos.extend(args.drain(..));
                break;
            }
        }
        if pos.len() != 3 {
            self.usage_error();
        }
        for v in &pos {
            if !valid_number(v) {
                self.usage_error();
            }
        }
        self.rounds = pos[0].parse().unwrap();
        self.study_min = pos[1].parse().unwrap();
        self.break_min = pos[2].parse().unwrap();
        if self.rounds > 50 {
            eprintln!("Error: rounds must be <= 50");
            self.usage_error();
        }
        if self.study_min > 600 {
            eprintln!("Error: study minutes must be <= 600");
            self.usage_error();
        }
        if self.break_min > 120 {
            eprintln!("Error: break minutes must be <= 120");
            self.usage_error();
        }
        if self.dry_run {
            self.duration_unit = "seconds";
            self.seconds_per_unit = 1;
        }
    }

    fn print_theme_list(&self) {
        for t in THEMES.iter() {
            println!("  {:<8} {}\u{2588}\u{2588}\u{2588}\u{2588}{}", t.0, t.1, t.2);
        }
    }

    // -----------------------------------------------------------------------
    // Configuration file
    // -----------------------------------------------------------------------
    fn find_config_file(&self) -> Option<String> {
        if !self.config_file.is_empty() {
            return Some(self.config_file.clone());
        }
        if let Ok(p) = std::env::var("OBS_PANEL_CONFIG") {
            if !p.is_empty() {
                return Some(p);
            }
        }
        let xdg_base = std::env::var("XDG_CONFIG_HOME")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                format!("{}/.config", std::env::var("HOME").unwrap_or_default())
            });
        let xdg = format!("{}/obs-study-panel/config", xdg_base);
        if Path::new(&xdg).is_file() {
            return Some(xdg);
        }
        let local = self.dir.join("obs-panel.conf");
        if local.is_file() {
            return Some(local.to_string_lossy().into_owned());
        }
        None
    }

    fn quotes_to_list(&mut self, raw: &str) {
        self.quote_list = raw.split('\n')
            .map(|l| l.trim_end_matches('\r'))
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect();
    }

    fn load_config(&mut self, path: &str) {
        if !Path::new(path).is_file() {
            eprintln!("Error: config file is not readable: {}", path);
            std::process::exit(1);
        }
        // Syntax check up front, exactly like the reference.
        let chk = Command::new("bash").arg("-n").arg(path)
            .stderr(Stdio::piped()).output().expect("bash -n");
        if !chk.status.success() {
            eprintln!("Error: syntax error in config file: {}", path);
            let err = String::from_utf8_lossy(&chk.stderr);
            for line in err.lines().filter(|l| !l.trim().is_empty()).take(3) {
                eprintln!("{}", line);
            }
            std::process::exit(1);
        }

        let dump_path = std::env::temp_dir().join(format!(
            "obs-panel-conf-{}", std::process::id()));
        std::fs::write(&dump_path, b"").ok();

        // Seed the pre-config defaults in the child environment.
        let mut env: Vec<(String, String)> = std::env::vars().collect();
        fn setseed(env: &mut Vec<(String, String)>, k: &str, v: String) {
            env.retain(|(ek, _)| ek != k);
            env.push((k.to_string(), v));
        }
        setseed(&mut env, "ALERT_SOUND", self.alert_sound.clone());
        setseed(&mut env, "SINK_NAME", self.sink_name.clone());
        setseed(&mut env, "STATE_DIR", String::new());
        setseed(&mut env, "MAX_LOG_BYTES", "1048576".to_string());
        setseed(&mut env, "FILE_BAR_WIDTH", "20".to_string());
        setseed(&mut env, "NON_TTY_ENTER_TIMEOUT", "300".to_string());
        setseed(&mut env, "POINTS", format!("{}", self.points));
        setseed(&mut env, "LAST_DATE", self.last_date.clone());
        setseed(&mut env, "QUOTES_SEED",
                self.quote_list.join("\x1f"));
        let envs: Vec<String> = env.iter()
            .map(|(k, v)| format!("{}={}", k, v)).collect();

        let status = Command::new("bash")
            .arg("-c").arg(CONFIG_DUMP_SH)
            .arg("obs-panel").arg(path).arg(&dump_path)
            .env_clear()
            .envs(envs.iter().map(|s| {
                let mut it = s.splitn(2, '=');
                (it.next().unwrap(), it.next().unwrap())
            }))
            .status()
            .expect("bash -c dump");
        let rc = status.code().unwrap_or(1);

        let raw = std::fs::read(&dump_path).unwrap_or_default();
        let _ = std::fs::remove_file(&dump_path);

        if raw.is_empty() {
            // The config called exit N before the dump was written.
            std::process::exit(if rc != 0 { rc } else { 1 });
        }

        let text = String::from_utf8_lossy(&raw).into_owned();
        let mut values: Vec<(String, String)> = Vec::new();
        let mut quotes: Vec<String> = Vec::new();
        for record in text.split('\x1e') {
            if record.is_empty() {
                continue;
            }
            if let Some(i) = record.find('\x1f') {
                let k = &record[..i];
                let v = record[i + 1..].to_string();
                if k == "QUOTE" {
                    quotes.push(v);
                } else {
                    values.push((k.to_string(), v));
                }
            }
        }

        let get = |k: &str| -> Option<String> {
            values.iter().find(|(ek, _)| ek == k).map(|(_, v)| v.clone())
        };

        if let Some(v) = get("ALERT_SOUND") { self.alert_sound = v; }
        if let Some(v) = get("SINK_NAME") { self.sink_name = v; }
        self.state_dir = get("STATE_DIR").unwrap_or_default();
        self.max_log_bytes = get("MAX_LOG_BYTES")
            .and_then(|v| v.trim().parse().ok())
            .filter(|n| *n > 0)
            .unwrap_or(1048576);
        self.file_bar_width = get("FILE_BAR_WIDTH")
            .and_then(|v| v.trim().parse().ok())
            .filter(|n| *n > 0 && *n <= 200)
            .unwrap_or(20);
        self.non_tty_enter_timeout = get("NON_TTY_ENTER_TIMEOUT")
            .and_then(|v| v.trim().parse().ok())
            .filter(|n| *n > 0 && *n <= 3600)
            .unwrap_or(300);
        self.config_theme = get("THEME").unwrap_or_default();
        self.points = get("POINTS")
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0);
        self.last_date = get("LAST_DATE").unwrap_or_default();
        self.config_quotes = get("QUOTES").unwrap_or_default();
        self.quote_list = quotes;
        self.config_loaded = path.to_string();
    }

    fn apply_quote_sources(&mut self) {
        if !self.env_quotes.is_empty() {
            let raw = self.env_quotes.clone();
            self.quotes_to_list(&raw);
        } else if !self.config_quotes.is_empty() {
            let raw = self.config_quotes.clone();
            self.quotes_to_list(&raw);
        }
    }

    // -----------------------------------------------------------------------
    // Paths and theme selection
    // -----------------------------------------------------------------------
    fn setup_paths(&mut self) {
        if self.state_dir.is_empty() {
            self.state_dir = self.dir.to_string_lossy().into_owned();
        }
        if std::fs::create_dir_all(&self.state_dir).is_err() {
            eprintln!("Error: cannot create state dir: {}", self.state_dir);
            std::process::exit(1);
        }
        let join = |n: &str| -> PathBuf {
            Path::new(&self.state_dir).join(n)
        };
        self.date_file = join("date.txt");
        self.day_file = join("day.txt");
        self.session_file = join("session.txt");
        self.timer_file = join("timer.txt");
        self.log_file = join("log.txt");
        self.progress_file = join("progress.txt");
        self.points_file = join("points.txt");
        self.message_file = join("message.txt");
        self.next_file = join("next.txt");
        self.overlay_file = join("overlay.txt");
        self.theme_file = join("theme.txt");
    }

    fn select_theme(&mut self) {
        let mut request = self.cli_theme.clone();
        if request.is_empty() {
            request = self.env_theme.clone();
        }
        if request.is_empty() {
            request = self.config_theme.clone();
        }
        if request.is_empty() && self.theme_file.is_file() {
            if let Ok(content) = std::fs::read_to_string(&self.theme_file) {
                request = content.lines().next().unwrap_or("").to_string();
            }
        }
        if !request.is_empty() {
            match self.theme_index_of(&request) {
                None => {
                    eprintln!("Warning: unknown theme '{}', using {}",
                              request, self.theme_name);
                }
                Some(idx) => self.set_theme(idx),
            }
        }
    }

    // -----------------------------------------------------------------------
    // OBS state files
    // -----------------------------------------------------------------------
    fn write_state(&self, path: &Path, text: &str) {
        if let Ok(mut fh) = File::create(path) {
            let _ = writeln!(fh, "{}", text);
        }
    }

    fn update_date_day(&mut self) {
        let d = local_time("%Y-%m-%d");
        if d == self.last_date {
            return;
        }
        self.last_date = d;
        self.last_day = local_time("%A");
        let dd = self.last_date.clone();
        let dw = self.last_day.clone();
        self.write_state(&self.date_file, &dd);
        self.write_state(&self.day_file, &dw);
    }

    fn sync_state(&mut self) {
        self.update_date_day();
        self.publish_state();
    }

    fn publish_state(&mut self) {
        let filled = (self.pct * self.file_bar_width as i64 / 100) as usize;
        let bar = Self::make_bar(filled, self.file_bar_width, "#", "-", "");
        let pct_s = format!("{:3}%", self.pct);

        let st = self.session_text.clone();
        let rem = self.remaining_str.clone();
        let nxt = self.next_text.clone();
        let msg = self.message_text.clone();
        self.write_state(&self.session_file, &st);
        self.write_state(&self.timer_file, &rem);
        self.write_state(&self.points_file, &format!("{}", self.points));
        self.write_state(&self.next_file, &nxt);
        self.write_state(&self.message_file, &msg);
        self.write_state(&self.progress_file,
                         &format!("[{}] {}", bar, pct_s));

        let overlay = format!(
            "{} {}\n{}\n{}\n[{}] {}\nPts: {}\nNext: {}\n",
            self.last_date, self.last_day, st, rem, bar, pct_s, self.points,
            nxt);
        let _ = std::fs::write(&self.overlay_file, overlay);
    }

    fn rotate_log_if_needed(&self) {
        if let Ok(meta) = std::fs::metadata(&self.log_file) {
            if meta.len() >= self.max_log_bytes as u64 {
                let rotated = format!("{}.1", self.log_file.to_string_lossy());
                if std::fs::rename(&self.log_file, &rotated).is_ok() {
                    let _ = std::fs::write(&self.log_file, b"");
                }
            }
        }
    }

    fn log_event(&self, msg: &str) {
        self.rotate_log_if_needed();
        if let Ok(mut fh) = OpenOptions::new().create(true).append(true)
            .open(&self.log_file) {
            let _ = writeln!(fh, "[{}] {}", local_time("%Y-%m-%d %H:%M:%S"),
                             msg);
        }
    }

    // -----------------------------------------------------------------------
    // Audio alerts
    // -----------------------------------------------------------------------
    fn sink_is_ready(&self) -> bool {
        if which("pactl").is_none() {
            return false;
        }
        let out = Command::new("pactl").args(["list", "short", "sinks"])
            .stderr(Stdio::null()).output();
        match out {
            Ok(o) => {
                let text = String::from_utf8_lossy(&o.stdout);
                text.lines().any(|line| {
                    let mut it = line.split_whitespace();
                    it.next();
                    it.next() == Some(self.sink_name.as_str())
                })
            }
            Err(_) => false,
        }
    }

    fn setup_audio_sink(&self) {
        if !self.use_sink {
            return;
        }
        if which("pactl").is_none() {
            return;
        }
        if self.sink_is_ready() {
            return;
        }
        let _ = Command::new("pactl")
            .args(["load-module", "module-null-sink",
                   &format!("sink_name={}", self.sink_name),
                   &format!("sink_properties=device.description={}",
                            self.sink_name)])
            .stdout(Stdio::null()).stderr(Stdio::null()).status();
    }

    fn stop_alert(&mut self) {
        if self.alert_pid > 0 {
            unsafe {
                kill(self.alert_pid, SIGTERM);
            }
            self.alert_pid = 0;
        }
    }

    fn play_alert(&mut self) {
        if !self.use_alert {
            return;
        }
        self.stop_alert();
        if self.alert_sound.is_empty()
            || !Path::new(&self.alert_sound).is_file() {
            println!("{}(alert file not found: {}){}",
                     DIM,
                     if self.alert_sound.is_empty() { "none" }
                     else { &self.alert_sound }, NC);
            return;
        }

        let player: Vec<&str> = if which("mpv").is_some() {
            vec!["mpv", "--no-video", "--volume=70"]
        } else if which("paplay").is_some() {
            vec!["paplay"]
        } else if which("ffplay").is_some() {
            vec!["ffplay", "-nodisp", "-autoexit"]
        } else if which("cvlc").is_some() {
            vec!["cvlc", "--play-and-exit", "--no-video", "--volume=70"]
        } else {
            println!("{}(no audio player found - install mpv / paplay / ffplay){}",
                     DIM, NC);
            return;
        };

        if self.use_sink && !self.sink_is_ready() {
            self.setup_audio_sink();
        }

        let mut cmd = Command::new(player[0]);
        cmd.args(&player[1..]).arg(&self.alert_sound)
            .stdout(Stdio::null()).stderr(Stdio::null());
        if self.use_sink && self.sink_is_ready() {
            cmd.env("PULSE_SINK", &self.sink_name);
        }
        if let Ok(child) = cmd.spawn() {
            self.alert_pid = child.id() as i32;
        }

        if self.use_sink && self.sink_is_ready() {
            println!("{}-> alert on OBS sink ({}){}", DIM, self.sink_name, NC);
        } else {
            println!("{}-> alert on default device (OBS sink unavailable){}",
                     self.secondary, NC);
        }
    }

    // -----------------------------------------------------------------------
    // Keyboard input
    // -----------------------------------------------------------------------
    fn setup_terminal(&mut self) {
        unsafe {
            self.stdin_is_tty = isatty(STDIN_FD) == 1;
            if !self.stdin_is_tty {
                return;
            }
            let mut t: Termios = std::mem::zeroed();
            if ioctl(STDIN_FD, TCGETS, &mut t as *mut Termios) == 0 {
                let mut raw = t.clone();
                self.term_saved = Some(t);
                raw.c_lflag &= !(ECHO | ICANON);
                raw.c_cc[VMIN] = 1;
                raw.c_cc[VTIME] = 0;
                ioctl(STDIN_FD, TCSETS, &raw as *const Termios);
            }
        }
    }

    fn restore_terminal(&mut self) {
        if let Some(t) = self.term_saved.take() {
            unsafe {
                ioctl(STDIN_FD, TCSETS, &t as *const Termios);
            }
        }
    }

    fn read_byte_timeout(&self, timeout: f64) -> i32 {
        unsafe {
            let mut fds: FdSet = std::mem::zeroed();
            fds.fds_bits[0] = 1u64;   // fd 0
            let tv_sec = timeout as i64;
            let tv_usec = ((timeout - timeout.floor()) * 1e6) as i64;
            let mut tv = Timeval { tv_sec, tv_usec };
            let rc = select(1, &mut fds,
                            std::ptr::null_mut::<FdSet>(),
                            std::ptr::null_mut::<FdSet>(), &mut tv as *mut Timeval);
            if rc <= 0 {
                return -1;   // timeout / signal: treat as no byte
            }
            let mut buf = [0u8; 1];
            let n = read(STDIN_FD, buf.as_mut_ptr() as *mut c_void, 1);
            if n <= 0 {
                return -2;   // EOF
            }
            buf[0] as i32
        }
    }

    fn wait_key(&mut self, timeout: f64) {
        self.key.clear();
        self.key_read = false;
        if !self.stdin_is_tty {
            sleep_seconds(timeout);
            return;
        }
        let b = self.read_byte_timeout(timeout);
        if b < 0 {
            return;
        }
        self.key_read = true;
        if b == 0x1b {
            let nxt = self.read_byte_timeout(0.3);
            if nxt == 't' as i32 || nxt == 'T' as i32 {
                self.key = "alt-t".to_string();
            }
        } else {
            self.key = (b as u8 as char).to_string();
        }
    }

    fn discard_pending_input(&mut self) {
        if !self.stdin_is_tty {
            return;
        }
        loop {
            let b = self.read_byte_timeout(0.01);
            if b < 0 {
                return;
            }
        }
    }

    fn wait_for_enter(&mut self) {
        if self.stdin_is_tty {
            loop {
                let b = self.read_byte_timeout(1.0);
                if b == -1 {
                    self.update_date_day();
                    continue;
                }
                if b == -2 || b == '\n' as i32 {
                    return;
                }
            }
        }
        let mut waited = 0i64;
        while waited < self.non_tty_enter_timeout {
            let slice_start = std::time::Instant::now();
            loop {
                let elapsed = slice_start.elapsed().as_secs_f64();
                if elapsed >= 5.0 {
                    waited += 5;
                    break;
                }
                let b = self.read_byte_timeout(5.0 - elapsed);
                if b == -2 {
                    return;
                }
                if b == -1 {
                    waited += 5;
                    break;
                }
                if b == '\n' as i32 {
                    return;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Status / progress UI
    // -----------------------------------------------------------------------
    fn phase_color(&self, label: &str) -> &'static str {
        if label == "STUDY" {
            self.primary
        } else {
            self.secondary
        }
    }

    fn duration_label(&self, n: i64) -> String {
        if n == 1 {
            if self.duration_unit == "seconds" {
                "1 second".to_string()
            } else {
                "1 minute".to_string()
            }
        } else {
            format!("{} {}", n, self.duration_unit)
        }
    }

    fn rounds_label(n: i64) -> String {
        if n == 1 {
            "1 round".to_string()
        } else {
            format!("{} rounds", n)
        }
    }

    fn draw_status(&self, label: &str, round: i64, total_rounds: i64,
                   elapsed: i64, total: i64, paused: bool) {
        let mut filled = 0usize;
        if total > 0 {
            filled = (elapsed as f64 * TERM_BAR_WIDTH as f64
                      / total as f64) as usize;
        }
        if filled > TERM_BAR_WIDTH {
            filled = TERM_BAR_WIDTH;
        }
        let bar = Self::make_bar(filled, TERM_BAR_WIDTH, "=", " ", ">");
        let color = self.phase_color(label);
        let mut flag = String::new();
        if paused {
            flag = format!("{} PAUSED{}", self.primary, NC);
        }
        if self.now_seconds() < self.theme_notice_until {
            flag.push_str(&format!("  {}Theme: {}{}", DIM, self.theme_name, NC));
        }
        print!("\r\x1b[K");
        print!("{}{}{:<6}{} [{}/{}] {}[{}]{} {:3}%  {}  {}Pts:{}{}{}",
               BOLD, color, label, NC, round, total_rounds,
               color, bar, NC, self.pct, self.remaining_str,
               self.primary, self.points, NC, flag);
    }

    fn box_row(color: &str, plain: &str, styled: &str) {
        let mut pad = BOX_INNER as i64 - plain.chars().count() as i64;
        if pad < 0 {
            pad = 0;
        }
        println!("{}\u{2551}{}{}{}\u{2551}{}", color, styled,
                 " ".repeat(pad as usize), color, NC);
    }

    fn phase_header(&self, label: &str, round: i64, total: i64, minutes: i64,
                    subtitle: &str) {
        let sub: String = subtitle.chars().take(BOX_INNER - 4).collect();
        let color = self.phase_color(label);
        let bar = "\u{2550}".repeat(BOX_INNER);
        let dur = self.duration_label(minutes);
        let info = format!("{}  \u{b7}  Round {} / {}  \u{b7}  {}", label,
                           round, total, dur);
        let styled1 = format!("  {}{}{}{}  \u{b7}  Round {} / {}  \u{b7}  {}",
                              BOLD, label, NC, color, round, total, dur);
        let styled2 = format!("  {}{}{}{}", DIM, sub, NC, color);
        println!();
        println!("{}\u{2554}{}\u{2557}{}", color, bar, NC);
        Self::box_row(color, &format!("  {}", info), &styled1);
        Self::box_row(color, &format!("  {}", sub), &styled2);
        if self.stdin_is_tty {
            let keys = "  p pause  \u{b7}  s skip  \u{b7}  q quit  \u{b7}  Alt+T theme";
            Self::box_row(color, keys, &format!("{}{}{}{}", DIM, keys, NC, color));
        }
        println!("{}\u{255a}{}\u{255d}{}", color, bar, NC);
        println!();
    }

    fn show_completion(&self, phase: &str, round: i64, total_rounds: i64,
                       next_phase: &str, skipped: bool) {
        let width = 60usize;
        let line = "=".repeat(width);
        let title = if skipped {
            "PHASE SKIPPED"
        } else if phase == "STUDY" {
            "STUDY SESSION COMPLETE"
        } else {
            "BREAK COMPLETE"
        };
        let color = self.phase_color(phase);
        let pad = (width + title.len()) / 2;
        println!();
        println!("{}{}{}", color, line, NC);
        println!("{}{}{}{}", color, " ".repeat(pad), title, NC);
        println!("{}{}{}", color, line, NC);
        println!();
        println!("  Round:   {}{}{} / {}", BOLD, round, NC, total_rounds);
        println!("  Points:  {}{}{}", self.primary, self.points, NC);
        println!();
        if next_phase == "None" {
            println!("  Next:    {}Session complete{}", DIM, NC);
        } else {
            println!("  Next:    {}{}{}", BOLD, next_phase, NC);
        }
        println!();
        print!("  {}Press Enter to continue...{}", self.primary, NC);
    }

    // -----------------------------------------------------------------------
    // Phase runner
    // -----------------------------------------------------------------------
    fn phase_prepare(&mut self, ptype: &str, minutes: i64, round: i64,
                     total_rounds: i64) {
        if ptype == "study" {
            self.phase_label = "STUDY".to_string();
            if !self.quote_list.is_empty() {
                use std::collections::hash_map::DefaultHasher;
                use std::hash::{Hash, Hasher};
                let mut h = DefaultHasher::new();
                SystemTime::now().hash(&mut h);
                std::process::id().hash(&mut h);
                let idx = (h.finish() % self.quote_list.len() as u64) as usize;
                self.phase_subtitle = self.quote_list[idx].clone();
            } else {
                self.phase_subtitle = "Stay focused.".to_string();
            }
        } else {
            self.phase_label = "BREAK".to_string();
            self.phase_subtitle = "Relax and recharge.".to_string();
        }

        if ptype == "study" {
            if round < total_rounds {
                self.phase_next = format!("Break ({})",
                                          self.duration_label(self.break_min));
            } else {
                self.phase_next = "None".to_string();
            }
        } else {
            self.phase_next = format!("Study ({})",
                                      self.duration_label(self.study_min));
        }

        self.phase_total = minutes * self.seconds_per_unit;
        self.phase_elapsed = 0;
        self.phase_paused = false;
        self.phase_skipped = false;
        self.phase_start = self.now_seconds();
        self.phase_paused_total = 0;
        self.phase_pause_at = 0;

        self.session_text = format!("{} {}/{}", self.phase_label, round,
                                   total_rounds);
        self.remaining_str = Self::fmt_hms(self.phase_total);
        self.pct = 0;
        self.next_text = if self.phase_next == "None" {
            "Session complete".to_string()
        } else {
            self.phase_next.clone()
        };
        self.message_text = self.phase_subtitle.clone();

        let label = self.phase_label.clone();
        let sub = self.phase_subtitle.clone();
        self.log_event(&format!("Start: {} {}/{} ({})", label, round,
                                total_rounds, self.duration_label(minutes)));
        self.phase_header(&label, round, total_rounds, minutes, &sub);
        self.sync_state();
    }

    fn phase_handle_key(&mut self, round: i64, total_rounds: i64) {
        if self.key == "p" || self.key == "P" || self.key == " " {
            if self.phase_paused {
                self.phase_paused_total += self.now_seconds() - self.phase_pause_at;
                self.phase_paused = false;
                let label = self.phase_label.clone();
                self.log_event(&format!("Resumed: {} {}/{}", label, round,
                                       total_rounds));
            } else {
                self.phase_paused = true;
                self.phase_pause_at = self.now_seconds();
                let label = self.phase_label.clone();
                self.log_event(&format!("Paused: {} {}/{}", label, round,
                                       total_rounds));
            }
        } else if self.key == "s" || self.key == "S" {
            self.phase_skipped = true;
            let label = self.phase_label.clone();
            self.log_event(&format!("Skipped: {} {}/{}", label, round,
                                   total_rounds));
        } else if self.key == "q" || self.key == "Q" {
            self.log_event("Quit requested by user");
            cleanup(0);
        } else if self.key == "alt-t" {
            self.cycle_theme();
        }
    }

    fn phase_count(&mut self, round: i64, total_rounds: i64) {
        while self.phase_elapsed < self.phase_total {
            let mut remaining = self.phase_total - self.phase_elapsed;
            if remaining < 0 {
                remaining = 0;
            }
            self.remaining_str = Self::fmt_hms(remaining);
            self.pct = if self.phase_total > 0 {
                self.phase_elapsed * 100 / self.phase_total
            } else {
                0
            };
            if self.pct > 100 {
                self.pct = 100;
            }
            self.session_text = format!("{} {}/{}", self.phase_label, round,
                                       total_rounds);
            if self.phase_paused {
                self.session_text.push_str(" (PAUSED)");
            }

            self.sync_state();
            let paused = self.phase_paused;
            let label = self.phase_label.clone();
            let elapsed = self.phase_elapsed;
            let total = self.phase_total;
            self.draw_status(&label, round, total_rounds, elapsed, total,
                             paused);

            self.wait_key(1.0);
            if self.key_read {
                self.phase_handle_key(round, total_rounds);
                if self.phase_skipped {
                    break;
                }
            }
            // CRASH-INJECT-POINT
            if !self.phase_paused {
                self.phase_elapsed = self.now_seconds() - self.phase_start
                    - self.phase_paused_total;
            }
        }
    }

    fn phase_finish(&mut self, round: i64, total_rounds: i64) {
        if self.phase_skipped {
            self.session_text = format!("{} {}/{} (SKIPPED)",
                                        self.phase_label, round, total_rounds);
        } else {
            self.pct = 100;
            self.points += 1;
        }
        self.remaining_str = "00:00:00".to_string();
        self.sync_state();
        let label = self.phase_label.clone();
        let elapsed = self.phase_elapsed;
        let total = self.phase_total;
        self.draw_status(&label, round, total_rounds, elapsed, total, false);
        println!();
        self.log_event(&format!("End: {} {}/{}", label, round, total_rounds));

        self.play_alert();

        self.discard_pending_input();
        let next = self.phase_next.clone();
        let skipped = self.phase_skipped;
        self.show_completion(&label, round, total_rounds, &next, skipped);
        self.wait_for_enter();
        self.stop_alert();
        println!();
    }

    fn run_phase(&mut self, ptype: &str, minutes: i64, round: i64,
                 total_rounds: i64) {
        self.phase_prepare(ptype, minutes, round, total_rounds);
        self.phase_count(round, total_rounds);
        self.phase_finish(round, total_rounds);
    }

    // -----------------------------------------------------------------------
    // Cleanup
    // -----------------------------------------------------------------------
    fn reset_state_files(&mut self) {
        self.session_text = "stopped".to_string();
        self.remaining_str = "00:00:00".to_string();
        self.pct = 0;
        self.next_text.clear();
        self.sync_state();
    }

    fn on_unexpected_death(&mut self, rc: i32) {
        if !self.state_ready || self.state_finalized {
            return;
        }
        self.state_finalized = true;
        self.stop_alert();
        self.reset_state_files();
        self.log_event(&format!("Protocol ended unexpectedly (exit {})", rc));
    }

    fn finalize_session(&mut self) {
        self.session_text = "session complete".to_string();
        self.remaining_str = "00:00:00".to_string();
        self.pct = 100;
        self.next_text.clear();
        self.sync_state();
        self.state_finalized = true;
        self.log_event(&format!("Protocol complete - total points: {}",
                                self.points));
    }

    fn final_banner(&self) {
        let banner_width = 60usize;
        let title = "ALL SESSIONS COMPLETE";
        let inner = banner_width - 2;
        let pad = (inner - title.len()) / 2;
        let border = "#".repeat(banner_width);
        println!();
        println!("{}{}{}", self.primary, border, NC);
        println!("{}#{}{}{}{}{}{}#{}",
                 self.primary, NC,
                 " ".repeat(pad), BOLD, title,
                 " ".repeat(inner - pad - title.len()), NC, self.primary);
        println!("{}{}{}", self.primary, border, NC);
        println!();
        println!("  {}Total Rounds:{}  {}{}{}", BOLD, NC, self.primary,
                 self.rounds, NC);
        println!("  {}Total Points:{} {}{}{}", BOLD, NC, self.primary,
                 self.points, NC);
        println!();
        println!("{}{}Great work!{} {}Exiting.{}", self.primary, BOLD, NC,
                 DIM, NC);
    }

    fn print_logo(&self) {
        println!("{}", self.primary);
        println!("{}", LOGO);
        println!("{}", NC);
        println!("{}{}     Study / Break Timer Protocol{}", self.primary,
                 BOLD, NC);
        println!("{}\u{2500}\u{2500} live state written to date \u{b7} day \
                  \u{b7} session \u{b7} timer \u{b7} log{}", DIM, NC);
        println!();
    }
}

fn valid_number(s: &str) -> bool {
    !s.is_empty() && s.len() <= 4 && s.as_bytes()[0].is_ascii_digit()
        && s.as_bytes()[0] != b'0' && s.bytes().all(|b| b.is_ascii_digit())
}

fn which(cmd: &str) -> Option<PathBuf> {
    let path = std::env::var("PATH").ok()?;
    for dir in path.split(':') {
        let candidate = Path::new(dir).join(cmd);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn sleep_seconds(t: f64) {
    unsafe {
        let tv = Timeval {
            tv_sec: t as i64,
            tv_usec: ((t - t.floor()) * 1e6) as i64,
        };
        // nanosleep takes a timespec; Timeval is layout-compatible here.
        nanosleep(&tv, std::ptr::null_mut());
    }
}

fn local_time(format: &str) -> String {
    unsafe {
        let secs = SystemTime::now().duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64).unwrap_or(0);
        let mut tmv: Tm = std::mem::zeroed();
        if localtime_r(&secs, &mut tmv).is_null() {
            return String::new();
        }
        let fmt_c = std::ffi::CString::new(format).unwrap();
        let mut buf = [0 as c_char; 128];
        let n = strftime(buf.as_mut_ptr(), 128, fmt_c.as_ptr(), &tmv);
        String::from_utf8_lossy(std::slice::from_raw_parts(
            buf.as_ptr() as *const u8, n)).into_owned()
    }
}

// The config file is bash source code (exactly like the reference). It is
// interpreted by a child bash that first seeds the pre-config default knobs,
// sources the file, and then dumps the resulting values: unit separator
// 0x1F between key and value, record separator 0x1E between records.
const CONFIG_DUMP_SH: &str = r#"
set -u
IFS=$'\037' read -r -a QUOTE_LIST <<< "${QUOTES_SEED-}"
unset QUOTES_SEED
source "$1" || true
{
  d() { printf '%s\037%s\036' "$1" "${2-}"; }
  d ALERT_SOUND "${ALERT_SOUND-}"
  d SINK_NAME "${SINK_NAME-}"
  d STATE_DIR "${STATE_DIR-}"
  d MAX_LOG_BYTES "${MAX_LOG_BYTES-}"
  d FILE_BAR_WIDTH "${FILE_BAR_WIDTH-}"
  d NON_TTY_ENTER_TIMEOUT "${NON_TTY_ENTER_TIMEOUT-}"
  d THEME "${THEME-}"
  d POINTS "${POINTS-}"
  d LAST_DATE "${LAST_DATE-}"
  d QUOTES "${QUOTES-}"
  for q in ${QUOTE_LIST[@]+"${QUOTE_LIST[@]}"}; do d QUOTE "$q"; done
} > "$2"
"#;

// ---------------------------------------------------------------------------
// Cleanup (signal handlers; plain functions on the global state)
// ---------------------------------------------------------------------------
fn cleanup(code: i32) {
    let s = state();
    if IN_CLEANUP.load(Ordering::SeqCst) {
        return;
    }
    IN_CLEANUP.store(true, Ordering::SeqCst);
    unsafe { ignore_signals(); }
    s.state_finalized = true;
    s.stop_alert();
    s.reset_state_files();
    s.log_event("Protocol stopped manually");
    let secondary = s.secondary;
    println!();
    println!("{}{}Interrupted.{} {}State files reset to stopped.{}",
             secondary, BOLD, NC, DIM, NC);
    s.restore_terminal();
    std::process::exit(code);
}

unsafe fn ignore_signals() {
    let mut sa: SigAction = std::mem::zeroed();
    sa.sa_handler = SIG_IGN;
    sigaction(SIGINT, &sa, std::ptr::null_mut());
    sigaction(SIGTERM, &sa, std::ptr::null_mut());
    sigaction(SIGHUP, &sa, std::ptr::null_mut());
}

extern "C" fn handle_signal(sig: c_int) {
    let code = match sig {
        SIGINT => 130,
        SIGTERM => 143,
        _ => 129,
    };
    cleanup(code);
}

fn install_signal_handlers() {
    unsafe {
        let mut sa: SigAction = std::mem::zeroed();
        sa.sa_handler = handle_signal as usize;
        // SA_RESTART deliberately NOT set: waits must wake on signals.
        sigaction(SIGINT, &sa, std::ptr::null_mut());
        sigaction(SIGTERM, &sa, std::ptr::null_mut());
        sigaction(SIGHUP, &sa, std::ptr::null_mut());
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
fn main() {
    let prog = std::env::args().next()
        .map(|a| {
            std::path::Path::new(&a).file_name()
                .map(|f| f.to_string_lossy().into_owned())
                .unwrap_or(a.clone())
        })
        .unwrap_or_else(|| "OBS".to_string());
    let mut st = new_state(prog);
    unsafe { STATE_PTR = &mut st; }

    st.parse_args(&std::env::args().skip(1).collect::<Vec<_>>());

    if let Some(cfg) = st.find_config_file() {
        st.load_config(&cfg);
    }

    // Environment variables beat the config file.
    if !st.env_alert_sound.is_empty() {
        st.alert_sound = st.env_alert_sound.clone();
    }
    if !st.env_sink_name.is_empty() {
        st.sink_name = st.env_sink_name.clone();
    }
    if !st.env_state_dir.is_empty() {
        st.state_dir = st.env_state_dir.clone();
    }
    if !st.env_max_log_bytes.is_empty() {
        if let Ok(v) = st.env_max_log_bytes.trim().parse::<i64>() {
            if v > 0 {
                st.max_log_bytes = v;
            }
        }
    }

    st.apply_quote_sources();
    st.setup_paths();
    st.select_theme();

    install_signal_handlers();
    st.setup_terminal();

    st.print_logo();
    st.setup_audio_sink();
    st.update_date_day();
    // From here on the state files may be written (and have to be reset if
    // the program dies unexpectedly).
    st.state_ready = true;
    st.log_event(&format!("Starting new study protocol: {}, {} study, {} break",
                          State::rounds_label(st.rounds),
                          st.duration_label(st.study_min),
                          st.duration_label(st.break_min)));

    println!("{}Protocol:{} {}{}{}  {}|{}  {}{}{} study  {}|{}  {}{}{} break  {}|{}  {}Theme: {}{}",
             st.secondary, NC, BOLD, State::rounds_label(st.rounds), NC, DIM,
             NC, BOLD, st.duration_label(st.study_min), NC, DIM, NC, BOLD,
             st.duration_label(st.break_min), NC, DIM, NC, BOLD,
             st.theme_name, NC);
    if !st.config_loaded.is_empty() {
        println!("{}Config: {}{}", DIM, st.config_loaded, NC);
    }
    println!();

    // The EXIT-trap equivalent: an injected panic (or a runtime error)
    // unwinds through this catch, resets the state files and exits with the
    // crash-test code.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        for round in 1..=st.rounds {
            st.run_phase("study", st.study_min, round, st.rounds);
            if round < st.rounds {
                st.run_phase("break", st.break_min, round, st.rounds);
            }
        }
    }));
    if result.is_err() {
        st.on_unexpected_death(42);
        st.restore_terminal();
        std::process::exit(42);
    }

    st.finalize_session();
    st.final_banner();
    st.restore_terminal();
    std::process::exit(0);
}
