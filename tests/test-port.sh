#!/usr/bin/env bash
#
# tests/test-port.sh - run the full OBS.sh test battery against any port.
#
# Usage: ./tests/test-port.sh <port-file>          e.g. ./tests/test-port.sh OBS.py
#        TESTS_QUICK=1 ./tests/test-port.sh <port-file>   (skip the pty section)
#
# The battery mirrors tests/run-tests.sh (the reference suite for OBS.sh):
# argument validation, dry-run sessions, config file, themes, log rotation,
# interactive keys via a pty, signals, unexpected death and bounded waits.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-}"
[[ -n "$PORT" ]] || { echo "usage: $0 <port-file>" >&2; exit 2; }

# shellcheck source=/dev/null
[ -f "$ROOT/tests/test-env.sh" ] && . "$ROOT/tests/test-env.sh"

# ---------------------------------------------------------------- manifest
ROW=""
while IFS='|' read -r f lang build run crash_sed crash_rc flags; do
    [[ "$f" == "$PORT" ]] && ROW="$f|$lang|$build|$run|$crash_sed|$crash_rc|$flags"
done < "$ROOT/tests/ports.tsv"
[[ -n "$ROW" ]] || { echo "Error: $PORT is not listed in tests/ports.tsv" >&2; exit 2; }
IFS='|' read -r FILE LANG_NAME BUILD RUN CRASH_SED CRASH_RC FLAGS <<< "$ROW"
[[ -n "$CRASH_RC" ]] || CRASH_RC=42
case ",$FLAGS," in *,skip-pty,*) SKIP_PTY=1;; *) SKIP_PTY=0;; esac
[[ -n "${TESTS_QUICK:-}" ]] && SKIP_PTY=1   # TESTS_QUICK=1: skip the slow pty section

SRC="$ROOT/$FILE"
[[ -f "$SRC" ]] || { echo "Error: $SRC not found" >&2; exit 2; }
BUILD_DIR="$ROOT/tests/build"
mkdir -p "$BUILD_DIR"
BIN="$BUILD_DIR/${FILE}.$$.bin"
trap 'rm -f "$BIN" "$BIN".*' EXIT

[[ -z "$BUILD" ]] || {
    b="${BUILD//%SRC%/$SRC}"; b="${b//%BIN%/$BIN}"; b="${b//%DIR%/$BUILD_DIR}"
    if ! $b > "$BUILD_DIR/${FILE}.build.log" 2>&1; then
        echo "BUILD FAILED for $FILE (see tests/build/${FILE}.build.log):" >&2
        tail -20 "$BUILD_DIR/${FILE}.build.log" >&2
        exit 2
    fi
}

# run_obs <state-dir> [args...] - run the port non-interactively, no stdin.
run_obs() {
    local dir=$1; shift
    r="${RUN//%SRC%/$SRC}"; r="${r//%BIN%/$BIN}"; r="${r//%DIR%/$BUILD_DIR}"
    STATE_DIR="$dir" timeout 90 $r "$@"
}

# run_session <state-dir> <newlines> [args...] - feed Enter keys via a pipe.
run_session() {
    local dir=$1 n=$2; shift 2
    local input="" i
    for (( i=0; i<n; i++ )); do input+=$'\n'; done
    r="${RUN//%SRC%/$SRC}"; r="${r//%BIN%/$BIN}"; r="${r//%DIR%/$BUILD_DIR}"
    printf '%s' "$input" | STATE_DIR="$dir" timeout 90 $r "$@" > "$TMP/stdout" 2>&1
}

expect_fail() { # expect_fail <desc> [args...]
    local desc=$1; shift
    run_obs "$TMP/no-state" "$@" > "$TMP/stdout" 2>&1
    local rc=$?
    if (( rc == 1 )); then ok "$desc"; else bad "$desc" "expected exit 1, got $rc"; fi
}

check()        { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
check_contains() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected [$2] inside [$3]"; fi; }

theme_of() { # theme_of <stdout-file>
    sed -e 's/\x1b\[[0-9;]*m//g' "$1" | grep -oE 'Theme: [A-Za-z]+' | head -1 | cut -d' ' -f2
}

pty_run() { # pty_run <state_dir> <feed> [args...]
    local dir=$1 feed=$2; shift 2
    local r="${RUN//%SRC%/$SRC}"; r="${r//%BIN%/$BIN}"; r="${r//%DIR%/$BUILD_DIR}"
    local cmd="$r" a
    for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
    { eval "$feed"; } | STATE_DIR="$dir" timeout 90 script -qec "$cmd" /dev/null > "$TMP/pty" 2>&1
}

wait_for_phase() { # wait_for_phase <state-dir> [timeout]
    local dir=$1 i=0 max=${2:-60}
    while (( i < max * 5 )); do
        grep -q 'Start: ' "$dir/log.txt" 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}

# ---------------------------------------------------------------- preflight
TMP="$(mktemp -d)"
PASS=0; FAIL=0
section() { printf '\n\033[1;35m%s\033[0m\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  \033[0;32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "$2"; }

printf '\033[1;36m== %s (%s) ==\033[0m\n' "$FILE" "$LANG_NAME"

# ---------------------------------------------------------------- arguments
section "Argument validation"
run_obs "$TMP/no-state" --help > "$TMP/stdout" 2>&1
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

# ---------------------------------------------------------------- sessions
section "Dry run: full session"
DIR1="$TMP/state1"; mkdir -p "$DIR1"
run_session "$DIR1" 3 --dry-run --no-alert --no-sink 2 2 1
check "session exits 0" "0" "$?"
check "session.txt marks completion" "session complete" "$(cat "$DIR1/session.txt")"
check "timer.txt is zeroed"          "00:00:00"         "$(cat "$DIR1/timer.txt")"
check "points.txt counts 3 phases"   "3"                "$(cat "$DIR1/points.txt")"
check "progress.txt is 100%"         "[####################] 100%" "$(cat "$DIR1/progress.txt")"
check "date.txt is today"            "$(date +%F)"      "$(cat "$DIR1/date.txt")"
check "day.txt is today"             "$(date +%A)"      "$(cat "$DIR1/day.txt")"
check_contains "log has the start event"  "Start: STUDY 1/2"  "$(cat "$DIR1/log.txt")"
check_contains "log has the break event"  "Start: BREAK 1/2"  "$(cat "$DIR1/log.txt")"
check_contains "log has the end event"    "End: STUDY 2/2"    "$(cat "$DIR1/log.txt")"
check_contains "log has the summary"      "Protocol complete - total points: 3" "$(cat "$DIR1/log.txt")"
check_contains "overlay has the session"  "session complete"  "$(cat "$DIR1/overlay.txt")"
check_contains "overlay has the points"   "Pts: 3"           "$(cat "$DIR1/overlay.txt")"
check_contains "overlay has the date"     "$(date +%F)"      "$(cat "$DIR1/overlay.txt")"

section "Dry run: one round"
DIR2="$TMP/state2"; mkdir -p "$DIR2"
run_session "$DIR2" 1 --dry-run --no-alert --no-sink 1 1 1
check "single round exits 0" "0" "$?"
check "single round scores 1 point" "1" "$(cat "$DIR2/points.txt")"
check "no break phase runs" "0" "$(grep -c 'Start: BREAK' "$DIR2/log.txt")"

# ---------------------------------------------------------------- config
section "Configuration file"
DIR3="$TMP/state3"; CFG="$TMP/test.conf"; mkdir -p "$DIR3"
cat > "$CFG" <<EOF
STATE_DIR="$DIR3"
SINK_NAME="Test_Sink"
QUOTE_LIST=(
  "Configured quote"
)
EOF
run_session "$DIR3" 1 --dry-run --no-alert --no-sink --config "$CFG" 1 1 1
check "config file sets STATE_DIR" "1" "$(cat "$DIR3/points.txt")"
check_contains "config file sets the quote" "Configured quote" "$(cat "$DIR3/message.txt")"
check_contains "config file is reported" "Config: $CFG" "$(cat "$TMP/stdout")"

DIR4="$TMP/state4"; mkdir -p "$DIR4"
STATE_DIR="$DIR4" run_session "$DIR4" 1 --dry-run --no-alert --no-sink --config "$CFG" 1 1 1
check "environment overrides the config file" "1" "$(cat "$DIR4/points.txt")"

DIR5="$TMP/state5"; mkdir -p "$DIR5"
STATE_DIR="$DIR5" QUOTES=$'First quote\nSecond quote' \
    run_session "$DIR5" 1 --dry-run --no-alert --no-sink 1 1 1
QUOTE_FOUND="$(cat "$DIR5/message.txt")"
if [[ "$QUOTE_FOUND" == "First quote" || "$QUOTE_FOUND" == "Second quote" ]]; then
    ok "QUOTES environment variable is used"
else
    bad "QUOTES environment variable is used" "got [$QUOTE_FOUND]"
fi

DIR5B="$TMP/state5b"; CFG_EMPTY="$TMP/empty.conf"; mkdir -p "$DIR5B"
cat > "$CFG_EMPTY" <<EOF
STATE_DIR="$DIR5B"
QUOTE_LIST=()
EOF
run_session "$DIR5B" 1 --dry-run --no-alert --no-sink --config "$CFG_EMPTY" 1 1 1
check "an empty quote list does not crash" "0" "$?"
check "an empty quote list falls back to a default" "Stay focused." "$(cat "$DIR5B/message.txt")"

DIR5C="$TMP/state5c"; CFG_FAIL="$TMP/failing.conf"; mkdir -p "$DIR5C"
cat > "$CFG_FAIL" <<EOF
STATE_DIR="$DIR5C"
false
EOF
run_session "$DIR5C" 1 --dry-run --no-alert --no-sink --config "$CFG_FAIL" 1 1 1
check "a config file ending in a failed command still loads" "0" "$?"
check "a config file ending in a failed command is applied" "1" "$(cat "$DIR5C/points.txt")"

CFG_BAD="$TMP/broken.conf"
printf 'STATE_DIR="%s"\nif then\n' "$TMP" > "$CFG_BAD"
expect_fail "a config file with a syntax error is an error" --config "$CFG_BAD" --dry-run 1 1 1
check_contains "a config syntax error is explained" "syntax error" "$(cat "$TMP/stdout")"

DIR5D="$TMP/state5d"; mkdir -p "$DIR5D"
r="${RUN//%SRC%/$SRC}"; r="${r//%BIN%/$BIN}"; r="${r//%DIR%/$BUILD_DIR}"
printf '\n' | env -u HOME STATE_DIR="$DIR5D" timeout 90 $r \
    --dry-run --no-alert --no-sink 1 1 1 > "$TMP/stdout" 2>&1
check "the port runs without HOME" "0" "$?"
check "the session completes without HOME" "1" "$(cat "$DIR5D/points.txt")"

# ---------------------------------------------------------------- themes
section "Color themes"
run_obs "$TMP/no-state" --list-themes > "$TMP/themes" 2>&1
check "--list-themes exits 0" "0" "$?"
THEME_COUNT=$(grep -cE '^  [A-Za-z]+ ' "$TMP/themes")
if (( THEME_COUNT >= 10 )); then
    ok "at least 10 themes are available ($THEME_COUNT)"
else
    bad "at least 10 themes are available" "only $THEME_COUNT themes"
fi
check_contains "--list-themes names the themes" "Purple" "$(cat "$TMP/themes")"
check_contains "--list-themes names the themes" "Ocean"  "$(cat "$TMP/themes")"

DIRT1="$TMP/themet1"; mkdir -p "$DIRT1"
run_session "$DIRT1" 1 --dry-run --no-alert --no-sink --theme Ocean 1 1 1
check "--theme picks the theme" "Ocean" "$(theme_of "$TMP/stdout")"

DIRT2="$TMP/themet2"; mkdir -p "$DIRT2"
r="${RUN//%SRC%/$SRC}"; r="${r//%BIN%/$BIN}"; r="${r//%DIR%/$BUILD_DIR}"
printf '\n' | THEME=Forest STATE_DIR="$DIRT2" timeout 90 $r \
    --dry-run --no-alert --no-sink 1 1 1 > "$TMP/stdout" 2>&1
check "the THEME environment variable picks the theme" "Forest" "$(theme_of "$TMP/stdout")"

printf '\n' | THEME=Forest STATE_DIR="$DIRT2" timeout 90 $r \
    --dry-run --no-alert --no-sink --theme Ice 1 1 1 > "$TMP/stdout" 2>&1
check "--theme beats the environment variable" "Ice" "$(theme_of "$TMP/stdout")"

DIRT3="$TMP/themet3"; CFG_T="$TMP/theme.conf"; mkdir -p "$DIRT3"
cat > "$CFG_T" <<EOF
STATE_DIR="$DIRT3"
THEME="Cobalt"
EOF
run_session "$DIRT3" 1 --dry-run --no-alert --no-sink --config "$CFG_T" 1 1 1
check "the config file picks the theme" "Cobalt" "$(theme_of "$TMP/stdout")"

printf '\n' | THEME=Rose STATE_DIR="$DIRT3" timeout 90 $r \
    --dry-run --no-alert --no-sink --config "$CFG_T" 1 1 1 > "$TMP/stdout" 2>&1
check "the environment variable beats the config file" "Rose" "$(theme_of "$TMP/stdout")"

DIRT4="$TMP/themet4"; mkdir -p "$DIRT4"
printf 'Gold\n' > "$DIRT4/theme.txt"
run_session "$DIRT4" 1 --dry-run --no-alert --no-sink 1 1 1
check "a saved theme is restored" "Gold" "$(theme_of "$TMP/stdout")"

DIRT5="$TMP/themet5"; mkdir -p "$DIRT5"
run_session "$DIRT5" 1 --dry-run --no-alert --no-sink --theme Nope 1 1 1
check "an unknown theme still runs" "0" "$?"
check_contains "an unknown theme is reported" "Warning: unknown theme" "$(cat "$TMP/stdout")"
check "an unknown theme falls back to the default" "Purple" "$(theme_of "$TMP/stdout")"

# ---------------------------------------------------------------- rotation
section "Log rotation"
DIR6="$TMP/state6"; CFG2="$TMP/rotate.conf"; mkdir -p "$DIR6"
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

# ---------------------------------------------------------------- pty
section "Interactive keys (pty)"
if [[ "$SKIP_PTY" == 1 ]]; then
    printf '  \033[0;33mskip\033[0m pty tests (port declares skip-pty)\n'
elif ! command -v script >/dev/null 2>&1; then
    printf '  \033[0;33mskip\033[0m pty tests (util-linux "script" not found)\n'
else
    DIRP="$TMP/statep"; mkdir -p "$DIRP"
    pty_run "$DIRP" "sleep 1; printf 'p'; sleep 3; printf 'p'; sleep 8; printf '\n'" \
        --dry-run --no-alert --no-sink 1 4 1
    check_contains "pause is logged" "Paused: STUDY 1/1"   "$(cat "$DIRP/log.txt")"
    check_contains "resume is logged" "Resumed: STUDY 1/1" "$(cat "$DIRP/log.txt")"
    check "paused phase still scores a point" "1" "$(cat "$DIRP/points.txt")"

    DIRP2="$TMP/statep2"; mkdir -p "$DIRP2"
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
    max_jump=0; prev=""
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

    DIRS="$TMP/states"; mkdir -p "$DIRS"
    pty_run "$DIRS" "sleep 1; printf 's'; sleep 1; printf '\n'" \
        --dry-run --no-alert --no-sink 1 30 1
    check_contains "skip is logged" "Skipped: STUDY 1/1" "$(cat "$DIRS/log.txt")"
    check "skipped phase scores no point" "0" "$(cat "$DIRS/points.txt")"

    DIRQ="$TMP/stateq"; mkdir -p "$DIRQ"
    pty_run "$DIRQ" "sleep 1; printf 'q'; sleep 1" \
        --dry-run --no-alert --no-sink 1 30 1
    check_contains "quit is logged" "Quit requested by user" "$(cat "$DIRQ/log.txt")"
    check "quit resets the session file" "stopped" "$(cat "$DIRQ/session.txt")"
    check "quit zeroes the timer file" "00:00:00" "$(cat "$DIRQ/timer.txt")"

    DIRT="$TMP/statet"; mkdir -p "$DIRT"
    pty_run "$DIRT" "sleep 1; printf '\033T'; sleep 3; printf '\n'" \
        --dry-run --no-alert --no-sink 1 8 1
    check_contains "the theme change is logged" "Theme changed to: Ocean" "$(cat "$DIRT/log.txt")"
    check "the new theme is remembered" "Ocean" "$(cat "$DIRT/theme.txt")"
    check_contains "the new theme is shown" "Theme: Ocean" \
        "$(sed -e 's/\x1b\[[0-9;]*m//g' "$TMP/pty")"

    # SIGINT through a pty, after the phase has actually started.
    DIRS2="$TMP/statesig"; mkdir -p "$DIRS2"
    r2="${RUN//%SRC%/$SRC}"; r2="${r2//%BIN%/$BIN}"; r2="${r2//%DIR%/$BUILD_DIR}"
    cmd="$r2 --dry-run --no-alert --no-sink 1 60 1"
    { while ! grep -q 'Start: ' "$DIRS2/log.txt" 2>/dev/null; do sleep 0.2; done
      sleep 0.5; printf '\003'; sleep 2; } \
        | STATE_DIR="$DIRS2" timeout 60 script -qec "$cmd" /dev/null > "$TMP/stdout" 2>&1
    check "Ctrl+C exits with 130" "130" "$?"
    check "Ctrl+C resets the session file" "stopped" "$(cat "$DIRS2/session.txt")"
    check "Ctrl+C zeroes the timer file" "00:00:00" "$(cat "$DIRS2/timer.txt")"
    check_contains "Ctrl+C is logged" "Protocol stopped manually" "$(cat "$DIRS2/log.txt")"
fi

# ---------------------------------------------------------------- SIGTERM
section "Signals"
DIRT="$TMP/stateterm"; mkdir -p "$DIRT"
r="${RUN//%SRC%/$SRC}"; r="${r//%BIN%/$BIN}"; r="${r//%DIR%/$BUILD_DIR}"
STATE_DIR="$DIRT" timeout 90 $r --dry-run --no-alert --no-sink 1 60 1 > "$TMP/stdout" 2>&1 &
PID=$!
wait_for_phase "$DIRT" 60
kill -TERM "$PID" 2>/dev/null
wait "$PID"
check "SIGTERM exits with 143" "143" "$?"
check "SIGTERM resets the session file" "stopped" "$(cat "$DIRT/session.txt")"
check_contains "SIGTERM is logged" "Protocol stopped manually" "$(cat "$DIRT/log.txt")"

# ---------------------------------------------------------------- crash
section "Unexpected death"
if [[ -z "$CRASH_SED" ]]; then
    printf '  \033[0;33mskip\033[0m crash injection (not applicable to %s)\n' "$LANG_NAME"
else
    CRASH_SRC="$TMP/crash.${FILE##*.}"
    sed -e "$CRASH_SED" "$SRC" > "$CRASH_SRC" || { bad "crash injection" "sed failed"; }
    CRASH_BIN="$BUILD_DIR/${FILE}.crash.$$"
    if [[ -n "$BUILD" ]]; then
        b="${BUILD//%SRC%/$CRASH_SRC}"; b="${b//%BIN%/$CRASH_BIN}"; b="${b//%DIR%/$BUILD_DIR}"
        if ! $b > "$TMP/crash.build.log" 2>&1; then
            bad "crash variant builds" "see $TMP/crash.build.log"
        fi
    fi
    DIRX="$TMP/statex"; mkdir -p "$DIRX"
    cr="${RUN//%SRC%/$CRASH_SRC}"; cr="${cr//%BIN%/$CRASH_BIN}"; cr="${cr//%DIR%/$BUILD_DIR}"
    printf '\n' | STATE_DIR="$DIRX" timeout 60 $cr --dry-run --no-alert --no-sink 1 30 1 > "$TMP/stdout" 2>&1
    check "an unexpected death keeps the exit code" "$CRASH_RC" "$?"
    check "an unexpected death resets the session file" "stopped" "$(cat "$DIRX/session.txt")"
    check "an unexpected death zeroes the timer file" "00:00:00" "$(cat "$DIRX/timer.txt")"
    check_contains "an unexpected death is logged" "Protocol ended unexpectedly" "$(cat "$DIRX/log.txt")"
    rm -f "$CRASH_BIN" "$CRASH_BIN".*
fi

# ---------------------------------------------------------------- non-tty wait
section "Non-interactive input"
DIRW="$TMP/statew"; CFG_W="$TMP/wait.conf"; mkdir -p "$DIRW"
cat > "$CFG_W" <<EOF
STATE_DIR="$DIRW"
NON_TTY_ENTER_TIMEOUT=5
EOF
mkfifo "$TMP/hold.fifo"
exec 9<> "$TMP/hold.fifo"
START=$(date +%s)
r="${RUN//%SRC%/$SRC}"; r="${r//%BIN%/$BIN}"; r="${r//%DIR%/$BUILD_DIR}"
STATE_DIR="$DIRW" timeout 30 $r --dry-run --no-alert --no-sink \
    --config "$CFG_W" 1 1 1 < "$TMP/hold.fifo" > "$TMP/stdout" 2>&1
RC=$?
END=$(date +%s)
exec 9>&-
check "a pipe that never sends anything does not hang the port" "0" "$RC"
if (( END - START <= 20 )); then
    ok "the wait for Enter is bounded ($((END - START))s)"
else
    bad "the wait for Enter is bounded" "took $((END - START))s"
fi

# ---------------------------------------------------------------- summary
printf '\n\033[1;35m%s (%s): %d passed, %d failed\033[0m\n' "$FILE" "$LANG_NAME" "$PASS" "$FAIL"
rm -rf "$TMP"
(( FAIL == 0 )) || exit 1
exit 0
