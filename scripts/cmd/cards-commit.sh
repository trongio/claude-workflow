#!/usr/bin/env bash
# wf-help: commit tasks/ in the main checkout under the merge lock (-m MSG)
#
# Usage: wf cards-commit [-m MSG]     (default message: chore(tasks): update cards)
#
# Commits only tasks/, in the main checkout (found from any worktree), under the
# same lock wf merge takes. Prints one line. Unknown flags are refused.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"

usage() { sed -n '4,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
msg=""
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
wf_lock merge
trap 'wf_unlock merge' EXIT
git -C "$main" add -A tasks
if git -C "$main" diff --cached --quiet -- tasks; then
    echo "no card changes to commit"
else
    git -C "$main" commit -q -m "$msg" -- tasks
    echo "committed cards: $msg"
fi
