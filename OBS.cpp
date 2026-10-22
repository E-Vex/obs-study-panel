//
// OBS.cpp - Study/break timer protocol (C++ port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: C++17 + POSIX (termios, select, fork/exec), bash (to load the
// bash-syntax config file).
//
// Build: g++ -O2 -std=c++17 -o OBS OBS.cpp
// Usage: ./OBS [options] <rounds> <study_minutes> <break_minutes>
// Stop:  Ctrl+C, or press 'q' while a phase is running
// Theme: press Alt+T while a phase is running (see --list-themes)
//
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <cassert>
#include <cctype>
#include <cstdarg>
#include <chrono>
#include <cstdio>
#include <map>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static std::string PROG;
static time_t START_TIME;

/* ---------------------------------------------------------------------------
 * Color themes
 * ------------------------------------------------------------------------ */
static const char *THEME_NAMES[] = {
    "Purple", "Ocean", "Forest", "Sunset", "Rose", "Gold",
    "Mono", "Ice", "Ember", "Neon", "Cobalt", "Cherry"
};
static const char *THEME_PRIMARY[] = {
    "\033[1;35m", "\033[1;36m", "\033[1;32m", "\033[1;33m", "\033[1;95m",
    "\033[1;93m", "\033[1;37m", "\033[1;96m", "\033[1;91m", "\033[1;92m",
    "\033[1;34m", "\033[1;91m"
};
static const char *THEME_SECONDARY[] = {
    "\033[0;35m", "\033[0;34m", "\033[0;32m", "\033[0;31m", "\033[0;31m",
    "\033[0;33m", "\033[0;37m", "\033[0;36m", "\033[0;31m", "\033[0;96m",
    "\033[0;36m", "\033[0;35m"
};
#define THEME_COUNT 12

#define BOLD "\033[1m"
#define DIM  "\033[2m"
#define NC   "\033[0m"

static const char *LOGO =
    " /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$\n"
    "| $$_____/     | $$   | $$| $$_____/| $$  / $$\n"
    "| $$           | $$   | $$| $$      |  $$/ $$/\n"
    "| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \\  $$$$/\n"
    "| $$__/|______/ \\  $$ $$/ | $$__/     >$$  $$\n"
    "| $$             \\  $$$/  | $$       /$$/\\  $$\n"
    "| $$$$$$$$        \\  $/   | $$$$$$$$| $$  \\ $$\n"
    "|________/         \\_/    |________/|__/  |__/";

static const std::vector<std::string> DEFAULT_QUOTE_LIST = {
    "Focused effort beats scattered hours",
    "Every round finished is progress made",
    "Consistency beats intensity",
    "Start now, figure out the rest along the way",
    "A short break now means sharper focus next round",
};

static const char *WEEKDAYS[] = { "Sunday", "Monday", "Tuesday", "Wednesday",
    "Thursday", "Friday", "Saturday" };

/* ---------------------------------------------------------------------------
 * Mutable program state (mirrors the reference's global variables)
 * ------------------------------------------------------------------------ */
static std::string g_primary, g_secondary, g_theme_name;
static int g_theme_index = 0;
static long g_theme_notice_until = 0;

static std::string g_env_alert_sound, g_env_sink_name, g_env_state_dir;
static std::string g_env_max_log_bytes, g_env_quotes, g_env_theme;

static std::string g_dir;
static std::string g_alert_sound;
static std::string g_sink_name = "OBS_Alert_Sink";
static std::string g_state_dir;
static long g_max_log_bytes = 1048576;
static long g_file_bar_width = 20;
static long g_non_tty_enter_timeout = 300;
static pid_t g_alert_pid = 0;
static std::vector<std::string> g_quote_list = DEFAULT_QUOTE_LIST;
static long g_points = 0;
static std::string g_last_date;

static std::string g_config_file;
static bool g_dry_run = false;
static bool g_use_alert = true;
static bool g_use_sink = true;
static int g_rounds = 0, g_study_min = 0, g_break_min = 0;
static std::string g_cli_theme;
static std::string g_duration_unit = "minutes";
static int g_seconds_per_unit = 60;
static std::string g_config_theme, g_config_quotes, g_config_loaded;

static std::string g_date_file, g_day_file, g_session_file, g_timer_file;
static std::string g_log_file, g_progress_file, g_points_file, g_message_file;
static std::string g_next_file, g_overlay_file, g_theme_file;

static std::string g_session_text;
static std::string g_remaining_str = "00:00:00";
static int g_pct = 0;
static std::string g_next_text;
static std::string g_message_text;
static std::string g_last_day;
static bool g_state_ready = false;
static bool g_state_finalized = false;
static bool g_in_cleanup = false;

static std::string g_phase_label, g_phase_subtitle, g_phase_next;
static long g_phase_total = 0;
static long g_phase_elapsed = 0;
static bool g_phase_paused = false;
static bool g_phase_skipped = false;
static long g_phase_start = 0;
static long g_phase_paused_total = 0;
static long g_phase_pause_at = 0;

static bool g_stdin_is_tty = false;
static struct termios g_term_saved;
static bool g_term_saved_ok = false;
static std::string g_key;
static bool g_key_read = false;

#define TERM_BAR_WIDTH 24
#define BOX_INNER 62

/* Forward declarations */
static void log_event(const std::string &msg);
static void publish_state();
static void cleanup(int code);

/* ---------------------------------------------------------------------------
 * Small helpers
 * ------------------------------------------------------------------------ */
static long now_seconds() {
    return (long)(time(nullptr) - START_TIME);
}

static std::string fmt(const char *pattern, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, pattern);
    vsnprintf(buf, sizeof buf, pattern, ap);
    va_end(ap);
    return std::string(buf);
}

static void write_state(const std::string &path, const std::string &text) {
    std::ofstream fh(path);
    if (!fh) return;
    fh << text << "\n";
}

static void mkdirs(const std::string &path) {
    std::string tmp = path;
    if (tmp.empty()) return;
    for (size_t i = 1; i < tmp.size(); i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            mkdir(tmp.c_str(), 0755);
            tmp[i] = '/';
        }
    }
    mkdir(tmp.c_str(), 0755);
}

static bool which(const std::string &cmd) {
    const char *path_env = getenv("PATH");
    if (!path_env) return false;
    std::string dirs(path_env);
    size_t start = 0;
    while (start <= dirs.size()) {
        size_t end = dirs.find(':', start);
        std::string dir = dirs.substr(start, end == std::string::npos
                                       ? std::string::npos : end - start);
        std::string full = dir + "/" + cmd;
        if (access(full.c_str(), X_OK) == 0) return true;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return false;
}

static void set_theme(int i) {
    if (i < 0 || i >= THEME_COUNT) return;
    g_theme_index = i;
    g_theme_name = THEME_NAMES[i];
    g_primary = THEME_PRIMARY[i];
    g_secondary = THEME_SECONDARY[i];
}

static int theme_index(const std::string &want) {
    if (want.empty()) return -1;
    for (int i = 0; i < THEME_COUNT; i++) {
        if (strcasecmp(THEME_NAMES[i], want.c_str()) == 0) return i;
    }
    return -1;
}

static void save_theme() {
    if (!g_theme_file.empty()) write_state(g_theme_file, g_theme_name);
}

static void cycle_theme() {
    set_theme((g_theme_index + 1) % THEME_COUNT);
    save_theme();
    g_theme_notice_until = now_seconds() + 3;
    log_event(fmt("Theme changed to: %s", g_theme_name.c_str()));
}

static void print_theme_list() {
    for (int i = 0; i < THEME_COUNT; i++) {
        printf("  %-8s %s\xE2\x96\x88\xE2\x96\x88\xE2\x96\x88\xE2\x96\x88%s\n",
               THEME_NAMES[i], THEME_PRIMARY[i], THEME_SECONDARY[i]);
    }
}

static std::string fmt_hms(long total) {
    return fmt("%02ld:%02ld:%02ld", total / 3600, (total % 3600) / 60,
               total % 60);
}

static std::string make_bar(long filled, long width, const std::string &fill,
                            const std::string &empty, const std::string &head = "") {
    std::string out;
    out.reserve((size_t)width * 3);
    for (long i = 0; i < width; i++) {
        if (i < filled) {
            out += (!head.empty() && i == filled - 1) ? head : fill;
        } else {
            out += empty;
        }
    }
    return out;
}

/* ---------------------------------------------------------------------------
 * Help and argument parsing
 * ------------------------------------------------------------------------ */
static std::string help_text() {
    return fmt(
        "Usage: %s [options] <rounds> <study_minutes> <break_minutes>\n"
        "\n"
        "Runs a Pomodoro-style study/break loop and writes the live state to text\n"
        "files that OBS Studio can display as \"Text (read from file)\" sources.\n"
        "\n"
        "Options:\n"
        "  -h, --help          Show this help and exit\n"
        "  -c, --config FILE   Load settings from FILE (bash syntax)\n"
        "  -d, --dry-run       Treat the durations as seconds (fast testing)\n"
        "  -n, --no-alert      Disable the audio alert\n"
        "  -s, --no-sink       Don't create or use the OBS virtual audio sink\n"
        "  -t, --theme NAME    Use a color theme (see --list-themes)\n"
        "      --list-themes   Show the available color themes and exit\n"
        "\n"
        "Arguments:\n"
        "  rounds             1-50   number of study rounds\n"
        "  study_minutes      1-600  length of a study phase\n"
        "  break_minutes      1-120  length of a break phase\n"
        "\n"
        "Examples:\n"
        "  %s 5 50 10           # 5 rounds, 50 min study, 10 min break\n"
        "  %s --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break\n"
        "  %s --theme Ocean 5 50 10\n"
        "\n"
        "Keys (while a phase is running):\n"
        "  p / space   pause and resume the current phase\n"
        "  s           skip the rest of the current phase\n"
        "  q           quit the session\n"
        "  Alt+T       switch to the next color theme\n"
        "\n"
        "Environment overrides:\n"
        "  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME\n"
        "\n"
        "Config file (first one that exists):\n"
        "  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config\n",
        PROG.c_str(), PROG.c_str(), PROG.c_str(), PROG.c_str());
}

static void print_help(int code, FILE *stream) {
    fputs(help_text().c_str(), stream);
    exit(code);
}

static void usage_error() {
    print_help(1, stderr);
}

static bool valid_number(const std::string &s) {
    if (s.empty() || s.size() > 4) return false;
    if (s[0] < '1' || s[0] > '9') return false;
    for (char c : s) {
        if (c < '0' || c > '9') return false;
    }
    return true;
}

static void parse_args(int argc, char **argv) {
    int i = 1;
    std::vector<std::string> pos;
    while (i < argc) {
        std::string a = argv[i];
        if (a == "-h" || a == "--help") {
            print_help(0, stdout);
        } else if (a == "-c" || a == "--config") {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: %s needs a file argument\n", a.c_str());
                usage_error();
            }
            g_config_file = argv[i + 1];
            i += 2;
        } else if (a == "-d" || a == "--dry-run") {
            g_dry_run = true; i++;
        } else if (a == "-n" || a == "--no-alert") {
            g_use_alert = false; i++;
        } else if (a == "-s" || a == "--no-sink") {
            g_use_sink = false; i++;
        } else if (a == "-t" || a == "--theme") {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: %s needs a theme name\n", a.c_str());
                usage_error();
            }
            g_cli_theme = argv[i + 1];
            i += 2;
        } else if (a == "--list-themes") {
            print_theme_list();
            exit(0);
        } else if (a == "--") {
            i++;
            for (; i < argc; i++) pos.push_back(argv[i]);
            break;
        } else if (!a.empty() && a[0] == '-') {
            fprintf(stderr, "Error: unknown option: %s\n", a.c_str());
            usage_error();
        } else {
            for (; i < argc; i++) pos.push_back(argv[i]);
            break;
        }
    }
    if (pos.size() != 3) usage_error();
    for (const auto &v : pos) {
        if (!valid_number(v)) usage_error();
    }
    g_rounds = atoi(pos[0].c_str());
    g_study_min = atoi(pos[1].c_str());
    g_break_min = atoi(pos[2].c_str());
    if (g_rounds > 50) {
        fprintf(stderr, "Error: rounds must be <= 50\n");
        usage_error();
    }
    if (g_study_min > 600) {
        fprintf(stderr, "Error: study minutes must be <= 600\n");
        usage_error();
    }
    if (g_break_min > 120) {
        fprintf(stderr, "Error: break minutes must be <= 120\n");
        usage_error();
    }
    if (g_dry_run) {
        g_duration_unit = "seconds";
        g_seconds_per_unit = 1;
    }
}

/* ---------------------------------------------------------------------------
 * Configuration file
 * ------------------------------------------------------------------------ */
/* The config file is bash source code (exactly like the reference). It is
 * interpreted by a child bash that first seeds the pre-config default knobs,
 * sources the file, and then dumps the resulting values: unit separator
 * 0x1F between key and value, record separator 0x1E between records. A
 * sourced file that calls `exit N` terminates the child before the dump is
 * written, which this program detects and mirrors. */
static const char *CONFIG_DUMP_SH =
    "set -u\n"
    "IFS=$'\\037' read -r -a QUOTE_LIST <<< \"${QUOTES_SEED-}\"\n"
    "unset QUOTES_SEED\n"
    "source \"$1\" || true\n"
    "{\n"
    "  d() { printf '%s\\037%s\\036' \"$1\" \"${2-}\"; }\n"
    "  d ALERT_SOUND \"${ALERT_SOUND-}\"\n"
    "  d SINK_NAME \"${SINK_NAME-}\"\n"
    "  d STATE_DIR \"${STATE_DIR-}\"\n"
    "  d MAX_LOG_BYTES \"${MAX_LOG_BYTES-}\"\n"
    "  d FILE_BAR_WIDTH \"${FILE_BAR_WIDTH-}\"\n"
    "  d NON_TTY_ENTER_TIMEOUT \"${NON_TTY_ENTER_TIMEOUT-}\"\n"
    "  d THEME \"${THEME-}\"\n"
    "  d POINTS \"${POINTS-}\"\n"
    "  d LAST_DATE \"${LAST_DATE-}\"\n"
    "  d QUOTES \"${QUOTES-}\"\n"
    "  for q in ${QUOTE_LIST[@]+\"${QUOTE_LIST[@]}\"}; do d QUOTE \"$q\"; done\n"
    "} > \"$2\"\n";

static bool file_exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

static std::string find_config_file() {
    if (!g_config_file.empty()) return g_config_file;
    const char *p = getenv("OBS_PANEL_CONFIG");
    if (p && *p) return p;
    std::string xdg_base;
    const char *xh = getenv("XDG_CONFIG_HOME");
    if (xh && *xh) xdg_base = xh;
    else {
        const char *home = getenv("HOME");
        xdg_base = std::string(home ? home : "") + "/.config";
    }
    std::string xdg = xdg_base + "/obs-study-panel/config";
    if (file_exists(xdg)) return xdg;
    std::string local_cfg = g_dir + "/obs-panel.conf";
    if (file_exists(local_cfg)) return local_cfg;
    return "";
}

static void quotes_to_list(const std::string &raw) {
    g_quote_list.clear();
    size_t start = 0;
    while (start <= raw.size()) {
        size_t end = raw.find('\n', start);
        std::string line = raw.substr(start, end == std::string::npos
                                       ? std::string::npos : end - start);
        while (!line.empty() && line.back() == '\r') line.pop_back();
        if (!line.empty()) g_quote_list.push_back(line);
        if (end == std::string::npos) break;
        start = end + 1;
    }
}

static long parse_long_safe(const std::string &v, long dflt) {
    if (v.empty()) return dflt;
    try {
        size_t pos = 0;
        long n = std::stol(v, &pos);
        while (pos < v.size() && isspace((unsigned char)v[pos])) pos++;
        if (pos != v.size()) return dflt;
        return n;
    } catch (...) {
        return dflt;
    }
}

static void load_config(const std::string &path) {
    if (access(path.c_str(), R_OK) != 0) {
        fprintf(stderr, "Error: config file is not readable: %s\n", path.c_str());
        exit(1);
    }
    /* Syntax check up front, exactly like the reference. */
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDOUT_FILENO);
        dup2(STDERR_FILENO, STDERR_FILENO);
        execl("/bin/bash", "bash", "-n", path.c_str(), (char *)nullptr);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
        fprintf(stderr, "Error: syntax error in config file: %s\n", path.c_str());
        /* Print the first 3 lines of bash -n's stderr, like the reference. */
        std::string errfile = "/tmp/obs-panel-bashn-" + std::to_string((long)getpid());
        pid = fork();
        if (pid == 0) {
            int e = open(errfile.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
            dup2(e, STDERR_FILENO);
            int devnull = open("/dev/null", O_WRONLY);
            dup2(devnull, STDOUT_FILENO);
            execl("/bin/bash", "bash", "-n", path.c_str(), (char *)nullptr);
            _exit(127);
        }
        waitpid(pid, &status, 0);
        std::ifstream ef(errfile);
        std::string line;
        int shown = 0;
        while (shown < 3 && std::getline(ef, line)) {
            if (line.empty()) continue;
            fprintf(stderr, "%s\n", line.c_str());
            shown++;
        }
        unlink(errfile.c_str());
        exit(1);
    }

    std::string dump_path = "/tmp/obs-panel-conf-" + std::to_string((long)getpid());
    pid = fork();
    if (pid == 0) {
        setenv("ALERT_SOUND", g_alert_sound.c_str(), 1);
        setenv("SINK_NAME", g_sink_name.c_str(), 1);
        setenv("STATE_DIR", "", 1);
        setenv("MAX_LOG_BYTES", "1048576", 1);
        setenv("FILE_BAR_WIDTH", "20", 1);
        setenv("NON_TTY_ENTER_TIMEOUT", "300", 1);
        setenv("POINTS", std::to_string(g_points).c_str(), 1);
        setenv("LAST_DATE", g_last_date.c_str(), 1);
        std::string seed;
        for (size_t i = 0; i < g_quote_list.size(); i++) {
            if (i > 0) seed += '\x1f';
            seed += g_quote_list[i];
        }
        setenv("QUOTES_SEED", seed.c_str(), 1);
        execl("/bin/bash", "bash", "-c", CONFIG_DUMP_SH, "obs-panel",
              path.c_str(), dump_path.c_str(), (char *)nullptr);
        _exit(127);
    }
    waitpid(pid, &status, 0);
    int c_code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

    std::ifstream dfh(dump_path, std::ios::binary);
    std::string raw;
    if (dfh) {
        raw.assign((std::istreambuf_iterator<char>(dfh)),
                   std::istreambuf_iterator<char>());
        dfh.close();
        unlink(dump_path.c_str());
    }

    if (raw.empty()) {
        /* The config called exit N before the dump was written. */
        exit(c_code != 0 ? c_code : 1);
    }

    std::map<std::string, std::string> values;
    g_quote_list.clear();
    size_t cursor = 0;
    while (cursor < raw.size()) {
        size_t rec_end = raw.find('\x1e', cursor);
        if (rec_end == std::string::npos) rec_end = raw.size();
        std::string record = raw.substr(cursor, rec_end - cursor);
        size_t sep = record.find('\x1f');
        if (sep != std::string::npos) {
            std::string key = record.substr(0, sep);
            std::string value = record.substr(sep + 1);
            if (key == "QUOTE") g_quote_list.push_back(value);
            else values[key] = value;
        }
        cursor = rec_end + 1;
    }

    if (values.count("ALERT_SOUND")) g_alert_sound = values["ALERT_SOUND"];
    if (values.count("SINK_NAME")) g_sink_name = values["SINK_NAME"];
    g_state_dir = values.count("STATE_DIR") ? values["STATE_DIR"] : "";
    g_max_log_bytes = values.count("MAX_LOG_BYTES")
        ? parse_long_safe(values["MAX_LOG_BYTES"], 1048576) : 1048576;
    g_file_bar_width = values.count("FILE_BAR_WIDTH")
        ? parse_long_safe(values["FILE_BAR_WIDTH"], 20) : 20;
    g_non_tty_enter_timeout = values.count("NON_TTY_ENTER_TIMEOUT")
        ? parse_long_safe(values["NON_TTY_ENTER_TIMEOUT"], 300) : 300;
    g_config_theme = values.count("THEME") ? values["THEME"] : "";
    g_points = values.count("POINTS") ? parse_long_safe(values["POINTS"], 0) : 0;
    g_last_date = values.count("LAST_DATE") ? values["LAST_DATE"] : "";
    g_config_quotes = values.count("QUOTES") ? values["QUOTES"] : "";
    g_config_loaded = path;
}

static void apply_quote_sources() {
    if (!g_env_quotes.empty()) quotes_to_list(g_env_quotes);
    else if (!g_config_quotes.empty()) quotes_to_list(g_config_quotes);
}

static void sanity_knobs() {
    if (g_max_log_bytes <= 0) g_max_log_bytes = 1048576;
    if (g_file_bar_width <= 0 || g_file_bar_width > 200) g_file_bar_width = 20;
    if (g_non_tty_enter_timeout <= 0 || g_non_tty_enter_timeout > 3600)
        g_non_tty_enter_timeout = 300;
}

/* ---------------------------------------------------------------------------
 * Paths and theme selection
 * ------------------------------------------------------------------------ */
static void setup_paths() {
    if (g_state_dir.empty()) g_state_dir = g_dir;
    struct stat st;
    if (stat(g_state_dir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
        mkdirs(g_state_dir);
        if (stat(g_state_dir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
            fprintf(stderr, "Error: cannot create state dir: %s\n",
                    g_state_dir.c_str());
            exit(1);
        }
    }
    g_date_file     = g_state_dir + "/date.txt";
    g_day_file      = g_state_dir + "/day.txt";
    g_session_file  = g_state_dir + "/session.txt";
    g_timer_file    = g_state_dir + "/timer.txt";
    g_log_file      = g_state_dir + "/log.txt";
    g_progress_file = g_state_dir + "/progress.txt";
    g_points_file   = g_state_dir + "/points.txt";
    g_message_file  = g_state_dir + "/message.txt";
    g_next_file     = g_state_dir + "/next.txt";
    g_overlay_file  = g_state_dir + "/overlay.txt";
    g_theme_file    = g_state_dir + "/theme.txt";
}

static void select_theme() {
    std::string request = g_cli_theme;
    if (request.empty()) request = g_env_theme;
    if (request.empty()) request = g_config_theme;
    if (request.empty() && !g_theme_file.empty()) {
        std::ifstream fh(g_theme_file);
        std::string line;
        if (fh && std::getline(fh, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            request = line;
        }
    }
    if (!request.empty()) {
        int idx = theme_index(request);
        if (idx < 0) {
            fprintf(stderr, "Warning: unknown theme '%s', using %s\n",
                    request.c_str(), g_theme_name.c_str());
        } else {
            set_theme(idx);
        }
    }
}

/* ---------------------------------------------------------------------------
 * OBS state files
 * ------------------------------------------------------------------------ */
static void update_date_day() {
    time_t t = time(nullptr);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char d[32];
    strftime(d, sizeof d, "%Y-%m-%d", &tmv);
    if (g_last_date == d) return;
    g_last_date = d;
    g_last_day = WEEKDAYS[tmv.tm_wday];
    write_state(g_date_file, d);
    write_state(g_day_file, g_last_day);
}

static void sync_state() {
    update_date_day();
    publish_state();
}

static void publish_state() {
    std::string bar = make_bar((long)g_pct * g_file_bar_width / 100,
                               g_file_bar_width, "#", "-");
    std::string pct_s = fmt("%3d%%", g_pct);

    write_state(g_session_file, g_session_text);
    write_state(g_timer_file, g_remaining_str);
    write_state(g_points_file, std::to_string(g_points));
    write_state(g_next_file, g_next_text);
    write_state(g_message_file, g_message_text);
    write_state(g_progress_file, "[" + bar + "] " + pct_s);

    std::ofstream fh(g_overlay_file);
    if (!fh) return;
    fh << g_last_date << " " << g_last_day << "\n"
       << g_session_text << "\n"
       << g_remaining_str << "\n"
       << "[" << bar << "] " << pct_s << "\n"
       << "Pts: " << g_points << "\n"
       << "Next: " << g_next_text << "\n";
    if (!g_message_text.empty()) fh << g_message_text << "\n";
}

static void rotate_log_if_needed() {
    struct stat st;
    if (stat(g_log_file.c_str(), &st) == 0 && S_ISREG(st.st_mode)
        && st.st_size >= g_max_log_bytes) {
        if (rename(g_log_file.c_str(), (g_log_file + ".1").c_str()) == 0) {
            std::ofstream fh(g_log_file);
        }
    }
}

static void log_event(const std::string &msg) {
    rotate_log_if_needed();
    std::ofstream fh(g_log_file, std::ios::app);
    if (!fh) return;
    time_t t = time(nullptr);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    fh << "[" << ts << "] " << msg << "\n";
}

/* ---------------------------------------------------------------------------
 * Audio alerts
 * ------------------------------------------------------------------------ */
static bool sink_is_ready() {
    if (!which("pactl")) return false;
    int pipefd[2];
    if (pipe(pipefd) != 0) return false;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[0]); close(pipefd[1]);
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDERR_FILENO);
        execlp("pactl", "pactl", "list", "short", "sinks", (char *)nullptr);
        _exit(127);
    }
    close(pipefd[1]);
    FILE *fh = fdopen(pipefd[0], "r");
    bool found = false;
    char line[512];
    while (fh && fgets(line, sizeof line, fh)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        while (*p && *p != ' ' && *p != '\t') p++;
        while (*p == ' ' || *p == '\t') p++;
        char *f2 = p;
        while (*p && *p != ' ' && *p != '\t' && *p != '\n') p++;
        *p = '\0';
        if (strcmp(f2, g_sink_name.c_str()) == 0) { found = true; break; }
    }
    if (fh) fclose(fh);
    waitpid(pid, nullptr, 0);
    return found;
}

static void run_quiet(const std::vector<std::string> &argv,
                      const std::string &stderr_to = "") {
    pid_t pid = fork();
    if (pid != 0) {
        waitpid(pid, nullptr, 0);
        return;
    }
    int devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, STDOUT_FILENO);
    int e = stderr_to.empty() ? devnull : open(stderr_to.c_str(),
        O_WRONLY | O_CREAT | O_TRUNC, 0600);
    dup2(e, STDERR_FILENO);
    std::vector<char *> cargv;
    for (const auto &a : argv) cargv.push_back(const_cast<char *>(a.c_str()));
    cargv.push_back(nullptr);
    execvp(cargv[0], cargv.data());
    _exit(127);
}

static void setup_audio_sink() {
    if (!g_use_sink) return;
    if (!which("pactl")) return;
    if (sink_is_ready()) return;
    run_quiet({ "pactl", "load-module", "module-null-sink",
                "sink_name=" + g_sink_name,
                "sink_properties=device.description=" + g_sink_name });
}

static void stop_alert() {
    if (g_alert_pid > 0) {
        kill(g_alert_pid, SIGTERM);
        g_alert_pid = 0;
    }
}

static void play_alert() {
    if (!g_use_alert) return;
    stop_alert();
    struct stat st;
    if (g_alert_sound.empty() || stat(g_alert_sound.c_str(), &st) != 0
        || !S_ISREG(st.st_mode)) {
        printf("%s(alert file not found: %s)%s\n", DIM,
               g_alert_sound.empty() ? "none" : g_alert_sound.c_str(), NC);
        return;
    }

    std::vector<std::string> player;
    if (which("mpv")) player = { "mpv", "--no-video", "--volume=70" };
    else if (which("paplay")) player = { "paplay" };
    else if (which("ffplay")) player = { "ffplay", "-nodisp", "-autoexit" };
    else if (which("cvlc")) {
        player = { "cvlc", "--play-and-exit", "--no-video", "--volume=70" };
    } else {
        printf("%s(no audio player found - install mpv / paplay / ffplay)%s\n",
               DIM, NC);
        return;
    }
    player.push_back(g_alert_sound);

    if (g_use_sink && !sink_is_ready()) setup_audio_sink();

    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        if (g_use_sink && sink_is_ready()) {
            setenv("PULSE_SINK", g_sink_name.c_str(), 1);
        }
        std::vector<char *> cargv;
        for (const auto &a : player) cargv.push_back(const_cast<char *>(a.c_str()));
        cargv.push_back(nullptr);
        execvp(cargv[0], cargv.data());
        _exit(127);
    }
    g_alert_pid = pid;
    if (g_use_sink && sink_is_ready()) {
        printf("%s-> alert on OBS sink (%s)%s\n", DIM, g_sink_name.c_str(), NC);
    } else {
        printf("%s-> alert on default device (OBS sink unavailable)%s\n",
               g_secondary.c_str(), NC);
    }
}

/* ---------------------------------------------------------------------------
 * Keyboard input
 * ------------------------------------------------------------------------ */
static void setup_terminal() {
    g_stdin_is_tty = isatty(0) == 1;
    if (!g_stdin_is_tty) return;
    if (tcgetattr(0, &g_term_saved) == 0) {
        g_term_saved_ok = true;
        struct termios raw = g_term_saved;
        raw.c_lflag &= ~(tcflag_t)(ECHO | ICANON);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        tcsetattr(0, TCSANOW, &raw);
    }
}

static void restore_terminal() {
    if (!g_stdin_is_tty || !g_term_saved_ok) return;
    tcsetattr(0, TCSANOW, &g_term_saved);
    g_term_saved_ok = false;
}

/* One byte with a timeout (seconds, may be fractional).
 * Returns: 1 = byte read (*out), 0 = timeout, -1 = EOF. */
static int read_byte_timeout(double timeout, char *out) {
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(0, &rfds);
    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - (double)tv.tv_sec) * 1000000.0);
    int rc = select(1, &rfds, nullptr, nullptr, &tv);
    if (rc < 0) {
        if (errno == EINTR) return 0;
        return -1;
    }
    if (rc == 0) return 0;
    char buf;
    ssize_t n = read(0, &buf, 1);
    if (n <= 0) return -1;
    *out = buf;
    return 1;
}

static void wait_key(double timeout) {
    g_key.clear();
    g_key_read = false;
    if (!g_stdin_is_tty) {
        struct timespec ts;
        ts.tv_sec = (time_t)timeout;
        ts.tv_nsec = 0;
        nanosleep(&ts, nullptr);
        return;
    }
    char b;
    int rc = read_byte_timeout(timeout, &b);
    if (rc != 1) return;
    g_key_read = true;
    if (b == '\x1b') {
        g_key.clear();
        char nxt;
        if (read_byte_timeout(0.3, &nxt) == 1 && (nxt == 't' || nxt == 'T')) {
            g_key = "alt-t";
        }
    } else {
        g_key = std::string(1, b);
    }
}

static void discard_pending_input() {
    if (!g_stdin_is_tty) return;
    char b;
    while (read_byte_timeout(0.01, &b) == 1) {
    }
}

static void wait_for_enter() {
    char b;
    if (g_stdin_is_tty) {
        for (;;) {
            int rc = read_byte_timeout(1, &b);
            if (rc == 0) { update_date_day(); continue; }
            if (rc < 0 || b == '\n') return;
        }
    }
    long waited = 0;
    while (waited < g_non_tty_enter_timeout) {
        auto slice_start = std::chrono::steady_clock::now();
        for (;;) {
            auto elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - slice_start).count();
            if (elapsed >= 5.0) { waited += 5; break; }
            int rc = read_byte_timeout(5.0 - elapsed, &b);
            if (rc < 0) return;
            if (rc == 0) { waited += 5; break; }
            if (b == '\n') return;
        }
    }
}

/* ---------------------------------------------------------------------------
 * Status / progress UI
 * ------------------------------------------------------------------------ */
static std::string phase_color(const std::string &label) {
    return label == "STUDY" ? g_primary : g_secondary;
}

static std::string duration_label(int n) {
    if (n == 1) {
        return g_duration_unit == "seconds" ? "1 second" : "1 minute";
    }
    return std::to_string(n) + " " + g_duration_unit;
}

static std::string rounds_label(int n) {
    return n == 1 ? "1 round" : std::to_string(n) + " rounds";
}

static void draw_status(const std::string &label, int round, int total_rounds,
                        long elapsed, long total, int paused) {
    long filled = 0;
    if (total > 0) filled = elapsed * TERM_BAR_WIDTH / total;
    if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH;
    std::string bar = make_bar(filled, TERM_BAR_WIDTH, "=", " ", ">");
    std::string color = phase_color(label);
    std::string flag;
    if (paused) flag = g_primary + " PAUSED" + NC;
    if (now_seconds() < g_theme_notice_until) {
        flag += std::string("  ") + DIM + "Theme: " + g_theme_name + NC;
    }
    printf("\r\033[K");
    printf("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%ld%s%s",
           BOLD, color.c_str(), label.c_str(), NC, round, total_rounds,
           color.c_str(), bar.c_str(), NC, g_pct, g_remaining_str.c_str(),
           g_primary.c_str(), g_points, NC, flag.c_str());
    fflush(stdout);
}

static void box_row(const std::string &color, const std::string &plain,
                    const std::string &styled) {
    int pad = BOX_INNER - (int)plain.size();
    if (pad < 0) pad = 0;
    printf("%s\xe2\x95\x91%s%*s%s\xe2\x95\x91%s\n",
           color.c_str(), styled.c_str(), pad, "", color.c_str(), NC);
}

static void phase_header(const std::string &label, int round, int total,
                         int minutes, const std::string &subtitle) {
    std::string sub = subtitle.substr(0, BOX_INNER - 4);
    std::string color = phase_color(label);
    std::string dur = duration_label(minutes);
    std::string bar_line;
    for (int i = 0; i < BOX_INNER; i++) bar_line += "\xe2\x95\x90";

    std::string info = fmt("%s  \xc2\xb7  Round %d / %d  \xc2\xb7  %s",
                           label.c_str(), round, total, dur.c_str());
    std::string styled1 = fmt("  %s%s%s%s  \xc2\xb7  Round %d / %d  \xc2\xb7  %s",
                              BOLD, label.c_str(), NC, color.c_str(), round,
                              total, dur.c_str());
    std::string styled2 = std::string("  ") + DIM + sub + NC + color;
    printf("\n");
    printf("%s\xe2\x95\x94%s\xe2\x95\x97%s\n", color.c_str(),
           bar_line.c_str(), NC);
    box_row(color, "  " + info, styled1);
    box_row(color, "  " + sub, styled2);
    if (g_stdin_is_tty) {
        std::string keys = "  p pause  \xc2\xb7  s skip  \xc2\xb7  q quit  \xc2\xb7  Alt+T theme";
        box_row(color, keys, std::string(DIM) + keys + NC + color);
    }
    printf("%s\xe2\x95\x9a%s\xe2\x95\x9d%s\n", color.c_str(),
           bar_line.c_str(), NC);
    printf("\n");
}

static void show_completion(const std::string &phase, int round,
                            int total_rounds, const std::string &next_phase,
                            int skipped) {
    int width = 60;
    std::string line(width, '=');
    std::string title;
    if (skipped == 1) title = "PHASE SKIPPED";
    else if (phase == "STUDY") title = "STUDY SESSION COMPLETE";
    else title = "BREAK COMPLETE";
    std::string color = phase_color(phase);
    int pad = (width + (int)title.size()) / 2;
    printf("\n");
    printf("%s%s%s\n", color.c_str(), line.c_str(), NC);
    printf("%s%*s%s%s\n", color.c_str(), pad, "", title.c_str(), NC);
    printf("%s%s%s\n", color.c_str(), line.c_str(), NC);
    printf("\n");
    printf("  Round:   %s%d%s / %d\n", BOLD, round, NC, total_rounds);
    printf("  Points:  %s%ld%s\n", g_primary.c_str(), g_points, NC);
    printf("\n");
    if (next_phase == "None") {
        printf("  Next:    %sSession complete%s\n", DIM, NC);
    } else {
        printf("  Next:    %s%s%s\n", BOLD, next_phase.c_str(), NC);
    }
    printf("\n");
    printf("  %sPress Enter to continue...%s", g_primary.c_str(), NC);
    fflush(stdout);
}

/* ---------------------------------------------------------------------------
 * Phase runner
 * ------------------------------------------------------------------------ */
static void phase_prepare(const std::string &ptype, int minutes, int round,
                          int total_rounds) {
    if (ptype == "study") {
        g_phase_label = "STUDY";
        if (!g_quote_list.empty()) {
            g_phase_subtitle = g_quote_list[rand() % g_quote_list.size()];
        } else {
            g_phase_subtitle = "Stay focused.";
        }
    } else {
        g_phase_label = "BREAK";
        g_phase_subtitle = "Relax and recharge.";
    }

    if (ptype == "study") {
        if (round < total_rounds) {
            g_phase_next = "Break (" + duration_label(g_break_min) + ")";
        } else {
            g_phase_next = "None";
        }
    } else {
        g_phase_next = "Study (" + duration_label(g_study_min) + ")";
    }

    g_phase_total = (long)minutes * g_seconds_per_unit;
    g_phase_elapsed = 0;
    g_phase_paused = false;
    g_phase_skipped = false;
    g_phase_start = now_seconds();
    g_phase_paused_total = 0;
    g_phase_pause_at = 0;

    g_session_text = fmt("%s %d/%d", g_phase_label.c_str(), round, total_rounds);
    g_remaining_str = fmt_hms(g_phase_total);
    g_pct = 0;
    g_next_text = g_phase_next == "None" ? "Session complete" : g_phase_next;
    g_message_text = g_phase_subtitle;

    log_event(fmt("Start: %s %d/%d (%s)", g_phase_label.c_str(), round,
                  total_rounds, duration_label(minutes).c_str()));
    phase_header(g_phase_label, round, total_rounds, minutes, g_phase_subtitle);
    sync_state();
}

static void phase_handle_key(int round, int total_rounds) {
    if (g_key == "p" || g_key == "P" || g_key == " ") {
        if (g_phase_paused) {
            g_phase_paused_total += now_seconds() - g_phase_pause_at;
            g_phase_paused = false;
            log_event(fmt("Resumed: %s %d/%d", g_phase_label.c_str(), round,
                          total_rounds));
        } else {
            g_phase_paused = true;
            g_phase_pause_at = now_seconds();
            log_event(fmt("Paused: %s %d/%d", g_phase_label.c_str(), round,
                          total_rounds));
        }
    } else if (g_key == "s" || g_key == "S") {
        g_phase_skipped = true;
        log_event(fmt("Skipped: %s %d/%d", g_phase_label.c_str(), round,
                      total_rounds));
    } else if (g_key == "q" || g_key == "Q") {
        log_event("Quit requested by user");
        cleanup(0);
    } else if (g_key == "alt-t") {
        cycle_theme();
    }
}

static void phase_count(int round, int total_rounds) {
    while (g_phase_elapsed < g_phase_total) {
        long remaining = g_phase_total - g_phase_elapsed;
        if (remaining < 0) remaining = 0;
        g_remaining_str = fmt_hms(remaining);
        g_pct = g_phase_total > 0
            ? (int)(g_phase_elapsed * 100 / g_phase_total) : 0;
        if (g_pct > 100) g_pct = 100;
        g_session_text = fmt("%s %d/%d", g_phase_label.c_str(), round,
                             total_rounds);
        if (g_phase_paused) g_session_text += " (PAUSED)";

        sync_state();
        draw_status(g_phase_label, round, total_rounds, g_phase_elapsed,
                    g_phase_total, g_phase_paused ? 1 : 0);

        wait_key(1);
        if (g_key_read) {
            phase_handle_key(round, total_rounds);
            if (g_phase_skipped) break;
        }
        /* CRASH-INJECT-POINT */
        if (!g_phase_paused) {
            g_phase_elapsed = now_seconds() - g_phase_start - g_phase_paused_total;
        }
    }
}

static void phase_finish(int round, int total_rounds) {
    if (g_phase_skipped) {
        g_session_text = fmt("%s %d/%d (SKIPPED)", g_phase_label.c_str(),
                              round, total_rounds);
    } else {
        g_pct = 100;
        g_points += 1;
    }
    g_remaining_str = "00:00:00";
    sync_state();
    draw_status(g_phase_label, round, total_rounds, g_phase_elapsed,
                g_phase_total, 0);
    printf("\n");
    log_event(fmt("End: %s %d/%d", g_phase_label.c_str(), round, total_rounds));

    play_alert();

    discard_pending_input();
    show_completion(g_phase_label, round, total_rounds, g_phase_next,
                    g_phase_skipped ? 1 : 0);
    wait_for_enter();
    stop_alert();
    printf("\n");
}

static void run_phase(const std::string &ptype, int minutes, int round,
                      int total_rounds) {
    phase_prepare(ptype, minutes, round, total_rounds);
    phase_count(round, total_rounds);
    phase_finish(round, total_rounds);
}

/* ---------------------------------------------------------------------------
 * Cleanup
 * ------------------------------------------------------------------------ */
static void reset_state_files() {
    g_session_text = "stopped";
    g_remaining_str = "00:00:00";
    g_pct = 0;
    g_next_text.clear();
    sync_state();
}

static void cleanup(int code) {
    if (g_in_cleanup) return;
    g_in_cleanup = true;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = SIG_IGN;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGHUP, &sa, nullptr);
    g_state_finalized = true;
    stop_alert();
    reset_state_files();
    log_event("Protocol stopped manually");
    printf("\n");
    printf("%s%sInterrupted.%s %sState files reset to stopped.%s\n",
           g_secondary.c_str(), BOLD, NC, DIM, NC);
    fflush(stdout);
    restore_terminal();
    exit(code);
}

/* The EXIT-trap equivalent, registered with on_exit(3): it receives the
 * pending exit code (atexit(3) does not). */
static void on_exit_hook(int code, void *unused) {
    (void)unused;
    if (!g_state_ready) return;
    if (g_state_finalized) return;
    g_state_finalized = true;
    stop_alert();
    reset_state_files();
    log_event(fmt("Protocol ended unexpectedly (exit %d)", code));
}

static void handle_signal(int signum) {
    int code = signum == SIGINT ? 130 : signum == SIGTERM ? 143 : 129;
    cleanup(code);
}

/* ---------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------ */
static void finalize_session() {
    g_session_text = "session complete";
    g_remaining_str = "00:00:00";
    g_pct = 100;
    g_next_text.clear();
    sync_state();
    g_state_finalized = true;
    log_event(fmt("Protocol complete - total points: %ld", g_points));
}

static void final_banner() {
    int banner_width = 60;
    std::string title = "ALL SESSIONS COMPLETE";
    int inner = banner_width - 2;
    int pad = (inner - (int)title.size()) / 2;
    std::string border(banner_width, '#');
    printf("\n");
    printf("%s%s%s\n", g_primary.c_str(), border.c_str(), NC);
    printf("%s#%s%*s%s%s%*s%s#%s\n", g_primary.c_str(), NC, pad, "", BOLD,
           title.c_str(), inner - pad - (int)title.size(), "", NC,
           g_primary.c_str());
    printf("%s%s%s\n", g_primary.c_str(), border.c_str(), NC);
    printf("\n");
    printf("  %sTotal Rounds:%s  %s%d%s\n", BOLD, NC, g_primary.c_str(),
           g_rounds, NC);
    printf("  %sTotal Points:%s %s%ld%s\n", BOLD, NC, g_primary.c_str(),
           g_points, NC);
    printf("\n");
    printf("%s%sGreat work!%s %sExiting.%s\n", g_primary.c_str(), BOLD, NC,
           DIM, NC);
}

static void print_logo() {
    printf("%s\n", g_primary.c_str());
    printf("%s\n", LOGO);
    printf("%s\n", NC);
    printf("%s%s     Study / Break Timer Protocol%s\n", g_primary.c_str(),
           BOLD, NC);
    printf("%s\xe2\x94\x80\xe2\x94\x80 live state written to "
           "date \xc2\xb7 day \xc2\xb7 session \xc2\xb7 timer \xc2\xb7 log%s\n",
           DIM, NC);
    printf("\n");
}

int main(int argc, char **argv) {
    const char *base = strrchr(argv[0], '/');
    PROG = base ? base + 1 : argv[0];
    START_TIME = time(nullptr);
    srand((unsigned)START_TIME ^ (unsigned)getpid());
    setvbuf(stdout, nullptr, _IONBF, 0);

    /* DIR = directory of the program (absolute) */
    {
        std::string a0 = argv[0];
        if (!a0.empty() && a0[0] == '/') {
            size_t slash = a0.rfind('/');
            g_dir = a0.substr(0, slash == 0 ? 1 : slash);
        } else if (a0.find('/') != std::string::npos) {
            char cwd[1024];
            if (getcwd(cwd, sizeof cwd)) {
                size_t slash = a0.rfind('/');
                g_dir = std::string(cwd) + "/" + a0.substr(0, slash);
            } else g_dir = ".";
        } else {
            char cwd[1024];
            g_dir = getcwd(cwd, sizeof cwd) ? cwd : ".";
        }
    }

    /* Environment overrides (captured before the defaults are applied) */
    const char *e;
    if ((e = getenv("ALERT_SOUND"))) g_env_alert_sound = e;
    if ((e = getenv("SINK_NAME"))) g_env_sink_name = e;
    if ((e = getenv("STATE_DIR"))) g_env_state_dir = e;
    if ((e = getenv("MAX_LOG_BYTES"))) g_env_max_log_bytes = e;
    if ((e = getenv("QUOTES"))) g_env_quotes = e;
    if ((e = getenv("THEME"))) g_env_theme = e;

    /* Built-in defaults */
    const char *home = getenv("HOME");
    if (home && *home) {
        g_alert_sound = std::string(home) + "/Videos/Alarm/n_alarm.mp3";
    }
    g_primary = THEME_PRIMARY[0];
    g_secondary = THEME_SECONDARY[0];
    g_theme_name = THEME_NAMES[0];

    parse_args(argc, argv);

    std::string cfg = find_config_file();
    if (!cfg.empty()) load_config(cfg);

    /* Environment variables beat the config file. */
    if (!g_env_alert_sound.empty()) g_alert_sound = g_env_alert_sound;
    if (!g_env_sink_name.empty()) g_sink_name = g_env_sink_name;
    if (!g_env_state_dir.empty()) g_state_dir = g_env_state_dir;
    if (!g_env_max_log_bytes.empty())
        g_max_log_bytes = parse_long_safe(g_env_max_log_bytes, g_max_log_bytes);

    apply_quote_sources();
    sanity_knobs();

    setup_paths();
    select_theme();

    on_exit(on_exit_hook, nullptr);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGHUP, &sa, nullptr);

    setup_terminal();
    print_logo();
    setup_audio_sink();
    update_date_day();
    /* From here on the state files may be written (and have to be reset if
     * the program dies unexpectedly). */
    g_state_ready = true;
    log_event("Starting new study protocol: " + rounds_label(g_rounds)
              + ", " + duration_label(g_study_min) + " study, "
              + duration_label(g_break_min) + " break");

    printf("%sProtocol:%s %s%s%s  %s|%s  %s%s%s study  %s|%s  %s%s%s break"
           "  %s|%s  %sTheme: %s%s\n",
           g_secondary.c_str(), NC, BOLD, rounds_label(g_rounds).c_str(), NC,
           DIM, NC, BOLD, duration_label(g_study_min).c_str(), NC, DIM, NC,
           BOLD, duration_label(g_break_min).c_str(), NC, DIM, NC, BOLD,
           g_theme_name.c_str(), NC);
    if (!g_config_loaded.empty()) {
        printf("%sConfig: %s%s\n", DIM, g_config_loaded.c_str(), NC);
    }
    printf("\n");

    for (int round = 1; round <= g_rounds; round++) {
        run_phase("study", g_study_min, round, g_rounds);
        if (round < g_rounds) run_phase("break", g_break_min, round, g_rounds);
    }

    finalize_session();
    final_banner();
    restore_terminal();
    return 0;
}
