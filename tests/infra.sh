#!/usr/bin/env bash
# Infra tests: gates (timeout, missing tool, pending, rerun, cache across
# worktrees, --last, post-merge base, release log), gate-log, wt-init (no
# symlinks, env, hooksPath), ledger teardown via prune, wt-merge refusals,
# runner limit handling, test-affected, doctor. Needs bun, jq, git.
#
# Usage: tests/infra.sh [SCRATCH_DIR]
# shellcheck disable=SC2015
set -eu

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo/bin/wf"
dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/wf-infra.XXXXXX")}"
pass=0
ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}
die() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}
cfg() { jq "$1" .claude/workflow.json >cfg.tmp && mv cfg.tmp .claude/workflow.json; }

rm -rf "$dir" "$dir-wt"* "$dir-bin"
mkdir -p "$dir"
cd "$dir"
git init -q -b main
git config user.email infra@example.test
git config user.name infra
mkdir -p src docs
echo 'export const a = 1;' >src/a.ts
echo '{ "name": "wf-infra" }' >package.json
git add -A
git commit -qm "chore: init"
"$wf" init --write >/dev/null
cfg '.idPrefix = "WF" | .gates = [
  {"name":"ok","cmd":"echo ran >> .runs; echo fine"},
  {"name":"slow","cmd":"sleep 177","timeout":1},
  {"name":"missing","cmd":"no_such_tool_wf --check"},
  {"name":"later","cmd":"phpstan","pending":true},
  {"name":"flaky","cmd":"if [ -f .flaked ]; then echo second; else touch .flaked; echo FLAKE-SIGNAL; exit 1; fi","rerun":{"when":"FLAKE-SIGNAL"},"cache":false},
  {"name":"src","cmd":"echo src-ran","when":["src/"]}
]'
printf '.runs\n.flaked\n' >>.gitignore
git add -A
git commit -qm "chore: workflow"

# Gates: timeout, missing tool, pending, rerun.
out="$("$wf" gates 2>&1)" && die "red gates must exit 1"
echo "$out" | grep -qE '^slow +\| TIMEOUT' && ok "gates: timeout reported red" || die "timeout: $out"
pgrep -fx 'sleep 177' >/dev/null && die "timeout left sleep running" || ok "gates: timeout kills the process group"
echo "$out" | grep -qE '^missing +\| NOT INSTALLED' && ok "gates: missing tool is red NOT INSTALLED" || die "missing: $out"
echo "$out" | grep -qE '^later +\| PENDING' && echo "$out" | grep -qE 'not proven: .*later' && ok "gates: pending is not proven" || die "pending: $out"
echo "$out" | grep -qE '^flaky +\| PASS \(rerun\)' && ok "gates: evidence-based rerun" || die "rerun: $out"
echo "$out" | grep -qE 'not proven: .*src' && ok "gates: skipped gates listed as not proven" || die "skip summary: $out"
jq -e '.sha and .tree and (.results | length == 6) and (.results[] | select(.name == "slow") | .status == "TIMEOUT")' .workflow/gates-last.json >/dev/null &&
    ok "gates: gates-last.json written" || die "json"
"$wf" gate-log | grep -q 'no_such_tool_wf' && ok "gate-log: last red gate" || die "gate-log"
"$wf" gate-log slow | grep -q '^gate slow (TIMEOUT)' && ok "gate-log: named gate" || die "gate-log slow"

# --last reprints without running.
cfg '.gates |= map(select(.name == "ok" or .name == "src"))'
git commit -qam "chore: two gates"
"$wf" gates >/dev/null
runs="$(wc -l <.runs)"
"$wf" gates --last --no-cache | grep -qE '^ok +\| PASS' && [ "$(wc -l <.runs)" = "$runs" ] && ok "gates --last: no run when unchanged" || die "--last"
echo 'export const z = 0;' >src/z.ts
"$wf" gates --last 2>&1 | grep -q 'tree changed' && ok "gates --last: runs when the tree changed" || die "--last changed"
rm src/z.ts

# Cache shared across two worktrees, alternating.
git worktree add -q -b wt-a "$dir-wta" main
git worktree add -q -b wt-b "$dir-wtb" main
echo 'export const a = 2;' >"$dir-wta/src/a.ts"
echo 'export const a = 3;' >"$dir-wtb/src/a.ts"
(cd "$dir-wta" && "$wf" gates --only src >/dev/null)
(cd "$dir-wtb" && "$wf" gates --only src >/dev/null)
(cd "$dir-wta" && "$wf" gates --only src) | grep -qE '^src +\| PASS .*cached' &&
    (cd "$dir-wtb" && "$wf" gates --only src) | grep -qE '^src +\| PASS .*cached' &&
    ok "gates: cache keeps entries for alternating worktrees" || die "cache alternation"
git worktree remove --force "$dir-wta"
git worktree remove --force "$dir-wtb"
git branch -qD wt-a wt-b

# Post-merge: on main after a merge, the first parent is the base.
git checkout -q -b feat/m
echo 'export const m = 1;' >src/m.ts
git add src/m.ts
git commit -qm "feat: m"
git checkout -q main
git merge -q --no-ff -m "merge: m" feat/m
"$wf" gates | grep -qE '^src +\| PASS' && ok "gates: post-merge diffs against the first parent" || die "post-merge"
"$wf" gates --json | jq -e --arg p "$(git rev-parse HEAD^1)" '.base == $p' >/dev/null && ok "gates --json: base is HEAD^1" || die "json base"

# Release: log has sha and exit code; refuses outside the root.
"$wf" gates --release >/dev/null || die "release run"
grep -q "sha $(git rev-parse HEAD)" .workflow/release.log && grep -qE '^exit 0 after' .workflow/release.log &&
    ok "gates --release: log has sha and exit code" || die "release log"
(cd src && "$wf" gates --release 2>&1 || true) | grep -q 'must run from the worktree root' && ok "gates --release: refuses outside root" || die "release cwd"
cfg '.release = {"cmd": "echo ci-ran; exit 4"}'
"$wf" gates --release >/dev/null 2>&1 && die "release cmd failure must exit 1"
grep -qE '^exit 4 after' .workflow/release.log && ok "gates --release: release.cmd exit code logged" || die "release cmd log"
cfg 'del(.release)' # back to the committed config

# wt-init: copies deps (never symlinks), env, ledger, hooksPath.
mkdir -p node_modules/dep .hooks
echo x >node_modules/dep/index.js
echo 'node_modules/' >>.gitignore
git config core.hooksPath .hooks
mark="$dir-teardown.mark"
cfg '.worktree = {"link": ["node_modules"], "env": {"DB_DATABASE": "app_{slug}", "APP_PORT": "{port}"},
    "teardown": ["echo dropped app_{slug} > '"$mark"'"]}'
git add -A
git commit -qm "chore: worktree cfg"
"$wf" new "Ledger card" --area infra >/dev/null
git add -A && git commit -qm "chore: card"
wt="$dir/.workflow/worktrees/WF-1"
git worktree add -q -b wf/WF-1 "$wt" main
git -C "$wt" config extensions.worktreeConfig true
git -C "$wt" config --worktree core.hooksPath /nowhere
"$wf" wt-init "$wt" 2>"$dir-init.err" | grep -q '^ready' || die "wt-init"
[ -d "$wt/node_modules" ] && [ ! -L "$wt/node_modules" ] && [ -f "$wt/node_modules/.wf-hardlinked" ] && ok "wt-init: deps hardlink-copied, never symlinked" || die "wt-init link"
grep -q "^DB_DATABASE='app_wf_1'" "$wt/.workflow/env" && grep -qE "^APP_PORT='81[0-9]{2}'" "$wt/.workflow/env" && ok "wt-init: env rendered with slug and port" || die "env: $(cat "$wt/.workflow/env")"
[ "$(git -C "$wt" config core.hooksPath)" = .hooks ] && grep -q 'core.hooksPath' "$dir-init.err" && ok "wt-init: hooksPath aligned with main" || die "hooksPath"
ledger="$(git rev-parse --path-format=absolute --git-common-dir)/workflow-resources.json"
jq -e --arg d "$wt" '.worktrees[$d] | .branch == "wf/WF-1" and (.db == ["app_wf_1"]) and (.port >= 8100)' "$ledger" >/dev/null && ok "ledger: worktree, branch, db, port recorded" || die "ledger: $(cat "$ledger")"

# Preview: own port, recorded pid, stopped by down.
if command -v python3 >/dev/null; then
    cfg '.preview = {"cmd": "exec python3 -m http.server {port} --bind 127.0.0.1"}'
    out="$("$wf" preview up WF-1)"
    port="$(jq -r --arg d "$wt" '.worktrees[$d].port' "$ledger")"
    echo "$out" | grep -q "http://127.0.0.1:$port" && curl -sf "http://127.0.0.1:$port/" >/dev/null && ok "preview up: serves on the worktree port" || die "preview: $out"
    pid="$(cat "$wt/.workflow/preview.pid")"
    "$wf" orphans | grep -q "^$pid " && ok "orphans: lists the preview server" || die "orphans: $("$wf" orphans)"
    "$wf" preview down WF-1 | grep -q stopped && ! kill -0 "$pid" 2>/dev/null && ok "preview down: stops it" || die "preview down"
    cfg 'del(.preview)'
fi

# wt-merge refusals.
git worktree add -q -b side "$dir-wts" main
(cd "$wt" && echo 'export const l = 1;' >src/l.ts && git add src/l.ts && git commit -qm "feat: l")
msg="$("$wf" merge wf/WF-1 --into side 2>&1)" && die "merge into a checked-out branch must fail"
echo "$msg" | grep -q 'side is checked out in another worktree' && ok "wt-merge: refuses a branch checked out elsewhere" || die "merge refusal: $msg"
git worktree remove --force "$dir-wts"
git branch -qD side
echo 'dirty' >>src/a.ts
msg="$("$wf" merge wf/WF-1 2>&1)" && die "merge with a dirty main must fail"
echo "$msg" | grep -q 'uncommitted changes outside tasks/' && ok "wt-merge: refuses a dirty main checkout" || die "dirty refusal: $msg"
git checkout -q src/a.ts
"$wf" move WF-1 "done" --force >/dev/null
[ ! -d "$wt" ] && grep -q 'dropped app_wf_1' "$mark" && ok "move done: teardown ran with {slug}, worktree gone" || die "teardown on done"
[ "$(jq '.worktrees | length' "$ledger")" = 0 ] && ok "move done: ledger empty" || die "ledger left: $(cat "$ledger")"
git rev-parse -q --verify refs/heads/wf/WF-1 >/dev/null && ok "move done: unmerged branch kept" || die "unmerged branch deleted"
"$wf" merge wf/WF-1 | grep -q 'committed pending card changes' && ok "wt-merge: commits pending card edits first" || die "merge cards"

# Prune: the now-merged branch is a leftover.
"$wf" prune | grep -q "would delete merged branch wf/WF-1" && ok "prune: dry run lists the merged branch" || die "prune dry"
"$wf" doctor >/dev/null && die "doctor must fail on leftovers" || ok "doctor: fails on leftovers"
"$wf" prune --apply >/dev/null
! git rev-parse -q --verify refs/heads/wf/WF-1 >/dev/null && ok "prune: merged branch gone" || die "prune remove"

# Doctor: stale lock.
mkdir -p "$(dirname "$ledger")/workflow-x.lock" && echo 999999 >"$(dirname "$ledger")/workflow-x.lock/pid"
"$wf" doctor | grep -q 'stale lock' && ok "doctor: stale lock" || die "doctor lock"
rm -rf "$(dirname "$ledger")/workflow-x.lock"

# test-affected with a map.
mkdir -p tests
echo 't' >tests/a.test.ts
cfg '.testAffected = {"cmd": "echo testing {files}", "map": [{"src": "src/*.ts", "tests": "tests/{name}.test.ts"}]}'
git add -A && git commit -qm "chore: tests"
echo 'export const a = 9;' >src/a.ts
out="$("$wf" test-affected)"
echo "$out" | grep -q 'src/a.ts -> tests/a.test.ts' && echo "$out" | grep -q 'testing tests/a.test.ts' && ok "test-affected: mapped test runs" || die "test-affected: $out"
git checkout -q src/a.ts

# Runner: model text mentioning a rate limit must not loop; a real CLI limit
# counts an attempt after three waits.
stub="$dir-bin"
mkdir -p "$stub"
cat >"$stub/claude" <<'EOF'
#!/bin/sh
if [ -n "$STUB_LIMIT" ]; then
    echo "Claude AI usage limit reached|$(($(date +%s) + 5))" >&2
    echo '{"is_error":true,"result":"Claude AI usage limit reached"}'
    exit 1
fi
printf '{"is_error":true,"session_id":"s1","result":"%s"}\n' "I looked at the API docs. The rate limit section says clients must back off on 429. I wrote that handling and the tests now cover a rate limit response, a retry, and the backoff ceiling, plus the logging path for repeated failures."
exit 1
EOF
chmod +x "$stub/claude"
"$wf" new "Runner card" --area runner >/dev/null
git add -A && git commit -qm "chore: card 2"
"$wf" queue 1 >/dev/null
PATH="$stub:$PATH" RETRIES=2 LIMIT_WAIT_MAX=1 timeout 120 "$wf" run >"$dir-run.log" 2>&1 || die "runner exit: $(tail -5 "$dir-run.log")"
[ -f .workflow/failed/WF-2.task ] && ! grep -q 'usage limit' .workflow/logs/summary.md && grep -q 'attempt 2 failed' .workflow/logs/summary.md &&
    ok "runner: model text about rate limits does not loop" || die "runner limit loop: $(cat .workflow/logs/summary.md)"
jq -e '.active == false and (.failed == ["WF-2"])' .workflow/runner/state.json >/dev/null && ok "runner: state.json" || die "state: $(cat .workflow/runner/state.json)"
[ ! -d .workflow/worktrees/WF-2 ] && ok "runner: failed worktree torn down" || die "runner teardown"
"$wf" new "Limit card" --area limit >/dev/null
git add -A && git commit -qm "chore: card 3"
"$wf" queue 1 >/dev/null
PATH="$stub:$PATH" STUB_LIMIT=1 RETRIES=1 LIMIT_WAIT_MAX=1 timeout 120 "$wf" run >"$dir-run.log" 2>&1 || die "runner exit 2"
[ "$(grep -c 'WF-3: usage limit' .workflow/logs/summary.md)" = 3 ] && grep -q 'counted after 3 limit waits' .workflow/logs/summary.md &&
    ok "runner: three limit waits count an attempt" || die "runner limit count: $(cat .workflow/logs/summary.md)"
"$wf" new "Excluded card" --area x >/dev/null
sed -i.bak 's/^status: todo/tags: [deploy]\nstatus: todo/' tasks/WF-4*.md && rm -f tasks/*.bak
git add -A && git commit -qm "chore: card 4"
"$wf" queue 1 >/dev/null
PATH="$stub:$PATH" timeout 60 "$wf" run >"$dir-run.log" 2>&1 || die "runner exit 3"
[ -f .workflow/skipped/WF-4.task ] && ok "runner: overnight.exclude tags skipped" || die "exclude: $(cat "$dir-run.log")"

rm -rf "$stub" "$dir-run.log" "$dir-init.err" "$mark"
printf '\n%d infra checks passed (scratch: %s)\n' "$pass" "$dir"
