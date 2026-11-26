#!/usr/bin/env bash
# wf-help: commit tasks/ in the main checkout under the merge lock (-m MSG)
#
# Usage: wf cards-commit [-m MSG] [--branch B]   (default message: chore(tasks): update cards)
#
# Commits only tasks/, in the main checkout (found from any worktree), under the
# same lock wf merge takes. Refuses unless the main checkout is on the base
# branch (or on B with --branch B); never switches it. Prints one line. When
# the commit fails (a hook), the card edits are unstaged again and the output
# tail is printed; exit 1.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"

usage() { wf_help "${BASH_SOURCE[0]}"; }
msg="" want=""
while [ $# -gt 0 ]; do
    case "$1" in
    -m | --message)
        [ $# -ge 2 ] || {
            echo "cards-commit: $1 needs a message" >&2
            exit 2
        }
        msg="$2"
        shift
        ;;
    --message=*) msg="${1#--message=}" ;;
    --branch)
        [ $# -ge 2 ] || {
            echo "cards-commit: --branch needs a name" >&2
            exit 2
        }
        want="$2"
        shift
        ;;
    --branch=*) want="${1#--branch=}" ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        echo "cards-commit: unknown flag $1" >&2
        usage >&2
        exit 2
        ;;
    *)
        # Positional message kept for the 0.1 form `wf cards-commit "msg"`.
        [ -z "$msg" ] || {
            echo "cards-commit: one message only" >&2
            exit 2
        }
        msg="$1"
        ;;
    esac
    shift
done
msg="${msg:-chore(tasks): update cards}"

main="$(wf_main)"
want="${want:-$(wf_base_branch)}"
on="$(git -C "$main" branch --show-current)"
if [ "$on" != "$want" ]; then
    echo "cards-commit: the main checkout $main is on ${on:-a detached HEAD}, not $want; switch it yourself (or --branch $on)" >&2
    exit 2
fi
wf_lock merge
trap 'wf_unlock merge' EXIT
git -C "$main" add -A tasks
if git -C "$main" diff --cached --quiet -- tasks; then
    echo "no card changes to commit"
else
    if ! out="$(git -C "$main" commit -q -m "$msg" -- tasks 2>&1)"; then
        # A failing hook must not leave the card edits staged for the next commit.
        git -C "$main" reset -q -- tasks 2>/dev/null || true
        echo "cards-commit: the commit failed (card edits left unstaged):" >&2
        printf '%s\n' "$out" | tail -n 10 >&2
        exit 1
    fi
    echo "committed cards: $msg"
fi
