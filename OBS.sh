#!/usr/bin/env bash
#
# OBS.sh - Study/break timer protocol
# Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
# progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
# use as Text sources in OBS Studio.
#
# Usage:   ./OBS.sh [options] <rounds> <study_minutes> <break_minutes>
# Example: ./OBS.sh 5 50 10            ->  5 rounds, 50 min study, 10 min break
#          ./OBS.sh --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
# Stop:    Ctrl+C, or press 'q' while a phase is running
# Theme:   press Alt+T while a phase is running (see --list-themes)

set -uo pipefail

# ---------------------------------------------------------------------------
# Color themes
#
# A theme is a pair of ANSI colors:
#   PRIMARY   - the bright accent: study phase, headings, points
#   SECONDARY - the soft accent: break phase, boxes, borders
# The theme can be changed while a phase is running with Alt+T; the choice
# is remembered in the state directory.
# ---------------------------------------------------------------------------
THEME_NAMES=(
    Purple Ocean Forest Sunset Rose Gold
    Mono   Ice    Ember  Neon   Cobalt Cherry
)
THEME_PRIMARY=(
    $'\e[1;35m' $'\e[1;36m' $'\e[1;32m' $'\e[1;33m' $'\e[1;95m' $'\e[1;93m'
    $'\e[1;37m' $'\e[1;96m' $'\e[1;91m' $'\e[1;92m' $'\e[1;34m' $'\e[1;91m'
)
THEME_SECONDARY=(
    $'\e[0;35m' $'\e[0;34m' $'\e[0;32m' $'\e[0;31m' $'\e[0;31m' $'\e[0;33m'
    $'\e[0;37m' $'\e[0;36m' $'\e[0;31m' $'\e[0;96m' $'\e[0;36m' $'\e[0;35m'
)

# The colors of the theme that is currently active.
PRIMARY="${THEME_PRIMARY[0]}"
SECONDARY="${THEME_SECONDARY[0]}"
THEME_NAME="${THEME_NAMES[0]}"
THEME_INDEX=0
# A theme that was just picked is shown in the status line for a moment.
THEME_NOTICE_UNTIL=0

BOLD=$'\e[1m'
DIM=$'\e[2m'
NC=$'\e[0m'

# ---------------------------------------------------------------------------
# Theme handling
# ---------------------------------------------------------------------------
# set_theme <index>: make the theme with that index the active one.
set_theme() {
    local i=${1:-0}
    (( i >= 0 && i < ${#THEME_NAMES[@]} )) || return 1
    THEME_INDEX=$i
    THEME_NAME="${THEME_NAMES[i]}"
    PRIMARY="${THEME_PRIMARY[i]}"
    SECONDARY="${THEME_SECONDARY[i]}"
    return 0
}

# theme_index <name>: the index of the theme with that name, case ignored.
theme_index() {
    local want=${1:-} i
    [[ -n "$want" ]] || return 1
    want=${want,,}
    for i in "${!THEME_NAMES[@]}"; do
        if [[ "${THEME_NAMES[i],,}" == "$want" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}

# save_theme: remember the active theme in the state directory.
save_theme() {
    [[ -n "$THEME_FILE" ]] || return 0
    printf '%s\n' "$THEME_NAME" > "$THEME_FILE" 2>/dev/null || true
}

# cycle_theme: switch to the next theme, remember it and show it for a
# moment in the status line.
cycle_theme() {
    local i=$(( (THEME_INDEX + 1) % ${#THEME_NAMES[@]} ))
    set_theme "$i"
    save_theme
    THEME_NOTICE_UNTIL=$(( SECONDS + 3 ))
    log_event "Theme changed to: $THEME_NAME"
}

# list_themes: print every available theme.
list_themes() {
    local i
    for i in "${!THEME_NAMES[@]}"; do
        printf '  %-8s %s%s%s\n' "${THEME_NAMES[i]}" \
            "${THEME_PRIMARY[i]}" "████" "${THEME_SECONDARY[i]}"
    done
}

# ---------------------------------------------------------------------------
# Environment overrides
#
# These are captured *first*: before the built-in defaults are applied and
# before the config file is sourced. Otherwise the defaults would clobber the
# environment, and the config file (which is shell code) would clobber the
# environment as well. The captured values are re-applied after the config
# file has been loaded, so the environment always wins over the config file.
# ---------------------------------------------------------------------------
ENV_ALERT_SOUND="${ALERT_SOUND:-}"
ENV_SINK_NAME="${SINK_NAME:-}"
ENV_STATE_DIR="${STATE_DIR:-}"
ENV_MAX_LOG_BYTES="${MAX_LOG_BYTES:-}"
ENV_QUOTES="${QUOTES:-}"
ENV_THEME="${THEME:-}"

# ---------------------------------------------------------------------------
# Built-in defaults
#
# Every one of these can be overridden by the config file or by an
# environment variable (see load_config). Precedence, lowest to highest:
#   built-in default  <  config file  <  environment variable  <  CLI flag
# ---------------------------------------------------------------------------
# HOME is not guaranteed to be set (a cron job or a container may not have
# it), and "set -u" would abort the script on "$HOME".
if [[ -n "${HOME:-}" ]]; then
    ALERT_SOUND="$HOME/Videos/Alarm/n_alarm.mp3"
else
    ALERT_SOUND=""      # no home directory -> no default alert file
fi
SINK_NAME="OBS_Alert_Sink"
STATE_DIR=""                 # empty -> the directory holding this script
MAX_LOG_BYTES=1048576        # rotate log.txt once it grows past this
ALERT_PID=0

# How wide the progress bar in the OBS files is (in characters).
FILE_BAR_WIDTH=20

# How long "Press Enter to continue" waits for a key when the input is not a
# terminal (a pipe that never closes must not hang the session forever).
NON_TTY_ENTER_TIMEOUT=300

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QUOTE_LIST=(
  "Focused effort beats scattered hours"
  "Every round finished is progress made"
  "Consistency beats intensity"
  "Start now, figure out the rest along the way"
  "A short break now means sharper focus next round"
)

# The running score and the date of the last state update. They are set
# before the config file is loaded, so a config file can seed them.
POINTS=0
LAST_DATE=""

# ---------------------------------------------------------------------------
# Argument parsing & validation
# ---------------------------------------------------------------------------
CONFIG_FILE=""
DRY_RUN=0
USE_ALERT=1
USE_SINK=1
ROUNDS=""
STUDY_MIN=""
BREAK_MIN=""
CLI_THEME=""

# "minutes" normally, "seconds" in --dry-run mode.
DURATION_UNIT="minutes"
# How many seconds one duration unit is worth.
SECONDS_PER_UNIT=60

# print_help [code]: print the help text and exit with <code> (default 0).
print_help() {
    local code=${1:-0}
    cat <<EOF
Usage: $(basename "$0") [options] <rounds> <study_minutes> <break_minutes>

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
  $(basename "$0") 5 50 10           # 5 rounds, 50 min study, 10 min break
  $(basename "$0") --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  $(basename "$0") --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | \$OBS_PANEL_CONFIG | \$XDG_CONFIG_HOME/obs-study-panel/config
EOF
    exit "$code"
}

# usage: print the help to stderr and exit with an error.
usage() {
    print_help 1 >&2
}

while (( $# )); do
    case "$1" in
        -h|--help)      print_help 0 ;;
        -c|--config)    [[ $# -ge 2 ]] || { echo "Error: $1 needs a file argument" >&2; usage; }
                        CONFIG_FILE=$2; shift 2 ;;
        -d|--dry-run)   DRY_RUN=1; shift ;;
        -n|--no-alert)  USE_ALERT=0; shift ;;
        -s|--no-sink)   USE_SINK=0; shift ;;
        -t|--theme)     [[ $# -ge 2 ]] || { echo "Error: $1 needs a theme name" >&2; usage; }
                        CLI_THEME=$2; shift 2 ;;
        --list-themes)  list_themes; exit 0 ;;
        --)             shift; break ;;
        -*)             echo "Error: unknown option: $1" >&2; usage ;;
        *)              break ;;
    esac
done

[ $# -eq 3 ] || usage
ROUNDS=$1
STUDY_MIN=$2
BREAK_MIN=$3

# Must be positive integers; reject leading-zero forms and silly ranges.
# At most 4 digits: longer numbers would overflow bash's 64-bit arithmetic and
# wrap around to a small value, slipping past the range checks below.
for val in "$ROUNDS" "$STUDY_MIN" "$BREAK_MIN"; do
    [[ "$val" =~ ^[1-9][0-9]{0,3}$ ]] || usage
done
# Hard caps to prevent runaway countdowns / disk fill.
(( ROUNDS    <= 50 ))  || { echo "Error: rounds must be <= 50" >&2;  usage; }
(( STUDY_MIN <= 600 )) || { echo "Error: study minutes must be <= 600" >&2; usage; }
(( BREAK_MIN <= 120 )) || { echo "Error: break minutes must be <= 120" >&2; usage; }

if (( DRY_RUN )); then
    DURATION_UNIT="seconds"
    SECONDS_PER_UNIT=1
fi

# ---------------------------------------------------------------------------
# Configuration file
#
# The file is sourced, so it is ordinary bash and can set any of the knobs
# below. It is looked up in this order:
#   1. --config FILE
#   2. $OBS_PANEL_CONFIG
#   3. $XDG_CONFIG_HOME/obs-study-panel/config  (~/.config/... by default)
#   4. obs-panel.conf next to this script
# A file given with --config is always used, even when it is missing (that
# is reported as an error); otherwise the first file of the list that exists
# is used.
# ---------------------------------------------------------------------------
find_config_file() {
    if [[ -n "$CONFIG_FILE" ]]; then
        printf '%s\n' "$CONFIG_FILE"
        return 0
    fi
    if [[ -n "${OBS_PANEL_CONFIG:-}" ]]; then
        printf '%s\n' "$OBS_PANEL_CONFIG"
        return 0
    fi
    local xdg="${XDG_CONFIG_HOME:-${HOME:-}/.config}/obs-study-panel/config"
    if [[ -f "$xdg" ]]; then
        printf '%s\n' "$xdg"
        return 0
    fi
    local local_cfg="$DIR/obs-panel.conf"
    if [[ -f "$local_cfg" ]]; then
        printf '%s\n' "$local_cfg"
        return 0
    fi
    return 1
}

# Turn a newline separated string into the QUOTE_LIST array.
quotes_to_list() {
    local raw=$1 line
    QUOTE_LIST=()
    while IFS= read -r line; do
        line=${line%$'\r'}
        [[ -n "$line" ]] && QUOTE_LIST+=("$line")
    done <<< "$raw"
}

load_config() {
    local file=$1
    if [[ ! -r "$file" ]]; then
        echo "Error: config file is not readable: $file" >&2
        exit 1
    fi
    # Check the syntax up front: bash only reports a syntax error in a sourced
    # file and then skips the rest of it, which would silently apply half of
    # the settings.
    local err
    if ! err=$(bash -n "$file" 2>&1); then
        echo "Error: syntax error in config file: $file" >&2
        [[ -n "$err" ]] && printf '%s\n' "$err" | head -n 3 >&2
        exit 1
    fi
    # The exit status is deliberately ignored: a config file whose last
    # command returns non-zero is perfectly valid.
    # shellcheck source=/dev/null
    source "$file" || true
    CONFIG_LOADED="$file"
}

CONFIG_LOADED=""
if cfg="$(find_config_file)"; then
    load_config "$cfg"
fi

# Environment variables beat the config file.
[[ -n "$ENV_ALERT_SOUND" ]]   && ALERT_SOUND="$ENV_ALERT_SOUND"
[[ -n "$ENV_SINK_NAME" ]]     && SINK_NAME="$ENV_SINK_NAME"
[[ -n "$ENV_STATE_DIR" ]]     && STATE_DIR="$ENV_STATE_DIR"
[[ -n "$ENV_MAX_LOG_BYTES" ]] && MAX_LOG_BYTES="$ENV_MAX_LOG_BYTES"

# QUOTES: a newline separated string, either from the environment or from the
# config file. The config file may also set QUOTE_LIST=(...) directly.
if [[ -n "$ENV_QUOTES" ]]; then
    quotes_to_list "$ENV_QUOTES"
elif [[ -n "${QUOTES:-}" ]]; then
    quotes_to_list "$QUOTES"
    unset QUOTES
fi

# Sanity check the knobs the config file may have mangled.
[[ "$MAX_LOG_BYTES" =~ ^[0-9]+$ ]] && (( MAX_LOG_BYTES > 0 )) \
    || MAX_LOG_BYTES=1048576
[[ "$FILE_BAR_WIDTH" =~ ^[0-9]+$ ]] && (( FILE_BAR_WIDTH > 0 && FILE_BAR_WIDTH <= 200 )) \
    || FILE_BAR_WIDTH=20
[[ "$NON_TTY_ENTER_TIMEOUT" =~ ^[0-9]+$ ]] \
    && (( NON_TTY_ENTER_TIMEOUT > 0 && NON_TTY_ENTER_TIMEOUT <= 3600 )) \
    || NON_TTY_ENTER_TIMEOUT=300

# ---------------------------------------------------------------------------
# Paths and runtime state
# ---------------------------------------------------------------------------
STATE_DIR="${STATE_DIR:-$DIR}"
mkdir -p "$STATE_DIR" || { echo "Error: cannot create state dir: $STATE_DIR" >&2; exit 1; }

DATE_FILE="$STATE_DIR/date.txt"
DAY_FILE="$STATE_DIR/day.txt"
SESSION_FILE="$STATE_DIR/session.txt"
TIMER_FILE="$STATE_DIR/timer.txt"
LOG_FILE="$STATE_DIR/log.txt"
PROGRESS_FILE="$STATE_DIR/progress.txt"
POINTS_FILE="$STATE_DIR/points.txt"
MESSAGE_FILE="$STATE_DIR/message.txt"
NEXT_FILE="$STATE_DIR/next.txt"
OVERLAY_FILE="$STATE_DIR/overlay.txt"
THEME_FILE="$STATE_DIR/theme.txt"

# ---------------------------------------------------------------------------
# Theme selection
#
# The theme is picked in this order:
#   --theme NAME  >  $THEME  >  config file  >  the saved theme  >  default
# ---------------------------------------------------------------------------
THEME_REQUEST="$CLI_THEME"
[[ -z "$THEME_REQUEST" && -n "$ENV_THEME" ]] && THEME_REQUEST="$ENV_THEME"
[[ -z "$THEME_REQUEST" && -n "${THEME:-}" ]] && THEME_REQUEST="$THEME"
if [[ -z "$THEME_REQUEST" && -f "$THEME_FILE" ]]; then
    THEME_REQUEST="$(head -n 1 "$THEME_FILE" 2>/dev/null || true)"
fi
if [[ -n "$THEME_REQUEST" ]]; then
    if theme_idx="$(theme_index "$THEME_REQUEST")"; then
        set_theme "$theme_idx"
    else
        echo "Warning: unknown theme '$THEME_REQUEST', using ${THEME_NAME}" >&2
    fi
fi

# The state that is mirrored into the OBS files (see publish_state).
SESSION_TEXT=""
REMAINING_STR="00:00:00"
PCT=0
NEXT_TEXT=""
MESSAGE_TEXT=""

# POINTS and LAST_DATE are set before the config file is loaded, so a config
# file can seed them.
LAST_DAY=""

# STATE_READY: 1 = the state files exist and can be written.
# STATE_FINALIZED: 1 = the files already show a final state (see cleanup /
# on_exit), so they must not be reset any more.
STATE_READY=0
STATE_FINALIZED=0

# ---------------------------------------------------------------------------
# Startup logo
# ---------------------------------------------------------------------------
print_logo() {
    echo "${PRIMARY}"
    cat <<'EOF'
 /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/
EOF
    echo "${NC}"
    echo "${PRIMARY}${BOLD}     Study / Break Timer Protocol${NC}"
    echo "${DIM}── live state written to date · day · session · timer · log${NC}"
    echo
}

# ---------------------------------------------------------------------------
# OBS state files
# ---------------------------------------------------------------------------
# Called every tick, but only touches the files when the date actually changes
# (so a session running past midnight rolls over). Uses printf's %()T builtin,
# so there are no `date` forks in the loop.
update_date_day() {
    local d dow
    printf -v d '%(%Y-%m-%d)T' -1
    [[ "$d" == "$LAST_DATE" ]] && return 0
    LAST_DATE=$d
    printf -v dow '%(%A)T' -1
    LAST_DAY=$dow
    printf '%s\n' "$d"   > "$DATE_FILE"
    printf '%s\n' "$dow" > "$DAY_FILE"
}

# sync_state: refresh the date files and write every OBS file.
sync_state() {
    update_date_day
    publish_state
}

# publish_state: write every OBS file from the current state variables.
# Only bash builtins, no forks - this runs once per second.
publish_state() {
    printf '%s\n' "$SESSION_TEXT"  > "$SESSION_FILE"
    printf '%s\n' "$REMAINING_STR" > "$TIMER_FILE"
    printf '%s\n' "$POINTS"        > "$POINTS_FILE"
    printf '%s\n' "$NEXT_TEXT"     > "$NEXT_FILE"
    printf '%s\n' "$MESSAGE_TEXT"  > "$MESSAGE_FILE"

    make_bar "$(( PCT * FILE_BAR_WIDTH / 100 ))" "$FILE_BAR_WIDTH" "#" "-"
    printf '[%s] %3d%%\n' "$BAR" "$PCT" > "$PROGRESS_FILE"

    # One-file overlay for people who want a single OBS text source.
    {
        printf '%s  %s\n' "$LAST_DATE" "$LAST_DAY"
        printf '%s\n' "$SESSION_TEXT"
        printf '%s\n' "$REMAINING_STR"
        printf '[%s] %3d%%\n' "$BAR" "$PCT"
        printf 'Pts: %d\n' "$POINTS"
        printf 'Next: %s\n' "$NEXT_TEXT"
        if [[ -n "$MESSAGE_TEXT" ]]; then
            printf '%s\n' "$MESSAGE_TEXT"
        fi
    } > "$OVERLAY_FILE"
}

# Keep log.txt from growing without bound: when it passes MAX_LOG_BYTES the
# previous version is moved aside and a fresh one is started.
rotate_log_if_needed() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null) || return 0
    [[ "$size" =~ ^[0-9]+$ ]] || return 0
    (( size < MAX_LOG_BYTES )) && return 0
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || return 0
    : > "$LOG_FILE"
}

log_event() {
    rotate_log_if_needed
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Audio alerts
# ---------------------------------------------------------------------------
# sink_is_ready: 0 = unknown/missing, 1 = present
sink_is_ready() {
    command -v pactl &>/dev/null || return 1
    # Single awk instead of `awk | grep -q`: under `pipefail`, grep -q exiting
    # early can SIGPIPE awk and make a present sink look missing.
    pactl list short sinks 2>/dev/null \
        | awk -v name="$SINK_NAME" '$2 == name { found = 1 } END { exit !found }'
}

setup_audio_sink() {
    (( USE_SINK )) || return 0
    command -v pactl &>/dev/null || return 0
    sink_is_ready && return 0
    pactl load-module module-null-sink sink_name="$SINK_NAME" \
        sink_properties=device.description="$SINK_NAME" &>/dev/null || true
}

stop_alert() {
    if (( ALERT_PID > 0 )); then
        kill "$ALERT_PID" 2>/dev/null
        ALERT_PID=0
    fi
}

# Throw away anything typed while the timer was running, so a stray Enter
# can't silently skip the "Press Enter to continue" pause.
discard_pending_input() {
    [[ -t 0 ]] || return 0
    local _junk
    while IFS= read -r -s -t 0.01 -n 1 _junk; do :; done
}

play_alert() {
    (( USE_ALERT )) || return 0
    stop_alert   # never let two alarms overlap
    if [[ -z "$ALERT_SOUND" || ! -f "$ALERT_SOUND" ]]; then
        echo "${DIM}(alert file not found: ${ALERT_SOUND:-none})${NC}"
        return 0
    fi

    # Pick whichever player is available. mpv first because it is what the
    # project shipped with originally; fall back to paplay / ffplay / cvlc so
    # the script still bleeps on a minimal install.
    local player=()
    if    command -v mpv    &>/dev/null; then player=(mpv --no-video --volume=70)
    elif  command -v paplay &>/dev/null; then player=(paplay)
    elif  command -v ffplay &>/dev/null; then player=(ffplay -nodisp -autoexit)
    elif  command -v cvlc   &>/dev/null; then player=(cvlc --play-and-exit --no-video --volume=70)
    else
        echo "${DIM}(no audio player found - install mpv / paplay / ffplay)${NC}"
        return 0
    fi

    # Self-heal the OBS sink: recreate it if it vanished since startup
    # (e.g. PulseAudio was restarted). Without this, sink_is_ready fails and
    # we fall back to the default output, which OBS can't capture.
    if (( USE_SINK )) && ! sink_is_ready; then
        setup_audio_sink
    fi

    if (( USE_SINK )) && sink_is_ready; then
        # PULSE_SINK routes any PulseAudio client through our virtual sink,
        # so OBS captures the alert independently of the user's mic. This is
        # far more portable than mpv's --audio-device flag, whose format has
        # changed across mpv versions (pulse/<name> vs. alsa/<name> vs ...).
        PULSE_SINK="$SINK_NAME" "${player[@]}" "$ALERT_SOUND" &>/dev/null &
        ALERT_PID=$!
        echo "${DIM}-> alert on OBS sink ($SINK_NAME)${NC}"
    else
        "${player[@]}" "$ALERT_SOUND" &>/dev/null &
        ALERT_PID=$!
        echo "${SECONDARY}-> alert on default device (OBS sink unavailable)${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Keyboard input
#
# The countdown polls for a single keypress instead of just sleeping, so a
# phase can be paused, skipped or aborted without killing the session.
# ---------------------------------------------------------------------------
KEY=""
KEY_READ=0

# wait_key <timeout>: wait up to <timeout> seconds for one keypress.
# Sets KEY to the character (empty for Enter, "alt-t" for Alt+T) and KEY_READ
# to 1 when a key was actually read, 0 on timeout.
wait_key() {
    local timeout=${1:-1} next=""
    KEY=""
    KEY_READ=0
    if [[ ! -t 0 ]]; then
        # Nothing to read from (piped input, cron, ...): just wait it out.
        sleep "$timeout"
        return 0
    fi
    # rc 0 = a key was read, rc 142 = timeout.
    if IFS= read -rsn1 -t "$timeout" KEY; then
        KEY_READ=1
    fi
    (( KEY_READ )) || return 0

    # ESC starts an escape sequence: the arrow keys send "ESC [ A", while
    # Alt+<key> sends "ESC <key>". Only Alt+T is used here, the rest is
    # swallowed.
    if [[ "$KEY" == $'\e' ]]; then
        KEY=""
        if IFS= read -rsn1 -t 0.3 next; then
            [[ "$next" == "T" || "$next" == "t" ]] && KEY="alt-t"
        fi
    fi
    return 0
}

# wait_for_enter: block until the user presses Enter.
# The read is done with a 1s timeout so the date can roll over at midnight
# while we sit here waiting.
wait_for_enter() {
    local line="" rc=0
    if [[ -t 0 ]]; then
        while true; do
            IFS= read -r -t 1 line
            rc=$?
            (( rc == 0 )) && return 0
            # rc 1 = EOF: stdin is gone, nothing left to wait for.
            (( rc < 128 )) && return 0
            update_date_day
        done
    fi
    # Not a terminal: the input may be a pipe that never sends anything and
    # never closes, so the wait has to be bounded or the session would hang
    # forever. A line that arrives is used right away.
    local waited=0
    while (( waited < NON_TTY_ENTER_TIMEOUT )); do
        IFS= read -r -t 5 line
        rc=$?
        (( rc == 0 )) && return 0
        # rc 1 = EOF: nothing left to read.
        (( rc < 128 )) && return 0
        waited=$(( waited + 5 ))
    done
    return 0
}

# ---------------------------------------------------------------------------
# Progress bars
# ---------------------------------------------------------------------------
# make_bar <filled> <width> <fill char> <empty char> [head char]
# Builds a progress bar in the global BAR. It uses no forks, so it is safe to
# call in the once-per-second tick loop.
make_bar() {
    local filled=$1 width=$2 fill=$3 empty=$4 head=${5:-} i
    BAR=""
    for (( i=0; i<width; i++ )); do
        if (( i < filled )); then
            if [[ -n "$head" ]] && (( i == filled - 1 )); then
                BAR+="$head"
            else
                BAR+="$fill"
            fi
        else
            BAR+="$empty"
        fi
    done
}

# ---------------------------------------------------------------------------
# Status / progress UI
# ---------------------------------------------------------------------------
TERM_BAR_WIDTH=24

draw_status() {
    local label=$1 round=$2 total_rounds=$3 elapsed=$4 total=$5 paused=$6
    local filled=0
    if (( total > 0 )); then
        filled=$(( elapsed * TERM_BAR_WIDTH / total ))
    fi
    (( filled > TERM_BAR_WIDTH )) && filled=$TERM_BAR_WIDTH
    make_bar "$filled" "$TERM_BAR_WIDTH" "=" " " ">"

    # The percentage comes from the shared state, so the terminal and the
    # OBS files always show the same number.
    local pct=$PCT

    phase_color "$label"
    local color=$COLOR

    local flag=""
    if (( paused )); then
        flag="${PRIMARY} PAUSED${NC}"
    fi
    # A theme that was just switched to is shown for a few seconds.
    if (( SECONDS < THEME_NOTICE_UNTIL )); then
        flag="${flag}  ${DIM}Theme: $THEME_NAME${NC}"
    fi

    printf '\r\033[K'
    printf '%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s' \
        "$BOLD" "$color" "$label" "$NC" \
        "$round" "$total_rounds" \
        "$color" "$BAR" "$NC" \
        "$pct" "$REMAINING_STR" \
        "$PRIMARY" "$POINTS" "$NC" "$flag"
}

BOX_INNER=62

# box_row <border color> <visible text> <styled text>
# Padding is computed from the *visible* text, because ANSI escape codes take
# bytes but no screen columns (printf %-62s would count them and skew the box).
box_row() {
    local color=$1 plain=$2 styled=$3
    local pad=$(( BOX_INNER - ${#plain} ))
    (( pad < 0 )) && pad=0
    printf '%s║%s%*s%s║%s\n' "$color" "$styled" "$pad" "" "$color" "$NC"
}

# phase_color <label>: the color of a phase - the study phase is bright, the
# break phase is soft. The result is put in the global COLOR, so the tick
# loop stays free of forks.
phase_color() {
    if [[ "$1" == "STUDY" ]]; then
        COLOR="$PRIMARY"
    else
        COLOR="$SECONDARY"
    fi
}

phase_header() {
    # $1 = label, $2 = round, $3 = total, $4 = minutes, $5 = subtitle
    local label=$1 round=$2 total=$3 minutes=$4 subtitle=${5:-}
    subtitle=${subtitle:0:$(( BOX_INNER - 4 ))}
    local color bar
    phase_color "$label"
    color=$COLOR
    printf -v bar '%*s' "$BOX_INNER" ''
    bar=${bar// /═}

    local info="${label}  ·  Round ${round} / ${total}  ·  $(duration_label "$minutes")"
    echo
    echo "${color}╔${bar}╗${NC}"
    box_row "$color" "  ${info}" \
        "  ${BOLD}${label}${NC}${color}  ·  Round ${round} / ${total}  ·  $(duration_label "$minutes")"
    box_row "$color" "  ${subtitle}" "  ${DIM}${subtitle}${NC}${color}"
    if [[ -t 0 ]]; then
        local keys="  p pause  ·  s skip  ·  q quit  ·  Alt+T theme"
        box_row "$color" "$keys" "${DIM}${keys}${NC}${color}"
    fi
    echo "${color}╚${bar}╝${NC}"
    echo
}

show_completion() {
    # $1 = phase label, $2 = round, $3 = total rounds, $4 = next phase
    # description, $5 = "skipped" when the phase was cut short
    local phase=$1 round=$2 total_rounds=$3 next_phase=$4 skipped=${5:-0}
    local width=60
    local line
    printf -v line '%*s' "$width" ''
    line=${line// /=}

    local title
    if [[ "$skipped" == "1" ]]; then
        title="PHASE SKIPPED"
    elif [[ "$phase" == "STUDY" ]]; then
        title="STUDY SESSION COMPLETE"
    else
        title="BREAK COMPLETE"
    fi

    phase_color "$phase"
    local color=$COLOR
    echo
    echo "${color}${line}${NC}"
    printf '%s%*s%s\n' "$color" $(( (width + ${#title}) / 2 )) "$title" "$NC"
    echo "${color}${line}${NC}"
    echo
    printf '  Round:   %s%d%s / %d\n'        "$BOLD" "$round" "$NC" "$total_rounds"
    printf '  Points:  %s%d%s\n'             "$PRIMARY" "$POINTS" "$NC"
    echo
    if [[ "$next_phase" == "None" ]]; then
        printf '  Next:    %sSession complete%s\n' "$DIM" "$NC"
    else
        printf '  Next:    %s%s%s\n' "$BOLD" "$next_phase" "$NC"
    fi
    echo
    printf '  %sPress Enter to continue...%s' "$PRIMARY" "$NC"
}

# ---------------------------------------------------------------------------
# Phase runner
# ---------------------------------------------------------------------------
duration_label() {
    local n=$1
    if (( n == 1 )); then
        if [[ "$DURATION_UNIT" == "seconds" ]]; then
            echo "1 second"
        else
            echo "1 minute"
        fi
    else
        echo "$n $DURATION_UNIT"
    fi
}

rounds_label() {
    if (( $1 == 1 )); then echo "1 round"; else echo "$1 rounds"; fi
}

# run_phase <type> <minutes> <round> <total_rounds>
# Run one phase: prepare it, count it down, close it.
run_phase() {
    phase_prepare "$1" "$2" "$3" "$4"
    phase_count "$3" "$4"
    phase_finish "$3" "$4"
}

# The state of the phase that is running. It lives in globals so that the
# three steps of a phase (prepare, count, finish) all work on the same data.
PHASE_LABEL=""
PHASE_SUBTITLE=""
PHASE_NEXT=""
PHASE_TOTAL=0
PHASE_ELAPSED=0
PHASE_PAUSED=0
PHASE_SKIPPED=0
# The wall-clock second the phase started, plus the seconds spent paused.
PHASE_START=0
PHASE_PAUSED_TOTAL=0
PHASE_PAUSE_AT=0

# phase_prepare <type> <minutes> <round> <total_rounds>
# Set up the state of a phase and draw its header.
phase_prepare() {
    local type=$1 minutes=$2 round=$3 total_rounds=$4

    if [[ "$type" == "study" ]]; then
        PHASE_LABEL="STUDY"
        if (( ${#QUOTE_LIST[@]} > 0 )); then
            PHASE_SUBTITLE="${QUOTE_LIST[$(( RANDOM % ${#QUOTE_LIST[@]} ))]}"
        else
            # An empty quote list would be a division by zero.
            PHASE_SUBTITLE="Stay focused."
        fi
    else
        PHASE_LABEL="BREAK"
        PHASE_SUBTITLE="Relax and recharge."
    fi

    # What comes after this phase, shown live in next.txt / overlay.txt.
    if [[ "$type" == "study" ]]; then
        if (( round < total_rounds )); then
            PHASE_NEXT="Break ($(duration_label "$BREAK_MIN"))"
        else
            PHASE_NEXT="None"
        fi
    else
        PHASE_NEXT="Study ($(duration_label "$STUDY_MIN"))"
    fi

    PHASE_TOTAL=$(( minutes * SECONDS_PER_UNIT ))
    PHASE_ELAPSED=0
    PHASE_PAUSED=0
    PHASE_SKIPPED=0
    # Count against the shell's wall-clock ($SECONDS) instead of adding 1 per
    # loop: each iteration costs a bit more than 1s (file writes, redraw), so
    # a naive counter makes a 50 min phase run noticeably longer.
    PHASE_START=$SECONDS
    # The seconds spent paused: the countdown freezes while the phase is
    # paused and resumes exactly where it left off.
    PHASE_PAUSED_TOTAL=0
    PHASE_PAUSE_AT=0

    SESSION_TEXT="$PHASE_LABEL $round/$total_rounds"
    printf -v REMAINING_STR '%02d:%02d:%02d' \
        $((PHASE_TOTAL/3600)) $((PHASE_TOTAL%3600/60)) $((PHASE_TOTAL%60))
    PCT=0
    NEXT_TEXT="$PHASE_NEXT"
    # "None" is the internal marker for "no phase follows"; on the stream
    # that reads better as a finished session.
    [[ "$NEXT_TEXT" == "None" ]] && NEXT_TEXT="Session complete"
    MESSAGE_TEXT="$PHASE_SUBTITLE"

    log_event "Start: $PHASE_LABEL $round/$total_rounds ($(duration_label "$minutes"))"
    phase_header "$PHASE_LABEL" "$round" "$total_rounds" "$minutes" "$PHASE_SUBTITLE"
    sync_state
}

# phase_handle_key <round> <total_rounds>: act on the key that was pressed.
phase_handle_key() {
    local round=$1 total_rounds=$2
    case "$KEY" in
        p|P|' ')
            if (( PHASE_PAUSED )); then
                # *Add* the pause to the total instead of replacing it: the
                # countdown has to stay frozen for the sum of every pause,
                # not just for the last one.
                PHASE_PAUSED_TOTAL=$(( PHASE_PAUSED_TOTAL + SECONDS - PHASE_PAUSE_AT ))
                PHASE_PAUSED=0
                log_event "Resumed: $PHASE_LABEL $round/$total_rounds"
            else
                PHASE_PAUSED=1
                PHASE_PAUSE_AT=$SECONDS
                log_event "Paused: $PHASE_LABEL $round/$total_rounds"
            fi
            ;;
        s|S)
            PHASE_SKIPPED=1
            log_event "Skipped: $PHASE_LABEL $round/$total_rounds"
            ;;
        q|Q)
            log_event "Quit requested by user"
            cleanup 0
            ;;
        alt-t)
            cycle_theme
            ;;
    esac
}

# phase_count <round> <total_rounds>: count the phase down and react to the
# keys that are pressed while it runs.
phase_count() {
    local round=$1 total_rounds=$2
    while (( PHASE_ELAPSED < PHASE_TOTAL )); do
        local remaining=$(( PHASE_TOTAL - PHASE_ELAPSED ))
        (( remaining < 0 )) && remaining=0
        printf -v REMAINING_STR '%02d:%02d:%02d' \
            $((remaining/3600)) $((remaining%3600/60)) $((remaining%60))
        PCT=0
        (( PHASE_TOTAL > 0 )) && PCT=$(( PHASE_ELAPSED * 100 / PHASE_TOTAL ))
        (( PCT > 100 )) && PCT=100
        SESSION_TEXT="$PHASE_LABEL $round/$total_rounds"
        (( PHASE_PAUSED )) && SESSION_TEXT="$SESSION_TEXT (PAUSED)"

        sync_state

        # Redraw every tick so the terminal countdown matches timer.txt. This
        # is pure bash builtins (no forks), so it costs next to nothing.
        draw_status "$PHASE_LABEL" "$round" "$total_rounds" \
            "$PHASE_ELAPSED" "$PHASE_TOTAL" "$PHASE_PAUSED"

        wait_key 1
        if (( KEY_READ )); then
            phase_handle_key "$round" "$total_rounds"
            # A skipped phase ends right away.
            (( PHASE_SKIPPED )) && break
        fi

        if (( ! PHASE_PAUSED )); then
            # Only recompute the elapsed time while the timer runs: while it
            # is paused the countdown has to stay frozen where it was.
            PHASE_ELAPSED=$(( SECONDS - PHASE_START - PHASE_PAUSED_TOTAL ))
        fi
    done
}

# phase_finish <round> <total_rounds>: close the phase, play the alert and
# wait for the user to continue.
phase_finish() {
    local round=$1 total_rounds=$2

    # The phase is over (finished, or skipped).
    if (( PHASE_SKIPPED )); then
        # A skipped phase doesn't earn a point.
        SESSION_TEXT="$PHASE_LABEL $round/$total_rounds (SKIPPED)"
    else
        PCT=100
        POINTS=$(( POINTS + 1 ))
    fi
    REMAINING_STR="00:00:00"
    sync_state
    # Final redraw so the bar ends at 100% / 00:00:00 instead of whatever the
    # last update happened to show. A skipped phase keeps its real progress,
    # so the bar matches the published PCT.
    draw_status "$PHASE_LABEL" "$round" "$total_rounds" \
        "$PHASE_ELAPSED" "$PHASE_TOTAL" "0"
    printf '\n'
    log_event "End: $PHASE_LABEL $round/$total_rounds"

    play_alert

    discard_pending_input
    show_completion "$PHASE_LABEL" "$round" "$total_rounds" \
        "$PHASE_NEXT" "$PHASE_SKIPPED"
    # Block until user is ready. No input besides Enter needed.
    wait_for_enter
    stop_alert   # silence the alarm once the user has acknowledged it
    echo
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
# The OBS files must never keep showing a frozen timer, so they are reset
# when the script stops - also when it dies unexpectedly.

reset_state_files() {
    SESSION_TEXT="stopped"
    REMAINING_STR="00:00:00"
    PCT=0
    NEXT_TEXT=""
    sync_state
}

cleanup() {
    local code=${1:-0}
    trap '' INT TERM HUP   # ignore repeated signals while shutting down
    STATE_FINALIZED=1
    # Kill any in-flight audio so the alert doesn't keep going after exit.
    stop_alert
    # Reset the OBS files first: on SIGHUP the terminal is already gone and
    # printing may fail, but the stream must not keep showing a frozen timer.
    reset_state_files
    log_event "Protocol stopped manually"
    {
        echo
        echo "${SECONDARY}${BOLD}Interrupted.${NC} ${DIM}State files reset to stopped.${NC}"
    } 2>/dev/null
    exit "$code"
}

# Runs on every exit, including an unexpected one (a bash error, a killed
# child, ...). It must not change the exit code of the script.
on_exit() {
    local rc=$?
    (( STATE_READY ))    || return 0
    (( STATE_FINALIZED )) && return 0
    STATE_FINALIZED=1
    stop_alert
    reset_state_files
    log_event "Protocol ended unexpectedly (exit $rc)"
    return 0
}

# Conventional exit codes: 128 + signal number.
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup 129' HUP
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
print_logo
setup_audio_sink
update_date_day
# From here on the state files may be written (and have to be reset if the
# script dies unexpectedly).
STATE_READY=1
log_event "Starting new study protocol: $(rounds_label "$ROUNDS"), $(duration_label "$STUDY_MIN") study, $(duration_label "$BREAK_MIN") break"

echo "${SECONDARY}Protocol:${NC} ${BOLD}$(rounds_label "$ROUNDS")${NC}  ${DIM}|${NC}  ${BOLD}$(duration_label "$STUDY_MIN")${NC} study  ${DIM}|${NC}  ${BOLD}$(duration_label "$BREAK_MIN")${NC} break  ${DIM}|${NC}  ${BOLD}Theme: ${THEME_NAME}${NC}"
if [[ -n "$CONFIG_LOADED" ]]; then
    echo "${DIM}Config: $CONFIG_LOADED${NC}"
fi
echo

for (( round=1; round<=ROUNDS; round++ )); do
    run_phase "study"  "$STUDY_MIN" "$round" "$ROUNDS"

    if (( round < ROUNDS )); then
        run_phase "break" "$BREAK_MIN" "$round" "$ROUNDS"
    fi
done

# Final OBS state: mark as complete.
SESSION_TEXT="session complete"
REMAINING_STR="00:00:00"
PCT=100
NEXT_TEXT=""
sync_state
# The files show the final state, so the exit trap must not reset them.
STATE_FINALIZED=1
log_event "Protocol complete - total points: $POINTS"

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
# The title is centered inside the box, so the banner reads the same way as
# the phase header.
BANNER_WIDTH=60
BANNER_TITLE="ALL SESSIONS COMPLETE"
BANNER_INNER=$(( BANNER_WIDTH - 2 ))
BANNER_PAD=$(( (BANNER_INNER - ${#BANNER_TITLE}) / 2 ))
BANNER_BORDER=""

echo
printf -v BANNER_BORDER '%*s' "$BANNER_WIDTH" ''
BANNER_BORDER=${BANNER_BORDER// /#}
echo "${PRIMARY}${BANNER_BORDER}${NC}"
printf '%s#%s%*s%s%s%*s%s#%s\n' \
    "$PRIMARY" "$NC" "$BANNER_PAD" "" "$BOLD" "$BANNER_TITLE" \
    "$(( BANNER_INNER - BANNER_PAD - ${#BANNER_TITLE} ))" "" "$NC" "$PRIMARY"
echo "${PRIMARY}${BANNER_BORDER}${NC}"
echo
printf '  %sTotal Rounds:%s  %s%d%s\n' "$BOLD" "$NC" "$PRIMARY" "$ROUNDS" "$NC"
printf '  %sTotal Points:%s %s%d%s\n' "$BOLD" "$NC" "$PRIMARY" "$POINTS" "$NC"
echo
echo "${PRIMARY}${BOLD}Great work!${NC} ${DIM}Exiting.${NC}"
