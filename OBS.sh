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

# Terminal colors
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
CYAN=$'\e[0;36m'
YELLOW=$'\e[1;33m'
NC=$'\e[0m'

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

print_logo() {
    if command -v figlet &>/dev/null; then
        echo "${CYAN}"
        figlet -f slant "E-Vex" 2>/dev/null || figlet "E-Vex" 2>/dev/null
        echo "${NC}"
    else
        echo "${CYAN}"
        echo "+------------------------+"
        echo "|        E - V e x        |"
        echo "+------------------------+"
        echo "${NC}"
    fi
    echo "${YELLOW}Study/Break Timer Protocol${NC}"
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
    
    local sink_exists=0
    if command -v pactl &>/dev/null; then
        if pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME"; then
            sink_exists=1
        fi
    fi

    if (( sink_exists )); then
        mpv --no-video --volume=70 --audio-device="pulse/$SINK_NAME" "$ALERT_SOUND" &>/dev/null &
        ALERT_PID=$!
    else
        mpv --no-video --volume=70 "$ALERT_SOUND" &>/dev/null &
        ALERT_PID=$!
    fi
}

draw_status() {
    local label=$1 round=$2 total_rounds=$3 elapsed=$4 total=$5 remaining_str=$6
    local width=24
    local filled=$(( elapsed * width / total ))
    local i bar="["
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
    bar+="]"
    local pct=$(( elapsed * 100 / total ))
    
    local color
    if [[ "$label" == "STUDY" ]]; then
        color="$GREEN"
    else
        color="$CYAN"
    fi
    
    printf '\r\033[K'
    printf '%s%-6s%s [%d/%d] %s%s%s %3d%%  %s' "$color" "$label" "$NC" "$round" "$total_rounds" "$color" "$bar" "$NC" "$pct" "$remaining_str"
}

show_completion() {
    local phase=$1 round=$2 total_rounds=$3 next_phase=$4
    local width=44
    local line
    line=$(printf '=%.0s' $(seq 1 $width))
    
    local title="$phase SESSION COMPLETE"
    if [[ "$phase" == "BREAK" ]]; then
        title="$phase COMPLETE"
    fi
    
    local box_color
    if [[ "$phase" == "STUDY" ]]; then
        box_color="$GREEN"
    else
        box_color="$CYAN"
    fi
    
    echo
    echo "${box_color}${line}${NC}"
    printf "%*s\n" $(( (width + ${#title}) / 2 )) "$title"
    echo "${box_color}${line}${NC}"
    echo
    printf " Round: %s / %s\n" "$round" "$total_rounds"
    printf " Points: %s\n" "$POINTS"
    echo
    if [[ "$next_phase" == "None" ]]; then
        printf " Next: Session complete\n"
    else
        printf " Next: %s\n" "$next_phase"
    fi
    echo
}

wait_for_enter() {
    read -rp "Press Enter to continue..." _
    echo
}

run_phase() {
    local type=$1 minutes=$2 round=$3 total_rounds=$4
    local label next_phase

    if [[ "$type" == "study" ]]; then
        label="STUDY"
    else
        label="BREAK"
    fi

    local total=$(( minutes * 60 )) elapsed=0

    echo "$label $round/$total_rounds" > "$SESSION_FILE"
    log_event "Start: $label $round/$total_rounds ($minutes min)"

    echo "${YELLOW}----------------------------------------------------${NC}"
    if [[ "$type" == "study" ]]; then
        echo "${YELLOW}STUDY SESSION ${round} / ${total_rounds}${NC}"
        echo "${YELLOW}\"${QUOTES[$(( RANDOM % ${#QUOTES[@]} ))]}\"${NC}"
    else
        echo "${YELLOW}BREAK TIME ${round} / ${total_rounds}${NC}"
        echo "${YELLOW}Relax and recharge.${NC}"
    fi
    echo "${YELLOW}----------------------------------------------------${NC}"
    echo

    while (( elapsed < total )); do
        local remaining=$(( total - elapsed ))
        printf -v t '%02d:%02d:%02d' $((remaining/3600)) $((remaining%3600/60)) $((remaining%60))
        echo "$t" > "$TIMER_FILE"
        update_date_day
        draw_status "$label" "$round" "$total_rounds" "$elapsed" "$total" "$t"
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done

    echo "00:00:00" > "$TIMER_FILE"
    printf '\n'
    log_event "End: $label $round/$total_rounds"
    
    POINTS=$(( POINTS + 1 ))
    play_alert

    if [[ "$type" == "study" ]]; then
        if (( round < total_rounds )); then
            next_phase="Break ($BREAK_MIN minutes)"
        else
            next_phase="None"
        fi
    else
        next_phase="Study ($STUDY_MIN minutes)"
    fi

    show_completion "$label" "$round" "$total_rounds" "$next_phase"
    wait_for_enter
}

cleanup() {
    if (( ALERT_PID > 0 )); then
        kill "$ALERT_PID" 2>/dev/null
    fi
    echo
    echo "stopped" > "$SESSION_FILE"
    echo "00:00:00" > "$TIMER_FILE"
    log_event "Protocol stopped manually"
    echo "${RED}Interrupted. Stopped.${NC}"
    exit 0
}
trap cleanup INT TERM

print_logo
setup_audio_sink
update_date_day
log_event "Starting new study protocol: $ROUNDS rounds, $STUDY_MIN min study, $BREAK_MIN min break"

echo "${YELLOW}Protocol: $ROUNDS rounds | $STUDY_MIN min study | $BREAK_MIN min break${NC}"
echo

for (( round=1; round<=ROUNDS; round++ )); do
    run_phase "study" "$STUDY_MIN" "$round" "$ROUNDS"

    if (( round < ROUNDS )); then
        run_phase "break" "$BREAK_MIN" "$round" "$ROUNDS"
    fi
done

echo "session complete" > "$SESSION_FILE"
echo "00:00:00" > "$TIMER_FILE"
log_event "Protocol complete - total points: $POINTS"

echo "${GREEN}========================================${NC}"
echo "${GREEN}          ALL SESSIONS COMPLETE         ${NC}"
echo "${GREEN}========================================${NC}"
echo
echo " Total Rounds: $ROUNDS"
echo " Total Points: $POINTS"
echo
echo "Great work! Exiting."