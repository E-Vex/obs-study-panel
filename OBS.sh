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
# Terminal colors
# ---------------------------------------------------------------------------
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
CYAN=$'\e[0;36m'
YELLOW=$'\e[1;33m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
NC=$'\e[0m'

# ---------------------------------------------------------------------------
# Argument parsing & validation
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <rounds> <study_minutes> <break_minutes>"
    echo "Example: $0 5 50 10"
    exit 1
}

[ $# -eq 3 ] || usage

ROUNDS=$1
STUDY_MIN=$2
BREAK_MIN=$3

# Must be positive integers; reject leading-zero forms and silly ranges.
for val in "$ROUNDS" "$STUDY_MIN" "$BREAK_MIN"; do
    [[ "$val" =~ ^[1-9][0-9]*$ ]] || usage
done
# Hard caps to prevent runaway countdowns / disk fill.
(( ROUNDS    <= 50 )) || { echo "Error: rounds must be <= 50";  usage; }
(( STUDY_MIN <= 600 )) || { echo "Error: study minutes must be <= 600"; usage; }
(( BREAK_MIN <= 120 )) || { echo "Error: break minutes must be <= 120"; usage; }

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

# ---------------------------------------------------------------------------
# Startup logo
# ---------------------------------------------------------------------------
print_logo() {
    # Compact figlet banner; degrades gracefully if figlet / slant font missing.
    if command -v figlet &>/dev/null; then
        if figlet -f slant -w 80 "E-Vex" 2>/dev/null | head -n 6 \
                | sed 's/[[:space:]]*$//' | grep -q .; then
            echo "${CYAN}"
            figlet -f slant -w 80 "E-Vex" 2>/dev/null \
                | head -n 6 | sed 's/[[:space:]]*$//'
            echo "${NC}"
        else
            print_logo_fallback
        fi
    else
        print_logo_fallback
    fi

    echo "${YELLOW}${BOLD}Study / Break Timer Protocol${NC}"
    echo "${DIM}── live state written to date · day · session · timer · log${NC}"
    echo
}

print_logo_fallback() {
    # Compact block-letter banner rendered with plain ASCII so it works on
    # any terminal without external tools.
    echo "${CYAN}"
    cat <<'EOF'
  ___  ____  __    __  _____
 | _ \/ ___| \ \  / / |___  |
 | |_) \___ \  \ \/ /     / /
 |  _ < ___) |  \  /     / /
 |_| \_\____/    \/     /_/
EOF
    echo "${NC}"
}

# ---------------------------------------------------------------------------
# OBS state files
# ---------------------------------------------------------------------------
update_date_day() {
    date '+%Y-%m-%d' > "$DATE_FILE"
    date '+%A'      > "$DAY_FILE"
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
setup_audio_sink() {
    command -v pactl &>/dev/null || return 0
    pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME" && return 0
    pactl load-module module-null-sink sink_name="$SINK_NAME" \
        sink_properties=device.description="$SINK_NAME" &>/dev/null || true
}

play_alert() {
    command -v mpv &>/dev/null || { echo "${DIM}(mpv missing - silent alert)${NC}"; return 0; }
    [ -f "$ALERT_SOUND" ] || { echo "${DIM}(alert file missing - silent)${NC}"; return 0; }

    local sink_exists=0
    if command -v pactl &>/dev/null; then
        if pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME"; then
            sink_exists=1
        fi
    fi

    if (( sink_exists )); then
        mpv --no-video --volume=70 --audio-device="pulse/$SINK_NAME" \
            "$ALERT_SOUND" &>/dev/null &
    else
        mpv --no-video --volume=70 "$ALERT_SOUND" &>/dev/null &
    fi
    ALERT_PID=$!
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
        color="$GREEN"
    else
        color="$CYAN"
    fi

    printf '\r\033[K'
    printf '%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s' \
        "$BOLD" "$color" "$label" "$NC" \
        "$round" "$total_rounds" \
        "$color" "$bar" "$NC" \
        "$pct" "$remaining_str" \
        "$YELLOW" "$POINTS" "$NC"
}

phase_header() {
    # $1 = label, $2 = round, $3 = total, $4 = minutes, $5 = subtitle
    local label=$1 round=$2 total=$3 minutes=$4 subtitle=$5
    local color
    if [[ "$label" == "STUDY" ]]; then
        color="$GREEN"
    else
        color="$CYAN"
    fi
    echo
    echo "${color}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf '%s║%-62s%s\n' "$color" \
        "  ${BOLD}${label}${NC}${color}  ·  Round ${round} / ${total}  ·  ${minutes} min" "$NC"
    printf '%s║%-62s%s\n' "$color" "  ${DIM}${subtitle}${NC}${color}" "$NC"
    echo "${color}╚══════════════════════════════════════════════════════════════╝${NC}"
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
        color="$GREEN"
    else
        color="$CYAN"
    fi

    echo
    echo "${color}${line}${NC}"
    printf '%s%*s%s\n' "$color" $(( (width + ${#title}) / 2 )) "$title" "$NC"
    echo "${color}${line}${NC}"
    echo
    printf '  Round:   %s%d%s / %d\n'        "$BOLD" "$round" "$NC" "$total_rounds"
    printf '  Points:  %s%d%s\n'             "$YELLOW" "$POINTS" "$NC"
    echo
    if [[ "$next_phase" == "None" ]]; then
        printf '  Next:    %sSession complete%s\n' "$DIM" "$NC"
    else
        printf '  Next:    %s%s%s\n' "$BOLD" "$next_phase" "$NC"
    fi
    echo
    printf '  %sPress Enter to continue...%s' "$YELLOW" "$NC"
}

# ---------------------------------------------------------------------------
# Phase runner
# ---------------------------------------------------------------------------
run_phase() {
    local type=$1 minutes=$2 round=$3 total_rounds=$4
    local label subtitle next_phase

    if [[ "$type" == "study" ]]; then
        label="STUDY"
        subtitle="${QUOTES[$(( RANDOM % ${#QUOTES[@]} ))]}"
    else
        label="BREAK"
        subtitle="Relax and recharge."
    fi

    local total=$(( minutes * 60 )) elapsed=0

    write_session "$label" "$round" "$total_rounds"
    log_event "Start: $label $round/$total_rounds ($minutes min)"
    phase_header "$label" "$round" "$total_rounds" "$minutes" "$subtitle"

    while (( elapsed < total )); do
        local remaining=$(( total - elapsed ))
        printf -v t '%02d:%02d:%02d' \
            $((remaining/3600)) $((remaining%3600/60)) $((remaining%60))
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
    # Block until user is ready. No input besides Enter needed.
    read -r _
    echo
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    # Kill any in-flight audio so the alert doesn't keep going after exit.
    if (( ALERT_PID > 0 )); then
        kill "$ALERT_PID" 2>/dev/null
        ALERT_PID=0
    fi
    echo
    echo "stopped"     > "$SESSION_FILE"
    echo "00:00:00"    > "$TIMER_FILE"
    log_event "Protocol stopped manually"
    echo
    echo "${RED}${BOLD}Interrupted.${NC} ${DIM}State files reset to stopped.${NC}"
    exit 0
}
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
print_logo
setup_audio_sink
update_date_day
log_event "Starting new study protocol: $ROUNDS rounds, $STUDY_MIN min study, $BREAK_MIN min break"

echo "${YELLOW}Protocol:${NC} ${BOLD}${ROUNDS}${NC} rounds  ${DIM}|${NC}  ${BOLD}${STUDY_MIN}${NC} min study  ${DIM}|${NC}  ${BOLD}${BREAK_MIN}${NC} min break"
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
echo "${GREEN}############################################################${NC}"
echo "${GREEN}#                                                          #${NC}"
printf '%s#%s%s%s%s#%s\n' \
    "$GREEN" "$NC" "$BOLD" \
    "$(printf '%-58s' 'ALL SESSIONS COMPLETE')" \
    "$NC" "$GREEN"
echo "${GREEN}#                                                          #${NC}"
echo "${GREEN}############################################################${NC}"
echo
printf '  %sTotal Rounds:%s  %s%d%s\n' "$BOLD" "$NC" "$YELLOW" "$ROUNDS" "$NC"
printf '  %sTotal Points:%s %s%d%s\n' "$BOLD" "$NC" "$YELLOW" "$POINTS" "$NC"
echo
echo "${GREEN}${BOLD}Great work!${NC} ${DIM}Exiting.${NC}"
