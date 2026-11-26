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
# detach DIR CMD...: start CMD in DIR reparented to init (no claude ancestor,
# as a server left by an agent's finished shell would be); prints its pid.
detach() {
    local d="$1"
    shift
    (
        cd "$d" || exit 1
        "$@" >/dev/null 2>&1 </dev/null &
        echo $! >"$dir-detach.pid"
    )
    cat "$dir-detach.pid"
}
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

# wt-init: a signal stops the setup command's process group too (Ctrl-C on npm install).
git worktree add -q -b sig "$dir-sig" main
jq '.worktree.setup = ["sleep 1777"]' "$dir-sig/.claude/workflow.json" >cfg.tmp && mv cfg.tmp "$dir-sig/.claude/workflow.json"
for sig in INT:130 TERM:143; do
    set -m # a background job of a script ignores SIGINT unless it has its own group
    "$wf" wt-init "$dir-sig" >/dev/null 2>&1 &
    ip=$!
    set +m
    bg_pids+=("$ip")
    wait_for 'sleep 1777' || die "wt-init setup never started"
    kill -"${sig%:*}" "$ip"
    r=0
    wait "$ip" || r=$?
    sleep 0.3
    [ "$r" = "${sig#*:}" ] && ! pgrep -fx 'sleep 1777' >/dev/null && ok "wt-init: SIG${sig%:*} stops the setup command, exit ${sig#*:}" ||
        die "wt-init SIG${sig%:*}: rc $r, $(pgrep -fx 'sleep 1777' || true)"
done
git worktree remove --force "$dir-sig"
git branch -qD sig

# ---- 5: orphans lists port-less processes, --kill is scoped -----------------
wt4="$wtroot/WF-4"
[ -d "$wt4" ] || die "WF-4 worktree missing"
cp "$(command -v sleep)" "$stub/node"
np="$(detach "$wt4" "$stub/node" 300)"
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

# A failing commit hook leaves the card edits unstaged, never staged for the next commit.
mkdir -p "$dir-hooks"
printf '#!/bin/sh\necho "hook said no"\nexit 1\n' >"$dir-hooks/pre-commit"
chmod +x "$dir-hooks/pre-commit"
git config core.hooksPath "$dir-hooks"
"$wf" note WF-3 "hook check" >/dev/null
[ "$(rc_of "$wf" cards-commit -m "docs(tasks): hooked")" = 1 ] && grep -q 'hook said no' "$dir-out" &&
    git diff --cached --quiet && [ -n "$(git status --porcelain -- tasks)" ] &&
    ok "cards-commit: a failing hook exits 1 with its output, card edits unstaged" || die "cards hook: $(cat "$dir-out"); $(git status --short)"
git config --unset core.hooksPath
"$wf" cards-commit -m "docs(tasks): hook check" >/dev/null

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

# ---- 13: a user's own worktree never enters the ledger or teardown ---------
jq --arg t "echo \"drop [\$DB_DATABASE]\" >>'$mark'" \
    '.worktree = {link: ["vendor"], env: {DB_DATABASE: "app_{slug}"}, teardown: [$t]}' .claude/workflow.json >cfg.tmp &&
    mv cfg.tmp .claude/workflow.json
git add -A && git commit -qm "chore: env teardown"
git worktree add -q -b hotfix "$dir-hot" main
(cd "$dir-hot" && "$wf" gates >/dev/null 2>"$dir-out") || die "gates in a user worktree: $(cat "$dir-out")"
! jq -e --arg d "$dir-hot" '.worktrees | has($d)' "$ledger" >/dev/null && [ ! -e "$dir-hot/vendor" ] && grep -q 'vendor is missing' "$dir-out" &&
    ok "gates: a user worktree only gets a warning, never wt-init or a ledger entry" || die "user worktree ledgered: $(cat "$dir-out")"
(cd "$dir-hot" && echo 'export const h = 1;' >src/h.ts && echo secret >.env.local && git add src/h.ts && git commit -qm "fix: h")
git merge -q --no-ff -m "merge: hotfix" hotfix
# An entry an older version recorded for it is forgotten, nothing else.
jq --arg d "$dir-hot" '.worktrees[$d] = {id: "hotfix", branch: "hotfix", db: [], pids: []}' "$ledger" >"$ledger.t" && mv "$ledger.t" "$ledger"
DB_DATABASE=main_dev_db "$wf" prune --apply >"$dir-out" 2>&1 || true
[ -f "$dir-hot/.env.local" ] && git rev-parse -q --verify refs/heads/hotfix >/dev/null && ! grep -q main_dev_db "$mark" 2>/dev/null &&
    ! jq -e --arg d "$dir-hot" '.worktrees | has($d)' "$ledger" >/dev/null && grep -q "forgot ledger entry $dir-hot" "$dir-out" &&
    ok "prune: a merged user worktree and its branch survive; its old ledger entry is only forgotten" || die "user worktree pruned: $(cat "$dir-out")"
git worktree remove --force "$dir-hot"
git branch -qD hotfix
rm -f "$mark"

git worktree add -q -b wf/ENV1 "$wtroot/ENV1" main
git worktree add -q -b wf/ENV2 "$wtroot/ENV2" main
"$wf" wt-init "$wtroot/ENV1" >/dev/null 2>&1
"$wf" wt-init "$wtroot/ENV2" >/dev/null 2>&1
: >"$wtroot/ENV1/.workflow/env" # an env file without the key the caller has set
rm "$wtroot/ENV2/.workflow/env"
DB_DATABASE=main_dev_db "$wf" prune --apply ENV1 >"$dir-out" 2>&1 || die "prune ENV1: $(cat "$dir-out")"
[ "$(cat "$mark")" = "drop []" ] && ok "teardown: worktree.env keys are unset, the caller's value never leaks" || die "env leak: $(cat "$mark")"
rm -f "$mark"
DB_DATABASE=main_dev_db "$wf" prune --apply ENV2 >"$dir-out" 2>&1 || die "prune ENV2: $(cat "$dir-out")"
[ ! -e "$mark" ] && [ ! -d "$wtroot/ENV2" ] && grep -q 'skipped worktree.teardown' "$dir-out" &&
    ok "teardown: no .workflow/env, teardown commands skipped and said so" || die "no env: $(cat "$dir-out")"
cfg '.worktree = {}'
git add -A && git commit -qm "chore: plain worktrees"

# ---- 14: squash-merged PR must match the branch tip ------------------------
pr="$("$wf" new "PR card" --area safety | awk '{ print $1 }')"
git add -A && git commit -qm "chore: pr card"
"$wf" move "$pr" "done" --force >/dev/null 2>&1 || die "move $pr done"
git worktree add -q -b "wf/$pr" "$dir-tmppr" main
(cd "$dir-tmppr" && echo 'export const p = 1;' >src/p.ts && git add src/p.ts && git commit -qm "feat: p")
merged_tip="$(git rev-parse "wf/$pr")"
(cd "$dir-tmppr" && echo 'export const p = 2;' >src/p.ts && git commit -qam "fix: after the merge")
git worktree remove --force "$dir-tmppr"
printf '#!/bin/sh\ncat "%s"\n' "$dir-gh.json" >"$stub/gh"
chmod +x "$stub/gh"
printf '{"state":"MERGED","headRefOid":"%s"}' "$merged_tip" >"$dir-gh.json"
out="$(PATH="$stub:$PATH" "$wf" prune 2>&1)"
! echo "$out" | grep -q "wf/$pr" && ok "prune: a merged PR whose head is not the branch tip keeps the branch" || die "stale PR: $out"
printf '{"state":"MERGED","headRefOid":"%s"}' "$(git rev-parse "wf/$pr")" >"$dir-gh.json"
PATH="$stub:$PATH" "$wf" prune 2>&1 | grep -q "would delete branch wf/$pr (card done, PR merged)" &&
    ok "prune: a merged PR at the branch tip is deletable" || die "PR at tip not listed"
git branch -qD "wf/$pr"
rm -f "$stub/gh"

# ---- 15: preview down kills only a pid inside the worktree ------------------
git worktree add -q -b wf/PV "$wtroot/PV" main
mkdir -p "$wtroot/PV/.workflow"
(cd / && exec sleep 1555) &
up=$!
bg_pids+=("$up")
echo "$up" >"$wtroot/PV/.workflow/preview.pid"
"$wf" preview down PV >"$dir-out" 2>&1 || die "preview down: $(cat "$dir-out")"
kill -0 "$up" 2>/dev/null && grep -q 'not killed' "$dir-out" && ok "preview down: a reused pid outside the worktree is not killed" || die "preview killed $up"
kill "$up"

# ---- 16: wt-merge aborts a conflict, main left clean -----------------------
echo base >src/c.txt
git add src/c.txt && git commit -qm "chore: c"
git branch wf/CF
git worktree add -q "$dir-cf" wf/CF
(cd "$dir-cf" && echo theirs >src/c.txt && git commit -qam "feat: theirs")
git worktree remove --force "$dir-cf"
echo ours >src/c.txt && git commit -qam "feat: ours"
head="$(git rev-parse HEAD)"
for flag in "" --squash; do
    r="$(rc_of "$wf" merge wf/CF ${flag:+"$flag"})"
    [ "$r" = 3 ] && grep -q 'src/c.txt' "$dir-out" && [ "$(git rev-parse HEAD)" = "$head" ] &&
        [ -z "$(git status --porcelain --untracked-files=no)" ] && [ ! -e .git/MERGE_HEAD ] && [ "$(cat src/c.txt)" = ours ] &&
        ok "wt-merge ${flag:-(no-ff)}: a conflict aborts, main clean, exit 3 with the files" || die "conflict $flag: rc $r, $(cat "$dir-out"); $(git status --short)"
done
git branch -qD wf/CF
sq="$("$wf" new "Squash card" --area safety | awk '{ print $1 }')"
git add -A && git commit -qm "chore: squash card"
git branch "wf/$sq"
git worktree add -q "$dir-sq" "wf/$sq"
(cd "$dir-sq" && echo 1 >src/s1.txt && git add -A && git commit -qm "feat: s1" && echo 2 >src/s2.txt && git add -A && git commit -qm "feat: s2")
git worktree remove --force "$dir-sq"
"$wf" merge "wf/$sq" --squash | grep -q 'squashed' && [ "$(git log -1 --format=%s)" = "Squash card ($sq)" ] &&
    [ "$(git log -1 --format=%P | wc -w)" = 1 ] && ok "wt-merge --squash: one commit named after the card" || die "squash: $(git log -3 --oneline)"
git branch -qD "wf/$sq"
# --sha, an empty net diff, headless refusal.
git checkout -q -b wf/SH main
echo 1 >src/sh.txt && git add -A && git commit -qm "feat: sh"
git checkout -q -b wf/EM main
echo 1 >src/em.txt && git add -A && git commit -qm "feat: em" && git rm -q src/em.txt && git commit -qm "revert: em"
git checkout -q main
head="$(git rev-parse HEAD)"
[ "$(rc_of "$wf" merge wf/SH --sha "$head")" = 2 ] && grep -q 'not the gated' "$dir-out" && [ "$(git rev-parse HEAD)" = "$head" ] &&
    ok "wt-merge --sha: refuses (exit 2) when the branch tip is not the gated sha" || die "sha mismatch: $(cat "$dir-out")"
for flag in "" --squash; do
    [ "$(rc_of "$wf" merge wf/EM ${flag:+"$flag"})" = 5 ] && grep -q 'nothing to merge' "$dir-out" && [ "$(git rev-parse HEAD)" = "$head" ] &&
        [ -z "$(git status --porcelain --untracked-files=no)" ] && ok "wt-merge ${flag:-(no-ff)}: an empty net diff exits 5, main untouched" || die "empty $flag: $(cat "$dir-out"); $(git status --short)"
done
[ "$(WF_HEADLESS=1 rc_of "$wf" merge wf/SH)" = 2 ] && grep -q 'refused in a headless session' "$dir-out" && [ "$(git rev-parse HEAD)" = "$head" ] &&
    ok "wt-merge: refused in a headless session" || die "headless: $(cat "$dir-out")"
[ "$(WF_HEADLESS=1 WF_FROM_FINISH=1 rc_of "$wf" merge wf/EM)" = 5 ] && ok "wt-merge: WF_FROM_FINISH=1 passes the headless check" || die "from finish: $(cat "$dir-out")"
"$wf" merge wf/SH --sha "$(git rev-parse wf/SH)" | grep -qx 'merged wf/SH (1 commit, 1 file)' && ok "wt-merge --sha: merges the gated tip; counts pluralized" || die "sha merge: $(git log -2 --oneline)"
git branch -qD wf/SH wf/EM

# ---- 17: runner lock takeover, session sweep, WF_HEADLESS -------------------
rm -f .workflow/queue/*.task
"$wf" move WF-4 backlog >/dev/null 2>&1 || true
printf '#!/bin/sh\necho "{\\"is_error\\":false}"\n' >"$stub/claude"
chmod +x "$stub/claude"
mkdir -p .workflow/.runner.lock
: >.workflow/.runner.lock/pid
[ "$(PATH="$stub:$PATH" rc_of timeout 30 "$wf" run)" = 1 ] && grep -q 'another runner is active' "$dir-out" &&
    ok "runner: a lock with an empty pid file (owner starting) is busy, not dead" || die "empty pid lock: $(cat "$dir-out")"
echo 999999 >.workflow/.runner.lock/pid
[ "$(PATH="$stub:$PATH" rc_of timeout 30 "$wf" run)" = 0 ] && [ ! -d .workflow/.runner.lock ] &&
    ok "runner: a dead owner's lock is taken over" || die "dead pid lock: $(cat "$dir-out")"
"$wf" new "Sweep card" --area safety >/dev/null
git add -A && git commit -qm "chore: sweep card"
cat >"$stub/claude" <<EOF
#!/bin/sh
echo "\$WF_HEADLESS" >"$dir-headless"
sleep 1666 >/dev/null 2>&1 &
setsid sleep 1667 >/dev/null 2>&1 </dev/null &
echo '{"is_error":false,"session_id":"s","total_cost_usd":0}'
EOF
"$wf" queue 1 >/dev/null
PATH="$stub:$PATH" timeout 60 "$wf" run >"$dir-run.log" 2>&1 || die "sweep runner: $(tail -5 "$dir-run.log")"
grep -q ' started (pid' "$dir-run.log" || die "sweep card never ran: $(cat "$dir-run.log")"
sleep 0.3
! pgrep -fx 'sleep 1666' >/dev/null && ok "runner: the session's process group is stopped after a normal exit" || die "group left: $(pgrep -fa 'sleep 166' || true)"
! pgrep -fx 'sleep 1667' >/dev/null && ok "runner: a process that left the group but runs in the worktree is stopped" || die "worktree process left"
[ "$(cat "$dir-headless")" = 1 ] && ok "runner: sessions get WF_HEADLESS=1" || die "WF_HEADLESS: $(cat "$dir-headless")"
# shellcheck disable=SC2016 # expands in the inner shell
setsid bash -c 'sleep 1644 >/dev/null 2>&1 & echo $$ >"$1"' _ "$dir-pg" &
for _ in $(seq 1 20); do
    [ -s "$dir-pg" ] && pgrep -fx 'sleep 1644' >/dev/null && break
    sleep 0.1
done
sleep 0.2
kill -0 "$(cat "$dir-pg")" 2>/dev/null && die "group leader still alive"
bash -c '. "$1/scripts/lib/common.sh"; wf_kill_tree "$2"' _ "$repo" "$(cat "$dir-pg")"
! pgrep -fx 'sleep 1644' >/dev/null && ok "wf_kill_tree: kills the group after its leader exited" || die "leaderless group survived"

# ---- 18: prune relative DIR, branch -D failure, orphans --json --kill -------
git worktree add -q -b wf/REL "$wtroot/REL" main
(cd "$dir/.workflow" && "$wf" prune worktrees/REL 2>&1) | grep -q "would tear down $wtroot/REL (named)" &&
    ok "prune: a relative DIR resolves against the caller's cwd" || die "relative dir"
op="$(detach "$wtroot/REL" "$stub/node" 302)"
bg_pids+=("$op")
cat >"$stub/claude" <<EOF
#!/bin/sh
"$stub/node" 303 &
wait
EOF
chmod +x "$stub/claude"
cl="$(detach "$wtroot/REL" "$stub/claude")"
bg_pids+=("$cl")
for _ in $(seq 1 20); do
    pgrep -fx "$stub/node 303" >/dev/null && break
    sleep 0.1
done
mcp="$(pgrep -fx "$stub/node 303")"
bg_pids+=("$mcp")
out="$("$wf" orphans --json --kill REL 2>"$dir-out")" || die "orphans json kill"
sleep 0.2
printf '%s' "$out" | jq -e --argjson p "$op" 'map(.pid) | index($p) != null' >/dev/null && gone "$op" &&
    ok "orphans --json --kill: kills and prints the JSON" || die "json kill: $out $(cat "$dir-out")"
kill -0 "$mcp" && printf '%s' "$out" | jq -e --argjson p "$mcp" '.[] | select(.pid == $p) | .underClaude' >/dev/null &&
    ok "orphans --kill: a child of a claude process (an MCP server) is never killed" || die "claude child killed: $out"
kill "$cl" "$mcp" 2>/dev/null || true
git branch wf/A-LOCK main
git branch wf/B-OK main
touch "$(git rev-parse --git-common-dir)/refs/heads/wf/A-LOCK.lock"
[ "$(rc_of "$wf" prune --apply)" = 1 ] && grep -q 'could not delete branch wf/A-LOCK' "$dir-out" &&
    ! git rev-parse -q --verify refs/heads/wf/B-OK >/dev/null && ok "prune: a failing branch -D is reported and the scan goes on" || die "branch -D: $(cat "$dir-out")"
rm -f "$(git rev-parse --git-common-dir)/refs/heads/wf/A-LOCK.lock"
git branch -qD wf/A-LOCK

# ---- 19: the session sweep spares claude processes and their children -------
mkdir -p "$dir-sweep"
cat >"$stub/claude" <<EOF
#!/bin/sh
sleep 1655 &
wait
EOF
chmod +x "$stub/claude"
cl="$(detach "$dir-sweep" "$stub/claude")"
plain="$(detach "$dir-sweep" sleep 1656)"
bg_pids+=("$cl" "$plain")
wait_for 'sleep 1655' || die "claude child never started"
mcp="$(pgrep -fx 'sleep 1655')"
bg_pids+=("$mcp")
bash -c '. "$1/scripts/lib/common.sh"; cd /; wf_sweep "$2"' _ "$repo" "$dir-sweep" >"$dir-out" 2>&1
sleep 0.2
kill -0 "$cl" && kill -0 "$mcp" && gone "$plain" &&
    ok "wf_sweep: a claude process and its children in the worktree survive, others stop" || die "sweep: $(cat "$dir-out")"
kill "$mcp" "$cl" 2>/dev/null || true

# ---- 20: bash older than 4.4 is refused -------------------------------------
bash -c '. "$1/scripts/lib/common.sh"; ! wf_bash_ok 4 3 && ! wf_bash_ok 3 2 && wf_bash_ok 4 4 && wf_bash_ok 5 0' _ "$repo" &&
    grep -q 'bash 4.4+ required.*brew install bash' "$repo/scripts/lib/common.sh" && ok "common.sh: requires bash 4.4" || die "bash version check"

rm -rf "$dir-sweep" "$dir-hooks"
rm -f "$dir-out" "$dir-seen" "$dir-run.log" "$dir-lock.log" "$mark" "$dir-gh.json" "$dir-headless" "$dir-pg" "$dir-detach.pid"
printf '\n%d safety checks passed (scratch: %s)\n' "$pass" "$dir"
