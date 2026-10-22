#!/usr/bin/env bash
#
# tests/run-all-ports.sh - run tests/test-port.sh for every port in ports.tsv.
#
# Usage:  ./tests/run-all-ports.sh [port-file ...]     (default: all)
#         TESTS_QUICK=1 ./tests/run-all-ports.sh      (skip pty sections)
#
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if (( $# )); then
    PORTS=("$@")
else
    PORTS=()
    while IFS='|' read -r f _; do
        [[ -n "$f" && "$f" != \#* ]] && PORTS+=("$f")
    done < "$ROOT/tests/ports.tsv"
fi

TOTAL=0; FAILED=0; FAILED_LIST=""
for p in "${PORTS[@]}"; do
    TOTAL=$((TOTAL+1))
    if "$ROOT/tests/test-port.sh" "$p"; then
        printf '== %s OK\n' "$p"
    else
        FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST $p"
        printf '== %s FAILED\n' "$p"
    fi
done

printf '\n%d ports tested, %d failed%s\n' "$TOTAL" "$FAILED" "${FAILED_LIST:+:$FAILED_LIST}"
(( FAILED == 0 )) || exit 1
