#!/usr/bin/env bash
# Benchmark wf gates on a generated repo: `--list` and a fully cached run.
# Target: cached run < 300 ms. Uses hyperfine when installed, else a timed loop.
#
# Usage: tests/bench-gates.sh [FILES]   (default 10000)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
files="${1:-10000}"
dir="$(mktemp -d "${TMPDIR:-/tmp}/wf-bench.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
cd "$dir"
git init -q -b main
git config user.email bench@example.test
git config user.name bench
mkdir -p .claude
echo '.workflow/' >.gitignore
for d in $(seq 1 100); do
    mkdir -p "src/d$d"
    for f in $(seq 1 $((files / 100))); do echo "export const v$f = $d;" >"src/d$d/f$f.ts"; done
done
cat >.claude/workflow.json <<'JSON'
{ "gates": [
  {"name": "unit", "cmd": "true"},
  {"name": "ts", "cmd": "true", "when": ["src/", "*.ts"]},
  {"name": "docs", "cmd": "true", "when": ["docs/"]}
] }
JSON
git add -A
git commit -qm init
echo 'export const dirty = 1;' >src/d1/dirty.ts
gates="$repo/scripts/gates.sh"
"$gates" >/dev/null # prime the cache
"$gates" | grep -q 'cached' || {
    echo "bench: second run was not cached" >&2
    exit 1
}
echo "repo: $(git ls-files | wc -l | tr -d ' ') tracked files, 1 dirty"
if command -v hyperfine >/dev/null; then
    hyperfine -N --warmup 3 --runs 20 --style basic "$gates --list" "$gates" 2>/dev/null | grep -E 'Benchmark|Time'
else
    for c in "--list" ""; do
        s=$(date +%s%N)
        # shellcheck disable=SC2086
        for _ in $(seq 1 10); do "$gates" $c >/dev/null; done
        echo "gates $c: $((($(date +%s%N) - s) / 10000000)) ms mean"
    done
fi
