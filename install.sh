#!/usr/bin/env bash
# Install the workflow plugin for Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/trongio/claude-workflow/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --project    # project scope (run in the repo)
#
# Adds the marketplace (trongio/claude-workflow) and installs workflow@trongio
# at user scope by default. --project / --local install for the current repo
# only (project scope is written to .claude/settings.json and shared via git).
set -euo pipefail

scope=user
source_repo="${WF_SOURCE:-trongio/claude-workflow}"
for arg in "$@"; do
    case "$arg" in
    --project) scope=project ;;
    --local) scope=local ;;
    --user) scope=user ;;
    -h | --help)
        sed -n '2,9p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "install: unknown argument $arg" >&2
        exit 2
        ;;
    esac
done

command -v claude >/dev/null || {
    echo "install: the Claude Code CLI (claude) is not on PATH" >&2
    exit 1
}
if [ "$scope" != user ] && ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "install: --$scope needs to run inside the target git repo" >&2
    exit 1
fi

echo "adding marketplace $source_repo ($scope scope)"
claude plugin marketplace add "$source_repo" --scope "$scope" || claude plugin marketplace update trongio
echo "installing workflow@trongio ($scope scope)"
claude plugin install workflow@trongio --scope "$scope"

missing=""
for tool in bun jq git; do command -v "$tool" >/dev/null || missing="$missing $tool"; done
[ -z "$missing" ] || echo "note: install these for the board, gates and runner:$missing"

cat <<'EOF'

Installed. Next, in the repo you want to run it in:
  claude            then type  /workflow:init
Then: /workflow:task "<what to build>"  or  /workflow:next
Optional: put `wf` on your shell PATH:
  ln -s ~/.claude/plugins/cache/trongio/workflow/*/bin/wf ~/.local/bin/wf
EOF
