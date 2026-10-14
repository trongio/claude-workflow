#!/usr/bin/env bash
# Merge an agent branch into the main checkout with a compact report.
#
# Usage: wf merge BRANCH [--into BASE] [-m "merge: <what> into main"]
#
# Runs in the main checkout (found via git's common dir, so it works from a
# worktree too), under a repo-wide lock so parallel tasks never merge at the
# same moment. Checks out --into (default: the base branch) when needed and
# merges BRANCH with --no-ff and a conventional message.
#
# Prints `merged <branch> (<n> commits, <files> files)`, or on conflict the
# conflicted files with the first 10 lines of each hunk, leaving the merge in
# progress (resolve, `git add`, `git commit --no-edit`, or `git merge --abort`).
# Exit 1 on conflict, 2 on usage or a dirty tree.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

branch="" into="" msg=""
while [ $# -gt 0 ]; do
    case "$1" in
    --into)
        into="${2:?--into needs a branch}"
        shift
        ;;
    --into=*) into="${1#--into=}" ;;
    -m)
        msg="${2:?-m needs a message}"
        shift
        ;;
    -h | --help)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) branch="$1" ;;
    esac
    shift
done
[ -n "$branch" ] || {
    echo "usage: wf merge BRANCH [--into BASE] [-m MSG]" >&2
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

if [ "$(g branch --show-current)" != "$into" ]; then
    if [ -n "$(g status --porcelain --untracked-files=no)" ]; then
        echo "wt-merge: $main has uncommitted changes and is not on $into" >&2
        exit 2
    fi
    g checkout --quiet "$into"
fi

commits="$(g rev-list --count "$into..$branch")"
if [ "$commits" = 0 ]; then
    echo "nothing to merge: $branch is already in $into"
    exit 0
fi
files="$(g diff --name-only "$into...$branch" | wc -l | tr -d ' ')"
msg="${msg:-merge: $branch into $into}"

if g merge --no-ff --quiet -m "$msg" "$branch" >/dev/null 2>&1; then
    echo "merged $branch ($commits commits, $files files)"
    exit 0
fi

mapfile -t conflicted < <(g diff --name-only --diff-filter=U)
if [ "${#conflicted[@]}" -eq 0 ]; then
    echo "wt-merge: merge failed without conflicts (dirty files in the way?):" >&2
    g merge --no-ff -m "$msg" "$branch" 2>&1 | tail -n 10 >&2 || true
    exit 2
fi

echo "CONFLICT merging $branch into $into (${#conflicted[@]} files; merge left in progress in $main):"
for f in "${conflicted[@]}"; do
    echo "--- $f"
    awk '
        /^<<<<<<< / { inside = 1; n = 0; printf "@@ line %d\n", NR }
        inside && n < 10 { print; n++ }
        /^>>>>>>> / { inside = 0 }
    ' "$main/$f" | head -n 60
done
echo "next: resolve, git add, git commit --no-edit  (or: git -C $main merge --abort)"
exit 1
