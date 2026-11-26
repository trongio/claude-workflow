#!/usr/bin/env bash
# Card CLI integration test in a scratch git repo: start -> outcome -> finish
# (modes none and merge) -> move done --verified, parallel wf new, cards-commit
# flag parsing, and the smaller card commands. Needs bun, git, jq.
#
# Usage: tests/cards.sh [SCRATCH_DIR]   (default: a fresh mktemp dir)
# `ok` never fails, so `test && ok || die` is a safe if-then-else here.
# shellcheck disable=SC2015
# No pipefail: `cmd | grep -q` checks would fail on SIGPIPE when grep exits early.
set -eu

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo/bin/wf"
dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/wf-cards.XXXXXX")}"
# Scratch is removed on success unless WF_KEEP=1 or a dir was passed; kept on failure for debugging.
own_scratch=$([ -z "${1:-}" ] && echo 1 || true)
wf_scratch_cleanup() {
    local rc="${1:-$?}"
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
# expect LABEL CMD...: CMD must succeed.  refuse LABEL CMD...: CMD must fail.
expect() {
    local label="$1"
    shift
    "$@" >"$dir.out" 2>&1 || {
        cat "$dir.out" >&2
        die "$label"
    }
    ok "$label"
}
refuse() {
    local label="$1"
    shift
    if "$@" >"$dir.out" 2>&1; then
        cat "$dir.out" >&2
        die "$label"
    fi
    ok "$label"
}
exits() { # exits CODE LABEL CMD...: CMD must exit with CODE.
    local want="$1" label="$2" rc=0
    shift 2
    "$@" >"$dir.out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || {
        cat "$dir.out" >&2
        die "$label (exit $rc, want $want)"
    }
    ok "$label"
}
field() { # field ID KEY: a front matter value, from tasks/ or tasks/archive/
    local f
    for f in "$dir"/tasks/"$1"-*.md "$dir"/tasks/archive/"$1"-*.md; do
        [ -f "$f" ] && sed -n "s/^$2: *//p" "$f" && return
    done
}
criterion() { sed -i 's/^<!-- acceptance: add - \[ \] items -->$/- [ ] it works/' "$dir"/tasks/"$1"-*.md; }
write_prose() { sed -i 's/<!-- what shipped and why, decisions, follow-ups -->/Shipped it./' "$dir"/tasks/"$1"-*.md; }
commit_in() { # commit_in DIR FILE
    echo "change" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -qm "feat: $2"
}

cd "$dir"
git init -q -b main
git config user.email t@example.invalid
git config user.name test
mkdir -p tasks .claude
echo ".workflow/" >.gitignore
cat >.claude/workflow.json <<'JSON'
{ "idPrefix": "T", "baseBranch": "main", "wipLimit": 3, "risk": { "high": ["db/"] },
  "gates": [{ "name": "ok", "cmd": "true", "when": ["*"] }],
  "finish": { "mode": "none" }, "tracker": { "onMerge": "echo \"$WF_ISSUE\" >> .workflow/onmerge.log" } }
JSON
# Merge mode squashes by default (finish.squash), through wt-merge --squash.
merge_flag=--squash
touch tasks/.keep
git add -A
git commit -qm "chore: init"
# A local bare remote, so pr-mode pushes run for real without GitHub.
git init -q --bare "$dir.remote"
git remote add origin "$dir.remote"
git push -q -u origin main

# Fake gh on PATH: PRs live in a JSON state file; headRefOid is the remote
# branch tip while open and frozen at merge time.
mkdir -p "$dir.bin"
export GH_STATE="$dir.gh.json" GH_LOG="$dir.gh.log"
echo '[]' >"$GH_STATE"
cat >"$dir.bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
echo "gh $*" >>"$GH_LOG"
[ "$1 $2" = "pr view" ] || [ "$1 $2" = "pr create" ] || [ "$1 $2" = "pr merge" ] || { echo "fake gh: unsupported $*" >&2; exit 1; }
sub="$2"
shift 2
tip() { git ls-remote origin "refs/heads/$1" | cut -f1; }
case "$sub" in
view)
    pr="$(jq -c --arg b "$1" '[.[] | select(.head == $b)] | (map(select(.state == "OPEN")) + reverse) | .[0] // empty' "$GH_STATE")"
    [ -n "$pr" ] || { echo "no pull requests found for branch \"$1\"" >&2; exit 1; }
    head="$(jq -r '.mergedHead // empty' <<<"$pr")"
    [ -n "$head" ] || head="$(tip "$1")"
    jq -c --arg h "$head" '{number, state, url, headRefOid: $h}' <<<"$pr"
    ;;
create)
    # GH_CREATE_NOOP: the forge answers but the new PR is not visible yet.
    [ -z "${GH_CREATE_NOOP:-}" ] || {
        echo "https://example.invalid/pull/0"
        exit 0
    }
    head=""
    while [ $# -gt 0 ]; do
        [ "$1" = --head ] && head="$2"
        shift
    done
    n=$(($(jq length "$GH_STATE") + 1))
    jq --arg b "$head" --argjson n "$n" '. + [{number: $n, head: $b, state: "OPEN", url: "https://example.invalid/pull/\($n)"}]' "$GH_STATE" >"$GH_STATE.tmp"
    mv "$GH_STATE.tmp" "$GH_STATE"
    echo "https://example.invalid/pull/$n"
    ;;
merge)
    url="$1" want=""
    while [ $# -gt 0 ]; do
        [ "$1" = --match-head-commit ] && want="$2"
        shift
    done
    b="$(jq -r --arg u "$url" '.[] | select(.url == $u) | .head' "$GH_STATE")"
    [ "$want" = "$(tip "$b")" ] || { echo "head moved: $want vs $(tip "$b")" >&2; exit 1; }
    jq --arg u "$url" --arg h "$want" 'map(if .url == $u then .state = "MERGED" | .mergedHead = $h else . end)' "$GH_STATE" >"$GH_STATE.tmp"
    mv "$GH_STATE.tmp" "$GH_STATE"
    ;;
esac
GH
chmod +x "$dir.bin/gh"
export PATH="$dir.bin:$PATH"
# gh_merge N: the owner merges PR N on the forge.
gh_merge() {
    local h
    h="$(git ls-remote origin "refs/heads/$(jq -r --argjson n "$1" '.[] | select(.number == $n) | .head' "$GH_STATE")" | cut -f1)"
    jq --argjson n "$1" --arg h "$h" 'map(if .number == $n then .state = "MERGED" | .mergedHead = $h else . end)' "$GH_STATE" >"$GH_STATE.tmp"
    mv "$GH_STATE.tmp" "$GH_STATE"
}
# set_config JQ: edit .claude/workflow.json and commit it (worktrees branch from main).
set_config() {
    jq "$1" .claude/workflow.json >.claude/workflow.json.tmp
    mv .claude/workflow.json.tmp .claude/workflow.json
    git commit -qm "chore: config" -- .claude/workflow.json
}
# ready ID FILE: start the card, commit FILE in its worktree, write the outcome and prose.
ready() {
    "$wf" start "$1" >/dev/null
    commit_in "$dir/.workflow/worktrees/$1" "$2"
    "$wf" outcome "$1" --tick 1 >/dev/null
    write_prose "$1"
}
count() { git log --format=%s | grep -c -- "$1" || true; }

# wf new refuses unknown flags; --accept repeats into acceptance lines.
code=0
"$wf" new "Typo" --sizee S >"$dir.out" 2>&1 || code=$?
[ "$code" = 2 ] && grep -q 'unknown flag --sizee' "$dir.out" && grep -q '^Usage: wf new' "$dir.out" && [ -z "$(ls tasks/T-*.md 2>/dev/null)" ] &&
    ok "new refuses an unknown flag with usage, exit 2, no card" || die "new unknown flag (exit $code): $(cat "$dir.out")"
"$wf" new "Accept" --accept "exports 10k rows" --accept "ka headers" >/dev/null
[ "$(grep -c '^- \[ \] ' tasks/T-1-accept.md)" = 2 ] && grep -qx -- '- \[ \] ka headers' tasks/T-1-accept.md && ok "new --accept writes one acceptance line each" || die "new --accept: $(cat tasks/T-1-*.md)"
rm -f tasks/T-*.md

# wf new under the lock: five at once get five ids.
for _ in 1 2 3 4 5; do "$wf" new "Parallel card" >/dev/null & done
wait
ids="$(sed -n 's/^id: //p' tasks/T-*.md | sort -u | wc -l)"
[ "$ids" = 5 ] && ok "parallel wf new x5 gives 5 unique ids" || die "parallel wf new gave $ids unique ids"
rm -f tasks/T-*.md

expect "new card with links" "$wf" new "Alpha" --links "#7" --tags deploy
[ "$(field T-1 tags)" = "[deploy]" ] && ok "tags recorded" || die "tags"
expect "new card" "$wf" new "Beta"
grep -q '^- \[ \]' tasks/T-2-*.md && die "wf new wrote a checkbox" || ok "wf new writes no placeholder checkbox"
"$wf" new "Gamma" --depends T-99 2>"$dir/.err" >/dev/null
grep -q "unknown card" "$dir/.err" && ok "unknown depends warns" || die "unknown depends warning"
for c in T-1 T-2 T-3; do criterion $c; done
git add -A && git commit -qm "chore(tasks): cards"

# start
"$wf" start T-1 >"$dir/.start"
grep -q '^T-1 started on wf/T-1' "$dir/.start" && ok "start on a new worktree says started" || die "start message: $(cat "$dir/.start")"
wt="$dir/.workflow/worktrees/T-1"
[ -d "$wt" ] && [ "$(git -C "$wt" branch --show-current)" = wf/T-1 ] && ok "worktree on wf/T-1" || die "worktree"
[ "$(field T-1 status)" = in-progress ] && [ "$(field T-1 branch)" = wf/T-1 ] && ok "card in-progress with branch" || die "card fields"
[ "$(git branch --show-current)" = main ] && ok "main checkout HEAD untouched" || die "main HEAD moved"
"$wf" start T-1 | grep -q 'in-progress (resumed)' && ok "start again resumes the worktree" || die "resume message"
(cd "$wt" && "$wf" list) | grep -q '^T-1 .*in-progress' && ok "a worktree sees the main checkout's board" || die "board from worktree"
commit_in "$wt" feature.txt

# risk
(cd "$wt" && "$wf" risk) | grep -q '^standard feature.txt$' && ok "risk standard" || die "risk standard"
mkdir -p "$wt/db" && echo x >"$wt/db/m.sql"
(cd "$wt" && "$wf" risk --json) | jq -e '.level == "high" and .file == "db/m.sql"' >/dev/null && ok "risk high from uncommitted file" || die "risk high"
(cd "$wt" && "$wf" risk --explain) >"$dir/.explain"
[ "$(sed -n 1p "$dir/.explain")" = "high db/m.sql" ] && grep -q '^  decided by: db/ ' "$dir/.explain" && grep -q '^high (risk.high in .claude/workflow.json): db/$' "$dir/.explain" &&
    grep -q '^light ' "$dir/.explain" && ok "risk --explain: level, deciding file and pattern, then the lists" || die "risk --explain: $(cat "$dir/.explain")"
rm -rf "$wt/db"

# finish refuses without ticks and outcome
refuse "finish refuses unticked card" "$wf" finish T-1
expect "outcome skeleton + tick" "$wf" outcome T-1 --tick 1
grep -q "wf:auto" tasks/T-1-*.md && grep -q "commits (1 on wf/T-1)" tasks/T-1-*.md && ok "outcome facts" || die "outcome facts"
refuse "finish refuses a skeleton-only outcome" "$wf" finish T-1
write_prose T-1
expect "finish T-1 (mode none)" "$wf" finish T-1
[ "$(field T-1 status)" = verifying ] && ok "T-1 verifying" || die "T-1 not verifying"
grep -qx 7 .workflow/onmerge.log && ok "tracker.onMerge got WF_ISSUE=7" || die "onMerge"
[ -z "$(git status --porcelain -- tasks)" ] && ok "cards committed" || die "cards left uncommitted"

refuse "done from verifying needs --verified" "$wf" move T-1 "done"
expect "move done --verified" "$wf" move T-1 "done" --verified "scratch test"
[ -f tasks/archive/T-1-alpha.md ] && [ "$(field T-1 verified)" = 'scratch test' ] && ok "archived with verified" || die "archive"
[ -z "$(git status --porcelain -- tasks)" ] && ok "move done committed the archive move" || die "move done left tasks/ dirty: $(git status --porcelain)"
[ ! -d "$wt" ] && git show-ref --quiet refs/heads/wf/T-1 && ok "move done tore down the worktree, kept the unmerged branch (mode none)" || die "teardown on done"

# merge mode
expect "start T-2" "$wf" start T-2
commit_in "$dir/.workflow/worktrees/T-2" beta.txt
expect "outcome T-2" "$wf" outcome T-2 --tick 1
write_prose T-2
expect "finish T-2 (mode merge)" "$wf" finish T-2 --mode merge
grep -q '^cleaned: .*worktree' "$dir.out" && ok "finish prints cleaned line" || die "cleaned line"
[ -f beta.txt ] && [ "$(git branch --show-current)" = main ] && ok "merged into main, HEAD still main" || die "merge"
[ ! -d "$dir/.workflow/worktrees/T-2" ] && ! git show-ref --quiet refs/heads/wf/T-2 && ok "finish cleaned worktree + branch" || die "finish cleanup"
[ -z "$(git ls-remote origin refs/heads/wf/T-2)" ] && ok "merge mode never pushes" || die "merge mode pushed"
refuse "move done needs ticks" "$wf" move T-3 "done"
expect "move done --force" "$wf" move T-3 "done" --force

# ---------------------------------------------------------------- acceptance, owner hold, pr mode
expect "new T-4 (no criteria)" "$wf" new "Empty"
refuse "outcome --tick with no criteria" "$wf" outcome T-4 --tick 1
grep -q 'no acceptance criteria on the card' "$dir.out" && ok "outcome --tick names the missing criteria" || die "outcome --tick message"
refuse "finish with no criteria" "$wf" finish T-4 --mode none
grep -q 'no acceptance criteria on the card: add - \[ \] items or pass --force' "$dir.out" && grep -q 'Outcome is missing or holds only the skeleton' "$dir.out" &&
    ok "finish lists everything missing in one message" || die "finish refusal: $(cat "$dir.out")"
"$wf" move T-4 backlog >/dev/null

# High risk is held for the owner in every mode, until approved.
"$wf" new "Risky" >/dev/null && criterion T-5 && git add -A && git commit -qm "chore(tasks): T-5" -q
"$wf" start T-5 >/dev/null
mkdir -p "$dir/.workflow/worktrees/T-5/db"
commit_in "$dir/.workflow/worktrees/T-5" db/m.sql
"$wf" outcome T-5 --tick 1 >/dev/null && write_prose T-5
exits 4 "finish high risk (mode merge) exits 4" "$wf" finish T-5 --mode merge
[ "$(field T-5 status)" = owner-review ] && grep -q 'high risk (db/m.sql)' "$dir.out" && [ ! -f db/m.sql ] && ok "high risk parked in owner-review, not merged" || die "owner hold: $(cat "$dir.out")"
refuse "move --approve is gone" "$wf" move T-5 owner-review --approve
grep -q 'wf approve T-5' "$dir.out" && ok "move --approve points at wf approve" || die "move --approve: $(cat "$dir.out")"
refuse "approve refused headless" env WF_HEADLESS=1 "$wf" approve T-5
[ -z "$(field T-5 owner-approved)" ] && ok "headless approve records nothing" || die "headless approve recorded"
expect "wf approve" "$wf" approve T-5
tip5="$(git rev-parse wf/T-5)"
[ "$(field T-5 owner-approved | cut -d' ' -f1)" = "$tip5" ] && [ "$(field T-5 status)" = in-progress ] && [ "$(field T-5 blocked)" = '""' ] &&
    ok "approve binds the tip sha, clears blocked, restores in-progress" || die "approve fields: $(sed -n '1,20p' tasks/T-5-*.md)"
"$wf" status | grep -q 'waiting on owner' && die "approved card still waiting on owner: $("$wf" status)" || ok "approved card leaves waiting on owner"
commit_in "$dir/.workflow/worktrees/T-5" db/later.sql
exits 4 "finish after a commit past the approval" "$wf" finish T-5 --mode merge
[ "$(field T-5 status)" = owner-review ] && grep -q "approved ${tip5:0:7}, the branch is now at" "$dir.out" && [ ! -f db/m.sql ] &&
    ok "a commit after approval re-holds" || die "re-hold: $(cat "$dir.out")"
expect "wf approve again" "$wf" approve T-5
expect "finish approved high risk" "$wf" finish T-5 --mode merge
[ "$(field T-5 status)" = verifying ] && [ -f db/m.sql ] && ok "approved high risk lands" || die "approved landing"

# pr mode needs push: true and refuses before doing anything.
"$wf" new "Pull" >/dev/null && criterion T-6 && git add -A && git commit -qm "chore(tasks): T-6" -q
ready T-6 pull.txt
before="$(git rev-parse HEAD)"
refuse "pr mode with push false" "$wf" finish T-6 --mode pr
grep -q 'push is false: set "push": true to open PRs, or use finish.mode merge|none' "$dir.out" && [ "$(git rev-parse HEAD)" = "$before" ] &&
    [ -z "$(git ls-remote origin refs/heads/wf/T-6)" ] && ok "push false: nothing committed or pushed" || die "push false: $(cat "$dir.out")"

set_config '.push = true | .finish.mode = "pr"'
expect "finish T-6 (pr, opens PR)" "$wf" finish T-6
head6="$(git rev-parse wf/T-6)"
[ "$(git ls-remote origin refs/heads/wf/T-6 | cut -f1)" = "$head6" ] && ok "pr mode pushed the branch" || die "push"
# shellcheck disable=SC2016 # literal backticks in the expected message
grep -q 'PR #1 open: card parked in owner-review; after it merges run `wf finish T-6` again' "$dir.out" && [ "$(field T-6 status)" = owner-review ] &&
    ok "open PR parks the card with the re-run hint" || die "park message: $(cat "$dir.out")"
[ ! -d "$dir/.workflow/worktrees/T-6" ] && git show-ref --quiet refs/heads/wf/T-6 && ok "clean pushed worktree removed, branch kept" || die "worktree teardown while PR waits"
expect "finish T-6 again (still open)" "$wf" finish T-6
[ "$(count 'T-6 awaiting merge')" = 1 ] && [ "$(count 'T-6 outcome')" = 1 ] && [ "$(jq length "$GH_STATE")" = 1 ] && ok "a retry adds no cards commit and no PR" || die "retry duplicated: $(git log --oneline | head -5)"

# Fix commits after review are pushed to the open PR.
"$wf" move T-6 in-progress >/dev/null && "$wf" start T-6 >/dev/null
commit_in "$dir/.workflow/worktrees/T-6" fix.txt
expect "finish T-6 with a fix commit" "$wf" finish T-6
[ "$(git ls-remote origin refs/heads/wf/T-6 | cut -f1)" = "$(git rev-parse wf/T-6)" ] && grep -q 'land: updated' "$dir.out" && [ "$(jq length "$GH_STATE")" = 1 ] &&
    ok "fix commit pushed to the same PR" || die "fix push: $(cat "$dir.out")"

gh_merge 1
expect "finish T-6 after the merge" "$wf" finish T-6
[ "$(field T-6 status)" = verifying ] && ! git show-ref --quiet refs/heads/wf/T-6 && [ -z "$(git ls-remote origin refs/heads/wf/T-6)" ] &&
    ok "merged PR: verifying, local and remote branch deleted" || die "after merge: $(cat "$dir.out")"

# A reopened card with a stale MERGED PR opens a new PR for the new work.
"$wf" move T-6 in-progress >/dev/null && "$wf" start T-6 >/dev/null
commit_in "$dir/.workflow/worktrees/T-6" again.txt
expect "finish reopened T-6" "$wf" finish T-6
[ "$(jq length "$GH_STATE")" = 2 ] && [ "$(field T-6 status)" = owner-review ] && grep -q 'PR #2 open' "$dir.out" &&
    ok "stale merged PR: new PR opened, card not landed" || die "stale merged PR: $(cat "$dir.out")"

# autoMerge: gates run only in the task worktree, merge pins the gated head.
set_config ".finish.autoMerge = true | .gates = [{\"name\": \"ok\", \"cmd\": \"touch $dir.gates-ran\", \"when\": [\"*\"]}]"
expect "finish T-6 with autoMerge and no worktree" "$wf" finish T-6
[ "$(field T-6 status)" = verifying ] && [ ! -e "$dir.gates-ran" ] && [ "$(jq -r '.[1].state' "$GH_STATE")" = MERGED ] &&
    ok "autoMerge with the worktree gone uses the green run recorded for that head, no gates at root" || die "autoMerge no worktree: $(cat "$dir.out")"
"$wf" new "Auto" >/dev/null && criterion T-7 && git add -A && git commit -qm "chore(tasks): T-7" -q
ready T-7 auto.txt
expect "finish T-7 (autoMerge)" "$wf" finish T-7
head7="$(sed -n 's/^land: pushed wf\/T-7 (\(.*\))$/\1/p' "$dir.out")"
[ -e "$dir.gates-ran" ] && [ "$(field T-7 status)" = verifying ] && [ -n "$head7" ] && grep -q -- "$merge_flag --match-head-commit $head7" "$GH_LOG" && ok "autoMerge merged the gated head" || die "autoMerge: $(cat "$dir.out")"
rm -f "$dir.gates-ran"
"$wf" new "Auto risky" >/dev/null && criterion T-8 && git add -A && git commit -qm "chore(tasks): T-8" -q
"$wf" start T-8 >/dev/null && mkdir -p "$dir/.workflow/worktrees/T-8/db" && commit_in "$dir/.workflow/worktrees/T-8" db/x.sql
"$wf" outcome T-8 --tick 1 >/dev/null && write_prose T-8 && "$wf" approve T-8 >/dev/null
expect "finish T-8 (autoMerge, high risk)" "$wf" finish T-8
grep -q 'no auto-merge, high risk (db/x.sql)' "$dir.out" && [ "$(field T-8 status)" = owner-review ] && [ "$(jq -r '.[3].state' "$GH_STATE")" = OPEN ] &&
    ok "autoMerge never merges approved high risk: the PR waits for the owner" || die "autoMerge high risk: $(cat "$dir.out")"
set_config '.finish.autoMerge = false'

# A landing failure keeps the card where it was, with one note however often it is retried.
"$wf" new "Offline" >/dev/null && criterion T-9 && git add -A && git commit -qm "chore(tasks): T-9" -q
ready T-9 off.txt
git remote set-url origin "$dir.nowhere"
refuse "finish with the remote gone" "$wf" finish T-9
[ "$(wc -l <"$dir.out")" -ge 3 ] && grep -q 'push failed' "$dir.out" && ok "push failure shows the git error lines" || die "push failure output: $(cat "$dir.out")"
refuse "finish retry with the remote gone" "$wf" finish T-9
[ "$(field T-9 status)" = in-progress ] && [ "$(grep -c 'finish failed: push failed' tasks/T-9-*.md)" = 1 ] && [ "$(count 'T-9 finish failed')" = 1 ] &&
    ok "failed land: card stays, one note, one commit" || die "land failure: $(grep -n 'finish failed' tasks/T-9-*.md)"
git remote set-url origin "$dir.remote"
"$wf" move T-9 backlog >/dev/null
set_config '.push = false | .finish.mode = "none"'

# outcome regenerates its facts on every run and keeps the prose.
"$wf" new "Facts" >/dev/null && criterion T-10 && git add -A && git commit -qm "chore(tasks): T-10" -q
ready T-10 f1.txt
commit_in "$dir/.workflow/worktrees/T-10" f2.txt
"$wf" outcome T-10 >/dev/null
grep -q 'commits (2 on wf/T-10)' tasks/T-10-*.md && grep -q '^Shipped it.$' tasks/T-10-*.md && [ "$(grep -c '^<!-- wf:auto -->$' tasks/T-10-*.md)" = 1 ] &&
    ok "outcome refreshes the auto block, keeps the prose" || die "outcome refresh"
"$wf" move T-10 backlog >/dev/null

# claim --headless skips overnight.exclude tags (default migration, deploy, hardware).
"$wf" new "Ship to prod" --tags deploy >/dev/null
id_deploy="$(sed -n 's/^id: //p' tasks/T-*-ship-to-prod.md)"
refuse "headless claim of an excluded card" "$wf" claim "$id_deploy" --headless --dry-run
expect "interactive claim of the same card" "$wf" claim "$id_deploy" --dry-run

# status: the ledger's top-level key is not a card; real leftovers say wf prune.
echo '{"worktrees":{}}' >.git/workflow-resources.json
"$wf" status | grep -q leftovers && die "status reports a phantom leftover" || ok "empty ledger: no leftovers"
echo "{\"worktrees\":{\"$dir/.workflow/worktrees/T-9\":{\"id\":\"T-9\",\"branch\":\"wf/T-9\"}}}" >.git/workflow-resources.json
"$wf" status | grep -q 'leftovers: T-9 (run wf prune)' && ok "ledger leftover named, says wf prune" || die "leftover line: $("$wf" status)"
rm .git/workflow-resources.json
git add -A tasks && git commit -qm "chore(tasks): sync" -q || true

# cards-commit flags
head="$(git rev-parse HEAD)"
"$wf" note T-2 'cost $& 100' >/dev/null
grep -q 'cost \$& 100' tasks/T-2-*.md && ok "note keeps \$& literally" || die "note text"
expect "cards-commit --help" "$wf" cards-commit --help
[ "$(git rev-parse HEAD)" = "$head" ] && ok "--help committed nothing" || die "--help committed"
refuse "cards-commit refuses unknown flag" "$wf" cards-commit --bogus
expect "cards-commit -m" "$wf" cards-commit -m "docs(tasks): note"
[ "$(git log -1 --format=%s)" = "docs(tasks): note" ] && ok "committed with message" || die "commit message"

# park, status, handoff, plan + brief, fix-sweep
expect "new card Delta" "$wf" new "Delta"
expect "park" "$wf" park T-4 'pick A or B? $&'
[ "$(field T-4 status)" = owner-review ] && ok "parked in owner-review" || die "park"
"$wf" status >"$dir/.status"
grep -q 'waiting on owner (2)' "$dir/.status" && grep -q 'verifying (4)' "$dir/.status" && [ "$(wc -l <"$dir/.status")" -le 25 ] && ok "status" || die "status: $(cat "$dir/.status")"
"$wf" handoff >"$dir/.handoff"
[ "$(wc -l <"$dir/.handoff")" = 5 ] && grep -q '^## Verifying' .workflow/HANDOFF.md && grep -q 'T-2 (verifying): Shipped it.' .workflow/HANDOFF.md && ok "handoff" || die "handoff"
printf '# Plan\n\nContext line.\n\n## Stream 1: api\n\nDo the api.\n\n## Stream 2: ui\n\nDo the ui.\n' >"$dir/plan.md"
expect "plan-save" "$wf" plan-save T-4 "$dir/plan.md"
expect "brief" "$wf" brief T-4 --stream 2
grep -q 'Do the ui.' .workflow/briefs/T-4-s2.md && ! grep -q 'Do the api.' .workflow/briefs/T-4-s2.md && grep -q 'Context line.' .workflow/briefs/T-4-s2.md && ok "brief has its stream only" || die "brief"
git commit -q --allow-empty -m "fix(cards): lock race"
git commit -q --allow-empty -m "fix(cards): another lock race"
"$wf" fix-sweep | grep -q '^cards ' && ok "fix-sweep clusters by scope" || die "fix-sweep"

# ---------------------------------------------------------------- fix round 2: finish safety, approve, help
# newcard TITLE: create, add a criterion, commit; prints the id.
newcard() {
    local id
    id="$("$wf" new "$1" | cut -d' ' -f1)"
    criterion "$id"
    git add -A tasks && git commit -qm "chore(tasks): $id" -q
    echo "$id"
}
snapshot() { (
    cd "$dir" && find tasks .workflow -type f ! -path '.workflow/worktrees/*' -print0 2>/dev/null | sort -z | xargs -0 md5sum
    git rev-parse HEAD
    git worktree list
) | md5sum; }

# Every card command's --help prints help, exits 0 and changes nothing, wherever the flag sits.
before="$(snapshot)"
for c in "list --help" "next 2 --help" "claim T-2 --dry-run --help" "show T-2 -h" "move T-2 done --force --help" "new Junk --size S --help" \
    "prio T-2 1 --help" "queue 3 --help" "stats --help" "root --help" "approve T-5 --help" "board --help" \
    "start T-3 --help" "finish T-2 --force --help" "outcome T-2 --tick 1 --help" "note T-2 text --help" "park T-2 question --help" \
    "status --help" "handoff --help" "brief T-4 --stream 1 --help" "plan-save T-4 x.md --help" "fix-sweep --help" "risk --explain --help"; do
    # shellcheck disable=SC2086 # word splitting is the point
    "$wf" $c >"$dir.out" 2>&1 || die "wf $c exited non-zero: $(cat "$dir.out")"
    grep -q '^Usage: wf ' "$dir.out" || die "wf $c printed no usage: $(cat "$dir.out")"
done
[ "$(snapshot)" = "$before" ] && [ ! -d .workflow/queue ] && ok "--help on every card command: usage, exit 0, no card, queue or git change" || die "--help changed state"
for c in list next claim show move new prio queue stats root approve; do
    bun "$repo/scripts/wf.ts" help "$c" | grep -q "^Example: wf $c" || die "wf.ts help $c has no example"
done
ok "wf.ts help <cmd> has usage and an example for every card command"

# A dirty worktree is refused before anything lands; --force commits it as wip first.
id="$(newcard "Dirty")"
ready "$id" dirty1.txt
echo wip >"$dir/.workflow/worktrees/$id/untracked.txt"
echo edit >>"$dir/.workflow/worktrees/$id/dirty1.txt"
refuse "finish refuses a dirty worktree" "$wf" finish "$id" --mode merge
grep -q 'has uncommitted work' "$dir.out" && grep -q '^  untracked.txt$' "$dir.out" && grep -q '^  dirty1.txt$' "$dir.out" && [ ! -f dirty1.txt ] && [ "$(field "$id" status)" = in-progress ] &&
    ok "dirty refusal lists the paths, nothing merged, card stays" || die "dirty refusal: $(cat "$dir.out")"
expect "finish --force on a dirty worktree" "$wf" finish "$id" --mode merge --force
grep -q 'committed 2 uncommitted paths as a wip commit' "$dir.out" && [ -f untracked.txt ] && [ "$(field "$id" status)" = verifying ] &&
    ok "--force commits the dirty work as wip, then lands it" || die "dirty --force: $(cat "$dir.out")"

# Red release gates never land, in any mode; a green run for an older commit is not reused.
id="$(newcard "Red")"
ready "$id" red.txt
wtr="$dir/.workflow/worktrees/$id"
(cd "$wtr" && "$wf" gates --release >/dev/null) || die "gates --release in the worktree"
jq '.gates = [{"name": "red", "cmd": "false", "when": ["*"]}]' "$wtr/.claude/workflow.json" >"$wtr/cfg.tmp" && mv "$wtr/cfg.tmp" "$wtr/.claude/workflow.json"
git -C "$wtr" commit -qam "chore: red gate"
refuse "finish merge with red gates" "$wf" finish "$id" --mode merge
grep -q "release gates are not green for $(git rev-parse --short=7 "wf/$id")" "$dir.out" && grep -q 'red FAIL' "$dir.out" && [ ! -f red.txt ] &&
    ok "merge mode: red gates (older green run ignored) refuse, nothing merged" || die "red merge: $(cat "$dir.out")"
set_config '.push = true'
prs="$(jq length "$GH_STATE")"
refuse "finish pr with red gates" "$wf" finish "$id" --mode pr
[ -z "$(git ls-remote origin "refs/heads/wf/$id")" ] && [ "$(jq length "$GH_STATE")" = "$prs" ] && ok "pr mode: red gates refuse before push or PR" || die "red pr: $(cat "$dir.out")"
set_config '.push = false'
"$wf" finish "$id" --mode merge --force >"$dir.out" 2>&1 || die "finish --force red: $(cat "$dir.out")"
grep -q 'WARNING: --force lands' "$dir.out" && grep -q 'landed WITHOUT green release gates' tasks/"$id"-*.md && [ -f red.txt ] &&
    ok "--force lands red gates with a loud note on the card" || die "red --force: $(cat "$dir.out")"
# The forced landing brought the red gate to main: later cards get a green one again.
set_config '.gates = [{"name": "ok", "cmd": "true", "when": ["*"]}]'

# Work saved by teardown after a PR merged (a wip commit past the merged head) keeps the branch, local and remote.
id="$("$wf" new "Late" --links "#9" | cut -d' ' -f1)"
criterion "$id" && git add -A tasks && git commit -qm "chore(tasks): $id" -q
ready "$id" late.txt
# shellcheck disable=SC2016 # $WF_CARD expands in the hook, not here
set_config '.push = true | .tracker.onMerge = "echo late > .workflow/worktrees/$WF_CARD/late-wip.txt"'
"$wf" finish "$id" --mode pr --no-cleanup >/dev/null 2>&1 || die "first pr finish (Late)"
gh_merge "$(jq --arg b "wf/$id" '[.[] | select(.head == $b)][0].number' "$GH_STATE")"
# The forge merge moved origin's main past the local one.
git clone -q -b main "$dir.remote" "$dir.clone"
git -C "$dir.clone" -c user.email=t@example.invalid -c user.name=test commit -q --allow-empty -m "forge merge"
git -C "$dir.clone" push -q origin main
expect "finish a merged PR while work appears in the worktree" "$wf" finish "$id" --mode pr
grep -qx "pull main to pick up the merge: git -C $dir pull --rebase" "$dir.out" && ok "merged PR: says how to pull the base, does not pull" || die "pull hint: $(cat "$dir.out")"
[ "$(git rev-parse main)" != "$(git -C "$dir.clone" rev-parse main)" ] || die "finish pulled main"
grep -q "kept branch wf/$id: its tip" "$dir.out" && git show "wf/$id:late-wip.txt" >/dev/null 2>&1 && [ -n "$(git ls-remote origin "refs/heads/wf/$id")" ] &&
    [ "$(field "$id" status)" = verifying ] && ok "a wip commit past the merged head keeps the branch and its remote" || die "late work: $(cat "$dir.out")"
set_config '.push = false | .tracker.onMerge = ""'

# A merged PR counts only for the branch tip, also after a fresh push and create.
set_config '.push = true'
id="$(newcard "Moved on")"
ready "$id" moved.txt
"$wf" finish "$id" --mode pr >/dev/null 2>&1 || die "first pr finish"
gh_merge "$(jq --arg b "wf/$id" '[.[] | select(.head == $b)][0].number' "$GH_STATE")"
"$wf" move "$id" in-progress >/dev/null && "$wf" start "$id" >/dev/null
commit_in "$dir/.workflow/worktrees/$id" moved2.txt
GH_CREATE_NOOP=1 "$wf" finish "$id" --mode pr >"$dir.out" 2>&1 || die "finish with a stale merged PR: $(cat "$dir.out")"
[ "$(field "$id" status)" = owner-review ] && grep -q "merged at .*, not the branch tip $(git rev-parse --short=7 "wf/$id")" "$dir.out" &&
    ok "a merged PR for an older head never lands the new tip" || die "stale merged after create: $(cat "$dir.out")"
set_config '.push = false'
"$wf" move "$id" backlog >/dev/null

# Waiting on the owner: the question is shown whole, and a kept worktree is not a leftover.
id="$(newcard "Question")"
"$wf" start "$id" >/dev/null
q="owner: should the export include archived employees, and if so do we mark them with a badge, a separate sheet, or a column that says when they left the company?"
"$wf" park "$id" "$q" >/dev/null
echo "{\"worktrees\":{\"$dir/.workflow/worktrees/$id\":{\"id\":\"$id\",\"branch\":\"wf/$id\"}}}" >.git/workflow-resources.json
"$wf" status >"$dir/.status"
shown="$(sed -n "/^waiting on owner/,/^[a-z]/p" "$dir/.status" | tr -s ' \n' ' ')"
grep -q leftovers "$dir/.status" && die "owner-review card with its worktree reported as leftover: $(cat "$dir/.status")" || true
[[ "$shown" == *"$id $q "* ]] && ! grep -q "^  $id .*~$" "$dir/.status" && [ "$(wc -l <"$dir/.status")" -le 25 ] &&
    ok "status: full owner question wrapped, parked worktree not a leftover" || die "status owner text: $(cat "$dir/.status")"
rm .git/workflow-resources.json
expect "approve the parked card" "$wf" approve "$id"
[ "$(field "$id" status)" = in-progress ] && ! "$wf" status | sed -n '/^waiting on owner/,/^[a-z]/p' | grep -q "^  $id " && ok "approve restores the parked status and leaves waiting on owner" || die "approve unpark: $("$wf" status)"

# A started card whose worktree is gone says how to resume.
git worktree remove --force "$dir/.workflow/worktrees/$id"
"$wf" status | grep -q "worktree gone: $id (worktree gone: wf start $id to resume or wf move $id backlog)" && ok "status hints at a lost worktree" || die "status gone: $("$wf" status)"
"$wf" show "$id" 2>&1 >/dev/null | grep -q "hint: worktree gone: wf start $id to resume" && ok "show hints at a lost worktree" || die "show gone hint"

# ---------------------------------------------------------------- fix round 3: finish exit codes and landing safety
# Moving a file out of a high-risk path is high risk: both rename paths count.
id="$(newcard "Rename out")"
"$wf" start "$id" >/dev/null
wtn="$dir/.workflow/worktrees/$id"
git -C "$wtn" mv db/m.sql moved-out.txt && git -C "$wtn" commit -qm "refactor: move the migration"
"$wf" outcome "$id" --tick 1 >/dev/null && write_prose "$id"
exits 4 "finish a rename out of risk.high exits 4" "$wf" finish "$id" --mode merge
[ "$(field "$id" status)" = owner-review ] && grep -q 'high risk (db/m.sql)' "$dir.out" && [ -f db/m.sql ] && ok "rename out of db/ parks for the owner, nothing merged" || die "rename hold: $(cat "$dir.out")"
"$wf" move "$id" backlog >/dev/null

# A release run on a dirty tree proves no commit: finish runs the gates again.
set_config ".gates = [{\"name\": \"ok\", \"cmd\": \"touch $dir.gates-ran\", \"when\": [\"*\"]}]"
id="$(newcard "Dirty proof")"
ready "$id" proof.txt
wtd="$dir/.workflow/worktrees/$id"
echo scratch >"$wtd/scratch.txt"
(cd "$wtd" && "$wf" gates --release >/dev/null 2>&1) || true
jq -e --arg sha "$(git rev-parse "wf/$id")" '.dirty == true and .sha == $sha' "$wtd/.workflow/gates-last.json" >/dev/null || die "gates did not record a dirty run: $(cat "$wtd/.workflow/gates-last.json")"
rm -f "$wtd/scratch.txt" "$dir.gates-ran"
expect "finish after a dirty-tree release run" "$wf" finish "$id" --mode merge
[ -e "$dir.gates-ran" ] && [ "$(field "$id" status)" = verifying ] && ok "a dirty-tree release run is not reused: the gates ran again" || die "dirty proof reused: $(cat "$dir.out")"

# A commit made after the gates checked the tip is never merged: wt-merge --sha refuses.
set_config '.gates = [{"name": "late", "cmd": "git commit -q --allow-empty -m late-commit", "when": ["*"]}]'
id="$(newcard "Late commit")"
ready "$id" gated.txt
gated="$(git rev-parse "wf/$id")"
exits 2 "finish refuses when the tip moved after the gates" "$wf" finish "$id" --mode merge
[ "$(git rev-parse "wf/$id")" != "$gated" ] && [ ! -f gated.txt ] && grep -q "not the gated $gated" "$dir.out" && [ "$(field "$id" status)" = in-progress ] &&
    ok "tip mismatch: nothing merged, card stays" || die "tip mismatch: $(cat "$dir.out")"
set_config '.gates = [{"name": "ok", "cmd": "true", "when": ["*"]}]'
"$wf" move "$id" backlog >/dev/null

# --force commits only in the task worktree; a branch checked out elsewhere is refused when dirty.
id="$(newcard "Elsewhere")"
git worktree add -q -b "wf/$id" "$dir.elsewhere" main
commit_in "$dir.elsewhere" elsewhere.txt
"$wf" outcome "$id" --tick 1 >/dev/null && write_prose "$id"
echo wip >"$dir.elsewhere/stray.txt"
exits 2 "finish --force in a foreign worktree exits 2" "$wf" finish "$id" --mode merge --force
grep -q 'is not the task worktree, so --force never commits there' "$dir.out" && [ -n "$(git -C "$dir.elsewhere" status --porcelain)" ] && [ ! -f elsewhere.txt ] &&
    ok "foreign worktree: dirty work refused, not committed, not merged" || die "foreign --force: $(cat "$dir.out")"
git worktree remove --force "$dir.elsewhere"
"$wf" move "$id" backlog >/dev/null

# Headless sessions never force a landing.
id="$(newcard "Headless")"
ready "$id" headless.txt
before="$(snapshot)"
exits 2 "WF_HEADLESS=1 finish --force exits 2" env WF_HEADLESS=1 "$wf" finish "$id" --mode merge --force
grep -q 'refused headless' "$dir.out" && [ "$(snapshot)" = "$before" ] && ok "headless --force changes nothing" || die "headless force: $(cat "$dir.out")"
expect "headless finish without --force lands through wt-merge" env WF_HEADLESS=1 "$wf" finish "$id" --mode merge
[ -f headless.txt ] && [ "$(field "$id" status)" = verifying ] && ok "headless finish passes WF_FROM_FINISH to wt-merge" || die "headless merge: $(cat "$dir.out")"

# pr mode with no gh binary: one clear line, exit 2, no stack trace.
nogh="$dir.nogh"
mkdir -p "$nogh"
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
    for f in "$d"/*; do
        n="${f##*/}"
        [ "$n" = gh ] || [ -e "$nogh/$n" ] || [ ! -x "$f" ] || ln -s "$f" "$nogh/$n"
    done
done
set_config '.push = true'
id="$(newcard "No gh")"
ready "$id" nogh.txt
exits 2 "pr mode without gh exits 2" env PATH="$nogh" "$wf" finish "$id" --mode pr
grep -qx 'gh not found: install GitHub CLI or use finish.mode merge|none' "$dir.out" && ! grep -q '^ *at ' "$dir.out" && [ -z "$(git ls-remote origin "refs/heads/wf/$id")" ] &&
    ok "missing gh: one line, nothing pushed" || die "missing gh: $(cat "$dir.out")"
set_config '.push = false'
"$wf" move "$id" backlog >/dev/null

# A conflict names the files and gives one next step, exit 3.
a="$(newcard "Side A")"
b="$(newcard "Side B")"
ready "$a" both.txt
ready "$b" both.txt
echo b >"$dir/.workflow/worktrees/$b/both.txt" && git -C "$dir/.workflow/worktrees/$b" commit -qam "feat: b side"
expect "finish side A" "$wf" finish "$a" --mode merge
exits 3 "finish side B conflicts with exit 3" "$wf" finish "$b" --mode merge
grep -q 'merge conflict in: both.txt$' "$dir.out" && grep -q "next: rebase the task branch onto main in its worktree, resolve, commit, then wf finish $b" "$dir.out" &&
    ! grep -q '>>>>>>>' "$dir.out" && [ "$(field "$b" status)" = in-progress ] && ok "conflict: file list and one next step" || die "conflict message: $(cat "$dir.out")"
"$wf" move "$b" backlog >/dev/null

# No net change against the base: exit 5, the base untouched.
id="$(newcard "No-op")"
ready "$id" noop.txt
git -C "$dir/.workflow/worktrees/$id" rm -q noop.txt && git -C "$dir/.workflow/worktrees/$id" commit -qm "revert: noop"
head="$(git rev-parse main)"
exits 5 "finish with no net change exits 5" "$wf" finish "$id" --mode merge
grep -q "nothing to land: the branch has no changes against main; wf move $id done --verified or backlog" "$dir.out" && [ "$(git log -1 --format=%s main)" != "No-op ($id)" ] &&
    ok "nothing to land: message, no merge commit" || die "nothing to land: $(cat "$dir.out") $head"

# The help documents every exit code.
"$wf" finish --help >"$dir.out"
for c in 0 2 3 4 5; do grep -q "^  $c  " "$dir.out" || die "finish --help lacks exit $c"; done
ok "finish --help documents exit codes 0 2 3 4 5"

echo "cards.sh: $pass passed ($dir)"
