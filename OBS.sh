#!/usr/bin/env bash
#
# OBS.sh - Study/break timer protocol
# Writes live state to 5 text files (date.txt, day.txt, session.txt,
# timer.txt, log.txt) for use as Text sources in OBS Studio.
#
# Usage:   ./OBS.sh [options] <rounds> <study_minutes> <break_minutes>
# Example: ./OBS.sh 5 50 10            ->  5 rounds, 50 min study, 10 min break
#          ./OBS.sh --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
# Stop:    Ctrl+C, or press 'q' while a phase is running

set -uo pipefail

# ---------------------------------------------------------------------------
# Terminal colors - Purple theme
# ---------------------------------------------------------------------------
PURPLE=$'\e[0;35m'
MAGENTA=$'\e[1;35m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
NC=$'\e[0m'

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

# ---------------------------------------------------------------------------
# Built-in defaults
#
# Every one of these can be overridden by the config file or by an
# environment variable (see load_config). Precedence, lowest to highest:
#   built-in default  <  config file  <  environment variable  <  CLI flag
# ---------------------------------------------------------------------------
ALERT_SOUND="$HOME/Videos/Alarm/n_alarm.mp3"
SINK_NAME="OBS_Alert_Sink"
STATE_DIR=""                 # empty -> the directory holding this script
MAX_LOG_BYTES=1048576        # rotate log.txt once it grows past this
ALERT_PID=0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QUOTE_LIST=(
  "Focused effort beats scattered hours"
  "Every round finished is progress made"
  "Consistency beats intensity"
  "Start now, figure out the rest along the way"
  "A short break now means sharper focus next round"
)

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

# "minutes" normally, "seconds" in --dry-run mode.
DURATION_UNIT="minutes"
# How many seconds one duration unit is worth.
SECONDS_PER_UNIT=60

usage() {
    {
        echo "Usage: $0 [options] <rounds> <study_minutes> <break_minutes>"
        echo
        echo "Options:"
        echo "  -h, --help          Show this help and exit"
        echo "  -c, --config FILE   Load settings from FILE (bash syntax)"
        echo "  -d, --dry-run       Treat the durations as seconds (fast testing)"
        echo "  -n, --no-alert      Disable the audio alert"
        echo "  -s, --no-sink       Don't create or use the OBS virtual audio sink"
        echo
        echo "Example: $0 5 50 10"
        echo "Example: $0 --config ~/obs-panel.conf 5 50 10"
        echo
        echo "Environment overrides: ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES"
    } >&2
    exit 1
}

print_help() {
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

Arguments:
  rounds             1-50   number of study rounds
  study_minutes      1-600  length of a study phase
  break_minutes      1-120  length of a break phase

Examples:
  $(basename "$0") 5 50 10           # 5 rounds, 50 min study, 10 min break
  $(basename "$0") --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break

Environment overrides: ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES
EOF
}

while (( $# )); do
    case "$1" in
        -h|--help)      print_help; exit 0 ;;
        -c|--config)    [[ $# -ge 2 ]] || { echo "Error: $1 needs a file argument" >&2; usage; }
                        CONFIG_FILE=$2; shift 2 ;;
        -d|--dry-run)   DRY_RUN=1; shift ;;
        -n|--no-alert)  USE_ALERT=0; shift ;;
        -s|--no-sink)   USE_SINK=0; shift ;;
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
# Only the first file that exists is used.
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
    local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/obs-study-panel/config"
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
    # shellcheck source=/dev/null
    if ! source "$file"; then
        echo "Error: could not load config file: $file" >&2
        exit 1
    fi
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

# How wide the progress bar in the OBS files is (in characters).
FILE_BAR_WIDTH=20

# The state that is mirrored into the OBS files (see publish_state).
SESSION_TEXT=""
REMAINING_STR="00:00:00"
PCT=0
NEXT_TEXT=""
MESSAGE_TEXT=""

POINTS=0
LAST_DATE=""
LAST_DAY=""

# ---------------------------------------------------------------------------
# Startup logo
# ---------------------------------------------------------------------------
print_logo() {
    echo "${MAGENTA}"
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
    echo "${MAGENTA}${BOLD}     Study / Break Timer Protocol${NC}"
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

# publish_state: write every OBS file from the current state variables.
# Only bash builtins, no forks - this runs once per second.
publish_state() {
    printf '%s\n' "$SESSION_TEXT"  > "$SESSION_FILE"
    printf '%s\n' "$REMAINING_STR" > "$TIMER_FILE"
    printf '%s\n' "$POINTS"        > "$POINTS_FILE"
    printf '%s\n' "$NEXT_TEXT"     > "$NEXT_FILE"
    printf '%s\n' "$MESSAGE_TEXT"  > "$MESSAGE_FILE"

    local i bar=""
    for (( i=0; i<FILE_BAR_WIDTH; i++ )); do
        if (( i < PCT * FILE_BAR_WIDTH / 100 )); then
            bar+="#"
        else
            bar+="-"
        fi
    done
    printf '[%s] %3d%%\n' "$bar" "$PCT" > "$PROGRESS_FILE"

    # One-file overlay for people who want a single OBS text source.
    {
        printf '%s  %s\n' "$LAST_DATE" "$LAST_DAY"
        printf '%s\n' "$SESSION_TEXT"
        printf '%s\n' "$REMAINING_STR"
        printf '[%s] %3d%%\n' "$bar" "$PCT"
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
    if [[ ! -f "$ALERT_SOUND" ]]; then
        echo "${DIM}(alert file not found: $ALERT_SOUND)${NC}"
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
        echo "${PURPLE}-> alert on default device (OBS sink unavailable)${NC}"
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
# Sets KEY to the character (empty for Enter) and KEY_READ to 1 when a key
# was actually read, 0 on timeout.
wait_key() {
    local timeout=${1:-1}
    KEY=""
    KEY_READ=0
    if [[ -t 0 ]]; then
        # rc 0 = a key was read, rc 142 = timeout.
        if IFS= read -rsn1 -t "$timeout" KEY; then
            KEY_READ=1
        fi
    else
        # Nothing to read from (piped input, cron, ...): just wait it out.
        sleep "$timeout"
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
    IFS= read -r line || true
    return 0
}

# ---------------------------------------------------------------------------
# Status / progress UI
# ---------------------------------------------------------------------------
draw_status() {
    local label=$1 round=$2 total_rounds=$3 elapsed=$4 total=$5 paused=$6
    local width=24
    local filled=0
    if (( total > 0 )); then
        filled=$(( elapsed * width / total ))
    fi
    (( filled > width )) && filled=$width
    local i bar=""
    for (( i=0; i<width; i++ )); do
        if (( i < filled )); then
            if (( i == filled - 1 )); then
                bar+=">"
            else
                bar+="="
            fi
        else
            bar+=" "
        fi
    done

    local pct=0
    (( total > 0 )) && pct=$(( elapsed * 100 / total ))

    local color
    if [[ "$label" == "STUDY" ]]; then
        color="$MAGENTA"
    else
        color="$PURPLE"
    fi

    local flag=""
    if (( paused )); then
        flag="${MAGENTA} PAUSED${NC}"
    fi

    printf '\r\033[K'
    printf '%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s' \
        "$BOLD" "$color" "$label" "$NC" \
        "$round" "$total_rounds" \
        "$color" "$bar" "$NC" \
        "$pct" "$REMAINING_STR" \
        "$MAGENTA" "$POINTS" "$NC" "$flag"
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

phase_header() {
    # $1 = label, $2 = round, $3 = total, $4 = minutes, $5 = subtitle
    local label=$1 round=$2 total=$3 minutes=$4 subtitle=${5:0:$(( BOX_INNER - 4 ))}
    local color bar
    if [[ "$label" == "STUDY" ]]; then
        color="$MAGENTA"
    else
        color="$PURPLE"
    fi
    printf -v bar '%*s' "$BOX_INNER" ''
    bar=${bar// /═}

    local info="${label}  ·  Round ${round} / ${total}  ·  ${minutes} ${DURATION_UNIT}"
    echo
    echo "${color}╔${bar}╗${NC}"
    box_row "$color" "  ${info}" \
        "  ${BOLD}${label}${NC}${color}  ·  Round ${round} / ${total}  ·  ${minutes} ${DURATION_UNIT}"
    box_row "$color" "  ${subtitle}" "  ${DIM}${subtitle}${NC}${color}"
    if [[ -t 0 ]]; then
        box_row "$color" "  p pause  ·  s skip  ·  q quit" \
            "  ${DIM}p pause  ·  s skip  ·  q quit${NC}${color}"
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
    line=$(printf '=%.0s' $(seq 1 $width))

    local title
    if [[ "$skipped" == "1" ]]; then
        title="PHASE SKIPPED"
    elif [[ "$phase" == "STUDY" ]]; then
        title="STUDY SESSION COMPLETE"
    else
        title="BREAK COMPLETE"
    fi

    local color
    if [[ "$phase" == "STUDY" ]]; then
        color="$MAGENTA"
    else
        color="$PURPLE"
    fi

    echo
    echo "${color}${line}${NC}"
    printf '%s%*s%s\n' "$color" $(( (width + ${#title}) / 2 )) "$title" "$NC"
    echo "${color}${line}${NC}"
    echo
    printf '  Round:   %s%d%s / %d\n'        "$BOLD" "$round" "$NC" "$total_rounds"
    printf '  Points:  %s%d%s\n'             "$MAGENTA" "$POINTS" "$NC"
    echo
    if [[ "$next_phase" == "None" ]]; then
        printf '  Next:    %sSession complete%s\n' "$DIM" "$NC"
    else
        printf '  Next:    %s%s%s\n' "$BOLD" "$next_phase" "$NC"
    fi
    echo
    printf '  %sPress Enter to continue...%s' "$MAGENTA" "$NC"
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

run_phase() {
    local type=$1 minutes=$2 round=$3 total_rounds=$4
    local label subtitle next_phase t

    if [[ "$type" == "study" ]]; then
        label="STUDY"
        subtitle="${QUOTE_LIST[$(( RANDOM % ${#QUOTE_LIST[@]} ))]}"
    else
        label="BREAK"
        subtitle="Relax and recharge."
    fi

    # What comes after this phase, shown live in next.txt / overlay.txt.
    if [[ "$type" == "study" ]]; then
        if (( round < total_rounds )); then
            next_phase="Break ($(duration_label "$BREAK_MIN"))"
        else
            next_phase="None"
        fi
    else
        next_phase="Study ($(duration_label "$STUDY_MIN"))"
    fi

    local total=$(( minutes * SECONDS_PER_UNIT )) elapsed=0
    # Count against the shell's wall-clock ($SECONDS) instead of adding 1 per
    # loop: each iteration costs a bit more than 1s (file writes, redraw), so
    # a naive counter makes a 50 min phase run noticeably longer.
    # `paused_total` holds the seconds spent paused, so the countdown freezes
    # while the phase is paused and resumes exactly where it left off.
    local start=$SECONDS paused_total=0 pause_at=0
    local paused=0 skipped=0

    SESSION_TEXT="$label $round/$total_rounds"
    printf -v REMAINING_STR '%02d:%02d:%02d' \
        $((total/3600)) $((total%3600/60)) $((total%60))
    PCT=0
    NEXT_TEXT="$next_phase"
    # "None" is the internal marker for "no phase follows"; on the stream
    # that reads better as a finished session.
    [[ "$NEXT_TEXT" == "None" ]] && NEXT_TEXT="Session complete"
    MESSAGE_TEXT="$subtitle"

    log_event "Start: $label $round/$total_rounds ($(duration_label "$minutes"))"
    phase_header "$label" "$round" "$total_rounds" "$minutes" "$subtitle"
    update_date_day
    publish_state

    while (( elapsed < total )); do
        local remaining=$(( total - elapsed ))
        (( remaining < 0 )) && remaining=0
        printf -v REMAINING_STR '%02d:%02d:%02d' \
            $((remaining/3600)) $((remaining%3600/60)) $((remaining%60))
        PCT=0
        (( total > 0 )) && PCT=$(( elapsed * 100 / total ))
        (( PCT > 100 )) && PCT=100
        SESSION_TEXT="$label $round/$total_rounds"
        (( paused )) && SESSION_TEXT="$SESSION_TEXT (PAUSED)"

        update_date_day
        publish_state

        # Redraw every tick so the terminal countdown matches timer.txt. This
        # is pure bash builtins (no forks), so it costs next to nothing.
        draw_status "$label" "$round" "$total_rounds" "$elapsed" "$total" "$paused"

        wait_key 1
        if (( KEY_READ )); then
            case "$KEY" in
                p|P|' ')
                    if (( paused )); then
                        paused=0
                        paused_total=$(( SECONDS - pause_at ))
                        log_event "Resumed: $label $round/$total_rounds"
                    else
                        paused=1
                        pause_at=$SECONDS
                        log_event "Paused: $label $round/$total_rounds"
                    fi
                    ;;
                s|S)
                    skipped=1
                    log_event "Skipped: $label $round/$total_rounds"
                    break
                    ;;
                q|Q)
                    log_event "Quit requested by user"
                    cleanup 0
                    ;;
            esac
        fi

        if (( paused )); then
            # Keep growing the paused time so the countdown stays frozen.
            paused_total=$(( SECONDS - pause_at ))
        else
            elapsed=$(( SECONDS - start - paused_total ))
        fi
    done

    # Phase is over (finished, or skipped).
    if (( skipped )); then
        # A skipped phase doesn't earn a point.
        SESSION_TEXT="$label $round/$total_rounds (SKIPPED)"
    else
        PCT=100
        POINTS=$(( POINTS + 1 ))
    fi
    REMAINING_STR="00:00:00"
    update_date_day
    publish_state
    # Final redraw so the bar ends at 100% / 00:00:00 instead of whatever the
    # last throttled update (up to 5s earlier) happened to show.
    draw_status "$label" "$round" "$total_rounds" "$total" "$total" "0"
    printf '\n'
    log_event "End: $label $round/$total_rounds"

    play_alert

    discard_pending_input
    show_completion "$label" "$round" "$total_rounds" "$next_phase" "$skipped"
    # Block until user is ready. No input besides Enter needed.
    wait_for_enter
    stop_alert   # silence the alarm once the user has acknowledged it
    echo
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    local code=${1:-0}
    trap '' INT TERM HUP   # ignore repeated signals while shutting down
    # Kill any in-flight audio so the alert doesn't keep going after exit.
    stop_alert
    # Reset the OBS files first: on SIGHUP the terminal is already gone and
    # printing may fail, but the stream must not keep showing a frozen timer.
    SESSION_TEXT="stopped"
    REMAINING_STR="00:00:00"
    PCT=0
    NEXT_TEXT=""
    publish_state
    log_event "Protocol stopped manually"
    {
        echo
        echo "${PURPLE}${BOLD}Interrupted.${NC} ${DIM}State files reset to stopped.${NC}"
    } 2>/dev/null
    exit "$code"
}
# Conventional exit codes: 128 + signal number.
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup 129' HUP

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
print_logo
setup_audio_sink
update_date_day
log_event "Starting new study protocol: $ROUNDS rounds, $(duration_label "$STUDY_MIN") study, $(duration_label "$BREAK_MIN") break"

echo "${PURPLE}Protocol:${NC} ${BOLD}${ROUNDS}${NC} rounds  ${DIM}|${NC}  ${BOLD}${STUDY_MIN}${NC} $DURATION_UNIT study  ${DIM}|${NC}  ${BOLD}${BREAK_MIN}${NC} $DURATION_UNIT break"
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
update_date_day
publish_state
log_event "Protocol complete - total points: $POINTS"

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo
echo "${MAGENTA}############################################################${NC}"
echo "${MAGENTA}#                                                          #${NC}"
printf '%s#%s%s%s%s#%s\n' \
    "$MAGENTA" "$NC" "$BOLD" \
    "$(printf '%-58s' 'ALL SESSIONS COMPLETE')" \
    "$NC" "$MAGENTA"
echo "${MAGENTA}#                                                          #${NC}"
echo "${MAGENTA}############################################################${NC}"
echo
printf '  %sTotal Rounds:%s  %s%d%s\n' "$BOLD" "$NC" "$MAGENTA" "$ROUNDS" "$NC"
printf '  %sTotal Points:%s %s%d%s\n' "$BOLD" "$NC" "$MAGENTA" "$POINTS" "$NC"
echo
echo "${MAGENTA}${BOLD}Great work!${NC} ${DIM}Exiting.${NC}"
