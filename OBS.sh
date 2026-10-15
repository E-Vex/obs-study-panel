#!/usr/bin/env bash
#
# OBS.sh - Study/break timer protocol
# Writes live state to 5 text files (date.txt, day.txt, session.txt,
# timer.txt, log.txt) for use as Text sources in OBS Studio.
#
# Usage:   ./OBS.sh <rounds> <study_minutes> <break_minutes>
# Example: ./OBS.sh 5 50 10   ->  5 rounds, 50 min study, 10 min break
# Stop:    Ctrl+C

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
# Argument parsing & validation
# ---------------------------------------------------------------------------
usage() {
    {
        echo "Usage: $0 <rounds> <study_minutes> <break_minutes>"
        echo "Example: $0 5 50 10"
        echo "Limits:  rounds 1-50, study 1-600 min, break 1-120 min"
    } >&2
    exit 1
}

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

# ---------------------------------------------------------------------------
# Paths and runtime state
# ---------------------------------------------------------------------------
ALERT_SOUND="$HOME/Videos/Alarm/n_alarm.mp3"
SINK_NAME="OBS_Alert_Sink"
ALERT_PID=0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATE_FILE="$DIR/date.txt"
DAY_FILE="$DIR/day.txt"
SESSION_FILE="$DIR/session.txt"
TIMER_FILE="$DIR/timer.txt"
LOG_FILE="$DIR/log.txt"

QUOTES=(
  "Focused effort beats scattered hours"
  "Every round finished is progress made"
  "Consistency beats intensity"
  "Start now, figure out the rest along the way"
  "A short break now means sharper focus next round"
)

POINTS=0
LAST_DATE=""

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
    printf '%s\n' "$d"   > "$DATE_FILE"
    printf '%s\n' "$dow" > "$DAY_FILE"
}

write_session() {
    # $1 = phase label, $2 = round, $3 = total rounds
    printf '%s %d/%d\n' "$1" "$2" "$3" > "$SESSION_FILE"
}

log_event() {
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
    if ! sink_is_ready; then
        setup_audio_sink
    fi

    if sink_is_ready; then
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
# Status / progress UI
# ---------------------------------------------------------------------------
draw_status() {
    local label=$1 round=$2 total_rounds=$3 elapsed=$4 total=$5 remaining_str=$6
    local width=24
    local filled=0
    if (( total > 0 )); then
        filled=$(( elapsed * width / total ))
    fi
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

    printf '\r\033[K'
    printf '%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s' \
        "$BOLD" "$color" "$label" "$NC" \
        "$round" "$total_rounds" \
        "$color" "$bar" "$NC" \
        "$pct" "$remaining_str" \
        "$MAGENTA" "$POINTS" "$NC"
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

    local info="${label}  ·  Round ${round} / ${total}  ·  ${minutes} min"
    echo
    echo "${color}╔${bar}╗${NC}"
    box_row "$color" "  ${info}" \
        "  ${BOLD}${label}${NC}${color}  ·  Round ${round} / ${total}  ·  ${minutes} min"
    box_row "$color" "  ${subtitle}" "  ${DIM}${subtitle}${NC}${color}"
    echo "${color}╚${bar}╝${NC}"
    echo
}

show_completion() {
    # $1 = phase label, $2 = round, $3 = total rounds, $4 = next phase description
    local phase=$1 round=$2 total_rounds=$3 next_phase=$4
    local width=60
    local line
    line=$(printf '=%.0s' $(seq 1 $width))

    local title
    if [[ "$phase" == "STUDY" ]]; then
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
minutes_label() {
    if (( $1 == 1 )); then echo "1 minute"; else echo "$1 minutes"; fi
}

run_phase() {
    local type=$1 minutes=$2 round=$3 total_rounds=$4
    local label subtitle next_phase t

    if [[ "$type" == "study" ]]; then
        label="STUDY"
        subtitle="${QUOTES[$(( RANDOM % ${#QUOTES[@]} ))]}"
    else
        label="BREAK"
        subtitle="Relax and recharge."
    fi

    local total=$(( minutes * 60 )) elapsed=0
    # Count against the shell's wall-clock ($SECONDS) instead of adding 1 per
    # loop: each iteration costs a bit more than 1s (file writes, redraw), so
    # a naive counter makes a 50 min phase run noticeably longer.
    local start=$SECONDS

    write_session "$label" "$round" "$total_rounds"
    log_event "Start: $label $round/$total_rounds ($minutes min)"
    phase_header "$label" "$round" "$total_rounds" "$minutes" "$subtitle"

    while (( elapsed < total )); do
        local remaining=$(( total - elapsed ))
        printf -v t '%02d:%02d:%02d' \
            $((remaining/3600)) $((remaining%3600/60)) $((remaining%60))
        printf '%s\n' "$t" > "$TIMER_FILE"
        update_date_day

        # Redraw every tick so the terminal countdown matches timer.txt. This
        # is pure bash builtins (no forks), so it costs next to nothing.
        draw_status "$label" "$round" "$total_rounds" "$elapsed" "$total" "$t"

        sleep 1
        elapsed=$(( SECONDS - start ))
    done

    echo "00:00:00" > "$TIMER_FILE"
    # Final redraw so the bar ends at 100% / 00:00:00 instead of whatever the
    # last throttled update (up to 5s earlier) happened to show.
    draw_status "$label" "$round" "$total_rounds" "$total" "$total" "00:00:00"
    printf '\n'
    log_event "End: $label $round/$total_rounds"

    POINTS=$(( POINTS + 1 ))
    play_alert

    if [[ "$type" == "study" ]]; then
        if (( round < total_rounds )); then
            next_phase="Break ($(minutes_label "$BREAK_MIN"))"
        else
            next_phase="None"
        fi
    else
        next_phase="Study ($(minutes_label "$STUDY_MIN"))"
    fi

    discard_pending_input
    show_completion "$label" "$round" "$total_rounds" "$next_phase"
    # Block until user is ready. No input besides Enter needed.
    read -r _
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
    echo "stopped"     > "$SESSION_FILE"
    echo "00:00:00"    > "$TIMER_FILE"
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
log_event "Starting new study protocol: $ROUNDS rounds, $STUDY_MIN min study, $BREAK_MIN min break"

echo "${PURPLE}Protocol:${NC} ${BOLD}${ROUNDS}${NC} rounds  ${DIM}|${NC}  ${BOLD}${STUDY_MIN}${NC} min study  ${DIM}|${NC}  ${BOLD}${BREAK_MIN}${NC} min break"
echo

for (( round=1; round<=ROUNDS; round++ )); do
    run_phase "study"  "$STUDY_MIN" "$round" "$ROUNDS"

    if (( round < ROUNDS )); then
        run_phase "break" "$BREAK_MIN" "$round" "$ROUNDS"
    fi
done

# Final OBS state: mark as complete.
echo "session complete" > "$SESSION_FILE"
echo "00:00:00"          > "$TIMER_FILE"
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
