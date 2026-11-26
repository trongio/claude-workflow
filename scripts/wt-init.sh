#!/usr/bin/env bash
# Make a git worktree runnable. Idempotent; prints `ready: <dir>`.
#
# Usage: wf wt-init [WORKTREE_DIR]     (default: current worktree)
#
# Driven by .claude/workflow.json "worktree":
#   link:  dependency dirs (node_modules, vendor) copied from the main checkout
#          as hardlinks (cp -al), else as a reflink/plain copy. Never symlinks:
#          a symlinked node_modules resolves to a second React copy and breaks
#          dev servers. A hardlinked dir gets a .wf-hardlinked marker; when the
#          worktree's lockfile differs from main's, the package manager's
#          install runs there (it replaces files instead of editing main's).
#   cache: build caches copied copy-on-write (cp --reflink=auto) when missing.
#   copy:  files copied once when missing, e.g. [".env"]
#   env:   KEY -> template with {id} {slug} {port}, written to .workflow/env
#   setup: shell commands run in the worktree afterwards, in order.
# Also aligns core.hooksPath with the main checkout and records the worktree
# (branch, port, databases) in the resource ledger that wf prune cleans up from.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
wf_need jq

case "${1:-}" in -h | --help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

dir="$(cd "${1:-.}" && git rev-parse --show-toplevel)"
cd "$dir"
main="$(wf_main)"
cfg="$(wf_config)"

if [ "$main" = "$dir" ]; then
    echo "ready: $dir (main checkout)"
    exit 0
fi

# Copy-on-write where the filesystem allows it, plain copy otherwise.
cow_copy() {
    cp -R --reflink=auto "$1" "$2" 2>/dev/null || cp -Rc "$1" "$2" 2>/dev/null || cp -R "$1" "$2"
}

# "<lockfile> <install command>" for a dependency dir, if one applies.
install_for() {
    local parent="$1" name="$2"
    case "$name" in
    node_modules)
        if [ -f "$parent/bun.lock" ]; then
            echo "bun.lock bun install"
        elif [ -f "$parent/bun.lockb" ]; then
            echo "bun.lockb bun install"
        elif [ -f "$parent/pnpm-lock.yaml" ]; then
            echo "pnpm-lock.yaml pnpm install --frozen-lockfile"
        elif [ -f "$parent/yarn.lock" ]; then
            echo "yarn.lock yarn install --frozen-lockfile"
        elif [ -f "$parent/package-lock.json" ]; then echo "package-lock.json npm ci"; fi
        ;;
    vendor) [ -f "$parent/composer.lock" ] && echo "composer.lock composer install" ;;
    esac
    return 0
}

while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -L "$dir/$name" ]; then
        rm "$dir/$name"
        echo "wt-init: $name was a symlink, replacing it with a copy" >&2
    fi
    [ -e "$dir/$name" ] && continue
    if [ ! -e "$main/$name" ]; then
        echo "wt-init: $main/$name missing, skipped" >&2
        continue
    fi
    mkdir -p "$(dirname "$dir/$name")"
    if cp -al "$main/$name" "$dir/$name" 2>/dev/null; then
        echo "hardlinked from $main/$name: installs replace files; never edit them in place" >"$dir/$name/.wf-hardlinked"
        sub="$(dirname "$name")"
        lock="" inst=""
        read -r lock inst <<<"$(install_for "$dir/$sub" "$(basename "$name")")" || true
        if [ -n "$lock" ] && ! cmp -s "$main/$sub/$lock" "$dir/$sub/$lock"; then
            echo "wt-init: $sub/$lock differs from main, running: $inst" >&2
            (cd "$dir/$sub" && bash -c "$inst") >&2 || echo "wt-init: $inst failed" >&2
        fi
    else
        rm -rf "${dir:?}/$name"
        cow_copy "$main/$name" "$dir/$name"
        echo "wt-init: $name copied (hardlinks not possible here)" >&2
    fi
done < <(jq -r '.worktree.link // [] | .[]' "$cfg")

while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -e "$dir/$name" ] && [ -e "$main/$name" ]; then
        mkdir -p "$(dirname "$dir/$name")"
        cow_copy "$main/$name" "$dir/$name"
    fi
done < <(jq -r '(.worktree.cache // []) + (.worktree.copy // []) | .[]' "$cfg")

# Env file; database-like values also go in the ledger.
mkdir -p "$dir/.workflow"
dbs=()
: >"$dir/.workflow/env.tmp"
while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    v="$(wf_expand "$dir" "$v")"
    printf "%s='%s'\n" "$k" "${v//\'/\'\\\'\'}" >>"$dir/.workflow/env.tmp"
    if [[ "$k" =~ DB|DATABASE ]]; then dbs+=("$v"); fi
done < <(jq -r '.worktree.env // {} | to_entries[] | "\(.key)\t\(.value)"' "$cfg")
if [ -s "$dir/.workflow/env.tmp" ]; then mv "$dir/.workflow/env.tmp" "$dir/.workflow/env"; else rm -f "$dir/.workflow/env.tmp"; fi

# shellcheck disable=SC2016 # jq variables
wf_ledger_edit '.worktrees[$d] = ((.worktrees[$d] // {}) + {id: $id, branch: $b, db: $db}
    | .created //= (now | todate) | .pids //= [])' \
    --arg d "$dir" --arg id "$(wf_wt_id "$dir")" --arg b "$(git branch --show-current)" \
    --argjson db "$(printf '%s\n' "${dbs[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"

# Hooks: a worktree with another hooksPath silently skips the project hooks.
want="$(git -C "$main" config --get core.hooksPath || true)"
have="$(git config --get core.hooksPath || true)"
if [ "$want" != "$have" ]; then
    git config extensions.worktreeConfig true
    if [ -n "$want" ]; then
        git config --worktree core.hooksPath "$want"
    else
        git config --worktree --unset core.hooksPath 2>/dev/null || true
    fi
    echo "wt-init: core.hooksPath was '$have', set to main's '$want'" >&2
fi

while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    echo "wt-init: $cmd" >&2
    bash -c "$cmd" >&2
done < <(jq -r '.worktree.setup // [] | .[]' "$cfg")

echo "ready: $dir"
