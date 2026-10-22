#!/usr/bin/env python3
#
# OBS.py - Study/break timer protocol (Python port of OBS.sh)
#
# Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
# progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
# use as Text sources in OBS Studio. OBS.sh is the reference implementation;
# see docs/port-spec.md for the behavior contract and README.md for usage.
#
# Requirements: Python 3.7+, bash (to load the bash-syntax config file).
#
# Usage:   ./OBS.py [options] <rounds> <study_minutes> <break_minutes>
# Example: ./OBS.py 5 50 10            ->  5 rounds, 50 min study, 10 min break
#          ./OBS.py --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
# Stop:    Ctrl+C, or press 'q' while a phase is running
# Theme:   press Alt+T while a phase is running (see --list-themes)
#
import os
import random
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tty

PROG = os.path.basename(sys.argv[0])
START_TIME = time.time()

try:
    sys.stdout.reconfigure(line_buffering=False, write_through=True)
except Exception:
    pass

# ---------------------------------------------------------------------------
# Color themes: (name, primary, secondary)
# ---------------------------------------------------------------------------
THEME_NAMES = ["Purple", "Ocean", "Forest", "Sunset", "Rose", "Gold",
               "Mono", "Ice", "Ember", "Neon", "Cobalt", "Cherry"]
THEME_PRIMARY = ["\x1b[1;35m", "\x1b[1;36m", "\x1b[1;32m", "\x1b[1;33m",
                 "\x1b[1;95m", "\x1b[1;93m", "\x1b[1;37m", "\x1b[1;96m",
                 "\x1b[1;91m", "\x1b[1;92m", "\x1b[1;34m", "\x1b[1;91m"]
THEME_SECONDARY = ["\x1b[0;35m", "\x1b[0;34m", "\x1b[0;32m", "\x1b[0;31m",
                   "\x1b[0;31m", "\x1b[0;33m", "\x1b[0;37m", "\x1b[0;36m",
                   "\x1b[0;31m", "\x1b[0;96m", "\x1b[0;36m", "\x1b[0;35m"]

PRIMARY = THEME_PRIMARY[0]
SECONDARY = THEME_SECONDARY[0]
THEME_NAME = THEME_NAMES[0]
THEME_INDEX = 0
THEME_NOTICE_UNTIL = 0

BOLD = "\x1b[1m"
DIM = "\x1b[2m"
NC = "\x1b[0m"

LOGO = r""" /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/"""

DEFAULT_QUOTE_LIST = [
    "Focused effort beats scattered hours",
    "Every round finished is progress made",
    "Consistency beats intensity",
    "Start now, figure out the rest along the way",
    "A short break now means sharper focus next round",
]


def set_theme(i):
    global THEME_INDEX, THEME_NAME, PRIMARY, SECONDARY
    if not (0 <= i < len(THEME_NAMES)):
        return False
    THEME_INDEX = i
    THEME_NAME = THEME_NAMES[i]
    PRIMARY = THEME_PRIMARY[i]
    SECONDARY = THEME_SECONDARY[i]
    return True


def theme_index(name):
    if not name:
        return None
    for i, t in enumerate(THEME_NAMES):
        if t.lower() == name.lower():
            return i
    return None


def save_theme():
    if THEME_FILE:
        try:
            with open(THEME_FILE, "w") as fh:
                fh.write(THEME_NAME + "\n")
        except OSError:
            pass


def cycle_theme():
    global THEME_NOTICE_UNTIL
    set_theme((THEME_INDEX + 1) % len(THEME_NAMES))
    save_theme()
    THEME_NOTICE_UNTIL = now_seconds() + 3
    log_event(f"Theme changed to: {THEME_NAME}")


def list_themes():
    for i in range(len(THEME_NAMES)):
        print(f"  {THEME_NAMES[i]:<8} {THEME_PRIMARY[i]}\u2588\u2588\u2588\u2588{THEME_SECONDARY[i]}")


def now_seconds():
    """Integer wall-clock seconds since program start (bash $SECONDS)."""
    return int(time.time() - START_TIME)


# ---------------------------------------------------------------------------
# Environment overrides (captured before the defaults are applied)
# ---------------------------------------------------------------------------
ENV_ALERT_SOUND = os.environ.get("ALERT_SOUND", "")
ENV_SINK_NAME = os.environ.get("SINK_NAME", "")
ENV_STATE_DIR = os.environ.get("STATE_DIR", "")
ENV_MAX_LOG_BYTES = os.environ.get("MAX_LOG_BYTES", "")
ENV_QUOTES = os.environ.get("QUOTES", "")
ENV_THEME = os.environ.get("THEME", "")

# ---------------------------------------------------------------------------
# Built-in defaults
# ---------------------------------------------------------------------------
ALERT_SOUND = os.path.join(os.environ.get("HOME", ""), "Videos/Alarm/n_alarm.mp3") \
    if os.environ.get("HOME") else ""
SINK_NAME = "OBS_Alert_Sink"
STATE_DIR = ""                       # empty -> the directory of this script
MAX_LOG_BYTES = 1048576
FILE_BAR_WIDTH = 20
NON_TTY_ENTER_TIMEOUT = 300
ALERT_PID = 0
DIR = os.path.dirname(os.path.abspath(__file__))
QUOTE_LIST = list(DEFAULT_QUOTE_LIST)
POINTS = 0
LAST_DATE = ""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIG_FILE = ""
DRY_RUN = False
USE_ALERT = True
USE_SINK = True
ROUNDS = STUDY_MIN = BREAK_MIN = 0
CLI_THEME = ""
DURATION_UNIT = "minutes"
SECONDS_PER_UNIT = 60
CONFIG_THEME = ""
CONFIG_QUOTES = ""
CONFIG_LOADED = ""


def help_text():
    return f"""Usage: {PROG} [options] <rounds> <study_minutes> <break_minutes>

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
  {PROG} 5 50 10           # 5 rounds, 50 min study, 10 min break
  {PROG} --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  {PROG} --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
"""


def print_help(code=0, stream=sys.stdout):
    stream.write(help_text())
    stream.flush()
    sys.exit(code)


def usage_error():
    """Full help to stderr, exit 1 - like the reference usage()."""
    print_help(1, sys.stderr)


NUM_RE = re.compile(r"^[1-9][0-9]{0,3}$")


def parse_args(argv):
    global CONFIG_FILE, DRY_RUN, USE_ALERT, USE_SINK, CLI_THEME
    global ROUNDS, STUDY_MIN, BREAK_MIN, DURATION_UNIT, SECONDS_PER_UNIT
    args = list(argv)
    positional = []
    while args:
        a = args[0]
        if a in ("-h", "--help"):
            print_help(0)
        elif a in ("-c", "--config"):
            if len(args) < 2:
                sys.stderr.write(f"Error: {a} needs a file argument\n")
                usage_error()
            CONFIG_FILE = args[1]
            del args[:2]
        elif a in ("-d", "--dry-run"):
            DRY_RUN = True
            del args[0]
        elif a in ("-n", "--no-alert"):
            USE_ALERT = False
            del args[0]
        elif a in ("-s", "--no-sink"):
            USE_SINK = False
            del args[0]
        elif a in ("-t", "--theme"):
            if len(args) < 2:
                sys.stderr.write(f"Error: {a} needs a theme name\n")
                usage_error()
            CLI_THEME = args[1]
            del args[:2]
        elif a == "--list-themes":
            list_themes()
            sys.exit(0)
        elif a == "--":
            del args[0]
            positional.extend(args)
            args = []
        elif a.startswith("-"):
            sys.stderr.write(f"Error: unknown option: {a}\n")
            usage_error()
        else:
            positional.extend(args)
            args = []

    if len(positional) != 3:
        usage_error()
    raw_rounds, raw_study, raw_break = positional
    for val in (raw_rounds, raw_study, raw_break):
        if not NUM_RE.match(val):
            usage_error()
    ROUNDS = int(raw_rounds)
    STUDY_MIN = int(raw_study)
    BREAK_MIN = int(raw_break)
    if ROUNDS > 50:
        sys.stderr.write("Error: rounds must be <= 50\n")
        usage_error()
    if STUDY_MIN > 600:
        sys.stderr.write("Error: study minutes must be <= 600\n")
        usage_error()
    if BREAK_MIN > 120:
        sys.stderr.write("Error: break minutes must be <= 120\n")
        usage_error()

    if DRY_RUN:
        DURATION_UNIT = "seconds"
        SECONDS_PER_UNIT = 1


# ---------------------------------------------------------------------------
# Configuration file
# ---------------------------------------------------------------------------
# The config file is bash source code (exactly like the reference). It is
# interpreted by a child bash that first seeds the pre-config default knobs,
# sources the file, and then dumps the resulting values for this program to
# pick up. The dump uses the ASCII unit separator 0x1F (bash printf '\037')
# between key and value and the record separator 0x1E ('\036') between
# records. A sourced file that calls `exit N` terminates the child before the
# dump is written, which this program detects and mirrors (like the
# reference, which sources in-process and would exit with N).
CONFIG_DUMP_SH = r"""
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
"""


def find_config_file():
    if CONFIG_FILE:
        return CONFIG_FILE
    if os.environ.get("OBS_PANEL_CONFIG"):
        return os.environ["OBS_PANEL_CONFIG"]
    xdg = os.path.join(os.environ.get("XDG_CONFIG_HOME",
                                      os.path.join(os.environ.get("HOME", ""), ".config")),
                       "obs-study-panel", "config")
    if os.path.isfile(xdg):
        return xdg
    local_cfg = os.path.join(DIR, "obs-panel.conf")
    if os.path.isfile(local_cfg):
        return local_cfg
    return None


def quotes_to_list(raw):
    global QUOTE_LIST
    QUOTE_LIST = [line for line in
                  (l.rstrip("\r") for l in raw.split("\n")) if line]


def parse_int(value, default=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def load_config(path):
    global ALERT_SOUND, SINK_NAME, STATE_DIR, MAX_LOG_BYTES, FILE_BAR_WIDTH
    global NON_TTY_ENTER_TIMEOUT, POINTS, LAST_DATE, QUOTE_LIST
    global CONFIG_LOADED, CONFIG_THEME, CONFIG_QUOTES

    if not os.access(path, os.R_OK):
        sys.stderr.write(f"Error: config file is not readable: {path}\n")
        sys.exit(1)
    # Syntax check up front, exactly like the reference.
    if shutil.which("bash") is None:
        sys.stderr.write(f"Error: bash is required to read the config file: {path}\n")
        sys.exit(1)
    proc = subprocess.run(["bash", "-n", path], capture_output=True)
    if proc.returncode != 0:
        sys.stderr.write(f"Error: syntax error in config file: {path}\n")
        err = proc.stderr.decode(errors="replace")
        lines = [l for l in err.split("\n") if l.strip()][:3]
        for line in lines:
            sys.stderr.write(line + "\n")
        sys.exit(1)

    dump_fd, dump_path = tempfile.mkstemp(prefix="obs-panel-conf-")
    os.close(dump_fd)
    child_env = os.environ.copy()
    # Seed the pre-config defaults, exactly what the reference holds while it
    # sources the file (the real environment's THEME/QUOTES pass through).
    child_env["ALERT_SOUND"] = ALERT_SOUND
    child_env["SINK_NAME"] = SINK_NAME
    child_env["STATE_DIR"] = ""
    child_env["MAX_LOG_BYTES"] = "1048576"
    child_env["FILE_BAR_WIDTH"] = "20"
    child_env["NON_TTY_ENTER_TIMEOUT"] = "300"
    child_env["POINTS"] = str(POINTS)
    child_env["LAST_DATE"] = LAST_DATE
    child_env["QUOTES_SEED"] = "\x1f".join(QUOTE_LIST)
    try:
        proc = subprocess.run(["bash", "-c", CONFIG_DUMP_SH, "obs-panel", path, dump_path],
                              env=child_env)
        rc = proc.returncode
        with open(dump_path, "rb") as fh:
            raw = fh.read()
    finally:
        try:
            os.unlink(dump_path)
        except OSError:
            pass

    if not raw:
        # The config called exit N before the dump was written: the
        # reference (sourcing in-process) would exit with N too.
        sys.exit(rc if rc != 0 else 1)

    values = {}
    quotes = []
    for record in raw.split(b"\x1e"):
        if not record:
            continue
        key, _, value = record.partition(b"\x1f")
        key = key.decode(errors="replace")
        value = value.decode(errors="replace")
        if key == "QUOTE":
            quotes.append(value)
        else:
            values[key] = value

    ALERT_SOUND = values.get("ALERT_SOUND", ALERT_SOUND)
    SINK_NAME = values.get("SINK_NAME", SINK_NAME)
    STATE_DIR = values.get("STATE_DIR", "")
    MAX_LOG_BYTES = values.get("MAX_LOG_BYTES", "1048576")
    FILE_BAR_WIDTH = values.get("FILE_BAR_WIDTH", "20")
    NON_TTY_ENTER_TIMEOUT = values.get("NON_TTY_ENTER_TIMEOUT", "300")
    CONFIG_THEME = values.get("THEME", "")
    POINTS = parse_int(values.get("POINTS", "0"), 0)
    LAST_DATE = values.get("LAST_DATE", "")
    CONFIG_QUOTES = values.get("QUOTES", "")
    # Zero QUOTE records means the config emptied the list: the seeded
    # defaults would have been dumped otherwise.
    QUOTE_LIST = quotes
    CONFIG_LOADED = path


def apply_quote_sources():
    """Env QUOTES > config QUOTES > config QUOTE_LIST (already loaded)."""
    global QUOTE_LIST
    if ENV_QUOTES:
        quotes_to_list(ENV_QUOTES)
    elif CONFIG_QUOTES:
        quotes_to_list(CONFIG_QUOTES)


def sanity_knobs():
    global MAX_LOG_BYTES, FILE_BAR_WIDTH, NON_TTY_ENTER_TIMEOUT
    if not (str(MAX_LOG_BYTES).isdigit() and int(MAX_LOG_BYTES) > 0):
        MAX_LOG_BYTES = 1048576
    else:
        MAX_LOG_BYTES = int(MAX_LOG_BYTES)
    if str(FILE_BAR_WIDTH).isdigit() and 0 < int(FILE_BAR_WIDTH) <= 200:
        FILE_BAR_WIDTH = int(FILE_BAR_WIDTH)
    else:
        FILE_BAR_WIDTH = 20
    if str(NON_TTY_ENTER_TIMEOUT).isdigit() and 0 < int(NON_TTY_ENTER_TIMEOUT) <= 3600:
        NON_TTY_ENTER_TIMEOUT = int(NON_TTY_ENTER_TIMEOUT)
    else:
        NON_TTY_ENTER_TIMEOUT = 300


# ---------------------------------------------------------------------------
# Paths and runtime state
# ---------------------------------------------------------------------------
DATE_FILE = DAY_FILE = SESSION_FILE = TIMER_FILE = LOG_FILE = ""
PROGRESS_FILE = POINTS_FILE = MESSAGE_FILE = NEXT_FILE = ""
OVERLAY_FILE = THEME_FILE = ""

SESSION_TEXT = ""
REMAINING_STR = "00:00:00"
PCT = 0
NEXT_TEXT = ""
MESSAGE_TEXT = ""
LAST_DAY = ""
STATE_READY = False
STATE_FINALIZED = False
IN_CLEANUP = False


def setup_paths():
    global STATE_DIR, DATE_FILE, DAY_FILE, SESSION_FILE, TIMER_FILE, LOG_FILE
    global PROGRESS_FILE, POINTS_FILE, MESSAGE_FILE, NEXT_FILE, OVERLAY_FILE, THEME_FILE
    STATE_DIR = STATE_DIR or DIR
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
    except OSError:
        sys.stderr.write(f"Error: cannot create state dir: {STATE_DIR}\n")
        sys.exit(1)
    DATE_FILE = os.path.join(STATE_DIR, "date.txt")
    DAY_FILE = os.path.join(STATE_DIR, "day.txt")
    SESSION_FILE = os.path.join(STATE_DIR, "session.txt")
    TIMER_FILE = os.path.join(STATE_DIR, "timer.txt")
    LOG_FILE = os.path.join(STATE_DIR, "log.txt")
    PROGRESS_FILE = os.path.join(STATE_DIR, "progress.txt")
    POINTS_FILE = os.path.join(STATE_DIR, "points.txt")
    MESSAGE_FILE = os.path.join(STATE_DIR, "message.txt")
    NEXT_FILE = os.path.join(STATE_DIR, "next.txt")
    OVERLAY_FILE = os.path.join(STATE_DIR, "overlay.txt")
    THEME_FILE = os.path.join(STATE_DIR, "theme.txt")


def select_theme():
    request = CLI_THEME
    if not request and ENV_THEME:
        request = ENV_THEME
    if not request and CONFIG_THEME:
        request = CONFIG_THEME
    if not request and os.path.isfile(THEME_FILE):
        try:
            with open(THEME_FILE) as fh:
                request = fh.readline().rstrip("\n")
        except OSError:
            pass
    if request:
        idx = theme_index(request)
        if idx is None:
            sys.stderr.write(f"Warning: unknown theme '{request}', using {THEME_NAME}\n")
        else:
            set_theme(idx)


# ---------------------------------------------------------------------------
# Startup logo
# ---------------------------------------------------------------------------
def print_logo():
    print(PRIMARY)
    print(LOGO)
    print(NC)
    print(f"{PRIMARY}{BOLD}     Study / Break Timer Protocol{NC}")
    print(f"{DIM}\u2500\u2500 live state written to date \u00b7 day \u00b7 session \u00b7 timer \u00b7 log{NC}")
    print()


# ---------------------------------------------------------------------------
# OBS state files
# ---------------------------------------------------------------------------
def _write(path, text):
    with open(path, "w") as fh:
        fh.write(text + "\n")


def update_date_day():
    global LAST_DATE, LAST_DAY
    d = time.strftime("%Y-%m-%d")
    if d == LAST_DATE:
        return
    LAST_DATE = d
    LAST_DAY = time.strftime("%A")
    _write(DATE_FILE, d)
    _write(DAY_FILE, LAST_DAY)


def sync_state():
    update_date_day()
    publish_state()


def make_bar(filled, width, fill, empty, head=""):
    chars = []
    for i in range(width):
        if i < filled:
            chars.append(head if (head and i == filled - 1) else fill)
        else:
            chars.append(empty)
    return "".join(chars)


def file_bar():
    return make_bar(PCT * FILE_BAR_WIDTH // 100, FILE_BAR_WIDTH, "#", "-")


def publish_state():
    bar = file_bar()
    _write(SESSION_FILE, SESSION_TEXT)
    _write(TIMER_FILE, REMAINING_STR)
    _write(POINTS_FILE, str(POINTS))
    _write(NEXT_FILE, NEXT_TEXT)
    _write(MESSAGE_FILE, MESSAGE_TEXT)
    _write(PROGRESS_FILE, f"[{bar}] {PCT:3d}%")
    overlay = [f"{LAST_DATE} {LAST_DAY}",
               SESSION_TEXT,
               REMAINING_STR,
               f"[{bar}] {PCT:3d}%",
               f"Pts: {POINTS}",
               f"Next: {NEXT_TEXT}"]
    if MESSAGE_TEXT:
        overlay.append(MESSAGE_TEXT)
    with open(OVERLAY_FILE, "w") as fh:
        fh.write("\n".join(overlay) + "\n")


def rotate_log_if_needed():
    try:
        if os.path.isfile(LOG_FILE) and os.path.getsize(LOG_FILE) >= MAX_LOG_BYTES:
            os.replace(LOG_FILE, LOG_FILE + ".1")
            open(LOG_FILE, "w").close()
    except OSError:
        pass


def log_event(msg):
    rotate_log_if_needed()
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Audio alerts
# ---------------------------------------------------------------------------
def _pactl_lines():
    try:
        proc = subprocess.run(["pactl", "list", "short", "sinks"],
                               capture_output=True, timeout=10)
        if proc.returncode != 0:
            return None
        return proc.stdout.decode(errors="replace").split("\n")
    except (OSError, subprocess.TimeoutExpired):
        return None


def sink_is_ready():
    if shutil.which("pactl") is None:
        return False
    lines = _pactl_lines()
    if lines is None:
        return False
    for line in lines:
        fields = line.split()
        if len(fields) > 1 and fields[1] == SINK_NAME:
            return True
    return False


def setup_audio_sink():
    if not USE_SINK:
        return
    if shutil.which("pactl") is None:
        return
    if sink_is_ready():
        return
    try:
        subprocess.run(["pactl", "load-module", "module-null-sink",
                        f"sink_name={SINK_NAME}",
                        f"sink_properties=device.description={SINK_NAME}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def stop_alert():
    global ALERT_PID
    if ALERT_PID > 0:
        try:
            os.kill(ALERT_PID, signal.SIGTERM)
        except OSError:
            pass
        ALERT_PID = 0


def play_alert():
    global ALERT_PID
    if not USE_ALERT:
        return
    stop_alert()
    if not ALERT_SOUND or not os.path.isfile(ALERT_SOUND):
        print(f"{DIM}(alert file not found: {ALERT_SOUND or 'none'}){NC}")
        return

    if shutil.which("mpv"):
        player = ["mpv", "--no-video", "--volume=70"]
    elif shutil.which("paplay"):
        player = ["paplay"]
    elif shutil.which("ffplay"):
        player = ["ffplay", "-nodisp", "-autoexit"]
    elif shutil.which("cvlc"):
        player = ["cvlc", "--play-and-exit", "--no-video", "--volume=70"]
    else:
        print(f"{DIM}(no audio player found - install mpv / paplay / ffplay){NC}")
        return

    if USE_SINK and not sink_is_ready():
        setup_audio_sink()

    try:
        if USE_SINK and sink_is_ready():
            env = dict(os.environ, PULSE_SINK=SINK_NAME)
            ALERT_PID = subprocess.Popen(player + [ALERT_SOUND], env=env,
                                          stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL).pid
            print(f"{DIM}-> alert on OBS sink ({SINK_NAME}){NC}")
        else:
            ALERT_PID = subprocess.Popen(player + [ALERT_SOUND],
                                         stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL).pid
            print(f"{SECONDARY}-> alert on default device (OBS sink unavailable){NC}")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Keyboard input
# ---------------------------------------------------------------------------
STDIN_IS_TTY = False
TERM_SAVED = None
KEY = ""
KEY_READ = False


def setup_terminal():
    global STDIN_IS_TTY, TERM_SAVED
    STDIN_IS_TTY = os.isatty(0)
    if STDIN_IS_TTY:
        try:
            TERM_SAVED = termios.tcgetattr(0)
            tty.setcbreak(0)
        except Exception:
            TERM_SAVED = None


def restore_terminal():
    global TERM_SAVED
    if TERM_SAVED is not None:
        try:
            termios.tcsetattr(0, termios.TCSADRAIN, TERM_SAVED)
        except Exception:
            pass
        TERM_SAVED = None


def read_byte_timeout(timeout):
    """One byte with a timeout. None = timeout, b'' = EOF."""
    try:
        r, _, _ = select.select([0], [], [], timeout)
    except OSError:
        return b""
    if not r:
        return None
    try:
        return os.read(0, 1)
    except OSError:
        return b""


def wait_key(timeout=1):
    global KEY, KEY_READ
    KEY = ""
    KEY_READ = False
    if not STDIN_IS_TTY:
        time.sleep(timeout)
        return
    b = read_byte_timeout(timeout)
    if b is None or b == b"":
        return
    KEY_READ = True
    if b == b"\x1b":
        KEY = ""
        nxt = read_byte_timeout(0.3)
        if nxt in (b"t", b"T"):
            KEY = "alt-t"
    else:
        KEY = b.decode("latin-1")


def discard_pending_input():
    if not STDIN_IS_TTY:
        return
    while True:
        try:
            r, _, _ = select.select([0], [], [], 0.01)
        except OSError:
            return
        if not r:
            return
        data = os.read(0, 4096)
        if not data:
            return


def wait_for_enter():
    if STDIN_IS_TTY:
        while True:
            b = read_byte_timeout(1)
            if b is None:
                update_date_day()
                continue
            if b == b"" or b == b"\n":
                return
    waited = 0
    while waited < NON_TTY_ENTER_TIMEOUT:
        slice_end = time.monotonic() + 5
        while True:
            remaining = slice_end - time.monotonic()
            if remaining <= 0:
                waited += 5
                break
            try:
                r, _, _ = select.select([0], [], [], remaining)
            except OSError:
                return
            if not r:
                waited += 5
                break
            data = os.read(0, 4096)
            if data == b"":
                return
            if b"\n" in data:
                return


# ---------------------------------------------------------------------------
# Status / progress UI
# ---------------------------------------------------------------------------
TERM_BAR_WIDTH = 24
BOX_INNER = 62


def phase_color(label):
    return PRIMARY if label == "STUDY" else SECONDARY


def draw_status(label, round_, total_rounds, elapsed, total, paused):
    filled = 0
    if total > 0:
        filled = elapsed * TERM_BAR_WIDTH // total
    filled = min(filled, TERM_BAR_WIDTH)
    bar = make_bar(filled, TERM_BAR_WIDTH, "=", " ", ">")
    color = phase_color(label)
    flag = ""
    if paused:
        flag = f"{PRIMARY} PAUSED{NC}"
    if now_seconds() < THEME_NOTICE_UNTIL:
        flag += f"  {DIM}Theme: {THEME_NAME}{NC}"
    print("\r\033[K", end="")
    print(f"{BOLD}{color}{label:<6}{NC} [{round_}/{total_rounds}] "
          f"{color}[{bar}]{NC} {PCT:3d}%  {REMAINING_STR}  "
          f"{PRIMARY}Pts:{POINTS}{NC}{flag}", end="")


def box_row(color, plain, styled):
    pad = BOX_INNER - len(plain)
    if pad < 0:
        pad = 0
    print(f"{color}\u2551{styled}{' ' * pad}{color}\u2551{NC}")


def duration_label(n):
    if n == 1:
        return "1 second" if DURATION_UNIT == "seconds" else "1 minute"
    return f"{n} {DURATION_UNIT}"


def rounds_label(n):
    return "1 round" if n == 1 else f"{n} rounds"


def phase_header(label, round_, total, minutes, subtitle):
    subtitle = subtitle[:BOX_INNER - 4]
    color = phase_color(label)
    bar = "\u2550" * BOX_INNER
    info = f"{label}  \u00b7  Round {round_} / {total}  \u00b7  {duration_label(minutes)}"
    print()
    print(f"{color}\u2554{bar}\u2557{NC}")
    box_row(color, f"  {info}",
            f"  {BOLD}{label}{NC}{color}  \u00b7  Round {round_} / {total}  \u00b7  {duration_label(minutes)}")
    box_row(color, f"  {subtitle}", f"  {DIM}{subtitle}{NC}{color}")
    if STDIN_IS_TTY:
        keys = "  p pause  \u00b7  s skip  \u00b7  q quit  \u00b7  Alt+T theme"
        box_row(color, keys, f"{DIM}{keys}{NC}{color}")
    print(f"{color}\u255a{bar}\u255d{NC}")
    print()


def show_completion(phase, round_, total_rounds, next_phase, skipped):
    width = 60
    line = "=" * width
    if skipped == 1:
        title = "PHASE SKIPPED"
    elif phase == "STUDY":
        title = "STUDY SESSION COMPLETE"
    else:
        title = "BREAK COMPLETE"
    color = phase_color(phase)
    print()
    print(f"{color}{line}{NC}")
    print(f"{color}{' ' * ((width + len(title)) // 2)}{title}{NC}")
    print(f"{color}{line}{NC}")
    print()
    print(f"  Round:   {BOLD}{round_}{NC} / {total_rounds}")
    print(f"  Points:  {PRIMARY}{POINTS}{NC}")
    print()
    if next_phase == "None":
        print(f"  Next:    {DIM}Session complete{NC}")
    else:
        print(f"  Next:    {BOLD}{next_phase}{NC}")
    print()
    print(f"  {PRIMARY}Press Enter to continue...{NC}", end="")


# ---------------------------------------------------------------------------
# Phase runner
# ---------------------------------------------------------------------------
PHASE_LABEL = ""
PHASE_SUBTITLE = ""
PHASE_NEXT = ""
PHASE_TOTAL = 0
PHASE_ELAPSED = 0
PHASE_PAUSED = False
PHASE_SKIPPED = False
PHASE_START = 0
PHASE_PAUSED_TOTAL = 0
PHASE_PAUSE_AT = 0


def fmt_hms(total):
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def phase_prepare(ptype, minutes, round_, total_rounds):
    global PHASE_LABEL, PHASE_SUBTITLE, PHASE_NEXT, PHASE_TOTAL, PHASE_ELAPSED
    global PHASE_PAUSED, PHASE_SKIPPED, PHASE_START, PHASE_PAUSED_TOTAL, PHASE_PAUSE_AT
    global SESSION_TEXT, REMAINING_STR, PCT, NEXT_TEXT, MESSAGE_TEXT

    if ptype == "study":
        PHASE_LABEL = "STUDY"
        PHASE_SUBTITLE = random.choice(QUOTE_LIST) if QUOTE_LIST else "Stay focused."
    else:
        PHASE_LABEL = "BREAK"
        PHASE_SUBTITLE = "Relax and recharge."

    if ptype == "study":
        if round_ < total_rounds:
            PHASE_NEXT = f"Break ({duration_label(BREAK_MIN)})"
        else:
            PHASE_NEXT = "None"
    else:
        PHASE_NEXT = f"Study ({duration_label(STUDY_MIN)})"

    PHASE_TOTAL = minutes * SECONDS_PER_UNIT
    PHASE_ELAPSED = 0
    PHASE_PAUSED = False
    PHASE_SKIPPED = False
    PHASE_START = now_seconds()
    PHASE_PAUSED_TOTAL = 0
    PHASE_PAUSE_AT = 0

    SESSION_TEXT = f"{PHASE_LABEL} {round_}/{total_rounds}"
    REMAINING_STR = fmt_hms(PHASE_TOTAL)
    PCT = 0
    NEXT_TEXT = "Session complete" if PHASE_NEXT == "None" else PHASE_NEXT
    MESSAGE_TEXT = PHASE_SUBTITLE

    log_event(f"Start: {PHASE_LABEL} {round_}/{total_rounds} ({duration_label(minutes)})")
    phase_header(PHASE_LABEL, round_, total_rounds, minutes, PHASE_SUBTITLE)
    sync_state()


def phase_handle_key(round_, total_rounds):
    global PHASE_PAUSED, PHASE_PAUSED_TOTAL, PHASE_PAUSE_AT, PHASE_SKIPPED
    if KEY in ("p", "P", " "):
        if PHASE_PAUSED:
            PHASE_PAUSED_TOTAL += now_seconds() - PHASE_PAUSE_AT
            PHASE_PAUSED = False
            log_event(f"Resumed: {PHASE_LABEL} {round_}/{total_rounds}")
        else:
            PHASE_PAUSED = True
            PHASE_PAUSE_AT = now_seconds()
            log_event(f"Paused: {PHASE_LABEL} {round_}/{total_rounds}")
    elif KEY in ("s", "S"):
        PHASE_SKIPPED = True
        log_event(f"Skipped: {PHASE_LABEL} {round_}/{total_rounds}")
    elif KEY in ("q", "Q"):
        log_event("Quit requested by user")
        cleanup(0)
    elif KEY == "alt-t":
        cycle_theme()


def phase_count(round_, total_rounds):
    global PHASE_ELAPSED, SESSION_TEXT, REMAINING_STR, PCT
    while PHASE_ELAPSED < PHASE_TOTAL:
        remaining = PHASE_TOTAL - PHASE_ELAPSED
        if remaining < 0:
            remaining = 0
        REMAINING_STR = fmt_hms(remaining)
        PCT = PHASE_ELAPSED * 100 // PHASE_TOTAL if PHASE_TOTAL > 0 else 0
        if PCT > 100:
            PCT = 100
        SESSION_TEXT = f"{PHASE_LABEL} {round_}/{total_rounds}"
        if PHASE_PAUSED:
            SESSION_TEXT += " (PAUSED)"

        sync_state()
        draw_status(PHASE_LABEL, round_, total_rounds, PHASE_ELAPSED, PHASE_TOTAL,
                    1 if PHASE_PAUSED else 0)

        wait_key(1)
        if KEY_READ:
            phase_handle_key(round_, total_rounds)
            # A skipped phase ends right away.
            if PHASE_SKIPPED:
                break
        # CRASH-INJECT-POINT
        if not PHASE_PAUSED:
            # Only recompute the elapsed time while the timer runs: while it
            # is paused the countdown has to stay frozen where it was.
            PHASE_ELAPSED = now_seconds() - PHASE_START - PHASE_PAUSED_TOTAL


def phase_finish(round_, total_rounds):
    global SESSION_TEXT, REMAINING_STR, PCT, POINTS
    if PHASE_SKIPPED:
        # A skipped phase doesn't earn a point.
        SESSION_TEXT = f"{PHASE_LABEL} {round_}/{total_rounds} (SKIPPED)"
    else:
        PCT = 100
        POINTS += 1
    REMAINING_STR = "00:00:00"
    sync_state()
    draw_status(PHASE_LABEL, round_, total_rounds, PHASE_ELAPSED, PHASE_TOTAL, 0)
    print()
    log_event(f"End: {PHASE_LABEL} {round_}/{total_rounds}")

    play_alert()

    discard_pending_input()
    show_completion(PHASE_LABEL, round_, total_rounds, PHASE_NEXT,
                    1 if PHASE_SKIPPED else 0)
    # Block until user is ready. No input besides Enter needed.
    wait_for_enter()
    stop_alert()
    print()


def run_phase(ptype, minutes, round_, total_rounds):
    phase_prepare(ptype, minutes, round_, total_rounds)
    phase_count(round_, total_rounds)
    phase_finish(round_, total_rounds)


# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
def reset_state_files():
    global SESSION_TEXT, REMAINING_STR, PCT, NEXT_TEXT
    SESSION_TEXT = "stopped"
    REMAINING_STR = "00:00:00"
    PCT = 0
    NEXT_TEXT = ""
    sync_state()


def cleanup(code):
    global STATE_FINALIZED, IN_CLEANUP
    if IN_CLEANUP:
        return
    IN_CLEANUP = True
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, signal.SIG_IGN)
    STATE_FINALIZED = True
    # Kill any in-flight audio so the alert doesn't keep going after exit.
    stop_alert()
    try:
        reset_state_files()
    except Exception:
        pass
    try:
        log_event("Protocol stopped manually")
    except Exception:
        pass
    try:
        sys.stdout.write("\n")
        sys.stdout.write(f"{SECONDARY}{BOLD}Interrupted.{NC} "
                         f"{DIM}State files reset to stopped.{NC}\n")
        sys.stdout.flush()
    except Exception:
        pass
    restore_terminal()
    sys.exit(code)


def on_unexpected_death(rc):
    global STATE_FINALIZED
    if not STATE_READY:
        return
    if STATE_FINALIZED:
        return
    STATE_FINALIZED = True
    stop_alert()
    try:
        reset_state_files()
    except Exception:
        pass
    try:
        log_event(f"Protocol ended unexpectedly (exit {rc})")
    except Exception:
        pass


def handle_signal(signum, _frame):
    code = {signal.SIGINT: 130, signal.SIGTERM: 143, signal.SIGHUP: 129}[signum]
    cleanup(code)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def finalize_session():
    global SESSION_TEXT, REMAINING_STR, PCT, NEXT_TEXT, STATE_FINALIZED
    SESSION_TEXT = "session complete"
    REMAINING_STR = "00:00:00"
    PCT = 100
    NEXT_TEXT = ""
    sync_state()
    STATE_FINALIZED = True
    log_event(f"Protocol complete - total points: {POINTS}")


def final_banner():
    banner_width = 60
    title = "ALL SESSIONS COMPLETE"
    inner = banner_width - 2
    pad = (inner - len(title)) // 2
    border = "#" * banner_width
    print()
    print(f"{PRIMARY}{border}{NC}")
    print(f"{PRIMARY}#{NC}{' ' * pad}{BOLD}{title}{' ' * (inner - pad - len(title))}{NC}#{PRIMARY}")
    print(f"{PRIMARY}{border}{NC}")
    print()
    print(f"  {BOLD}Total Rounds:{NC}  {PRIMARY}{ROUNDS}{NC}")
    print(f"  {BOLD}Total Points:{NC} {PRIMARY}{POINTS}{NC}")
    print()
    print(f"{PRIMARY}{BOLD}Great work!{NC} {DIM}Exiting.{NC}")


def main():
    global STATE_READY
    parse_args(sys.argv[1:])

    cfg = find_config_file()
    if cfg:
        load_config(cfg)

    # Environment variables beat the config file.
    global ALERT_SOUND, SINK_NAME, STATE_DIR, MAX_LOG_BYTES
    if ENV_ALERT_SOUND:
        ALERT_SOUND = ENV_ALERT_SOUND
    if ENV_SINK_NAME:
        SINK_NAME = ENV_SINK_NAME
    if ENV_STATE_DIR:
        STATE_DIR = ENV_STATE_DIR
    if ENV_MAX_LOG_BYTES:
        MAX_LOG_BYTES = ENV_MAX_LOG_BYTES

    apply_quote_sources()
    sanity_knobs()

    setup_paths()
    select_theme()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGHUP, handle_signal)

    setup_terminal()
    try:
        print_logo()
        setup_audio_sink()
        update_date_day()
        # From here on the state files may be written (and have to be reset
        # if the program dies unexpectedly).
        STATE_READY = True
        log_event(f"Starting new study protocol: {rounds_label(ROUNDS)}, "
                  f"{duration_label(STUDY_MIN)} study, {duration_label(BREAK_MIN)} break")

        print(f"{SECONDARY}Protocol:{NC} {BOLD}{rounds_label(ROUNDS)}{NC}  {DIM}|{NC}  "
              f"{BOLD}{duration_label(STUDY_MIN)}{NC} study  {DIM}|{NC}  "
              f"{BOLD}{duration_label(BREAK_MIN)}{NC} break  {DIM}|{NC}  "
              f"{BOLD}Theme: {THEME_NAME}{NC}")
        if CONFIG_LOADED:
            print(f"{DIM}Config: {CONFIG_LOADED}{NC}")
        print()

        try:
            for round_ in range(1, ROUNDS + 1):
                run_phase("study", STUDY_MIN, round_, ROUNDS)
                if round_ < ROUNDS:
                    run_phase("break", BREAK_MIN, round_, ROUNDS)
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
            on_unexpected_death(code)
            raise
        except BaseException:
            on_unexpected_death(1)
            raise

        finalize_session()
        final_banner()
    finally:
        restore_terminal()
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # Ctrl+C before the signal handler was installed (startup phase).
        restore_terminal()
        sys.exit(130)
