/*
 * OBS.c - Study/break timer protocol (C port of OBS.sh)
 *
 * Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
 * progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
 * use as Text sources in OBS Studio. OBS.sh is the reference implementation;
 * see docs/port-spec.md for the behavior contract and README.md for usage.
 *
 * Requirements: C99 + POSIX (termios, select, fork/exec), bash (to load the
 * bash-syntax config file).
 *
 * Build: gcc -O2 -o OBS OBS.c
 * Usage: ./OBS [options] <rounds> <study_minutes> <break_minutes>
 * Stop:  Ctrl+C, or press 'q' while a phase is running
 * Theme: press Alt+T while a phase is running (see --list-themes)
 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* Forward declarations */
static void log_event(const char *msg);
static void cleanup(int code);
static void sync_state(void);
static void publish_state(void);
static void update_date_day(void);
static void reset_state_files(void);
static void print_theme_list(void);

static char PROG[128];
time_t START_TIME;

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

static const char *DEFAULT_QUOTE_LIST[] = {
    "Focused effort beats scattered hours",
    "Every round finished is progress made",
    "Consistency beats intensity",
    "Start now, figure out the rest along the way",
    "A short break now means sharper focus next round",
};
#define DEFAULT_QUOTE_COUNT 5

static const char *WEEKDAYS[] = { "Sunday", "Monday", "Tuesday", "Wednesday",
    "Thursday", "Friday", "Saturday" };

/* ---------------------------------------------------------------------------
 * Mutable program state (mirrors the reference's global variables)
 * ------------------------------------------------------------------------ */
static const char *g_primary, *g_secondary;
static char g_theme_name[32];
static int g_theme_index = 0;
static long g_theme_notice_until = 0;

static char g_env_alert_sound[1024];
static char g_env_sink_name[1024];
static char g_env_state_dir[1024];
static char g_env_max_log_bytes[64];
static char g_env_quotes[8192];
static char g_env_theme[64];

static char g_dir[1024];
static char g_alert_sound[1024];
static char g_sink_name[256];
static char g_state_dir[1024];
static long g_max_log_bytes = 1048576;
static long g_file_bar_width = 20;
static long g_non_tty_enter_timeout = 300;
static pid_t g_alert_pid = 0;
static char g_quote_list[64][256];
static int g_quote_count = 0;
static long g_points = 0;
static char g_last_date[32] = "";

static char g_config_file[1024] = "";
static bool g_dry_run = false;
static bool g_use_alert = true;
static bool g_use_sink = true;
static int g_rounds = 0, g_study_min = 0, g_break_min = 0;
static char g_cli_theme[64] = "";
static char g_duration_unit[16] = "minutes";
static int g_seconds_per_unit = 60;
static char g_config_theme[64] = "";
static char g_config_quotes[8192] = "";
static char g_config_loaded[1024] = "";

static char g_date_file[1024], g_day_file[1024], g_session_file[1024];
static char g_timer_file[1024], g_log_file[1024], g_progress_file[1024];
static char g_points_file[1024], g_message_file[1024], g_next_file[1024];
static char g_overlay_file[1024], g_theme_file[1024];

static char g_session_text[256] = "";
static char g_remaining_str[16] = "00:00:00";
static int g_pct = 0;
static char g_next_text[256] = "";
static char g_message_text[256] = "";
static char g_last_day[32] = "";
static bool g_state_ready = false;
static bool g_state_finalized = false;
static bool g_in_cleanup = false;

static char g_phase_label[16];
static char g_phase_subtitle[256];
static char g_phase_next[256];
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
static char g_key[16] = "";
static bool g_key_read = false;

#define TERM_BAR_WIDTH 24
#define BOX_INNER 62

/* ---------------------------------------------------------------------------
 * Small helpers
 * ------------------------------------------------------------------------ */
static long now_seconds(void) {
    return (long)(time(NULL) - START_TIME);
}

static void write_state(const char *path, const char *text) {
    FILE *fh = fopen(path, "w");
    if (!fh) return;
    fprintf(fh, "%s\n", text);
    fclose(fh);
}

static void mkdirs(const char *path) {
    char tmp[1024];
    snprintf(tmp, sizeof tmp, "%s", path);
    size_t len = strlen(tmp);
    if (len == 0) return;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

static bool which(const char *cmd) {
    char *path_env = getenv("PATH");
    char path_copy[4096];
    if (!path_env) return false;
    snprintf(path_copy, sizeof path_copy, "%s", path_env);
    char *save = NULL;
    for (char *dir = strtok_r(path_copy, ":", &save); dir;
         dir = strtok_r(NULL, ":", &save)) {
        char full[4096];
        snprintf(full, sizeof full, "%s/%s", dir, cmd);
        if (access(full, X_OK) == 0) return true;
    }
    return false;
}

static void set_theme(int i) {
    if (i < 0 || i >= THEME_COUNT) return;
    g_theme_index = i;
    snprintf(g_theme_name, sizeof g_theme_name, "%s", THEME_NAMES[i]);
    g_primary = THEME_PRIMARY[i];
    g_secondary = THEME_SECONDARY[i];
}

static int theme_index(const char *want) {
    if (!want || !*want) return -1;
    for (int i = 0; i < THEME_COUNT; i++) {
        if (strcasecmp(THEME_NAMES[i], want) == 0) return i;
    }
    return -1;
}

static void save_theme(void) {
    if (*g_theme_file) write_state(g_theme_file, g_theme_name);
}

static void cycle_theme(void) {
    set_theme((g_theme_index + 1) % THEME_COUNT);
    save_theme();
    g_theme_notice_until = now_seconds() + 3;
    char msg[128];
    snprintf(msg, sizeof msg, "Theme changed to: %s", g_theme_name);
    log_event(msg);
}

static void fmt_hms(long total, char *out, size_t n) {
    snprintf(out, n, "%02ld:%02ld:%02ld", total / 3600,
             (total % 3600) / 60, total % 60);
}

static void make_bar(long filled, long width, const char *fill,
                     const char *empty, const char *head, char *out) {
    out[0] = '\0';
    for (long i = 0; i < width; i++) {
        if (i < filled) {
            if (head && *head && i == filled - 1) strcat(out, head);
            else strcat(out, fill);
        } else {
            strcat(out, empty);
        }
    }
}

/* ---------------------------------------------------------------------------
 * Help and argument parsing
 * ------------------------------------------------------------------------ */
static void help_text(char *out, size_t n) {
    snprintf(out, n,
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
        PROG, PROG, PROG, PROG);
}

static void print_help(int code, FILE *stream) {
    char buf[4096];
    help_text(buf, sizeof buf);
    fputs(buf, stream);
    exit(code);
}

static void usage_error(void) {
    print_help(1, stderr);
}

static bool valid_number(const char *s) {
    if (!s || !*s) return false;
    if (s[0] < '1' || s[0] > '9') return false;
    for (const char *p = s + 1; *p; p++) {
        if (*p < '0' || *p > '9') return false;
    }
    return strlen(s) <= 4;
}

static void parse_args(int argc, char **argv) {
    int i = 1;
    int npos = 0;
    const char *pos[8] = { 0 };
    while (i < argc) {
        const char *a = argv[i];
        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
            print_help(0, stdout);
        } else if (strcmp(a, "-c") == 0 || strcmp(a, "--config") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: %s needs a file argument\n", a);
                usage_error();
            }
            snprintf(g_config_file, sizeof g_config_file, "%s", argv[i + 1]);
            i += 2;
        } else if (strcmp(a, "-d") == 0 || strcmp(a, "--dry-run") == 0) {
            g_dry_run = true; i++;
        } else if (strcmp(a, "-n") == 0 || strcmp(a, "--no-alert") == 0) {
            g_use_alert = false; i++;
        } else if (strcmp(a, "-s") == 0 || strcmp(a, "--no-sink") == 0) {
            g_use_sink = false; i++;
        } else if (strcmp(a, "-t") == 0 || strcmp(a, "--theme") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: %s needs a theme name\n", a);
                usage_error();
            }
            snprintf(g_cli_theme, sizeof g_cli_theme, "%s", argv[i + 1]);
            i += 2;
        } else if (strcmp(a, "--list-themes") == 0) {
            print_theme_list();
            exit(0);
        } else if (strcmp(a, "--") == 0) {
            i++;
            for (; i < argc && npos < 8; i++) pos[npos++] = argv[i];
            break;
        } else if (a[0] == '-') {
            fprintf(stderr, "Error: unknown option: %s\n", a);
            usage_error();
        } else {
            for (; i < argc && npos < 8; i++) pos[npos++] = argv[i];
            break;
        }
    }
    if (npos != 3) usage_error();
    for (int k = 0; k < npos; k++) {
        if (!valid_number(pos[k])) usage_error();
    }
    g_rounds = atoi(pos[0]);
    g_study_min = atoi(pos[1]);
    g_break_min = atoi(pos[2]);
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
        snprintf(g_duration_unit, sizeof g_duration_unit, "seconds");
        g_seconds_per_unit = 1;
    }
}

static void print_theme_list(void) {
    for (int i = 0; i < THEME_COUNT; i++) {
        printf("  %-8s %s\xE2\x96\x88\xE2\x96\x88\xE2\x96\x88\xE2\x96\x88%s\n",
               THEME_NAMES[i], THEME_PRIMARY[i], THEME_SECONDARY[i]);
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

static const char *find_config_file(void) {
    if (*g_config_file) return g_config_file;
    const char *p = getenv("OBS_PANEL_CONFIG");
    if (p && *p) return p;
    char xdg[1024];
    const char *xh = getenv("XDG_CONFIG_HOME");
    if (xh && *xh) snprintf(xdg, sizeof xdg, "%s/obs-study-panel/config", xh);
    else {
        const char *home = getenv("HOME");
        if (!home) home = "";
        snprintf(xdg, sizeof xdg, "%s/.config/obs-study-panel/config", home);
    }
    struct stat st;
    if (stat(xdg, &st) == 0 && S_ISREG(st.st_mode)) {
        static char found[1024];
        snprintf(found, sizeof found, "%s", xdg);
        return found;
    }
    char local_cfg[1024];
    snprintf(local_cfg, sizeof local_cfg, "%s/obs-panel.conf", g_dir);
    if (stat(local_cfg, &st) == 0 && S_ISREG(st.st_mode)) {
        static char found[1024];
        snprintf(found, sizeof found, "%s", local_cfg);
        return found;
    }
    return NULL;
}

static void quotes_to_list(const char *raw) {
    g_quote_count = 0;
    char copy[8192];
    snprintf(copy, sizeof copy, "%s", raw);
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        size_t len = strlen(line);
        while (len > 0 && line[len - 1] == '\r') line[--len] = '\0';
        if (!*line) continue;
        if (g_quote_count < 64) {
            snprintf(g_quote_list[g_quote_count], 256, "%s", line);
            g_quote_count++;
        }
    }
}

static long parse_long_safe(const char *v, long dflt) {
    if (!v || !*v) return dflt;
    char *end = NULL;
    long n = strtol(v, &end, 10);
    if (end == v || (end && *end && *end != ' ')) return dflt;
    return n;
}

static void load_config(const char *path) {
    if (access(path, R_OK) != 0) {
        fprintf(stderr, "Error: config file is not readable: %s\n", path);
        exit(1);
    }
    /* Syntax check up front, exactly like the reference. */
    pid_t pid = fork();
    if (pid == 0) {
        execl("/bin/bash", "bash", "-n", path, (char *)NULL);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
        fprintf(stderr, "Error: syntax error in config file: %s\n", path);
        /* First 3 lines of bash -n output */
        pid = fork();
        if (pid == 0) {
            int devnull = open("/dev/null", O_WRONLY);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
            /* Rerun bash -n with stderr on our stderr for the message */
            execl("/bin/bash", "bash", "-n", path, (char *)NULL);
            _exit(127);
        }
        /* Not reachable in the child; the parent prints via a simpler path. */
        waitpid(pid, &status, 0);
        exit(1);
    }

    char dump_path[1024];
    snprintf(dump_path, sizeof dump_path,
             "/tmp/obs-panel-conf-%ld", (long)getpid());
    pid = fork();
    if (pid == 0) {
        /* Seed the pre-config defaults in the child environment. */
        setenv("ALERT_SOUND", g_alert_sound, 1);
        setenv("SINK_NAME", g_sink_name, 1);
        setenv("STATE_DIR", "", 1);
        setenv("MAX_LOG_BYTES", "1048576", 1);
        setenv("FILE_BAR_WIDTH", "20", 1);
        setenv("NON_TTY_ENTER_TIMEOUT", "300", 1);
        char pts[32];
        snprintf(pts, sizeof pts, "%ld", g_points);
        setenv("POINTS", pts, 1);
        setenv("LAST_DATE", g_last_date, 1);
        char seed[8192];
        seed[0] = '\0';
        for (int i = 0; i < g_quote_count; i++) {
            if (i > 0) strncat(seed, "\x1f", sizeof seed - strlen(seed) - 1);
            strncat(seed, g_quote_list[i], sizeof seed - strlen(seed) - 1);
        }
        setenv("QUOTES_SEED", seed, 1);
        execl("/bin/bash", "bash", "-c", CONFIG_DUMP_SH, "obs-panel",
              path, dump_path, (char *)NULL);
        _exit(127);
    }
    waitpid(pid, &status, 0);
    int c_code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

    FILE *fh = fopen(dump_path, "rb");
    char raw[32768];
    size_t raw_len = 0;
    if (fh) {
        raw_len = fread(raw, 1, sizeof raw - 1, fh);
        fclose(fh);
        unlink(dump_path);
        raw[raw_len] = '\0';
    } else {
        raw[0] = '\0';
    }

    if (raw_len == 0) {
        /* The config called exit N before the dump was written. */
        exit(c_code != 0 ? c_code : 1);
    }

    /* Parse the dump. */
    char values[16][1024];
    static const char *KEYS[] = {
        "ALERT_SOUND", "SINK_NAME", "STATE_DIR", "MAX_LOG_BYTES",
        "FILE_BAR_WIDTH", "NON_TTY_ENTER_TIMEOUT", "THEME", "POINTS",
        "LAST_DATE", "QUOTES", ""
    };
    bool key_seen[16] = { false };
    g_quote_count = 0;
    char *cursor = raw;
    while (*cursor) {
        char *rec_end = strchr(cursor, '\x1e');
        char saved = '\0';
        if (rec_end) { saved = *rec_end; *rec_end = '\0'; }
        char *sep = strchr(cursor, '\x1f');
        if (sep) {
            *sep = '\0';
            const char *key = cursor;
            const char *value = sep + 1;
            if (strcmp(key, "QUOTE") == 0) {
                if (g_quote_count < 64) {
                    snprintf(g_quote_list[g_quote_count], 256, "%s", value);
                    g_quote_count++;
                }
            } else {
                for (int k = 0; KEYS[k][0]; k++) {
                    if (strcmp(key, KEYS[k]) == 0) {
                        key_seen[k] = true;
                        snprintf(values[k], 1024, "%s", value);
                        break;
                    }
                }
            }
        }
        if (rec_end) { *rec_end = saved; cursor = rec_end + 1; }
        else break;
    }

    if (key_seen[0]) snprintf(g_alert_sound, sizeof g_alert_sound, "%s", values[0]);
    if (key_seen[1]) snprintf(g_sink_name, sizeof g_sink_name, "%s", values[1]);
    snprintf(g_state_dir, sizeof g_state_dir, "%s", key_seen[2] ? values[2] : "");
    g_max_log_bytes = key_seen[3] ? parse_long_safe(values[3], 1048576) : 1048576;
    g_file_bar_width = key_seen[4] ? parse_long_safe(values[4], 20) : 20;
    g_non_tty_enter_timeout =
        key_seen[5] ? parse_long_safe(values[5], 300) : 300;
    snprintf(g_config_theme, sizeof g_config_theme, "%s", key_seen[6] ? values[6] : "");
    g_points = key_seen[7] ? parse_long_safe(values[7], 0) : 0;
    snprintf(g_last_date, sizeof g_last_date, "%s", key_seen[8] ? values[8] : "");
    snprintf(g_config_quotes, sizeof g_config_quotes, "%s", key_seen[9] ? values[9] : "");
    snprintf(g_config_loaded, sizeof g_config_loaded, "%s", path);
}

static void apply_quote_sources(void) {
    if (*g_env_quotes) quotes_to_list(g_env_quotes);
    else if (*g_config_quotes) quotes_to_list(g_config_quotes);
}

static void sanity_knobs(void) {
    if (g_max_log_bytes <= 0) g_max_log_bytes = 1048576;
    if (g_file_bar_width <= 0 || g_file_bar_width > 200) g_file_bar_width = 20;
    if (g_non_tty_enter_timeout <= 0 || g_non_tty_enter_timeout > 3600)
        g_non_tty_enter_timeout = 300;
}

/* ---------------------------------------------------------------------------
 * Paths and theme selection
 * ------------------------------------------------------------------------ */
static void setup_paths(void) {
    if (!*g_state_dir) snprintf(g_state_dir, sizeof g_state_dir, "%s", g_dir);
    struct stat st;
    if (stat(g_state_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        mkdirs(g_state_dir);
        if (stat(g_state_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
            fprintf(stderr, "Error: cannot create state dir: %s\n", g_state_dir);
            exit(1);
        }
    }
    char join[1024];
#define SETFILE(var, name) do { \
    snprintf(join, sizeof join, "%s/%s", g_state_dir, name); \
    snprintf(var, sizeof var, "%s", join); } while (0)
    SETFILE(g_date_file, "date.txt");
    SETFILE(g_day_file, "day.txt");
    SETFILE(g_session_file, "session.txt");
    SETFILE(g_timer_file, "timer.txt");
    SETFILE(g_log_file, "log.txt");
    SETFILE(g_progress_file, "progress.txt");
    SETFILE(g_points_file, "points.txt");
    SETFILE(g_message_file, "message.txt");
    SETFILE(g_next_file, "next.txt");
    SETFILE(g_overlay_file, "overlay.txt");
    SETFILE(g_theme_file, "theme.txt");
#undef SETFILE
}

static void select_theme(void) {
    char request[512];
    request[0] = '\0';
    if (*g_cli_theme) snprintf(request, sizeof request, "%s", g_cli_theme);
    else if (*g_env_theme) snprintf(request, sizeof request, "%s", g_env_theme);
    else if (*g_config_theme) snprintf(request, sizeof request, "%s", g_config_theme);
    else if (*g_theme_file) {
        FILE *fh = fopen(g_theme_file, "r");
        if (fh) {
            if (fgets(request, sizeof request, fh)) {
                request[strcspn(request, "\n")] = '\0';
            } else request[0] = '\0';
            fclose(fh);
        }
    }
    if (*request) {
        int idx = theme_index(request);
        if (idx < 0) {
            fprintf(stderr, "Warning: unknown theme '%s', using %s\n",
                    request, g_theme_name);
        } else {
            set_theme(idx);
        }
    }
}

/* ---------------------------------------------------------------------------
 * OBS state files
 * ------------------------------------------------------------------------ */
static void update_date_day(void) {
    char d[32];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(d, sizeof d, "%Y-%m-%d", &tmv);
    if (strcmp(d, g_last_date) == 0) return;
    snprintf(g_last_date, sizeof g_last_date, "%s", d);
    snprintf(g_last_day, sizeof g_last_day, "%s", WEEKDAYS[tmv.tm_wday]);
    write_state(g_date_file, d);
    write_state(g_day_file, g_last_day);
}

static void sync_state(void) {
    update_date_day();
    publish_state();
}

static void publish_state(void) {
    char bar[256];
    long filled = (long)g_pct * g_file_bar_width / 100;
    make_bar(filled, g_file_bar_width, "#", "-", NULL, bar);

    char pts[32];
    snprintf(pts, sizeof pts, "%ld", g_points);

    write_state(g_session_file, g_session_text);
    write_state(g_timer_file, g_remaining_str);
    write_state(g_points_file, pts);
    write_state(g_next_file, g_next_text);
    write_state(g_message_file, g_message_text);

    char progress[512];
    snprintf(progress, sizeof progress, "[%s] %3d%%", bar, g_pct);
    write_state(g_progress_file, progress);

    FILE *fh = fopen(g_overlay_file, "w");
    if (!fh) return;
    fprintf(fh, "%s %s\n", g_last_date, g_last_day);
    fprintf(fh, "%s\n", g_session_text);
    fprintf(fh, "%s\n", g_remaining_str);
    fprintf(fh, "[%s] %3d%%\n", bar, g_pct);
    fprintf(fh, "Pts: %ld\n", g_points);
    fprintf(fh, "Next: %s\n", g_next_text);
    if (*g_message_text) fprintf(fh, "%s\n", g_message_text);
    fclose(fh);
}

static void rotate_log_if_needed(void) {
    struct stat st;
    if (stat(g_log_file, &st) == 0 && S_ISREG(st.st_mode)
        && st.st_size >= g_max_log_bytes) {
        char rotated[1024];
        snprintf(rotated, sizeof rotated, "%s.1", g_log_file);
        if (rename(g_log_file, rotated) == 0) {
            FILE *fh = fopen(g_log_file, "w");
            if (fh) fclose(fh);
        }
    }
}

static void log_event(const char *msg) {
    rotate_log_if_needed();
    FILE *fh = fopen(g_log_file, "a");
    if (!fh) return;
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    fprintf(fh, "[%s] %s\n", ts, msg);
    fclose(fh);
}

/* ---------------------------------------------------------------------------
 * Audio alerts
 * ------------------------------------------------------------------------ */
static bool sink_is_ready(void) {
    if (!which("pactl")) return false;
    int pipefd[2];
    if (pipe(pipefd) != 0) return false;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[0]); close(pipefd[1]);
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDERR_FILENO);
        execlp("pactl", "pactl", "list", "short", "sinks", (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    FILE *fh = fdopen(pipefd[0], "r");
    bool found = false;
    char line[512];
    while (fh && fgets(line, sizeof line, fh)) {
        /* second whitespace-separated field must equal SINK_NAME */
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        while (*p && *p != ' ' && *p != '\t') p++;   /* skip field 1 */
        while (*p == ' ' || *p == '\t') p++;
        char *f2 = p;
        while (*p && *p != ' ' && *p != '\t' && *p != '\n') p++;
        *p = '\0';
        if (strcmp(f2, g_sink_name) == 0) { found = true; break; }
    }
    if (fh) fclose(fh);
    waitpid(pid, NULL, 0);
    return found;
}

static void setup_audio_sink(void) {
    if (!g_use_sink) return;
    if (!which("pactl")) return;
    if (sink_is_ready()) return;
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        char arg1[512], arg2[768];
        snprintf(arg1, sizeof arg1, "sink_name=%s", g_sink_name);
        snprintf(arg2, sizeof arg2, "sink_properties=device.description=%s",
                 g_sink_name);
        execlp("pactl", "pactl", "load-module", "module-null-sink",
               arg1, arg2, (char *)NULL);
        _exit(127);
    }
    waitpid(pid, NULL, 0);
}

static void stop_alert(void) {
    if (g_alert_pid > 0) {
        kill(g_alert_pid, SIGTERM);
        g_alert_pid = 0;
    }
}

static void spawn_alert_player(char **player) {
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        if (g_use_sink && sink_is_ready()) {
            setenv("PULSE_SINK", g_sink_name, 1);
        }
        execvp(player[0], player);
        _exit(127);
    }
    g_alert_pid = pid;
}

static void play_alert(void) {
    if (!g_use_alert) return;
    stop_alert();
    struct stat st;
    if (!*g_alert_sound || stat(g_alert_sound, &st) != 0 || !S_ISREG(st.st_mode)) {
        char shown[1024];
        snprintf(shown, sizeof shown, "%s", *g_alert_sound ? g_alert_sound : "none");
        printf("%s(alert file not found: %s)%s\n", DIM, shown, NC);
        return;
    }

    char *player[8];
    int argc_ = 0;
    if (which("mpv")) {
        player[argc_++] = "mpv"; player[argc_++] = "--no-video";
        player[argc_++] = "--volume=70";
    } else if (which("paplay")) {
        player[argc_++] = "paplay";
    } else if (which("ffplay")) {
        player[argc_++] = "ffplay"; player[argc_++] = "-nodisp";
        player[argc_++] = "-autoexit";
    } else if (which("cvlc")) {
        player[argc_++] = "cvlc"; player[argc_++] = "--play-and-exit";
        player[argc_++] = "--no-video"; player[argc_++] = "--volume=70";
    } else {
        printf("%s(no audio player found - install mpv / paplay / ffplay)%s\n",
               DIM, NC);
        return;
    }
    player[argc_++] = (char *)g_alert_sound;
    player[argc_] = NULL;

    if (g_use_sink && !sink_is_ready()) setup_audio_sink();

    spawn_alert_player(player);
    if (g_use_sink && sink_is_ready()) {
        printf("%s-> alert on OBS sink (%s)%s\n", DIM, g_sink_name, NC);
    } else {
        printf("%s-> alert on default device (OBS sink unavailable)%s\n",
               g_secondary, NC);
    }
}

/* ---------------------------------------------------------------------------
 * Keyboard input
 * ------------------------------------------------------------------------ */
static void setup_terminal(void) {
    g_stdin_is_tty = isatty(0);
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

static void restore_terminal(void) {
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
    int rc = select(1, &rfds, NULL, NULL, &tv);
    if (rc < 0) {
        if (errno == EINTR) return 0;   /* signal: handler takes over */
        return -1;
    }
    if (rc == 0) return 0;              /* timeout */
    char buf;
    ssize_t n = read(0, &buf, 1);
    if (n <= 0) return -1;              /* EOF or error */
    *out = buf;
    return 1;
}

static void wait_key(double timeout) {
    g_key[0] = '\0';
    g_key_read = false;
    if (!g_stdin_is_tty) {
        struct timespec ts;
        ts.tv_sec = (time_t)timeout;
        ts.tv_nsec = 0;
        nanosleep(&ts, NULL);
        return;
    }
    char b;
    int rc = read_byte_timeout(timeout, &b);
    if (rc != 1) return;
    g_key_read = true;
    if (b == '\x1b') {
        g_key[0] = '\0';
        char nxt;
        if (read_byte_timeout(0.3, &nxt) == 1 && (nxt == 't' || nxt == 'T')) {
            snprintf(g_key, sizeof g_key, "alt-t");
        }
    } else {
        g_key[0] = b;
        g_key[1] = '\0';
    }
}

static void discard_pending_input(void) {
    if (!g_stdin_is_tty) return;
    char b;
    while (read_byte_timeout(0.01, &b) == 1) {
        /* discard */
    }
}

static void wait_for_enter(void) {
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
        struct timespec slice_start, now;
        clock_gettime(CLOCK_MONOTONIC, &slice_start);
        for (;;) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (double)(now.tv_sec - slice_start.tv_sec)
                + (double)(now.tv_nsec - slice_start.tv_nsec) / 1e9;
            if (elapsed >= 5.0) { waited += 5; break; }
            int rc = read_byte_timeout(5.0 - elapsed, &b);
            if (rc < 0) return;             /* EOF */
            if (rc == 0) { waited += 5; break; }
            if (b == '\n') return;          /* complete line */
        }
    }
}

/* ---------------------------------------------------------------------------
 * Status / progress UI
 * ------------------------------------------------------------------------ */
static const char *phase_color(const char *label) {
    return strcmp(label, "STUDY") == 0 ? g_primary : g_secondary;
}

static void duration_label(int n, char *out, size_t size) {
    if (n == 1) {
        snprintf(out, size, "%s", strcmp(g_duration_unit, "seconds") == 0
                 ? "1 second" : "1 minute");
    } else {
        snprintf(out, size, "%d %s", n, g_duration_unit);
    }
}

static void rounds_label(int n, char *out, size_t size) {
    snprintf(out, size, "%d rounds", n);
    if (n == 1) snprintf(out, size, "1 round");
}

static void draw_status(const char *label, int round, int total_rounds,
                         long elapsed, long total, int paused) {
    long filled = 0;
    if (total > 0) filled = elapsed * TERM_BAR_WIDTH / total;
    if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH;
    char bar[TERM_BAR_WIDTH + 1];
    make_bar(filled, TERM_BAR_WIDTH, "=", " ", ">", bar);
    const char *color = phase_color(label);
    char flag[256] = "";
    if (paused) snprintf(flag, sizeof flag, "%s PAUSED%s", g_primary, NC);
    if (now_seconds() < g_theme_notice_until) {
        char tbuf[128];
        snprintf(tbuf, sizeof tbuf, "  %sTheme: %s%s", DIM, g_theme_name, NC);
        strncat(flag, tbuf, sizeof flag - strlen(flag) - 1);
    }
    printf("\r\033[K");
    printf("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%ld%s%s",
           BOLD, color, label, NC, round, total_rounds,
           color, bar, NC, g_pct, g_remaining_str,
           g_primary, g_points, NC, flag);
    fflush(stdout);
}

static void box_row(const char *color, const char *plain, const char *styled) {
    int pad = BOX_INNER - (int)strlen(plain);
    if (pad < 0) pad = 0;
    printf("%s\xe2\x95\x91%s%*s%s\xe2\x95\x91%s\n",
           color, styled, pad, "", color, NC);
}

static void phase_header(const char *label, int round, int total,
                         int minutes, const char *subtitle) {
    char sub[256];
    snprintf(sub, sizeof sub, "%s", subtitle);
    if (strlen(sub) > (size_t)(BOX_INNER - 4)) sub[BOX_INNER - 4] = '\0';
    const char *color = phase_color(label);
    char dur[64];
    duration_label(minutes, dur, sizeof dur);
    char bar[BOX_INNER * 4];
    bar[0] = '\0';
    for (int i = 0; i < BOX_INNER; i++) strcat(bar, "\xe2\x95\x90");

    char info[256];
    snprintf(info, sizeof info, "%s  \xc2\xb7  Round %d / %d  \xc2\xb7  %s",
             label, round, total, dur);
    char styled[512];
    snprintf(styled, sizeof styled,
             "  %s%s%s%s  \xc2\xb7  Round %d / %d  \xc2\xb7  %s",
             BOLD, label, NC, color, round, total, dur);
    char styled2[512];
    snprintf(styled2, sizeof styled2, "  %s%s%s%s", DIM, sub, NC, color);

    printf("\n");
    printf("%s\xe2\x95\x94%s\xe2\x95\x97%s\n", color, bar, NC);
    box_row(color, info, styled);
    box_row(color, sub, styled2);
    if (g_stdin_is_tty) {
        const char *keys = "  p pause  \xc2\xb7  s skip  \xc2\xb7  q quit  \xc2\xb7  Alt+T theme";
        char styled3[512];
        snprintf(styled3, sizeof styled3, "%s%s%s%s", DIM, keys, NC, color);
        box_row(color, keys, styled3);
    }
    printf("%s\xe2\x95\x9a%s\xe2\x95\x9d%s\n", color, bar, NC);
    printf("\n");
}

static void show_completion(const char *phase, int round, int total_rounds,
                            const char *next_phase, int skipped) {
    int width = 60;
    char line[80];
    memset(line, '=', width);
    line[width] = '\0';
    const char *title;
    if (skipped == 1) title = "PHASE SKIPPED";
    else if (strcmp(phase, "STUDY") == 0) title = "STUDY SESSION COMPLETE";
    else title = "BREAK COMPLETE";
    const char *color = phase_color(phase);
    int pad = (width + (int)strlen(title)) / 2;
    printf("\n");
    printf("%s%s%s\n", color, line, NC);
    printf("%s%*s%s%s\n", color, pad, "", title, NC);
    printf("%s%s%s\n", color, line, NC);
    printf("\n");
    printf("  Round:   %s%d%s / %d\n", BOLD, round, NC, total_rounds);
    printf("  Points:  %s%ld%s\n", g_primary, g_points, NC);
    printf("\n");
    if (strcmp(next_phase, "None") == 0) {
        printf("  Next:    %sSession complete%s\n", DIM, NC);
    } else {
        printf("  Next:    %s%s%s\n", BOLD, next_phase, NC);
    }
    printf("\n");
    printf("  %sPress Enter to continue...%s", g_primary, NC);
    fflush(stdout);
}

/* ---------------------------------------------------------------------------
 * Phase runner
 * ------------------------------------------------------------------------ */
static void phase_prepare(const char *ptype, int minutes, int round,
                          int total_rounds) {
    if (strcmp(ptype, "study") == 0) {
        snprintf(g_phase_label, sizeof g_phase_label, "STUDY");
        if (g_quote_count > 0) {
            int idx = rand() % g_quote_count;
            snprintf(g_phase_subtitle, sizeof g_phase_subtitle, "%s",
                     g_quote_list[idx]);
        } else {
            snprintf(g_phase_subtitle, sizeof g_phase_subtitle, "Stay focused.");
        }
    } else {
        snprintf(g_phase_label, sizeof g_phase_label, "BREAK");
        snprintf(g_phase_subtitle, sizeof g_phase_subtitle, "Relax and recharge.");
    }

    char dur[64];
    if (strcmp(ptype, "study") == 0) {
        if (round < total_rounds) {
            duration_label(g_break_min, dur, sizeof dur);
            snprintf(g_phase_next, sizeof g_phase_next, "Break (%s)", dur);
        } else {
            snprintf(g_phase_next, sizeof g_phase_next, "None");
        }
    } else {
        duration_label(g_study_min, dur, sizeof dur);
        snprintf(g_phase_next, sizeof g_phase_next, "Study (%s)", dur);
    }

    g_phase_total = (long)minutes * g_seconds_per_unit;
    g_phase_elapsed = 0;
    g_phase_paused = false;
    g_phase_skipped = false;
    g_phase_start = now_seconds();
    g_phase_paused_total = 0;
    g_phase_pause_at = 0;

    char dur2[64];
    duration_label(minutes, dur2, sizeof dur2);
    snprintf(g_session_text, sizeof g_session_text, "%s %d/%d",
             g_phase_label, round, total_rounds);
    fmt_hms(g_phase_total, g_remaining_str, sizeof g_remaining_str);
    g_pct = 0;
    if (strcmp(g_phase_next, "None") == 0) {
        snprintf(g_next_text, sizeof g_next_text, "Session complete");
    } else {
        snprintf(g_next_text, sizeof g_next_text, "%s", g_phase_next);
    }
    snprintf(g_message_text, sizeof g_message_text, "%s", g_phase_subtitle);

    char msg[512];
    snprintf(msg, sizeof msg, "Start: %s %d/%d (%s)",
             g_phase_label, round, total_rounds, dur2);
    log_event(msg);
    phase_header(g_phase_label, round, total_rounds, minutes, g_phase_subtitle);
    sync_state();
}

static void phase_handle_key(int round, int total_rounds) {
    if (strcmp(g_key, "p") == 0 || strcmp(g_key, "P") == 0
        || strcmp(g_key, " ") == 0) {
        if (g_phase_paused) {
            g_phase_paused_total += now_seconds() - g_phase_pause_at;
            g_phase_paused = false;
            char msg[256];
            snprintf(msg, sizeof msg, "Resumed: %s %d/%d",
                     g_phase_label, round, total_rounds);
            log_event(msg);
        } else {
            g_phase_paused = true;
            g_phase_pause_at = now_seconds();
            char msg[256];
            snprintf(msg, sizeof msg, "Paused: %s %d/%d",
                     g_phase_label, round, total_rounds);
            log_event(msg);
        }
    } else if (strcmp(g_key, "s") == 0 || strcmp(g_key, "S") == 0) {
        g_phase_skipped = true;
        char msg[256];
        snprintf(msg, sizeof msg, "Skipped: %s %d/%d",
                 g_phase_label, round, total_rounds);
        log_event(msg);
    } else if (strcmp(g_key, "q") == 0 || strcmp(g_key, "Q") == 0) {
        log_event("Quit requested by user");
        cleanup(0);
    } else if (strcmp(g_key, "alt-t") == 0) {
        cycle_theme();
    }
}

static void phase_count(int round, int total_rounds) {
    while (g_phase_elapsed < g_phase_total) {
        long remaining = g_phase_total - g_phase_elapsed;
        if (remaining < 0) remaining = 0;
        fmt_hms(remaining, g_remaining_str, sizeof g_remaining_str);
        g_pct = g_phase_total > 0
            ? (int)(g_phase_elapsed * 100 / g_phase_total) : 0;
        if (g_pct > 100) g_pct = 100;
        snprintf(g_session_text, sizeof g_session_text, "%s %d/%d",
                 g_phase_label, round, total_rounds);
        if (g_phase_paused) {
            strncat(g_session_text, " (PAUSED)",
                    sizeof g_session_text - strlen(g_session_text) - 1);
        }

        sync_state();
        draw_status(g_phase_label, round, total_rounds,
                    g_phase_elapsed, g_phase_total, g_phase_paused ? 1 : 0);

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
        snprintf(g_session_text, sizeof g_session_text, "%s %d/%d (SKIPPED)",
                 g_phase_label, round, total_rounds);
    } else {
        g_pct = 100;
        g_points += 1;
    }
    snprintf(g_remaining_str, sizeof g_remaining_str, "00:00:00");
    sync_state();
    draw_status(g_phase_label, round, total_rounds,
                g_phase_elapsed, g_phase_total, 0);
    printf("\n");
    char msg[256];
    snprintf(msg, sizeof msg, "End: %s %d/%d", g_phase_label, round, total_rounds);
    log_event(msg);

    play_alert();

    discard_pending_input();
    show_completion(g_phase_label, round, total_rounds, g_phase_next,
                    g_phase_skipped ? 1 : 0);
    wait_for_enter();
    stop_alert();
    printf("\n");
}

static void run_phase(const char *ptype, int minutes, int round,
                      int total_rounds) {
    phase_prepare(ptype, minutes, round, total_rounds);
    phase_count(round, total_rounds);
    phase_finish(round, total_rounds);
}

/* ---------------------------------------------------------------------------
 * Cleanup
 * ------------------------------------------------------------------------ */
static void reset_state_files(void) {
    snprintf(g_session_text, sizeof g_session_text, "stopped");
    snprintf(g_remaining_str, sizeof g_remaining_str, "00:00:00");
    g_pct = 0;
    g_next_text[0] = '\0';
    sync_state();
}

static void cleanup(int code) {
    if (g_in_cleanup) return;
    g_in_cleanup = true;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = SIG_IGN;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    g_state_finalized = true;
    stop_alert();
    reset_state_files();
    log_event("Protocol stopped manually");
    printf("\n");
    printf("%s%sInterrupted.%s %sState files reset to stopped.%s\n",
           g_secondary, BOLD, NC, DIM, NC);
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
    char msg[128];
    snprintf(msg, sizeof msg, "Protocol ended unexpectedly (exit %d)", code);
    log_event(msg);
}

static void handle_signal(int signum) {
    int code = signum == SIGINT ? 130 : signum == SIGTERM ? 143 : 129;
    cleanup(code);
}

/* ---------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------ */
static void finalize_session(void) {
    snprintf(g_session_text, sizeof g_session_text, "session complete");
    snprintf(g_remaining_str, sizeof g_remaining_str, "00:00:00");
    g_pct = 100;
    g_next_text[0] = '\0';
    sync_state();
    g_state_finalized = true;
    char msg[128];
    snprintf(msg, sizeof msg, "Protocol complete - total points: %ld", g_points);
    log_event(msg);
}

static void final_banner(void) {
    int banner_width = 60;
    const char *title = "ALL SESSIONS COMPLETE";
    int inner = banner_width - 2;
    int pad = (inner - (int)strlen(title)) / 2;
    char border[80];
    memset(border, '#', banner_width);
    border[banner_width] = '\0';
    printf("\n");
    printf("%s%s%s\n", g_primary, border, NC);
    printf("%s#%s%*s%s%s%*s%s#%s\n", g_primary, NC, pad, "", BOLD, title,
           inner - pad - (int)strlen(title), "", NC, g_primary);
    printf("%s%s%s\n", g_primary, border, NC);
    printf("\n");
    printf("  %sTotal Rounds:%s  %s%d%s\n", BOLD, NC, g_primary, g_rounds, NC);
    printf("  %sTotal Points:%s %s%ld%s\n", BOLD, NC, g_primary, g_points, NC);
    printf("\n");
    printf("%s%sGreat work!%s %sExiting.%s\n", g_primary, BOLD, NC, DIM, NC);
}

static void print_logo(void) {
    printf("%s\n", g_primary);
    printf("%s\n", LOGO);
    printf("%s\n", NC);
    printf("%s%s     Study / Break Timer Protocol%s\n", g_primary, BOLD, NC);
    printf("%s\xe2\x94\x80\xe2\x94\x80 live state written to "
           "date \xc2\xb7 day \xc2\xb7 session \xc2\xb7 timer \xc2\xb7 log%s\n",
           DIM, NC);
    printf("\n");
}

int main(int argc, char **argv) {
    /* PROG = basename(argv[0]) */
    const char *base = strrchr(argv[0], '/');
    snprintf(PROG, sizeof PROG, "%s", base ? base + 1 : argv[0]);
    START_TIME = time(NULL);
    srand((unsigned)START_TIME ^ (unsigned)getpid());
    setvbuf(stdout, NULL, _IONBF, 0);

    /* DIR = directory of the program */
    if (argv[0][0] == '/') {
        char *slash = strrchr(argv[0], '/');
        size_t n = (size_t)(slash - argv[0]);
        snprintf(g_dir, sizeof g_dir, "%.*s", (int)n, argv[0]);
    } else {
        if (strchr(argv[0], '/')) {
            char cwd[1024];
            if (getcwd(cwd, sizeof cwd)) {
                char *slash = strrchr(argv[0], '/');
                snprintf(g_dir, sizeof g_dir, "%s/%.*s", cwd,
                         (int)(slash - argv[0]), argv[0]);
            } else {
                snprintf(g_dir, sizeof g_dir, ".");
            }
        } else {
            if (getcwd(g_dir, sizeof g_dir) == NULL) snprintf(g_dir, sizeof g_dir, ".");
        }
    }

    /* Environment overrides (captured before the defaults are applied) */
    const char *e;
    if ((e = getenv("ALERT_SOUND"))) snprintf(g_env_alert_sound, sizeof g_env_alert_sound, "%s", e);
    if ((e = getenv("SINK_NAME"))) snprintf(g_env_sink_name, sizeof g_env_sink_name, "%s", e);
    if ((e = getenv("STATE_DIR"))) snprintf(g_env_state_dir, sizeof g_env_state_dir, "%s", e);
    if ((e = getenv("MAX_LOG_BYTES"))) snprintf(g_env_max_log_bytes, sizeof g_env_max_log_bytes, "%s", e);
    if ((e = getenv("QUOTES"))) snprintf(g_env_quotes, sizeof g_env_quotes, "%s", e);
    if ((e = getenv("THEME"))) snprintf(g_env_theme, sizeof g_env_theme, "%s", e);

    /* Built-in defaults */
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(g_alert_sound, sizeof g_alert_sound,
                 "%s/Videos/Alarm/n_alarm.mp3", home);
    } else {
        g_alert_sound[0] = '\0';
    }
    snprintf(g_sink_name, sizeof g_sink_name, "OBS_Alert_Sink");
    g_quote_count = DEFAULT_QUOTE_COUNT;
    for (int i = 0; i < DEFAULT_QUOTE_COUNT; i++) {
        snprintf(g_quote_list[i], 256, "%s", DEFAULT_QUOTE_LIST[i]);
    }
    g_primary = THEME_PRIMARY[0];
    g_secondary = THEME_SECONDARY[0];
    snprintf(g_theme_name, sizeof g_theme_name, "%s", THEME_NAMES[0]);

    parse_args(argc, argv);

    const char *cfg = find_config_file();
    if (cfg) load_config(cfg);

    /* Environment variables beat the config file. */
    if (*g_env_alert_sound) snprintf(g_alert_sound, sizeof g_alert_sound, "%s", g_env_alert_sound);
    if (*g_env_sink_name) snprintf(g_sink_name, sizeof g_sink_name, "%s", g_env_sink_name);
    if (*g_env_state_dir) snprintf(g_state_dir, sizeof g_state_dir, "%s", g_env_state_dir);
    if (*g_env_max_log_bytes) g_max_log_bytes = parse_long_safe(g_env_max_log_bytes, g_max_log_bytes);

    apply_quote_sources();
    sanity_knobs();

    setup_paths();
    select_theme();

    on_exit(on_exit_hook, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    setup_terminal();
    print_logo();
    setup_audio_sink();
    update_date_day();
    /* From here on the state files may be written (and have to be reset if
     * the program dies unexpectedly). */
    g_state_ready = true;

    char dur[64], rl[64];
    duration_label(g_study_min, dur, sizeof dur);
    rounds_label(g_rounds, rl, sizeof rl);
    char msg[512];
    snprintf(msg, sizeof msg, "Starting new study protocol: %s, %s study",
             rl, dur);
    char dur3[64];
    duration_label(g_break_min, dur3, sizeof dur3);
    char msg2[512];
    snprintf(msg2, sizeof msg2, "%s, %s break", msg, dur3);
    log_event(msg2);

    printf("%sProtocol:%s %s%s%s  %s|%s  %s%s%s study  %s|%s  %s%s%s break"
           "  %s|%s  %sTheme: %s%s\n",
           g_secondary, NC, BOLD, rl, NC, DIM, NC, BOLD, dur, NC, DIM, NC,
           BOLD, dur3, NC, DIM, NC, BOLD, g_theme_name, NC);
    if (*g_config_loaded) printf("%sConfig: %s%s\n", DIM, g_config_loaded, NC);
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
