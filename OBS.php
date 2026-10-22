<?php
//
// OBS.php - Study/break timer protocol (PHP port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: PHP 8.0+ CLI with pcntl/posix, bash (to load the bash-syntax
// config file).
//
// Usage:   php OBS.php [options] <rounds> <study_minutes> <break_minutes>
// Example: php OBS.php 5 50 10            ->  5 rounds, 50 min study, 10 min break
//          php OBS.php --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
// Stop:    Ctrl+C, or press 'q' while a phase is running
// Theme:   press Alt+T while a phase is running (see --list-themes)
//

// ---------------------------------------------------------------------------
// Color themes
// ---------------------------------------------------------------------------
const THEME_NAMES = ['Purple', 'Ocean', 'Forest', 'Sunset', 'Rose', 'Gold',
                     'Mono', 'Ice', 'Ember', 'Neon', 'Cobalt', 'Cherry'];
const THEME_PRIMARY = ["\033[1;35m", "\033[1;36m", "\033[1;32m", "\033[1;33m",
                       "\033[1;95m", "\033[1;93m", "\033[1;37m", "\033[1;96m",
                       "\033[1;91m", "\033[1;92m", "\033[1;34m", "\033[1;91m"];
const THEME_SECONDARY = ["\033[0;35m", "\033[0;34m", "\033[0;32m", "\033[0;31m",
                         "\033[0;31m", "\033[0;33m", "\033[0;37m", "\033[0;36m",
                         "\033[0;31m", "\033[0;96m", "\033[0;36m", "\033[0;35m"];

const BOLD = "\033[1m";
const DIM  = "\033[2m";
const NC   = "\033[0m";

const LOGO = ' /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/';

const DEFAULT_QUOTE_LIST = [
    'Focused effort beats scattered hours',
    'Every round finished is progress made',
    'Consistency beats intensity',
    'Start now, figure out the rest along the way',
    'A short break now means sharper focus next round',
];

const TERM_BAR_WIDTH = 24;
const BOX_INNER = 62;
$START_TIME = time();
$PROG = basename($argv !== null && count($argv) > 0 ? $argv[0] : 'OBS.php');

// ---------------------------------------------------------------------------
// Mutable program state (mirrors the reference's global variables)
// ---------------------------------------------------------------------------
$primary = THEME_PRIMARY[0];
$secondary = THEME_SECONDARY[0];
$theme_name = THEME_NAMES[0];
$theme_index = 0;
$theme_notice_until = 0;

$env_alert_sound   = getenv('ALERT_SOUND') ?: '';
$env_sink_name     = getenv('SINK_NAME') ?: '';
$env_state_dir     = getenv('STATE_DIR') ?: '';
$env_max_log_bytes = getenv('MAX_LOG_BYTES') ?: '';
$env_quotes        = getenv('QUOTES') ?: '';
$env_theme         = getenv('THEME') ?: '';

$dir = __DIR__;
$alert_sound = getenv('HOME') ? getenv('HOME') . '/Videos/Alarm/n_alarm.mp3' : '';
$sink_name = 'OBS_Alert_Sink';
$state_dir = '';
$max_log_bytes = 1048576;
$file_bar_width = 20;
$non_tty_enter_timeout = 300;
$alert_pid = 0;
$quote_list = DEFAULT_QUOTE_LIST;
$points = 0;
$last_date = '';

$config_file = '';
$dry_run = false;
$use_alert = true;
$use_sink = true;
$rounds = 0; $study_min = 0; $break_min = 0;
$cli_theme = '';
$duration_unit = 'minutes';
$seconds_per_unit = 60;
$config_theme = '';
$config_quotes = '';
$config_loaded = '';

$date_file = $day_file = $session_file = $timer_file = $log_file = null;
$progress_file = $points_file = $message_file = $next_file = null;
$overlay_file = $theme_file = null;

$session_text = '';
$remaining_str = '00:00:00';
$pct = 0;
$next_text = '';
$message_text = '';
$last_day = '';
$state_ready = false;
$state_finalized = false;
$in_cleanup = false;

$phase_label = '';
$phase_subtitle = '';
$phase_next = '';
$phase_total = 0;
$phase_elapsed = 0;
$phase_paused = false;
$phase_skipped = false;
$phase_start = 0;
$phase_paused_total = 0;
$phase_pause_at = 0;

$stdin_is_tty = false;
$saved_term = null;
$key = '';
$key_read = false;
$exit_code_for_log = null;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function now_seconds(): int {
    global $START_TIME;
    return time() - $START_TIME;
}

function set_theme(int $i): void {
    global $theme_index, $theme_name, $primary, $secondary;
    if ($i < 0 || $i >= count(THEME_NAMES)) return;
    $theme_index = $i;
    $theme_name = THEME_NAMES[$i];
    $primary = THEME_PRIMARY[$i];
    $secondary = THEME_SECONDARY[$i];
}

function theme_index_of(string $want): int {
    if ($want === '') return -1;
    $w = strtolower($want);
    foreach (THEME_NAMES as $i => $name) {
        if (strtolower($name) === $w) return $i;
    }
    return -1;
}

function save_theme(): void {
    global $theme_file, $theme_name;
    if ($theme_file) {
        @file_put_contents($theme_file, $theme_name . "\n");
    }
}

function cycle_theme(): void {
    global $theme_index, $theme_notice_until, $theme_name;
    set_theme(($theme_index + 1) % count(THEME_NAMES));
    save_theme();
    $theme_notice_until = now_seconds() + 3;
    log_event("Theme changed to: $theme_name");
}

function print_theme_list(): void {
    foreach (THEME_NAMES as $i => $name) {
        printf("  %-8s %s%s%s%s\n", $name, THEME_PRIMARY[$i],
               "\u{2588}\u{2588}\u{2588}\u{2588}", THEME_SECONDARY[$i], '');
    }
}

function fmt_hms(int $total): string {
    return sprintf('%02d:%02d:%02d', intdiv($total, 3600),
                   intdiv($total % 3600, 60), $total % 60);
}

function make_bar(int $filled, int $width, string $fill, string $empty,
                  string $head = ''): string {
    $bar = '';
    for ($i = 0; $i < $width; $i++) {
        if ($i < $filled) {
            $bar .= ($head !== '' && $i === $filled - 1) ? $head : $fill;
        } else {
            $bar .= $empty;
        }
    }
    return $bar;
}

function which(string $cmd): ?string {
    $path = getenv('PATH');
    if (!$path) return null;
    foreach (explode(PATH_SEPARATOR, $path) as $d) {
        if ($d === '') continue;
        $cand = $d . '/' . $cmd;
        if (is_executable($cand)) return $cand;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Help and argument parsing
// ---------------------------------------------------------------------------
function help_text(): string {
    global $PROG;
    $h = <<<EOT
Usage: $PROG [options] <rounds> <study_minutes> <break_minutes>

Runs a Pomodoro-style study/break loop and writes the live state to text
files that OBS Studio can display as "Text (read from file)" sources.

Options:
  -h, --help          Show this help and exit
  -c, --config FILE   Load settings from FILE (bash syntax)
  -d, --dry-run       Treat the durations as seconds (fast testing)
  -n, --no-alert      Disable the audio alert
  -s, --no-sink       Don't create or use the OBS virtual audio sink
  -t, --theme NAME    Use a color theme (see --list-themes)
      --list-themes   Show the available color themes and exit

Arguments:
  rounds             1-50   number of study rounds
  study_minutes      1-600  length of a study phase
  break_minutes      1-120  length of a break phase

Examples:
  $PROG 5 50 10           # 5 rounds, 50 min study, 10 min break
  $PROG --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  $PROG --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | \$OBS_PANEL_CONFIG | \$XDG_CONFIG_HOME/obs-study-panel/config

EOT;
    return $h;
}

function print_help(int $code, bool $to_stderr): void {
    $text = help_text();
    if ($to_stderr) fwrite(STDERR, $text);
    else fwrite(STDOUT, $text);
    exit($code);
}

function usage_error(): void {
    print_help(1, true);
}

function valid_number(string $s): bool {
    return (bool) preg_match('/^[1-9][0-9]{0,3}$/', $s);
}

function parse_args(array $argv): void {
    global $config_file, $dry_run, $use_alert, $use_sink, $cli_theme;
    global $rounds, $study_min, $break_min, $duration_unit, $seconds_per_unit;
    $rest = array_values($argv);
    $pos = [];
    while (count($rest) > 0) {
        $a = $rest[0];
        if ($a === '-h' || $a === '--help') {
            print_help(0, false);
        } elseif ($a === '-c' || $a === '--config') {
            if (count($rest) < 2) {
                fwrite(STDERR, "Error: $a needs a file argument\n");
                usage_error();
            }
            array_shift($rest);
            $config_file = array_shift($rest);
        } elseif ($a === '-d' || $a === '--dry-run') {
            $dry_run = true;
            array_shift($rest);
        } elseif ($a === '-n' || $a === '--no-alert') {
            $use_alert = false;
            array_shift($rest);
        } elseif ($a === '-s' || $a === '--no-sink') {
            $use_sink = false;
            array_shift($rest);
        } elseif ($a === '-t' || $a === '--theme') {
            if (count($rest) < 2) {
                fwrite(STDERR, "Error: $a needs a theme name\n");
                usage_error();
            }
            array_shift($rest);
            $cli_theme = array_shift($rest);
        } elseif ($a === '--list-themes') {
            print_theme_list();
            exit(0);
        } elseif ($a === '--') {
            array_shift($rest);
            $pos = array_merge($pos, $rest);
            $rest = [];
        } elseif (str_starts_with($a, '-')) {
            fwrite(STDERR, "Error: unknown option: $a\n");
            usage_error();
        } else {
            $pos = array_merge($pos, $rest);
            $rest = [];
        }
    }
    if (count($pos) !== 3) usage_error();
    foreach ($pos as $v) {
        if (!valid_number($v)) usage_error();
    }
    $rounds = (int)$pos[0];
    $study_min = (int)$pos[1];
    $break_min = (int)$pos[2];
    if ($rounds > 50) {
        fwrite(STDERR, "Error: rounds must be <= 50\n");
        usage_error();
    }
    if ($study_min > 600) {
        fwrite(STDERR, "Error: study minutes must be <= 600\n");
        usage_error();
    }
    if ($break_min > 120) {
        fwrite(STDERR, "Error: break minutes must be <= 120\n");
        usage_error();
    }
    if ($dry_run) {
        $duration_unit = 'seconds';
        $seconds_per_unit = 1;
    }
}

// ---------------------------------------------------------------------------
// Configuration file
// ---------------------------------------------------------------------------
// The config file is bash source code (exactly like the reference). It is
// interpreted by a child bash that first seeds the pre-config default knobs,
// sources the file, and then dumps the resulting values: unit separator
// 0x1F between key and value, record separator 0x1E between records. A
// sourced file that calls `exit N` terminates the child before the dump is
// written, which this program detects and mirrors.
const CONFIG_DUMP_SH = <<<'SH'
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
SH;

function find_config_file(): ?string {
    global $config_file, $dir;
    if ($config_file !== '') return $config_file;
    $p = getenv('OBS_PANEL_CONFIG');
    if ($p) return $p;
    $xdg_base = getenv('XDG_CONFIG_HOME') ?: (getenv('HOME') ?: '') . '/.config';
    $xdg = $xdg_base . '/obs-study-panel/config';
    if (is_file($xdg)) return $xdg;
    $local = $dir . '/obs-panel.conf';
    if (is_file($local)) return $local;
    return null;
}

function quotes_to_list(string $raw): void {
    global $quote_list;
    $quote_list = [];
    foreach (explode("\n", $raw) as $line) {
        $line = rtrim($line, "\r");
        if ($line !== '') $quote_list[] = $line;
    }
}

function parse_long_or(?string $v, int $dflt): int {
    if ($v === null || !preg_match('/^\d+$/', $v)) return $dflt;
    return (int)$v;
}

function load_config(string $path): void {
    global $alert_sound, $sink_name, $state_dir, $max_log_bytes, $file_bar_width;
    global $non_tty_enter_timeout, $config_theme, $points, $last_date;
    global $config_quotes, $quote_list, $config_loaded;

    if (!is_readable($path)) {
        fwrite(STDERR, "Error: config file is not readable: $path\n");
        exit(1);
    }
    // Syntax check up front, exactly like the reference.
    if (which('bash') === null) {
        fwrite(STDERR, "Error: bash is required to read the config file: $path\n");
        exit(1);
    }
    $chk_rc = 0;
    exec('bash -n ' . escapeshellarg($path) . ' 2>&1', $chk_out, $chk_rc);
    if ($chk_rc !== 0) {
        fwrite(STDERR, "Error: syntax error in config file: $path\n");
        $shown = 0;
        foreach ($chk_out as $l) {
            if (trim($l) === '') continue;
            fwrite(STDERR, $l . "\n");
            if (++$shown >= 3) break;
        }
        exit(1);
    }

    global $points;
    $dump_path = sys_get_temp_dir() . '/obs-panel-conf-' . getmypid();
    // Seed the pre-config defaults in the child environment.
    $env = getenv();
    $env['ALERT_SOUND'] = $alert_sound;
    $env['SINK_NAME'] = $sink_name;
    $env['STATE_DIR'] = '';
    $env['MAX_LOG_BYTES'] = '1048576';
    $env['FILE_BAR_WIDTH'] = '20';
    $env['NON_TTY_ENTER_TIMEOUT'] = '300';
    $env['POINTS'] = (string)$points;
    $env['LAST_DATE'] = $last_date;
    $env['QUOTES_SEED'] = implode("\x1f", $quote_list);
    // Run the seeded child bash with passthru: its stdout/stderr appear on
    // this program's own streams (like the reference's in-process source)
    // and the exit status is captured.
    $env_prefix = '';
    foreach ($env as $k => $v) $env_prefix .= $k . '=' . escapeshellarg($v) . ' ';
    $cmd = $env_prefix . 'bash -c ' . escapeshellarg(CONFIG_DUMP_SH)
         . ' obs-panel ' . escapeshellarg($path) . ' ' . escapeshellarg($dump_path);
    $c_code = 1;
    passthru($cmd, $c_code);

    $raw = is_file($dump_path) ? (string)@file_get_contents($dump_path) : '';
    @unlink($dump_path);

    if ($raw === '') {
        // The config called exit N before the dump was written.
        exit($c_code !== 0 ? $c_code : 1);
    }

    $values = [];
    $quotes = [];
    foreach (explode("\x1e", $raw) as $record) {
        if ($record === '') continue;
        $i = strpos($record, "\x1f");
        if ($i === false) continue;
        $k = substr($record, 0, $i);
        $v = substr($record, $i + 1);
        if ($k === 'QUOTE') {
            $quotes[] = $v;
        } else {
            $values[$k] = $v;
        }
    }

    if (array_key_exists('ALERT_SOUND', $values)) $alert_sound = $values['ALERT_SOUND'];
    if (array_key_exists('SINK_NAME', $values)) $sink_name = $values['SINK_NAME'];
    $state_dir = $values['STATE_DIR'] ?? '';
    $max_log_bytes = parse_long_or($values['MAX_LOG_BYTES'] ?? null, 1048576);
    if ($max_log_bytes <= 0) $max_log_bytes = 1048576;
    $w = parse_long_or($values['FILE_BAR_WIDTH'] ?? null, 20);
    $file_bar_width = ($w > 0 && $w <= 200) ? $w : 20;
    $t = parse_long_or($values['NON_TTY_ENTER_TIMEOUT'] ?? null, 300);
    $non_tty_enter_timeout = ($t > 0 && $t <= 3600) ? $t : 300;
    $config_theme = $values['THEME'] ?? '';
    $points = parse_long_or($values['POINTS'] ?? null, 0);
    $last_date = $values['LAST_DATE'] ?? '';
    $config_quotes = $values['QUOTES'] ?? '';
    $quote_list = $quotes;
    $config_loaded = $path;
}

function apply_quote_sources(): void {
    global $env_quotes, $config_quotes;
    if ($env_quotes !== '') quotes_to_list($env_quotes);
    elseif ($config_quotes !== '') quotes_to_list($config_quotes);
}

// ---------------------------------------------------------------------------
// Paths and theme selection
// ---------------------------------------------------------------------------
function setup_paths(): void {
    global $state_dir, $dir;
    global $date_file, $day_file, $session_file, $timer_file, $log_file;
    global $progress_file, $points_file, $message_file, $next_file;
    global $overlay_file, $theme_file;
    if ($state_dir === '') $state_dir = $dir;
    if (!is_dir($state_dir) && !@mkdir($state_dir, 0755, true)) {
        fwrite(STDERR, "Error: cannot create state dir: $state_dir\n");
        exit(1);
    }
    $j = function (string $n): string {
        global $state_dir;
        return $state_dir . '/' . $n;
    };
    $date_file = $j('date.txt');
    $day_file = $j('day.txt');
    $session_file = $j('session.txt');
    $timer_file = $j('timer.txt');
    $log_file = $j('log.txt');
    $progress_file = $j('progress.txt');
    $points_file = $j('points.txt');
    $message_file = $j('message.txt');
    $next_file = $j('next.txt');
    $overlay_file = $j('overlay.txt');
    $theme_file = $j('theme.txt');
}

function select_theme(): void {
    global $cli_theme, $env_theme, $config_theme, $theme_file, $theme_name;
    $request = $cli_theme;
    if ($request === '' && $env_theme !== '') $request = $env_theme;
    if ($request === '' && $config_theme !== '') $request = $config_theme;
    if ($request === '' && $theme_file && is_file($theme_file)) {
        $lines = @file($theme_file, FILE_IGNORE_NEW_LINES);
        if ($lines !== false && count($lines) > 0) $request = $lines[0];
    }
    if ($request === '') return;
    $idx = theme_index_of($request);
    if ($idx < 0) {
        fwrite(STDERR, "Warning: unknown theme '$request', using $theme_name\n");
    } else {
        set_theme($idx);
    }
}

// ---------------------------------------------------------------------------
// OBS state files
// ---------------------------------------------------------------------------
function write_state(string $path, string $text): void {
    @file_put_contents($path, $text . "\n");
}

function update_date_day(): void {
    global $last_date, $last_day, $date_file, $day_file;
    $d = date('Y-m-d');
    if ($d === $last_date) return;
    $last_date = $d;
    $last_day = date('l');
    write_state($date_file, $d);
    write_state($day_file, $last_day);
}

function sync_state(): void {
    update_date_day();
    publish_state();
}

function publish_state(): void {
    global $pct, $file_bar_width, $session_text, $remaining_str, $points;
    global $next_text, $message_text, $last_date, $last_day;
    global $session_file, $timer_file, $points_file, $next_file;
    global $message_file, $progress_file, $overlay_file;
    $filled = intdiv($pct * $file_bar_width, 100);
    $bar = make_bar($filled, $file_bar_width, '#', '-');
    $pct_s = sprintf('%3d%%', $pct);

    write_state($session_file, $session_text);
    write_state($timer_file, $remaining_str);
    write_state($points_file, (string)$points);
    write_state($next_file, $next_text);
    write_state($message_file, $message_text);
    write_state($progress_file, "[$bar] $pct_s");

    $overlay = "$last_date $last_day\n$session_text\n$remaining_str\n"
             . "[$bar] $pct_s\nPts: $points\nNext: $next_text\n";
    if ($message_text !== '') $overlay .= $message_text . "\n";
    @file_put_contents($overlay_file, $overlay);
}

function rotate_log_if_needed(): void {
    global $log_file, $max_log_bytes;
    $size = @filesize($log_file);
    if ($size !== false && $size >= $max_log_bytes) {
        if (@rename($log_file, $log_file . '.1')) {
            @file_put_contents($log_file, '');
        }
    }
}

function log_event(string $msg): void {
    rotate_log_if_needed();
    global $log_file;
    @file_put_contents($log_file,
        '[' . date('Y-m-d H:i:s') . "] $msg\n", FILE_APPEND);
}

// ---------------------------------------------------------------------------
// Audio alerts
// ---------------------------------------------------------------------------
function sink_is_ready(): bool {
    global $sink_name;
    if (which('pactl') === null) return false;
    exec('pactl list short sinks 2>/dev/null', $out, $rc);
    if ($rc !== 0) return false;
    foreach ($out as $line) {
        $fields = preg_split('/\s+/', trim($line));
        if (count($fields) > 1 && $fields[1] === $sink_name) return true;
    }
    return false;
}

function setup_audio_sink(): void {
    global $use_sink, $sink_name;
    if (!$use_sink) return;
    if (which('pactl') === null) return;
    if (sink_is_ready()) return;
    $cmd = 'pactl load-module module-null-sink sink_name='
         . escapeshellarg($sink_name)
         . ' sink_properties=device.description=' . escapeshellarg($sink_name)
         . ' >/dev/null 2>&1';
    exec($cmd);
}

function stop_alert(): void {
    global $alert_pid;
    if ($alert_pid > 0) {
        posix_kill($alert_pid, SIGTERM);
        $alert_pid = 0;
    }
}

function play_alert(): void {
    global $use_alert, $alert_sound, $sink_name, $use_sink, $alert_pid;
    global $secondary;
    if (!$use_alert) return;
    stop_alert();
    if ($alert_sound === '' || !is_file($alert_sound)) {
        $shown = $alert_sound !== '' ? $alert_sound : 'none';
        printf("%s(alert file not found: %s)%s\n", DIM, $shown, NC);
        return;
    }

    if (which('mpv') !== null) $player = ['mpv', '--no-video', '--volume=70'];
    elseif (which('paplay') !== null) $player = ['paplay'];
    elseif (which('ffplay') !== null) $player = ['ffplay', '-nodisp', '-autoexit'];
    elseif (which('cvlc') !== null) $player = ['cvlc', '--play-and-exit', '--no-video', '--volume=70'];
    else {
        printf("%s(no audio player found - install mpv / paplay / ffplay)%s\n", DIM, NC);
        return;
    }

    if ($use_sink && !sink_is_ready()) setup_audio_sink();

    $full = array_merge($player, [$alert_sound]);
    $cmd_parts = [];
    foreach ($full as $a) $cmd_parts[] = escapeshellarg($a);
    if ($use_sink && sink_is_ready()) {
        $cmd = 'PULSE_SINK=' . escapeshellarg($sink_name) . ' '
             . implode(' ', $cmd_parts) . ' >/dev/null 2>&1 &';
    } else {
        $cmd = implode(' ', $cmd_parts) . ' >/dev/null 2>&1 &';
    }
    exec($cmd);
    exec("echo $! > /dev/null");  // shell pid not tracked: not exact

    if ($use_sink && sink_is_ready()) {
        printf("%s-> alert on OBS sink (%s)%s\n", DIM, $sink_name, NC);
    } else {
        printf("%s-> alert on default device (OBS sink unavailable)%s\n",
               $secondary, NC);
    }
}

// ---------------------------------------------------------------------------
// Keyboard input
// ---------------------------------------------------------------------------
function setup_terminal(): void {
    global $stdin_is_tty, $saved_term;
    $stdin_is_tty = function_exists('posix_isatty') ? posix_isatty(STDIN) : false;
    if (!$stdin_is_tty) return;
    $saved_term = trim((string)shell_exec('stty -g < /dev/tty 2>/dev/null'));
    system('stty -icanon -echo < /dev/tty 2>/dev/null');
}

function restore_terminal(): void {
    global $stdin_is_tty, $saved_term;
    if (!$stdin_is_tty) return;
    if ($saved_term !== null && $saved_term !== '') {
        system("stty $saved_term < /dev/tty 2>/dev/null");
    } else {
        system('stty sane < /dev/tty 2>/dev/null');
    }
    $saved_term = null;
}

/** One byte with a timeout (seconds, may be fractional).
 *  Returns the byte string, null on timeout, '' on EOF. */
function read_byte_timeout(float $timeout): ?string {
    $read = [STDIN];
    $write = $except = null;
    $sec = (int)floor($timeout);
    $usec = (int)(($timeout - $sec) * 1000000);
    $rc = stream_select($read, $write, $except, $sec, $usec);
    if ($rc === false || $rc === 0) return null;
    $data = fread(STDIN, 1);
    return ($data === false || $data === '') ? '' : $data;
}

function wait_key(float $timeout): void {
    global $key, $key_read, $stdin_is_tty;
    $key = '';
    $key_read = false;
    if (!$stdin_is_tty) {
        usleep((int)($timeout * 1000000));
        return;
    }
    $b = read_byte_timeout($timeout);
    if ($b === null || $b === '') return;
    $key_read = true;
    if ($b === "\x1b") {
        $nxt = read_byte_timeout(0.3);
        if ($nxt === 't' || $nxt === 'T') $key = 'alt-t';
    } else {
        $key = $b;
    }
}

function discard_pending_input(): void {
    global $stdin_is_tty;
    if (!$stdin_is_tty) return;
    while (true) {
        $b = read_byte_timeout(0.01);
        if ($b === null || $b === '') return;
    }
}

function wait_for_enter(): void {
    global $stdin_is_tty, $non_tty_enter_timeout;
    if ($stdin_is_tty) {
        while (true) {
            $b = read_byte_timeout(1);
            if ($b === null) {
                update_date_day();
                continue;
            }
            if ($b === '' || $b === "\n") return;
        }
    }
    $waited = 0;
    while ($waited < $non_tty_enter_timeout) {
        $slice_start = microtime(true);
        while (true) {
            $elapsed = microtime(true) - $slice_start;
            if ($elapsed >= 5.0) {
                $waited += 5;
                break;
            }
            $b = read_byte_timeout(5.0 - $elapsed);
            if ($b === '') return;               // EOF
            if ($b === null) { $waited += 5; break; }
            if ($b === "\n") return;
        }
    }
}

// ---------------------------------------------------------------------------
// Status / progress UI
// ---------------------------------------------------------------------------
function phase_color(string $label): string {
    global $primary, $secondary;
    return $label === 'STUDY' ? $primary : $secondary;
}

function duration_label(int $n): string {
    global $duration_unit;
    if ($n === 1) return $duration_unit === 'seconds' ? '1 second' : '1 minute';
    return "$n $duration_unit";
}

function rounds_label(int $n): string {
    return $n === 1 ? '1 round' : "$n rounds";
}

function draw_status(string $label, int $round, int $total_rounds, int $elapsed,
                     int $total, int $paused): void {
    global $pct, $remaining_str, $points, $primary, $theme_notice_until, $theme_name;
    $filled = $total > 0 ? intdiv($elapsed * TERM_BAR_WIDTH, $total) : 0;
    if ($filled > TERM_BAR_WIDTH) $filled = TERM_BAR_WIDTH;
    $bar = make_bar($filled, TERM_BAR_WIDTH, '=', ' ', '>');
    $color = phase_color($label);
    $flag = '';
    if ($paused) $flag = $primary . ' PAUSED' . NC;
    if (now_seconds() < $theme_notice_until) {
        $flag .= '  ' . DIM . "Theme: $theme_name" . NC;
    }
    print "\r\033[K";
    printf("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
           BOLD, $color, $label, NC, $round, $total_rounds,
           $color, $bar, NC, $pct, $remaining_str,
           $primary, $points, NC, $flag);
}

function box_row(string $color, string $plain, string $styled): void {
    $pad = BOX_INNER - strlen($plain);
    if ($pad < 0) $pad = 0;
    printf("%s\u{2551}%s%s%s\u{2551}%s\n", $color, $styled,
           str_repeat(' ', $pad), $color, NC);
}

function phase_header(string $label, int $round, int $total, int $minutes,
                      string $subtitle): void {
    global $stdin_is_tty;
    if (mb_strlen($subtitle) > BOX_INNER - 4) {
        $subtitle = mb_substr($subtitle, 0, BOX_INNER - 4);
    }
    $color = phase_color($label);
    $bar = str_repeat("\u{2550}", BOX_INNER);
    $dur = duration_label($minutes);
    $info = sprintf('%s  \u{b7}  Round %d / %d  \u{b7}  %s', $label, $round, $total, $dur);
    $styled1 = sprintf('  %s%s%s%s  \u{b7}  Round %d / %d  \u{b7}  %s',
                       BOLD, $label, NC, $color, $round, $total, $dur);
    print "\n";
    printf("%s\u{2554}%s\u{2557}%s\n", $color, $bar, NC);
    box_row($color, "  $info", $styled1);
    box_row($color, "  $subtitle", '  ' . DIM . $subtitle . NC . $color);
    if ($stdin_is_tty) {
        $keys = "  p pause  \u{b7}  s skip  \u{b7}  q quit  \u{b7}  Alt+T theme";
        box_row($color, $keys, DIM . $keys . NC . $color);
    }
    printf("%s\u{255a}%s\u{255d}%s\n", $color, $bar, NC);
    print "\n";
}

function show_completion(string $phase, int $round, int $total_rounds,
                         string $next_phase, bool $skipped): void {
    global $points, $primary;
    $width = 60;
    $line = str_repeat('=', $width);
    $title = $skipped ? 'PHASE SKIPPED'
            : ($phase === 'STUDY' ? 'STUDY SESSION COMPLETE' : 'BREAK COMPLETE');
    $color = phase_color($phase);
    $pad = intdiv($width + strlen($title), 2);
    print "\n";
    printf("%s%s%s\n", $color, $line, NC);
    printf("%s%s%s%s\n", $color, str_repeat(' ', $pad), $title, NC);
    printf("%s%s%s\n", $color, $line, NC);
    print "\n";
    printf("  Round:   %s%d%s / %d\n", BOLD, $round, NC, $total_rounds);
    printf("  Points:  %s%d%s\n", $primary, $points, NC);
    print "\n";
    if ($next_phase === 'None') {
        printf("  Next:    %sSession complete%s\n", DIM, NC);
    } else {
        printf("  Next:    %s%s%s\n", BOLD, $next_phase, NC);
    }
    print "\n";
    printf("  %sPress Enter to continue...%s", $primary, NC);
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------
function phase_prepare(string $ptype, int $minutes, int $round,
                       int $total_rounds): void {
    global $phase_label, $phase_subtitle, $phase_next, $phase_total;
    global $phase_elapsed, $phase_paused, $phase_skipped, $phase_start;
    global $phase_paused_total, $phase_pause_at, $quote_list;
    global $session_text, $remaining_str, $pct, $next_text, $message_text;
    global $study_min, $break_min, $seconds_per_unit;
    if ($ptype === 'study') {
        $phase_label = 'STUDY';
        if (count($quote_list) > 0) {
            $phase_subtitle = $quote_list[array_rand($quote_list)];
        } else {
            $phase_subtitle = 'Stay focused.';
        }
    } else {
        $phase_label = 'BREAK';
        $phase_subtitle = 'Relax and recharge.';
    }

    if ($ptype === 'study') {
        $phase_next = $round < $total_rounds
            ? 'Break (' . duration_label($break_min) . ')' : 'None';
    } else {
        $phase_next = 'Study (' . duration_label($study_min) . ')';
    }

    $phase_total = $minutes * $seconds_per_unit;
    $phase_elapsed = 0;
    $phase_paused = false;
    $phase_skipped = false;
    $phase_start = now_seconds();
    $phase_paused_total = 0;
    $phase_pause_at = 0;

    $session_text = "$phase_label $round/$total_rounds";
    $remaining_str = fmt_hms($phase_total);
    $pct = 0;
    $next_text = $phase_next === 'None' ? 'Session complete' : $phase_next;
    $message_text = $phase_subtitle;

    log_event("Start: $phase_label $round/$total_rounds ("
              . duration_label($minutes) . ')');
    phase_header($phase_label, $round, $total_rounds, $minutes, $phase_subtitle);
    sync_state();
}

function phase_handle_key(int $round, int $total_rounds): void {
    global $key, $phase_paused, $phase_paused_total, $phase_pause_at;
    global $phase_skipped, $phase_label;
    if ($key === 'p' || $key === 'P' || $key === ' ') {
        if ($phase_paused) {
            $phase_paused_total += now_seconds() - $phase_pause_at;
            $phase_paused = false;
            log_event("Resumed: $phase_label $round/$total_rounds");
        } else {
            $phase_paused = true;
            $phase_pause_at = now_seconds();
            log_event("Paused: $phase_label $round/$total_rounds");
        }
    } elseif ($key === 's' || $key === 'S') {
        $phase_skipped = true;
        log_event("Skipped: $phase_label $round/$total_rounds");
    } elseif ($key === 'q' || $key === 'Q') {
        log_event('Quit requested by user');
        cleanup(0);
    } elseif ($key === 'alt-t') {
        cycle_theme();
    }
}

function phase_count(int $round, int $total_rounds): void {
    global $phase_elapsed, $phase_total, $remaining_str, $pct, $session_text;
    global $phase_paused, $phase_skipped, $phase_label, $key_read;
    global $phase_start, $phase_paused_total;
    while ($phase_elapsed < $phase_total) {
        $remaining = $phase_total - $phase_elapsed;
        if ($remaining < 0) $remaining = 0;
        $remaining_str = fmt_hms($remaining);
        $pct = $phase_total > 0 ? intdiv($phase_elapsed * 100, $phase_total) : 0;
        if ($pct > 100) $pct = 100;
        $session_text = "$phase_label $round/$total_rounds";
        if ($phase_paused) $session_text .= ' (PAUSED)';

        sync_state();
        draw_status($phase_label, $round, $total_rounds, $phase_elapsed,
                    $phase_total, $phase_paused ? 1 : 0);

        wait_key(1);
        if ($key_read) {
            phase_handle_key($round, $total_rounds);
            if ($phase_skipped) break;
        }
        // CRASH-INJECT-POINT
        if (!$phase_paused) {
            $phase_elapsed = now_seconds() - $phase_start - $phase_paused_total;
        }
    }
}

function phase_finish(int $round, int $total_rounds): void {
    global $phase_skipped, $session_text, $phase_label, $pct, $points;
    global $remaining_str, $phase_elapsed, $phase_total, $phase_next;
    if ($phase_skipped) {
        $session_text = "$phase_label $round/$total_rounds (SKIPPED)";
    } else {
        $pct = 100;
        $points += 1;
    }
    $remaining_str = '00:00:00';
    sync_state();
    draw_status($phase_label, $round, $total_rounds, $phase_elapsed,
                $phase_total, 0);
    print "\n";
    log_event("End: $phase_label $round/$total_rounds");

    play_alert();

    discard_pending_input();
    show_completion($phase_label, $round, $total_rounds, $phase_next,
                    $phase_skipped);
    wait_for_enter();
    stop_alert();
    print "\n";
}

function run_phase(string $ptype, int $minutes, int $round, int $total_rounds): void {
    phase_prepare($ptype, $minutes, $round, $total_rounds);
    phase_count($round, $total_rounds);
    phase_finish($round, $total_rounds);
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------
function reset_state_files(): void {
    global $session_text, $remaining_str, $pct, $next_text;
    $session_text = 'stopped';
    $remaining_str = '00:00:00';
    $pct = 0;
    $next_text = '';
    sync_state();
}

function cleanup(int $code): void {
    global $in_cleanup, $state_finalized, $secondary;
    if ($in_cleanup) return;
    $in_cleanup = true;
    pcntl_signal(SIGINT, SIG_IGN);
    pcntl_signal(SIGTERM, SIG_IGN);
    pcntl_signal(SIGHUP, SIG_IGN);
    $state_finalized = true;
    stop_alert();
    try {
        reset_state_files();
        log_event('Protocol stopped manually');
        print "\n";
        printf("%s%sInterrupted.%s %sState files reset to stopped.%s\n",
               $secondary, BOLD, NC, DIM, NC);
    } catch (Throwable $t) {
        // best effort
    }
    restore_terminal();
    exit($code);
}

function on_unexpected_death(int $rc): void {
    global $state_ready, $state_finalized;
    if (!$state_ready || $state_finalized) return;
    $state_finalized = true;
    stop_alert();
    try {
        reset_state_files();
        log_event("Protocol ended unexpectedly (exit $rc)");
    } catch (Throwable $t) {
        // best effort
    }
}

/** Used by the crash-injection test: records the code for the shutdown
 *  handler's log message, then exits with it. */
function crash_exit(int $code): void {
    global $exit_code_for_log;
    $exit_code_for_log = $code;
    exit($code);
}

// The EXIT-trap equivalent: runs on exit() and on fatal errors; the exit
// code itself is preserved (we only read it for the log line).
register_shutdown_function(function () {
    global $exit_code_for_log;
    $rc = $exit_code_for_log !== null ? $exit_code_for_log
         : (http_response_code() ?: 1);
    on_unexpected_death(is_int($rc) ? $rc : 1);
    restore_terminal();
});

// Signal handling: conventional exit codes 128 + signal number.
if (function_exists('pcntl_signal')) {
    pcntl_async_signals(true);
    pcntl_signal(SIGINT, function () { cleanup(130); });
    pcntl_signal(SIGTERM, function () { cleanup(143); });
    pcntl_signal(SIGHUP, function () { cleanup(129); });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function finalize_session(): void {
    global $session_text, $remaining_str, $pct, $next_text;
    global $state_finalized, $points;
    $session_text = 'session complete';
    $remaining_str = '00:00:00';
    $pct = 100;
    $next_text = '';
    sync_state();
    $state_finalized = true;
    log_event("Protocol complete - total points: $points");
}

function final_banner(): void {
    global $primary, $rounds, $points;
    $banner_width = 60;
    $title = 'ALL SESSIONS COMPLETE';
    $inner = $banner_width - 2;
    $pad = intdiv($inner - strlen($title), 2);
    $border = str_repeat('#', $banner_width);
    print "\n";
    printf("%s%s%s\n", $primary, $border, NC);
    printf("%s#%s%s%s%s%s%s#%s\n", $primary, NC,
           str_repeat(' ', $pad), BOLD, $title,
           str_repeat(' ', $inner - $pad - strlen($title)), NC, $primary);
    printf("%s%s%s\n", $primary, $border, NC);
    print "\n";
    printf("  %sTotal Rounds:%s  %s%d%s\n", BOLD, NC, $primary, $rounds, NC);
    printf("  %sTotal Points:%s %s%d%s\n", BOLD, NC, $primary, $points, NC);
    print "\n";
    printf("%s%sGreat work!%s %sExiting.%s\n", $primary, BOLD, NC, DIM, NC);
}

function print_logo(): void {
    global $primary;
    print $primary . "\n";
    print LOGO . "\n";
    print NC . "\n";
    printf("%s%s     Study / Break Timer Protocol%s\n", $primary, BOLD, NC);
    printf("%s\u{2500}\u{2500} live state written to date \u{b7} day \u{b7} " .
           "session \u{b7} timer \u{b7} log%s\n", DIM, NC);
    print "\n";
}

parse_args(array_slice($argv ?? [], 1));

$cfg = find_config_file();
if ($cfg !== null) load_config($cfg);

// Environment variables beat the config file.
if ($env_alert_sound !== '') $alert_sound = $env_alert_sound;
if ($env_sink_name !== '') $sink_name = $env_sink_name;
if ($env_state_dir !== '') $state_dir = $env_state_dir;
if ($env_max_log_bytes !== '' && preg_match('/^\d+$/', $env_max_log_bytes)
    && (int)$env_max_log_bytes > 0) {
    $max_log_bytes = (int)$env_max_log_bytes;
}

apply_quote_sources();
setup_paths();
select_theme();
setup_terminal();

print_logo();
setup_audio_sink();
update_date_day();
// From here on the state files may be written (and have to be reset if the
// program dies unexpectedly).
$state_ready = true;
log_event('Starting new study protocol: ' . rounds_label($rounds) . ', '
          . duration_label($study_min) . ' study, '
          . duration_label($break_min) . ' break');

printf("%sProtocol:%s %s%s%s  %s|%s  %s%s%s study  %s|%s  %s%s%s break  " .
       "%s|%s  %sTheme: %s%s\n",
       $secondary, NC, BOLD, rounds_label($rounds), NC, DIM, NC,
       BOLD, duration_label($study_min), NC, DIM, NC, BOLD,
       duration_label($break_min), NC, DIM, NC, BOLD, $theme_name, NC);
if ($config_loaded !== '') {
    printf("%sConfig: %s%s\n", DIM, $config_loaded, NC);
}
print "\n";

for ($round = 1; $round <= $rounds; $round++) {
    run_phase('study', $study_min, $round, $rounds);
    if ($round < $rounds) run_phase('break', $break_min, $round, $rounds);
}

finalize_session();
final_banner();
restore_terminal();
exit(0);
