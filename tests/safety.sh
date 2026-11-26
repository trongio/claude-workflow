#!/usr/bin/env bash
# Data-safety regressions: prune never touches anything but task worktrees,
# teardown never loses uncommitted work, the runner never resets a kept
# branch, signals stop child process groups, orphans --kill is scoped, merge
# and cards-commit never move the main checkout, stale-lock takeover has one
# winner, test-affected never runs file names as shell, gates usage errors,
# wt-init never shares in-place-written files with main. Needs bun, jq, git.
#
# Usage: tests/safety.sh [SCRATCH_DIR]
# shellcheck disable=SC2015
set -eu

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo/bin/wf"
dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/wf-safety.XXXXXX")}"
# Scratch is removed on success unless WF_KEEP=1 or a dir was passed; kept on failure for debugging.
own_scratch=$([ -z "${1:-}" ] && echo 1 || true)
bg_pids=()
wf_scratch_cleanup() {
    local rc="${1:-$?}" p
    for p in "${bg_pids[@]}"; do kill "$p" 2>/dev/null || true; done
    if [ "$rc" = 0 ] && [ -n "$own_scratch" ] && [ -z "${WF_KEEP:-}" ]; then
        git -C "$dir" worktree prune 2>/dev/null || true
        rm -rf "$dir" "$dir".* "$dir"-*
    fi
    return "$rc"
}
trap wf_scratch_cleanup EXIT
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
rc_of() { # rc_of CMD...: exit code without tripping set -e
    local r=0
    "$@" >"$dir-out" 2>&1 || r=$?
    echo "$r"
}
gone() { ! kill -0 "$1" 2>/dev/null; }
wait_for() { # wait_for PATTERN: until pgrep -fx matches (10 s)
    local _
    for _ in $(seq 1 40); do
        pgrep -fx "$1" >/dev/null && return 0
        sleep 0.25
    done
    return 1
}

rm -rf "$dir" "$dir"-*
mkdir -p "$dir"
cd "$dir"
git init -q -b main
git config user.email safety@example.test
git config user.name safety
mkdir -p src
echo 'export const a = 1;' >src/a.ts
echo '{ "name": "wf-safety" }' >package.json
git add -A
git commit -qm "chore: init"
"$wf" init --write >/dev/null
mark="$dir-teardown.mark"
cfg '.idPrefix = "WF" | .gates = [{"name": "ok", "cmd": "true"}]
    | .worktree = {"teardown": ["echo ran >> '"$mark"'"]}'
git add -A
git commit -qm "chore: workflow"
stub="$dir-bin"
mkdir -p "$stub"
ledger="$(git rev-parse --path-format=absolute --git-common-dir)/workflow-resources.json"
wtroot="$dir/.workflow/worktrees"

# ---- 1, 6: prune touches task worktrees only --------------------------------
mkdir -p "$dir-victim/src"
echo keep >"$dir-victim/src/f"
head="$(git rev-parse HEAD)"
[ "$(rc_of "$wf" prune --apply "$dir-victim")" = 2 ] && [ -f "$dir-victim/src/f" ] && [ -f src/a.ts ] &&
    [ "$(git rev-parse HEAD)" = "$head" ] && [ ! -e "$mark" ] && ok "prune: refuses a directory outside the repo" || die "prune outside: $(cat "$dir-out")"
[ "$(rc_of "$wf" prune --apply .)" = 2 ] && [ -f src/a.ts ] && [ ! -e "$mark" ] && [ "$(git rev-parse HEAD)" = "$head" ] &&
    ok "prune: refuses the main checkout, runs no teardown there" || die "prune main: $(cat "$dir-out")"
mkdir -p "$wtroot/FAKE"
echo keep >"$wtroot/FAKE/f"
[ "$(rc_of "$wf" prune --apply FAKE)" = 2 ] && [ -f "$wtroot/FAKE/f" ] && ok "prune: refuses an unregistered dir under .workflow/worktrees" || die "prune fake: $(cat "$dir-out")"
rm -rf "$wtroot/FAKE"
git worktree add -q -b mine "$dir-mine" main
(cd "$dir-mine" && echo 'export const m = 1;' >src/m.ts && git add src/m.ts && git commit -qm "feat: m")
git merge -q --no-ff -m "merge: mine" mine
git worktree add -q -b wf/NOCARD "$wtroot/NOCARD" main
out="$("$wf" prune 2>/dev/null)" || die "prune dry run exited non-zero with a card-less worktree: $out"
echo "$out" | grep -q "$dir-mine" && die "prune lists a user worktree: $out"
ok "prune: a worktree without a card does not abort the scan; user worktrees are not listed"
[ "$(rc_of "$wf" prune --apply "$dir-mine")" = 2 ] && [ -f "$dir-mine/src/m.ts" ] && ok "prune: refuses a user worktree named explicitly" || die "prune mine: $(cat "$dir-out")"
"$wf" prune --apply NOCARD >/dev/null 2>&1 || die "prune NOCARD"
[ ! -d "$wtroot/NOCARD" ] && [ ! -e "$mark" ] && ok "prune: teardown commands only run for ledger worktrees" || die "teardown without ledger"
git worktree remove --force "$dir-mine"
git branch -qD mine

# ---- 2, 7: teardown keeps uncommitted work ----------------------------------
"$wf" new "Save card" --area safety >/dev/null
"$wf" new "Abort card" --area safety >/dev/null
git add -A && git commit -qm "chore: cards"
wt1="$wtroot/WF-1"
git worktree add -q -b wf/WF-1 "$wt1" main
"$wf" wt-init "$wt1" >/dev/null 2>&1
echo 'export const a = 42;' >"$wt1/src/a.ts"
echo 'export const n = 1;' >"$wt1/src/new.ts"
git config commit.gpgsign true
git config gpg.program "$dir-no-such-gpg"
(cd "$dir" && exec sleep 1777) &
unrelated=$!
bg_pids+=("$unrelated")
jq --arg d "$wt1" --argjson p "$unrelated" '.worktrees[$d].pids = [$p]' "$ledger" >"$ledger.t" && mv "$ledger.t" "$ledger"
"$wf" prune --apply WF-1 >"$dir-out" 2>&1 || die "prune WF-1: $(cat "$dir-out")"
git config --unset commit.gpgsign
git config --unset gpg.program
[ ! -d "$wt1" ] && [ "$(git show wf/WF-1:src/a.ts)" = 'export const a = 42;' ] && git show wf/WF-1:src/new.ts >/dev/null &&
    ok "teardown: gpgsign=true without gpg still saves edits as a wip commit" || die "gpgsign save: $(cat "$dir-out")"
grep -q 'kept branch wf/WF-1' "$dir-out" && ok "teardown: a branch that just got a wip commit is kept" || die "wip branch: $(cat "$dir-out")"
kill -0 "$unrelated" 2>/dev/null && ok "teardown: a recorded pid whose cwd is outside the worktree is not killed" || die "unrelated pid killed"
kill "$unrelated"
rm -f "$mark"

wt2="$wtroot/WF-2"
git worktree add -q -b wf/WF-2 "$wt2" main
"$wf" wt-init "$wt2" >/dev/null 2>&1
echo 'export const a = 7;' >"$wt2/src/a.ts"
touch "$(git -C "$wt2" rev-parse --absolute-git-dir)/index.lock"
[ "$(rc_of "$wf" prune --apply WF-2)" = 1 ] && [ -d "$wt2" ] && [ "$(cat "$wt2/src/a.ts")" = 'export const a = 7;' ] &&
    git rev-parse -q --verify refs/heads/wf/WF-2 >/dev/null && [ ! -e "$mark" ] &&
    ok "teardown: a failing wip commit aborts with the worktree, edits and branch intact" || die "abort: $(cat "$dir-out")"
grep -q 'could not save uncommitted work' "$dir-out" && ok "teardown: abort says why" || die "abort message: $(cat "$dir-out")"
rm -f "$(git -C "$wt2" rev-parse --absolute-git-dir)/index.lock"
git -C "$wt2" checkout -q --detach
"$wf" prune --apply WF-2 >"$dir-out" 2>&1 || die "prune detached: $(cat "$dir-out")"
rescue="$(git branch --format='%(refname:short)' --list 'wf/rescue-*' | head -1)"
[ -n "$rescue" ] && [ "$(git show "$rescue:src/a.ts")" = 'export const a = 7;' ] && ok "teardown: detached HEAD edits land on a wf/rescue-* branch" || die "rescue: $(cat "$dir-out")"
rm -f "$mark"

# ---- 3: runner checks out a kept branch as it is ----------------------------
"$wf" move WF-1 backlog >/dev/null 2>&1
"$wf" move WF-2 backlog >/dev/null 2>&1
"$wf" new "Kept branch card" --area safety >/dev/null
git add -A && git commit -qm "chore: card 3"
git worktree add -q -b wf/WF-3 "$dir-tmp3" main
(cd "$dir-tmp3" && echo 'export const k = 1;' >src/k.ts && git add src/k.ts && git commit -qm "wip(WF-3): kept")
git worktree remove --force "$dir-tmp3"
cat >"$stub/claude" <<EOF
#!/bin/sh
git log -1 --format=%s >"$dir-seen"
"$wf" move WF-3 done >/dev/null 2>&1
echo '{"is_error":false,"session_id":"s","total_cost_usd":0}'
EOF
chmod +x "$stub/claude"
"$wf" queue 1 >/dev/null
PATH="$stub:$PATH" timeout 60 "$wf" run >"$dir-run.log" 2>&1 || die "runner: $(tail -5 "$dir-run.log")"
grep -qx 'wip(WF-3): kept' "$dir-seen" && [ "$(git log -1 --format=%s wf/WF-3)" = 'wip(WF-3): kept' ] &&
    ok "runner: an existing task branch is not reset to the base" || die "runner reset the branch: seen $(cat "$dir-seen" 2>/dev/null)"

# ---- 4: signals stop child process groups -----------------------------------
"$wf" new "Signal card" --area safety >/dev/null
git add -A && git commit -qm "chore: card 4"
printf '#!/bin/sh\nexec sleep 1999\n' >"$stub/claude"
"$wf" queue 1 >/dev/null
PATH="$stub:$PATH" "$wf" run >"$dir-run.log" 2>&1 &
rp=$!
bg_pids+=("$rp")
wait_for 'sleep 1999' || die "runner never started the stub session: $(cat "$dir-run.log")"
kill -TERM "$rp"
r=0
wait "$rp" || r=$?
sleep 0.3
[ "$r" = 143 ] && ! pgrep -fx 'sleep 1999' >/dev/null && [ ! -d .workflow/.runner.lock ] &&
    ok "runner: SIGTERM stops the claude sessions, then releases the lock" || die "runner signal: rc $r, $(pgrep -fx 'sleep 1999' || true)"

cfg '.gates = [{"name": "sleeper", "cmd": "sleep 1888"}]'
"$wf" gates --no-cache >/dev/null 2>&1 &
gp=$!
bg_pids+=("$gp")
wait_for 'sleep 1888' || die "gate never started"
kill -TERM "$gp"
r=0
wait "$gp" || r=$?
sleep 0.3
[ "$r" = 143 ] && ! pgrep -fx 'sleep 1888' >/dev/null && ok "gates: SIGTERM kills the gate's process group" || die "gates signal: rc $r"

# ---- 5: orphans lists port-less processes, --kill is scoped -----------------
wt4="$wtroot/WF-4"
[ -d "$wt4" ] || die "WF-4 worktree missing"
cp "$(command -v sleep)" "$stub/node"
(cd "$wt4" && exec "$stub/node" 300) &
np=$!
bg_pids+=("$np")
sleep 0.3
[ "$(rc_of "$wf" orphans)" = 0 ] && grep -q "^$np " "$dir-out" && ok "orphans: a process with no listening port is listed, exit 0" || die "orphans: $(cat "$dir-out")"
[ "$(rc_of "$wf" orphans --kill)" = 2 ] && kill -0 "$np" && ok "orphans: bare --kill refuses" || die "bare kill: $(cat "$dir-out")"
"$wf" orphans --kill WF-1 >/dev/null 2>&1
kill -0 "$np" && ok "orphans: --kill ID spares other worktrees" || die "kill other"
"$wf" orphans --kill WF-4 >/dev/null 2>&1
sleep 0.2
gone "$np" && ok "orphans: --kill ID stops that worktree's processes" || die "kill WF-4"

# ---- 9: merge and cards-commit never move the main checkout -----------------
git checkout -q -b side
[ "$(rc_of "$wf" merge wf/WF-3)" = 2 ] && [ "$(git branch --show-current)" = side ] && grep -q 'never switches' "$dir-out" &&
    ok "wf merge: refuses when main is on another branch, HEAD unchanged" || die "merge: $(cat "$dir-out")"
[ "$(rc_of "$wf" cards-commit -m "docs(tasks): x")" = 2 ] && ok "cards-commit: refuses off the base branch" || die "cards-commit: $(cat "$dir-out")"
"$wf" cards-commit --branch side -m "docs(tasks): x" >/dev/null && ok "cards-commit: --branch names the branch it may commit on" || die "cards-commit --branch"
git checkout -q main
git branch -qD side

# ---- 10: stale lock takeover has one winner ---------------------------------
common="$(git rev-parse --path-format=absolute --git-common-dir)"
: >"$dir-lock.log"
for round in 1 2 3 4 5; do
    mkdir -p "$common/workflow-race.lock"
    echo 999999 >"$common/workflow-race.lock/pid"
    for w in a b c; do
        bash -c '. "$1/scripts/lib/common.sh"; wf_lock race || exit 1
            mkdir "$2-inside" 2>/dev/null || echo OVERLAP >>"$2-lock.log"
            sleep 0.2; rmdir "$2-inside" 2>/dev/null; wf_unlock race; echo "done $3" >>"$2-lock.log"' _ "$repo" "$dir" "$round$w" &
    done
    wait
done
! grep -q OVERLAP "$dir-lock.log" && [ "$(grep -c '^done' "$dir-lock.log")" = 15 ] &&
    ok "lock: concurrent stale takeovers, one holder at a time" || die "lock race: $(cat "$dir-lock.log")"

# ---- 11: test-affected passes names as arguments ----------------------------
mkdir -p tests
cfg '.testAffected = {"cmd": "printf \"<%s>\\n\" {files}", "map": [{"src": "src/*.ts", "tests": "tests/{name}.test.ts"}]}'
git add -A && git commit -qm "chore: test map"
# shellcheck disable=SC2016 # the literal name is the point
bad='tests/x$(touch PWNED).test.ts'
echo t >"$bad"
out="$("$wf" test-affected 2>&1)" || die "test-affected: $out"
[ ! -e PWNED ] && [ ! -e tests/PWNED ] && echo "$out" | grep -qF "<$bad>" && ok "test-affected: a malicious file name is an argument, never shell" || die "injection: $out"
rm -f "$bad"
cfg 'del(.testAffected)'
echo '{ "name": "wf-safety", "scripts": { "test": "node --test" } }' >package.json
echo 'export const b = 1;' >src/b.mjs
echo 'import "node:test";' >tests/b.test.mjs
git add -A && git commit -qm "chore: node tests"
echo 'export const b = 2;' >src/b.mjs
out="$("$wf" test-affected --dry 2>&1)" || die "node --test: $out"
echo "$out" | grep -q 'run: node --test tests/b.test.mjs' && ok "test-affected: node --test projects run the related test" || die "node --test: $out"
git checkout -q src/b.mjs

# ---- 12: gates usage --------------------------------------------------------
cfg '.gates = [{"name": "short", "cmd": "true"}, {"name": "a-rather-long-gate-name", "cmd": "true"}]'
[ "$(rc_of "$wf" gates --only typo)" = 2 ] && grep -q 'unknown gate name(s): typo (valid: short, a-rather-long-gate-name)' "$dir-out" &&
    ok "gates: an unknown --only name is exit 2 with the valid names" || die "--only typo: $(cat "$dir-out")"
"$wf" gates >"$dir-out" 2>&1 || die "gates: $(cat "$dir-out")"
[ "$(grep -E '^(gate|short|a-rather) ' "$dir-out" | awk -F'|' '{ print length($1) }' | sort -u | wc -l)" = 1 ] &&
    ok "gates: table column fits the longest name" || die "alignment: $(cat "$dir-out")"
[ "$("$wf" gates --json | wc -l)" = 1 ] && "$wf" gates --json | jq -e '.results | length == 2' >/dev/null && ok "gates --json: one line" || die "json lines"
cfg '.release = {"cmd": "echo released"}'
git add -A && git commit -qm "chore: release cmd"
out="$("$wf" gates --release --json)" || die "release json: $out"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && printf '%s' "$out" | jq -e '.release == true and .results[0].status == "PASS"' >/dev/null &&
    ok "gates --release --json: release.cmd prints the JSON line" || die "release json: $out"

# ---- 8: wt-init never shares in-place-written files -------------------------
mkdir -p vendor/composer
echo "<?php return 'main';" >vendor/composer/installed.php
echo "<?php // main" >vendor/autoload.php
echo 'vendor/' >>.gitignore
cfg '.worktree = {"link": ["vendor"]}'
git add -A && git commit -qm "chore: vendor link"
wt5="$wtroot/WF-5"
git worktree add -q -b wf/WF-5 "$wt5" main
"$wf" wt-init "$wt5" >/dev/null 2>"$dir-out" || die "wt-init: $(cat "$dir-out")"
grep -qE 'vendor: (reflink copy|clone copy|hardlinked|plain copy)' "$dir-out" && ok "wt-init: prints the copy method" || die "method: $(cat "$dir-out")"
echo "<?php return 'worktree';" >>"$wt5/vendor/composer/installed.php"
echo "// worktree" >>"$wt5/vendor/autoload.php"
[ "$(cat vendor/composer/installed.php)" = "<?php return 'main';" ] && [ "$(cat vendor/autoload.php)" = "<?php // main" ] &&
    ok "wt-init: in-place writes in the worktree leave main's vendor untouched" || die "shared inode: main changed"

rm -f "$dir-out" "$dir-seen" "$dir-run.log" "$dir-lock.log" "$mark"
printf '\n%d safety checks passed (scratch: %s)\n' "$pass" "$dir"
