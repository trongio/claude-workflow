#!/usr/bin/env bash
# Make a git worktree runnable. Idempotent; prints `ready: <dir>`.
#
# Usage: wf wt-init [WORKTREE_DIR]     (default: current worktree)
#
# Driven by .claude/workflow.json "worktree":
#   link:  dirs copied from the main checkout as hardlinks (cp -al: no extra
#          disk, works with tools that resolve real paths); symlink fallback
#          when hardlinks are not possible. e.g. ["node_modules", "vendor"]
#   copy:  files copied once when missing, e.g. [".env"]
#   setup: shell commands run in the worktree after linking, in order,
#          e.g. ["bun install --frozen-lockfile"]
# Never edit files inside a hardlinked dir in place: that edits the main
# checkout's copy too.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
wf_need jq

dir="$(cd "${1:-.}" && git rev-parse --show-toplevel)"
cd "$dir"
main="$(wf_main)"

if [ "$main" = "$dir" ]; then
    echo "ready: $dir (main checkout)"
    exit 0
fi

while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -e "$dir/$name" ] && continue
    [ -L "$dir/$name" ] && rm "$dir/$name" # dangling symlink
    if [ ! -e "$main/$name" ]; then
        echo "wt-init: $main/$name missing, skipped" >&2
        continue
    fi
    mkdir -p "$(dirname "$dir/$name")"
    if ! cp -al "$main/$name" "$dir/$name" 2>/dev/null; then
        rm -rf "${dir:?}/$name"
        ln -s "$main/$name" "$dir/$name"
        echo "wt-init: $name symlinked (hardlinks not possible here)" >&2
    fi
done < <(jq -r '.worktree.link // [] | .[]' "$(wf_config)")

while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -e "$dir/$name" ] && [ -e "$main/$name" ]; then
        mkdir -p "$(dirname "$dir/$name")"
        cp -R "$main/$name" "$dir/$name"
    fi
done < <(jq -r '.worktree.copy // [] | .[]' "$(wf_config)")

while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    echo "wt-init: $cmd" >&2
    bash -c "$cmd" >&2
done < <(jq -r '.worktree.setup // [] | .[]' "$(wf_config)")

echo "ready: $dir"
