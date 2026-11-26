#!/usr/bin/env bash
# wf-help: failing test names + the first 20 relevant lines of the last red gate (or GATE)
#
# Usage: wf gate-log [GATE] [--lines N]
# Reads .workflow/gates-last.json and .workflow/gates/<gate>.log written by wf gates.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq

gate="" lines=20
while [ $# -gt 0 ]; do
    case "$1" in
    --lines)
        lines="${2:?--lines needs a number}"
        shift
        ;;
    -h | --help)
        sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "gate-log: unknown flag $1" >&2
        exit 2
        ;;
    *) gate="$1" ;;
    esac
    shift
done

root="$(wf_root)"
last="$root/.workflow/gates-last.json"
if [ -z "$gate" ]; then
    [ -f "$last" ] || {
        echo "gate-log: no $last; run wf gates first" >&2
        exit 2
    }
    gate="$(jq -r '[.results[] | select(.status | test("FAIL|TIMEOUT|NOT_INSTALLED"))] | last | .name // empty' "$last")"
    [ -n "$gate" ] || {
        echo "gate-log: no red gate in the last run"
        exit 0
    }
fi
log="$root/.workflow/gates/$gate.log"
[ -f "$log" ] || {
    echo "gate-log: no log for $gate ($log)" >&2
    exit 2
}

clean="$(sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$log")"
st="$(jq -r --arg g "$gate" '.results[] | select(.name == $g) | .status' "$last" 2>/dev/null || true)"
echo "gate $gate${st:+ ($st)}, log $log"

# Test runner failure markers: go, vitest/jest, pytest, pest/phpunit, playwright.
names="$(printf '%s\n' "$clean" | grep -E '^\s*(--- FAIL:|FAIL( |:)|FAILED |✗|×|✕|⨯|✘|[0-9]+\) [A-Za-z0-9_\\]+(::|\.)|\[[a-z0-9-]+\] › )' |
    sed 's/^[[:space:]]*//' | awk '!seen[$0]++' | head -n 15 || true)"
if [ -n "$names" ]; then
    echo "failing:"
    printf '%s\n' "$names" | sed 's/^/  /'
fi
echo "first $lines relevant lines:"
rel="$(printf '%s\n' "$clean" | grep -inE 'error|fail|assert|expected|panic|exception|cannot|undefined|not found|timed? ?out|denied' | head -n "$lines" || true)"
if [ -n "$rel" ]; then
    printf '%s\n' "$rel" | cut -c1-200
else
    printf '%s\n' "$clean" | grep -v '^[[:space:]]*$' | tail -n "$lines" | cut -c1-200
fi
