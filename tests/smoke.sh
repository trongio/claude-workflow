#!/usr/bin/env bash
# Smoke test: plugin manifests, the card CLI, the board server, gates (incl.
# when-skips and the cache), worktree init + merge, shell lint. Needs bun, jq,
# git; optional: claude (manifest validation), shellcheck, shfmt, hyperfine.
#
# Usage: tests/smoke.sh [SCRATCH_DIR]   (default: a fresh mktemp dir)
# `ok` never fails, so `test && ok || die` is a safe if-then-else here.
# shellcheck disable=SC2015
# No pipefail: `cmd | grep -q` checks would fail on SIGPIPE when grep exits early.
set -eu

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo/bin/wf"
dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/wf-smoke.XXXXXX")}"
port="${WF_SMOKE_PORT:-18090}"
pass=0
board_pid=""
trap '[ -n "$board_pid" ] && kill "$board_pid" 2>/dev/null; true' EXIT

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}
die() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}
check() { # check "label" cmd...
    local label="$1"
    shift
    "$@" >/dev/null 2>&1 && ok "$label" || die "$label"
}

# Plugin
if command -v claude >/dev/null; then
    check "plugin + marketplace manifests validate" claude plugin validate "$repo"
fi
for f in "$repo"/.claude-plugin/*.json "$repo"/workflow.example.json "$repo"/schema/workflow.schema.json; do
    jq -e . "$f" >/dev/null || die "json $f"
done
ok "json files parse"
if command -v shellcheck >/dev/null; then
    check "shellcheck" shellcheck -x "$repo"/bin/wf "$repo"/scripts/*.sh "$repo"/scripts/lib/common.sh "$repo"/tests/*.sh "$repo"/install.sh
fi
if command -v shfmt >/dev/null; then
    [ -z "$(shfmt -i 4 -l "$repo"/bin/wf "$repo"/scripts/*.sh "$repo"/scripts/lib/common.sh "$repo"/tests/*.sh "$repo"/install.sh)" ] && ok "shfmt" || die "shfmt"
fi
if grep -rqI $'\xe2\x80\x94' --exclude-dir=.git "$repo" 2>/dev/null; then die "em dash found"; else ok "no em dash"; fi

# Scratch repo
rm -rf "$dir" "$dir-wt"
mkdir -p "$dir"
cd "$dir"
git init -q -b main
git config user.email smoke@example.test
git config user.name smoke
cat >package.json <<'EOF'
{ "name": "wf-smoke", "scripts": { "test": "node -e \"process.exit(0)\"", "lint": "node -e \"process.exit(0)\"" } }
EOF
mkdir -p src docs
echo 'export const a = 1;' >src/a.ts
echo '# notes' >docs/notes.md
git add -A
git commit -qm "chore: init"

"$wf" init --write >/dev/null
[ -f tasks/README.md ] && [ -d tasks/archive ] && [ -f .claude/workflow.json ] && ok "wf init --write scaffolds" || die "wf init"
[ "$(jq -r '.gates | map(.name) | join(",")' .claude/workflow.json)" = "test,lint" ] && ok "init detects package.json gates" || die "init gates"

# A sample gate config: a gate that always runs, a when-scoped one, a failing one.
jq '.idPrefix = "WF" | .gates = [
  {"name":"unit","cmd":"echo unit-ran"},
  {"name":"ts","cmd":"echo ts-ran","when":["src/","*.ts"]},
  {"name":"docs","cmd":"echo docs-ran","when":["docs/"]},
  {"name":"broken","cmd":"echo first-line; echo boom >&2; exit 3","when":["broken.txt"],"cache":false}
]' .claude/workflow.json >cfg.tmp && mv cfg.tmp .claude/workflow.json
git add -A
git commit -qm "chore: workflow"

# Card CLI
"$wf" new "First card" --size S --area backend --milestone | grep -q '^WF-1 ' && ok "wf new" || die "wf new"
"$wf" new "Second card" --area frontend --depends WF-1 >/dev/null
"$wf" new "Third card" --area frontend >/dev/null
[ "$("$wf" list | wc -l)" = 3 ] && ok "wf list" || die "wf list"
"$wf" next 2 | grep -q 'WF-1' && ok "wf next" || die "wf next"
"$wf" claim 2 | grep -c '^claimed' | grep -q 2 && ok "wf claim 2 (dependency respected)" || die "wf claim"
{ "$wf" claim 1 2>&1 || true; } | grep -q 'WIP limit' && ok "WIP limit enforced" || die "WIP limit"
"$wf" move WF-1 "done" | grep -q 'tasks/archive/' && ok "wf move done archives" || die "wf move"
"$wf" move WF-3 owner-review --blocked "owner: pick a color" >/dev/null
"$wf" stats | grep -q 'waiting on owner (1)' && ok "wf stats" || die "wf stats"
"$wf" show WF-2 | grep -q 'depends: \[WF-1\]' && ok "wf show" || die "wf show"
"$wf" queue 5 | grep -q 'queued WF-2' && [ -f .workflow/queue/WF-2.task ] && ok "wf queue" || die "wf queue"

# Board server
"$wf" board --port "$port" >board.log 2>&1 &
board_pid=$!
for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/api/state" >state.json 2>/dev/null && break
    sleep 0.1
done
[ "$(jq '.tasks | length' state.json)" = 3 ] && ok "board /api/state" || die "board api"
curl -sf "http://127.0.0.1:$port/" | grep -q '<h1 id="title">' && ok "board page" || die "board page"
kill "$board_pid" 2>/dev/null
board_pid=""

# Gates
git add -A
git commit -qm "chore: cards"
out="$("$wf" gates)" || die "gates clean run"
echo "$out" | grep -qE '^unit +\| PASS' && echo "$out" | grep -qE '^ts +\| skip' && ok "gates: no changes skips when-scoped gates" || die "gates skip: $out"
echo 'export const b = 2;' >src/b.ts
out="$("$wf" gates)" || die "gates with change"
echo "$out" | grep -qE '^ts +\| PASS' && echo "$out" | grep -qE '^docs +\| skip' && ok "gates: when globs select by changed files" || die "gates when: $out"
out="$("$wf" gates)"
echo "$out" | grep -qE '^ts +\| PASS.*cached' && ok "gates: unchanged inputs are cached" || die "gates cache: $out"
touch broken.txt
if out="$("$wf" gates)"; then die "failing gate should exit 1"; fi
echo "$out" | grep -qE '^broken +\| FAIL' && echo "$out" | grep -q 'boom' && ok "gates: failure shows tail and exits 1" || die "gates fail: $out"
rm broken.txt

# Worktree init + locked merge
git add -A
git commit -qm "feat: b"
mkdir -p node_modules/dep && echo x >node_modules/dep/index.js
echo 'node_modules/' >>.gitignore
jq '.worktree = {"link": ["node_modules"], "copy": [], "setup": []}' .claude/workflow.json >cfg.tmp && mv cfg.tmp .claude/workflow.json
git add -A
git commit -qm "chore: link"
git worktree add -q -b feat/x "$dir-wt" main
"$wf" wt-init "$dir-wt" | grep -q '^ready' && [ -f "$dir-wt"/node_modules/dep/index.js ] && ok "wf wt-init links deps" || die "wt-init"
(cd "$dir-wt" && echo 'export const c = 3;' >src/c.ts && git add src/c.ts && git commit -qm "feat: c")
(cd "$dir-wt" && "$wf" list | grep -q 'WF-2') && ok "worktree sees the main board" || die "worktree board"
"$wf" review-diff main...feat/x | grep -q 'src/c.ts' && ok "wf review-diff" || die "review-diff"
"$wf" merge feat/x | grep -q '^merged feat/x' && ok "wf merge" || die "merge"
git worktree remove --force "$dir-wt"

printf '\n%d checks passed (scratch: %s)\n' "$pass" "$dir"

if command -v hyperfine >/dev/null && [ "${WF_SMOKE_BENCH:-1}" = 1 ]; then
    { git add -A && git commit -qm "chore: bench"; } >/dev/null 2>&1 || true
    hyperfine -N --warmup 3 --runs 20 --style basic "$wf list" 2>/dev/null | grep -E 'Time|Range' | sed 's/^/wf list    /'
    hyperfine --warmup 2 --runs 10 --style basic "$wf gates" 2>/dev/null | grep -E 'Time|Range' | sed 's/^/wf gates   /'
fi
