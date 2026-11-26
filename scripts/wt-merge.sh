#!/usr/bin/env bash
# Merge an agent branch into the main checkout with a compact report.
#
# Usage: wf merge BRANCH [--into BASE] [--squash] [-m "merge: <what> into main"]
#
# Runs in the main checkout (found via git's common dir, so it works from a
# worktree too), under a repo-wide lock so parallel tasks never merge at the
# same moment. Refuses unless the main checkout is already on --into (default:
# the base branch): it never changes the main checkout's HEAD. Merges BRANCH
# with --no-ff and a conventional message; --squash makes one commit instead,
# "<card title> (<ID>)" for a wf/<ID> branch unless -m names it.
#
# Prints `merged <branch> (<n> commits, <files> files)`. On a conflict the
# merge is aborted (the main checkout is left exactly as it was, nothing
# staged) and the conflicting files are listed with their first hunks: merge
# the base into the branch in its worktree, resolve there, and run it again.
# Exit 3 on conflict, 1 when the merge or its commit fails otherwise, 2 on
# usage or a dirty tree.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

branch="" into="" msg="" squash=0
while [ $# -gt 0 ]; do
    case "$1" in
    --into)
        into="${2:?--into needs a branch}"
        shift
        ;;
    --into=*) into="${1#--into=}" ;;
    --squash) squash=1 ;;
    -m)
        msg="${2:?-m needs a message}"
        shift
        ;;
    -h | --help)
        wf_help "$0"
        exit 0
        ;;
    -*)
        echo "wt-merge: unknown flag $1" >&2
        exit 2
        ;;
    *) branch="$1" ;;
    esac
    shift
done
[ -n "$branch" ] || {
    echo "usage: wf merge BRANCH [--into BASE] [--squash] [-m MSG]" >&2
    exit 2
}
into="${into:-$(wf_base_branch)}"
main="$(wf_main)"
g() { git -C "$main" "$@"; }

g rev-parse --verify --quiet "$branch^{commit}" >/dev/null || {
    echo "wt-merge: no such branch: $branch" >&2
    exit 2
}

wf_lock merge
trap 'wf_unlock merge' EXIT

# Never move the main checkout's HEAD: it may be served, or another session's.
on="$(g branch --show-current)"
if [ "$on" != "$into" ]; then
    other="$(g worktree list --porcelain | awk -v b="refs/heads/$into" -v m="$main" '
        /^worktree / { p = substr($0, 10) } $0 == "branch " b && p != m { print p; exit }')"
    if [ -n "$other" ]; then
        echo "wt-merge: $into is checked out in another worktree ($other); merge there, or use another --into" >&2
    else
        echo "wt-merge: $main is on ${on:-a detached HEAD}, not $into; wf merge never switches it (check out $into there yourself)" >&2
    fi
    exit 2
fi

# Only card edits may be pending in the main checkout; commit them first.
dirty="$(g status --porcelain --untracked-files=no | grep -v '^.. tasks/' || true)"
if [ -n "$dirty" ]; then
    echo "wt-merge: $main has uncommitted changes outside tasks/; commit or stash them first:" >&2
    printf '%s\n' "$dirty" | head -n 5 >&2
    exit 2
fi
if [ -n "$(g status --porcelain -- tasks)" ]; then
    if ! out="$(g add -A tasks 2>&1 && g commit -q -m "chore(tasks): update cards" -- tasks 2>&1)"; then
        g reset -q -- tasks 2>/dev/null || true
        echo "wt-merge: could not commit the pending card changes (left unstaged): $(printf '%s' "$out" | tail -1)" >&2
        exit 1
    fi
    echo "committed pending card changes"
fi

commits="$(g rev-list --count "$into..$branch")"
if [ "$commits" = 0 ]; then
    echo "nothing to merge: $branch is already in $into"
    exit 0
fi
files="$(g diff --name-only "$into...$branch" | wc -l | tr -d ' ')"
if [ -z "$msg" ] && [ "$squash" = 1 ]; then
    case "$branch" in wf/*)
        id="${branch#wf/}"
        title="$({ "$here/../bin/wf" show "$id" 2>/dev/null || true; } | sed -n 's/^title: *//p' | head -1 | sed 's/^"\(.*\)"$/\1/')"
        [ -n "$title" ] && msg="$title ($id)"
        ;;
    esac
fi
msg="${msg:-merge: $branch into $into}"

if [ "$squash" = 1 ]; then
    merge=(merge --squash --quiet "$branch")
else
    merge=(merge --no-ff --quiet -m "$msg" "$branch")
fi
if out="$(g "${merge[@]}" 2>&1)"; then
    if [ "$squash" = 0 ] || out="$(g commit -q -m "$msg" 2>&1)"; then
        echo "merged $branch ($commits commits, $files files$([ "$squash" = 0 ] || echo ", squashed"))"
        exit 0
    fi
    g reset -q --merge 2>/dev/null || g reset -q --hard HEAD
    echo "wt-merge: the squash commit failed; $main is back where it was: $(printf '%s' "$out" | tail -1)" >&2
    exit 1
fi

mapfile -t conflicted < <(g diff --name-only --diff-filter=U)
if [ "${#conflicted[@]}" -eq 0 ]; then
    g merge --abort 2>/dev/null || g reset -q --merge 2>/dev/null || true
    echo "wt-merge: merge failed without conflicts (dirty files in the way?):" >&2
    printf '%s\n' "$out" | tail -n 10 >&2
    exit 1
fi

echo "CONFLICT merging $branch into $into (${#conflicted[@]} files); merge aborted, $main unchanged:"
for f in "${conflicted[@]}"; do
    echo "--- $f"
    awk '
        /^<<<<<<< / { inside = 1; n = 0; printf "@@ line %d\n", NR }
        inside && n < 10 { print; n++ }
        /^>>>>>>> / { inside = 0 }
    ' "$main/$f" | head -n 30
done
# A squash leaves no MERGE_HEAD, so --abort fails there; reset --merge undoes both.
g merge --abort 2>/dev/null || g reset -q --merge
echo "next: in the branch's worktree, git merge $into, resolve, commit; then wf merge $branch again"
exit 3
