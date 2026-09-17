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

usage() {
    echo "Usage: $0 <rounds> <study_minutes> <break_minutes>"
    echo "Example: $0 5 50 10"
    exit 1
}

[ $# -eq 3 ] || usage

ROUNDS=$1
STUDY_MIN=$2
BREAK_MIN=$3

for val in "$ROUNDS" "$STUDY_MIN" "$BREAK_MIN"; do
    [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] || usage
done

ALERT_SOUND="$HOME/Videos/Alarm/n_alarm.mp3"   # alarm played at the end of every phase
SINK_NAME="OBS_Alert_Sink"                      # virtual sink OBS can capture separately from the mic

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

print_logo() {
    if command -v figlet &>/dev/null; then
        figlet -f slant "E-Vex" 2>/dev/null || figlet "E-Vex"
    else
        echo "=========================="
        echo "          E-Vex"
        echo "=========================="
    fi
    echo
}

update_date_day() {
    date '+%Y-%m-%d' > "$DATE_FILE"
    date '+%A' > "$DAY_FILE"
}

log_event() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

setup_audio_sink() {
    command -v pactl &>/dev/null || return 0
    pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME" && return 0
    pactl load-module module-null-sink sink_name="$SINK_NAME" \
        sink_properties=device.description="$SINK_NAME" &>/dev/null || true
}

play_alert() {
    command -v mpv &>/dev/null || return 0
    [ -f "$ALERT_SOUND" ] || return 0
    if pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME"; then
        mpv --no-video --volume=70 --audio-device="pulse/$SINK_NAME" "$ALERT_SOUND" &>/dev/null &
    else
        mpv --no-video --volume=70 "$ALERT_SOUND" &>/dev/null &
    fi
}

draw_status() {
    local label=$1 elapsed=$2 total=$3 remaining_str=$4 width=30
    local filled=$(( elapsed * width / total ))
    local i bar="["
    for (( i=0; i<width; i++ )); do
        if (( i < filled )); then bar+="#"; else bar+="-"; fi
    done
    bar+="]"
    printf '\r%-16s %s %3d%%  %s' "$label" "$bar" "$(( elapsed * 100 / total ))" "$remaining_str"
}

run_phase() {
    local label=$1 minutes=$2
    local total=$(( minutes * 60 )) elapsed=0

    echo "$label" > "$SESSION_FILE"
    log_event "Start: $label ($minutes min)"

    if [[ "$label" == study* ]]; then
        echo
        echo "${QUOTES[$(( RANDOM % ${#QUOTES[@]} ))]}"
        echo
    fi

    while (( elapsed < total )); do
        local remaining=$(( total - elapsed ))
        printf -v t '%02d:%02d:%02d' $((remaining/3600)) $((remaining%3600/60)) $((remaining%60))
        echo "$t" > "$TIMER_FILE"
        update_date_day
        draw_status "$label" "$elapsed" "$total" "$t"
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done

    echo "00:00:00" > "$TIMER_FILE"
    printf '\n'
    log_event "End: $label"
    POINTS=$(( POINTS + 1 ))
    play_alert
    echo "Done: $label   |   Points: $POINTS"
}

cleanup() {
    echo
    echo "stopped" > "$SESSION_FILE"
    log_event "Protocol stopped manually"
    echo "Stopped."
    exit 0
}
trap cleanup INT TERM

print_logo
setup_audio_sink
update_date_day
log_event "Starting new study protocol: $ROUNDS rounds, $STUDY_MIN min study, $BREAK_MIN min break"

for (( round=1; round<=ROUNDS; round++ )); do
    run_phase "study $round/$ROUNDS" "$STUDY_MIN"

    if (( round < ROUNDS )); then
        run_phase "break $round/$ROUNDS" "$BREAK_MIN"
    fi
done

echo "session complete" > "$SESSION_FILE"
echo "00:00:00" > "$TIMER_FILE"
log_event "Protocol complete - total points: $POINTS"
echo
echo "Study session complete! Total points: $POINTS"
