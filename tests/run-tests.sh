#!/usr/bin/env bash
#
# tests/run-tests.sh - fast self-test for OBS.sh
#
# Everything runs in --dry-run mode (durations in seconds) inside a throwaway
# state directory, so the suite finishes in a few seconds and never touches
# the real OBS files or plays the alarm.
#
# Usage: ./tests/run-tests.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS="$ROOT/OBS.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

section() { printf '\n\033[1;35m%s\033[0m\n' "$1"; }
ok()      { PASS=$((PASS+1)); printf '  \033[0;32mok\033[0m   %s\n' "$1"; }
bad()     { FAIL=$((FAIL+1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "$2"; }

check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        bad "$1" "expected [$2] got [$3]"
    fi
}

check_contains() { # check_contains <desc> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then
        ok "$1"
    else
        bad "$1" "expected [$2] inside [$3]"
    fi
}

# run_session <state_dir> <newlines> [args...] - non-interactive run.
run_session() {
    local dir=$1 n=$2; shift 2
    local input="" i
    for (( i=0; i<n; i++ )); do input+=$'\n'; done
    printf '%s' "$input" | STATE_DIR="$dir" timeout 90 "$OBS" "$@" > "$TMP/stdout" 2>&1
}

# expect_fail <desc> [args...] - the script must reject these arguments.
expect_fail() {
    local desc=$1; shift
    "$OBS" "$@" > "$TMP/stdout" 2>&1
    local rc=$?
    if (( rc == 1 )); then
        ok "$desc"
    else
        bad "$desc" "expected exit 1, got $rc"
    fi
}

# ---------------------------------------------------------------------------
section "Argument validation"
# ---------------------------------------------------------------------------
"$OBS" --help > "$TMP/stdout" 2>&1
check "--help exits 0" "0" "$?"
check_contains "--help shows usage" "Usage:" "$(cat "$TMP/stdout")"

expect_fail "no arguments is an error"
expect_fail "too few arguments is an error" 5
expect_fail "too many arguments is an error" 5 50 10 7
expect_fail "non-numeric rounds is an error" abc 50 10
expect_fail "zero rounds is an error" 0 50 10
expect_fail "negative rounds is an error" -1 50 10
expect_fail "float duration is an error" 5 50.5 10
expect_fail "leading zero is an error" 05 50 10
expect_fail "5 digit number is an error" 99999 50 10
expect_fail "rounds above 50 is an error" 51 50 10
expect_fail "study above 600 is an error" 5 601 10
expect_fail "break above 120 is an error" 5 50 121
expect_fail "unknown option is an error" --nope 5 50 10
expect_fail "--config without argument is an error" --config

# ---------------------------------------------------------------------------
section "Dry run: full session"
# ---------------------------------------------------------------------------
DIR1="$TMP/state1"
mkdir -p "$DIR1"
run_session "$DIR1" 3 --dry-run --no-alert --no-sink 2 2 1
check "session exits 0" "0" "$?"

check "session.txt marks completion" "session complete" "$(cat "$DIR1/session.txt")"
check "timer.txt is zeroed"        "00:00:00"         "$(cat "$DIR1/timer.txt")"
check "points.txt counts 3 phases" "3"               "$(cat "$DIR1/points.txt")"
check "progress.txt is 100%"       "[####################] 100%" "$(cat "$DIR1/progress.txt")"
check "date.txt is today"          "$(date +%F)"      "$(cat "$DIR1/date.txt")"
check "day.txt is today"           "$(date +%A)"      "$(cat "$DIR1/day.txt")"
check_contains "log has the start event"  "Start: STUDY 1/2"  "$(cat "$DIR1/log.txt")"
check_contains "log has the break event"  "Start: BREAK 1/2"  "$(cat "$DIR1/log.txt")"
check_contains "log has the end event"    "End: STUDY 2/2"    "$(cat "$DIR1/log.txt")"
check_contains "log has the summary"      "Protocol complete - total points: 3" "$(cat "$DIR1/log.txt")"
check_contains "overlay has the session"  "session complete"  "$(cat "$DIR1/overlay.txt")"
check_contains "overlay has the points"   "Pts: 3"           "$(cat "$DIR1/overlay.txt")"
check_contains "overlay has the date"     "$(date +%F)"      "$(cat "$DIR1/overlay.txt")"

# ---------------------------------------------------------------------------
section "Dry run: one round"
# ---------------------------------------------------------------------------
DIR2="$TMP/state2"
mkdir -p "$DIR2"
run_session "$DIR2" 1 --dry-run --no-alert --no-sink 1 1 1
check "single round exits 0" "0" "$?"
check "single round scores 1 point" "1" "$(cat "$DIR2/points.txt")"
check "no break phase runs" "0" "$(grep -c 'Start: BREAK' "$DIR2/log.txt")"

# ---------------------------------------------------------------------------
section "Configuration file"
# ---------------------------------------------------------------------------
DIR3="$TMP/state3"
CFG="$TMP/test.conf"
cat > "$CFG" <<EOF
STATE_DIR="$DIR3"
SINK_NAME="Test_Sink"
QUOTE_LIST=(
  "Configured quote"
)
EOF
mkdir -p "$DIR3"
run_session "$DIR3" 1 --dry-run --no-alert --no-sink --config "$CFG" 1 1 1
check "config file sets STATE_DIR" "1" "$(cat "$DIR3/points.txt")"
check_contains "config file sets the quote" "Configured quote" "$(cat "$DIR3/message.txt")"
check_contains "config file is reported" "Config: $CFG" "$(cat "$TMP/stdout")"

# The environment must beat the config file.
DIR4="$TMP/state4"
mkdir -p "$DIR4"
STATE_DIR="$DIR4" run_session "$DIR4" 1 --dry-run --no-alert --no-sink --config "$CFG" 1 1 1
check "environment overrides the config file" "1" "$(cat "$DIR4/points.txt")"

# QUOTES from the environment.
DIR5="$TMP/state5"
mkdir -p "$DIR5"
STATE_DIR="$DIR5" QUOTES=$'First quote\nSecond quote' \
    run_session "$DIR5" 1 --dry-run --no-alert --no-sink 1 1 1
QUOTE_FOUND="$(cat "$DIR5/message.txt")"
if [[ "$QUOTE_FOUND" == "First quote" || "$QUOTE_FOUND" == "Second quote" ]]; then
    ok "QUOTES environment variable is used"
else
    bad "QUOTES environment variable is used" "got [$QUOTE_FOUND]"
fi

# An empty quote list must not blow up on a division by zero.
DIR5B="$TMP/state5b"
CFG_EMPTY="$TMP/empty.conf"
mkdir -p "$DIR5B"
cat > "$CFG_EMPTY" <<EOF
STATE_DIR="$DIR5B"
QUOTE_LIST=()
EOF
run_session "$DIR5B" 1 --dry-run --no-alert --no-sink --config "$CFG_EMPTY" 1 1 1
check "an empty quote list does not crash" "0" "$?"
check "an empty quote list falls back to a default" "Stay focused." "$(cat "$DIR5B/message.txt")"

# A config file whose last command fails is still a valid config file.
DIR5C="$TMP/state5c"
CFG_FAIL="$TMP/failing.conf"
mkdir -p "$DIR5C"
cat > "$CFG_FAIL" <<EOF
STATE_DIR="$DIR5C"
false
EOF
run_session "$DIR5C" 1 --dry-run --no-alert --no-sink --config "$CFG_FAIL" 1 1 1
check "a config file ending in a failed command still loads" "0" "$?"
check "a config file ending in a failed command is applied" "1" "$(cat "$DIR5C/points.txt")"

# A config file with a syntax error must be reported instead of being applied
# halfway.
CFG_BAD="$TMP/broken.conf"
printf 'STATE_DIR="%s"\nif then\n' "$TMP" > "$CFG_BAD"
expect_fail "a config file with a syntax error is an error" \
    --config "$CFG_BAD" --dry-run 1 1 1
check_contains "a config syntax error is explained" "syntax error" "$(cat "$TMP/stdout")"

# HOME is not always set (cron, containers) - the script must not die on it.
DIR5D="$TMP/state5d"
mkdir -p "$DIR5D"
printf '\n' | env -u HOME STATE_DIR="$DIR5D" \
    "$OBS" --dry-run --no-alert --no-sink 1 1 1 > "$TMP/stdout" 2>&1
check "the script runs without HOME" "0" "$?"
check "the session completes without HOME" "1" "$(cat "$DIR5D/points.txt")"

# ---------------------------------------------------------------------------
section "Log rotation"
# ---------------------------------------------------------------------------
DIR6="$TMP/state6"
CFG2="$TMP/rotate.conf"
mkdir -p "$DIR6"
cat > "$CFG2" <<EOF
STATE_DIR="$DIR6"
MAX_LOG_BYTES=1
EOF
run_session "$DIR6" 1 --dry-run --no-alert --no-sink --config "$CFG2" 1 1 1
if [[ -f "$DIR6/log.txt.1" ]]; then
    ok "log.txt is rotated when it passes MAX_LOG_BYTES"
else
    bad "log.txt is rotated when it passes MAX_LOG_BYTES" "log.txt.1 missing"
fi

# ---------------------------------------------------------------------------
section "Interactive keys (pty)"
# ---------------------------------------------------------------------------
if command -v script >/dev/null 2>&1; then
    pty_run() { # pty_run <state_dir> <feed> [args...]
        local dir=$1 feed=$2; shift 2
        local cmd="$OBS"
        local a
        for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
        { eval "$feed"; } | STATE_DIR="$dir" timeout 60 script -qec "$cmd" /dev/null > "$TMP/pty" 2>&1
    }

    # Pause and resume: the countdown must freeze while paused.
    DIRP="$TMP/statep"
    mkdir -p "$DIRP"
    pty_run "$DIRP" "sleep 1; printf 'p'; sleep 3; printf 'p'; sleep 8; printf '\n'" \
        --dry-run --no-alert --no-sink 1 4 1
    check_contains "pause is logged" "Paused: STUDY 1/1"   "$(cat "$DIRP/log.txt")"
    check_contains "resume is logged" "Resumed: STUDY 1/1" "$(cat "$DIRP/log.txt")"
    check "paused phase still scores a point" "1" "$(cat "$DIRP/points.txt")"

    # Two pauses: the countdown must stay frozen for the sum of *both*
    # pauses, not only for the last one. The remaining time is sampled from
    # timer.txt while the phase runs: it may never jump by more than a
    # second, not even over a pause.
    DIRP2="$TMP/statep2"
    mkdir -p "$DIRP2"
    (
        while [[ ! -s "$DIRP2/timer.txt" ]]; do sleep 0.1; done
        for (( i=0; i<70; i++ )); do
            cat "$DIRP2/timer.txt" 2>/dev/null
            sleep 0.2
        done
    ) > "$TMP/samples" 2>/dev/null &
    SAMPLER=$!
    pty_run "$DIRP2" "sleep 1; printf 'p'; sleep 4; printf 'p'; sleep 1; printf 'p'; sleep 1; printf 'p'; sleep 6; printf '\n'; sleep 2; printf '\n'" \
        --dry-run --no-alert --no-sink 1 6 1
    kill "$SAMPLER" 2>/dev/null
    wait "$SAMPLER" 2>/dev/null
    max_jump=0
    prev=""
    while IFS= read -r sample; do
        [[ "$sample" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || continue
        hh=${sample%%:*}; mm=${sample#*:}; mm=${mm%%:*}; ss=${sample##*:}
        val=$(( 10#$hh * 3600 + 10#$mm * 60 + 10#$ss ))
        if [[ -n "$prev" ]]; then
            jump=$(( prev - val ))
            (( jump < 0 )) && jump=0
            (( jump > max_jump )) && max_jump=$jump
        fi
        prev=$val
    done < "$TMP/samples"
    if (( max_jump <= 3 )); then
        ok "two pauses keep the countdown frozen for both (max jump ${max_jump}s)"
    else
        bad "two pauses keep the countdown frozen for both" "the countdown jumped ${max_jump}s"
    fi

    # Skip: the phase ends at once and earns no point.
    DIRS="$TMP/states"
    mkdir -p "$DIRS"
    pty_run "$DIRS" "sleep 1; printf 's'; sleep 1; printf '\n'" \
        --dry-run --no-alert --no-sink 1 30 1
    check_contains "skip is logged" "Skipped: STUDY 1/1" "$(cat "$DIRS/log.txt")"
    check "skipped phase scores no point" "0" "$(cat "$DIRS/points.txt")"

    # Quit: the session stops and the state files are reset.
    DIRQ="$TMP/stateq"
    mkdir -p "$DIRQ"
    pty_run "$DIRQ" "sleep 1; printf 'q'; sleep 1" \
        --dry-run --no-alert --no-sink 1 30 1
    check_contains "quit is logged" "Quit requested by user" "$(cat "$DIRQ/log.txt")"
    check "quit resets the session file" "stopped" "$(cat "$DIRQ/session.txt")"
    check "quit zeroes the timer file" "00:00:00" "$(cat "$DIRQ/timer.txt")"
else
    printf '  \033[0;33mskip\033[0m pty tests (util-linux "script" not found)\n'
fi

# ---------------------------------------------------------------------------
section "Signals"
# ---------------------------------------------------------------------------
# SIGINT can't be delivered to a background job: a non-interactive shell sets
# SIGINT to ignore in background children, and a signal that is ignored on
# entry can't be trapped. The pty below is the realistic case anyway - it is
# exactly what pressing Ctrl+C in the terminal does.
if command -v script >/dev/null 2>&1; then
    DIRS2="$TMP/statesig"
    mkdir -p "$DIRS2"
    { sleep 1; printf '\003'; sleep 1; } \
        | STATE_DIR="$DIRS2" timeout 30 script -qec \
            "$OBS --dry-run --no-alert --no-sink 1 60 1" /dev/null > "$TMP/stdout" 2>&1
    check "Ctrl+C exits with 130" "130" "$?"
    check "Ctrl+C resets the session file" "stopped" "$(cat "$DIRS2/session.txt")"
    check "Ctrl+C zeroes the timer file" "00:00:00" "$(cat "$DIRS2/timer.txt")"
    check_contains "Ctrl+C is logged" "Protocol stopped manually" "$(cat "$DIRS2/log.txt")"
else
    printf '  \033[0;33mskip\033[0m SIGINT test (util-linux "script" not found)\n'
fi

# SIGTERM is not ignored for background jobs, so it can be sent directly.
DIRT="$TMP/stateterm"
mkdir -p "$DIRT"
STATE_DIR="$DIRT" "$OBS" --dry-run --no-alert --no-sink 1 60 1 > "$TMP/stdout" 2>&1 &
PID=$!
sleep 2
kill -TERM "$PID" 2>/dev/null
wait "$PID"
RC=$?
check "SIGTERM exits with 143" "143" "$RC"
check "SIGTERM resets the session file" "stopped" "$(cat "$DIRT/session.txt")"
check_contains "SIGTERM is logged" "Protocol stopped manually" "$(cat "$DIRT/log.txt")"

# ---------------------------------------------------------------------------
section "Unexpected death"
# ---------------------------------------------------------------------------
# A script that dies without a signal (a bash error, an OOM kill, ...) must
# not leave a frozen timer on the stream. The crash is simulated with a copy
# of the script that exits in the middle of a phase.
DIRX="$TMP/statex"
mkdir -p "$DIRX"
sed 's|wait_key 1|exit 42|' "$OBS" > "$TMP/OBS.crash.sh"
chmod +x "$TMP/OBS.crash.sh"
printf '\n' | STATE_DIR="$DIRX" timeout 30 "$TMP/OBS.crash.sh" \
    --dry-run --no-alert --no-sink 1 30 1 > "$TMP/stdout" 2>&1
check "an unexpected death keeps the exit code" "42" "$?"
check "an unexpected death resets the session file" "stopped" "$(cat "$DIRX/session.txt")"
check "an unexpected death zeroes the timer file" "00:00:00" "$(cat "$DIRX/timer.txt")"
check_contains "an unexpected death is logged" "Protocol ended unexpectedly" "$(cat "$DIRX/log.txt")"

# ---------------------------------------------------------------------------
section "Non-interactive input"
# ---------------------------------------------------------------------------
# "Press Enter to continue" must not block forever when the input is a pipe
# that never sends a line and never closes.
DIRW="$TMP/statew"
CFG_W="$TMP/wait.conf"
mkdir -p "$DIRW"
cat > "$CFG_W" <<EOF
STATE_DIR="$DIRW"
NON_TTY_ENTER_TIMEOUT=5
EOF
mkfifo "$TMP/hold.fifo"
exec 9<> "$TMP/hold.fifo"
START=$(date +%s)
STATE_DIR="$DIRW" timeout 30 "$OBS" --dry-run --no-alert --no-sink \
    --config "$CFG_W" 1 1 1 < "$TMP/hold.fifo" > "$TMP/stdout" 2>&1
RC=$?
END=$(date +%s)
exec 9>&-
check "a pipe that never sends anything does not hang the script" "0" "$RC"
if (( END - START <= 20 )); then
    ok "the wait for Enter is bounded ($((END - START))s)"
else
    bad "the wait for Enter is bounded" "took $((END - START))s"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1;35m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
