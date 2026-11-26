#!/usr/bin/env bash
# wf-help: bounded rg search: every hit when few, else per-file counts and the top files' first hits
#
# Usage: wf rgx PATTERN [PATH...] [--max 60] [-- extra rg args]
#   e.g. wf rgx 'resolvePrice' src tests -- -t ts -w
#
# Up to --max matching lines (default 60) print as file:line:text. Above that it
# prints the total, per-file counts (descending, top 30) and the first 3 hits of the
# top 5 files. Lockfiles, minified files, source maps and build dirs are skipped;
# lines are cut at 200 columns. Exit status follows rg: 1 when nothing matched.
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
usage() { wf_help "${BASH_SOURCE[0]}"; }
case "${1:-}" in
'' | -h | --help)
    usage
    [ -n "${1:-}" ] && exit 0
    exit 2
    ;;
esac

pattern="$1"
shift
max=60
paths=()
extra=()
while [ $# -gt 0 ]; do
    case "$1" in
    --max)
        max="${2:?--max needs a number}"
        shift 2
        ;;
    --)
        shift
        extra=("$@")
        break
        ;;
    *)
        paths+=("$1")
        shift
        ;;
    esac
done
[[ "$max" =~ ^[0-9]+$ ]] || {
    echo "wf rgx: --max takes a number" >&2
    exit 2
}

# A real rg, else Claude Code's bundled one (the CLI acts as rg when argv[0] is rg).
rg() {
    local bin
    bin="$(type -P rg || true)"
    if [ -n "$bin" ]; then
        "$bin" "$@"
        return
    fi
    local cc="${CLAUDE_CODE_EXECPATH:-$HOME/.local/bin/claude}"
    [ -x "$cc" ] || {
        echo "wf rgx: ripgrep not found" >&2
        return 2
    }
    (exec -a rg "$cc" "$@")
}

excludes=()
for g in '*.lock' package-lock.json pnpm-lock.yaml yarn.lock composer.lock go.sum bun.lockb npm-shrinkwrap.json \
    '*.min.js' '*.min.css' '*.map' '*.snap' dist/ build/ .next/ .nuxt/ out/ coverage/ public/build/ target/; do
    excludes+=(-g "!$g")
done
base=(rg --no-config --with-filename --max-columns=200 --max-columns-preview --color=never "${excludes[@]}" "${extra[@]}")

hits="$(mktemp "${TMPDIR:-/tmp}/wf-rgx.XXXXXX")"
trap 'rm -f "$hits"' EXIT
# stdin from /dev/null so that with no PATH rg searches the cwd, not a pipe.
set +e
"${base[@]}" -n --no-heading -e "$pattern" -- "${paths[@]}" >"$hits" </dev/null
rc=$?
set -e
[ "$rc" -gt 1 ] && exit "$rc"

total="$(wc -l <"$hits")"
if [ "$total" -le "$max" ]; then
    cat "$hits"
    exit "$rc"
fi

counts="$("${base[@]}" -c -e "$pattern" -- "${paths[@]}" </dev/null |
    awk '{ n = $0; sub(/.*:/, "", n); f = $0; sub(/:[0-9]+$/, "", f); printf "%d\t%s\n", n, f }' | sort -t$'\t' -k1,1nr)"
echo "rgx: $total hits in $(wc -l <<<"$counts") files (> $max); per file:"
head -n 30 <<<"$counts" | awk -F'\t' '{ printf "%6d  %s\n", $1, $2 }'
echo "first hits of the top 5:"
while IFS=$'\t' read -r _ file; do
    awk -v f="$file:" 'index($0, f) == 1 && n < 3 { print; n++ }' "$hits"
done < <(head -n 5 <<<"$counts")
echo "narrow it: a PATH, or after -- use -t ts, -w, -F, -g '!tests'"
