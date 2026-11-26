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
    "$@" >"$dir/.out" 2>&1 || {
        cat "$dir/.out" >&2
        die "$label"
    }
    ok "$label"
}
refuse() {
    local label="$1"
    shift
    if "$@" >"$dir/.out" 2>&1; then
        cat "$dir/.out" >&2
        die "$label"
    fi
    ok "$label"
}
field() { # field ID KEY: a front matter value, from tasks/ or tasks/archive/
    local f
    for f in "$dir"/tasks/"$1"-*.md "$dir"/tasks/archive/"$1"-*.md; do
        [ -f "$f" ] && sed -n "s/^$2: *//p" "$f" && return
    done
}
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
  "finish": { "mode": "none" }, "tracker": { "onMerge": "echo \"$WF_ISSUE\" >> .workflow/onmerge.log" } }
JSON
touch tasks/.keep
git add -A
git commit -qm "chore: init"

# wf new under the lock: five at once get five ids.
for _ in 1 2 3 4 5; do "$wf" new "Parallel card" >/dev/null & done
wait
ids="$(sed -n 's/^id: //p' tasks/T-*.md | sort -u | wc -l)"
[ "$ids" = 5 ] && ok "parallel wf new x5 gives 5 unique ids" || die "parallel wf new gave $ids unique ids"
rm -f tasks/T-*.md

expect "new card with links" "$wf" new "Alpha" --links "#7" --tags deploy
[ "$(field T-1 tags)" = "[deploy]" ] && ok "tags recorded" || die "tags"
expect "new card" "$wf" new "Beta"
"$wf" new "Gamma" --depends T-99 2>"$dir/.err" >/dev/null
grep -q "unknown card" "$dir/.err" && ok "unknown depends warns" || die "unknown depends warning"
git add -A && git commit -qm "chore(tasks): cards"

# start
expect "start T-1" "$wf" start T-1
wt="$dir/.workflow/worktrees/T-1"
[ -d "$wt" ] && [ "$(git -C "$wt" branch --show-current)" = wf/T-1 ] && ok "worktree on wf/T-1" || die "worktree"
[ "$(field T-1 status)" = in-progress ] && [ "$(field T-1 branch)" = wf/T-1 ] && ok "card in-progress with branch" || die "card fields"
[ "$(git branch --show-current)" = main ] && ok "main checkout HEAD untouched" || die "main HEAD moved"
expect "start again reuses the worktree" "$wf" start T-1
commit_in "$wt" feature.txt

# risk
(cd "$wt" && "$wf" risk) | grep -q '^standard feature.txt$' && ok "risk standard" || die "risk standard"
mkdir -p "$wt/db" && echo x >"$wt/db/m.sql"
(cd "$wt" && "$wf" risk --json) | jq -e '.level == "high" and .file == "db/m.sql"' >/dev/null && ok "risk high from uncommitted file" || die "risk high"
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
[ ! -d "$wt" ] && ! git show-ref --quiet refs/heads/wf/T-1 && ok "move done tore down worktree + branch" || die "teardown on done"

# merge mode
expect "start T-2" "$wf" start T-2
commit_in "$dir/.workflow/worktrees/T-2" beta.txt
expect "outcome T-2" "$wf" outcome T-2 --tick 1
write_prose T-2
expect "finish T-2 (mode merge)" "$wf" finish T-2 --mode merge
grep -q '^cleaned: .*worktree' "$dir/.out" && ok "finish prints cleaned line" || die "cleaned line"
[ -f beta.txt ] && [ "$(git branch --show-current)" = main ] && ok "merged into main, HEAD still main" || die "merge"
[ ! -d "$dir/.workflow/worktrees/T-2" ] && ! git show-ref --quiet refs/heads/wf/T-2 && ok "finish cleaned worktree + branch" || die "finish cleanup"
refuse "move done needs ticks" "$wf" move T-3 "done"
expect "move done --force" "$wf" move T-3 "done" --force

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
expect "new T-4" "$wf" new "Delta"
expect "park" "$wf" park T-4 'pick A or B? $&'
[ "$(field T-4 status)" = owner-review ] && ok "parked in owner-review" || die "park"
"$wf" status >"$dir/.status"
grep -q 'waiting on owner (1)' "$dir/.status" && grep -q 'verifying (1)' "$dir/.status" && [ "$(wc -l <"$dir/.status")" -le 25 ] && ok "status" || die "status: $(cat "$dir/.status")"
"$wf" handoff >"$dir/.handoff"
[ "$(wc -l <"$dir/.handoff")" = 5 ] && grep -q '^## Verifying' .workflow/HANDOFF.md && grep -q 'T-2 (verifying): Shipped it.' .workflow/HANDOFF.md && ok "handoff" || die "handoff"
printf '# Plan\n\nContext line.\n\n## Stream 1: api\n\nDo the api.\n\n## Stream 2: ui\n\nDo the ui.\n' >"$dir/plan.md"
expect "plan-save" "$wf" plan-save T-4 "$dir/plan.md"
expect "brief" "$wf" brief T-4 --stream 2
grep -q 'Do the ui.' .workflow/briefs/T-4-s2.md && ! grep -q 'Do the api.' .workflow/briefs/T-4-s2.md && grep -q 'Context line.' .workflow/briefs/T-4-s2.md && ok "brief has its stream only" || die "brief"
git commit -q --allow-empty -m "fix(cards): lock race"
git commit -q --allow-empty -m "fix(cards): another lock race"
"$wf" fix-sweep | grep -q '^cards ' && ok "fix-sweep clusters by scope" || die "fix-sweep"

echo "cards.sh: $pass passed ($dir)"
