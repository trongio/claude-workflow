#!/usr/bin/env bash
# Make a git worktree runnable. Idempotent; prints `ready: <dir>`.
#
# Usage: wf wt-init [WORKTREE_DIR]     (default: current worktree)
#
# Driven by .claude/workflow.json "worktree":
#   link:  dependency dirs (node_modules, vendor) copied from the main checkout,
#          never symlinked (a symlinked node_modules resolves to a second React
#          copy and breaks dev servers). Method, printed per dir: a reflink copy
#          (cp -a --reflink, copy-on-write, nothing shared) when a probe shows
#          the filesystem supports it; else hardlinks (cp -al) with the files
#          tools rewrite in place (vendor/composer, autoload.php, bin;
#          node_modules/.cache, .vite, .package-lock.json)
#          made real copies, and a .wf-hardlinked marker; else a plain copy.
#          When the worktree's lockfile differs from main's, the package
#          manager's install runs there.
#   cache: build caches copied copy-on-write (cp --reflink=auto) when missing.
#   copy:  files copied once when missing, e.g. [".env"]
#   env:   KEY -> template with {id} {slug} {port}, written to .workflow/env
#   setup: shell commands run in the worktree afterwards, in order; the first
#          failure stops wt-init with its exit code.
#   setupTimeout: seconds per setup or install command (default 900); its
#          process group is then killed and wt-init exits 124.
# Also aligns core.hooksPath with the main checkout and, for a task worktree
# (.workflow/worktrees/<ID>), records it (branch, port, databases) in the
# resource ledger that wf prune cleans up from. Other worktrees are never recorded.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
wf_need jq

case "${1:-}" in -h | --help)
    wf_help "$0"
    exit 0
    ;;
esac

dir="$(cd "${1:-.}" && git rev-parse --show-toplevel)"
cd "$dir"
main="$(wf_main)"
cfg="$(wf_config)"
setup_tmo="$(wf_get .worktree.setupTimeout 900)"

if [ "$main" = "$dir" ]; then
    echo "ready: $dir (main checkout)"
    exit 0
fi

# Install and setup commands run in their own process group (wf_timed), so a
# Ctrl-C or kill of wt-init alone would leave them running: the trap stops them.
pgfile="$(mktemp "${TMPDIR:-/tmp}/wt-init.XXXXXX")"
trap 'rm -f "$pgfile"' EXIT
# shellcheck disable=SC2329 # invoked by the traps below
on_signal() {
    trap - INT TERM HUP
    wf_kill_groups "$pgfile"
    rm -f "$pgfile"
    exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# Copy-on-write where the filesystem allows it, plain copy otherwise.
cow_copy() {
    cp -R --reflink=auto "$1" "$2" 2>/dev/null || cp -Rc "$1" "$2" 2>/dev/null || cp -R "$1" "$2"
}

# Reflink support, probed once: a clone from the git dir into the worktree.
reflink=""
probe_reflink() {
    local src dst
    src="$(git rev-parse --path-format=absolute --git-common-dir)/wf-reflink-probe.$$"
    dst="$dir/.wf-reflink-probe.$$"
    echo probe >"$src"
    if cp --reflink=always "$src" "$dst" 2>/dev/null; then
        reflink=gnu
    elif [ "$(uname)" = Darwin ] && cp -c "$src" "$dst" 2>/dev/null; then
        reflink=clone
    else
        reflink=none
    fi
    rm -f "$src" "$dst"
}

# Files package managers and dev tools write IN PLACE (a hardlink would carry
# the write into main's copy). Replaced by real copies after a hardlink copy.
in_place_paths() {
    case "$(basename "$1")" in
    vendor) printf '%s\n' composer autoload.php bin ;;
    node_modules) printf '%s\n' .cache .vite .vite-temp .package-lock.json .modules.yaml ;;
    esac
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
    case "$name" in /* | ../* | */../* | *..)
        echo "wt-init: link entry $name leaves the worktree, skipped" >&2
        continue
        ;;
    esac
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
    [ -n "$reflink" ] || probe_reflink
    if [ "$reflink" = gnu ] && cp -a --reflink=always "$main/$name" "$dir/$name" 2>/dev/null; then
        echo "wt-init: $name: reflink copy (copy-on-write, nothing shared with main)" >&2
    elif [ "$reflink" = clone ] && cp -Rc "$main/$name" "$dir/$name" 2>/dev/null; then
        echo "wt-init: $name: clone copy (copy-on-write, nothing shared with main)" >&2
    elif rm -rf "${dir:?}/$name" && cp -al "$main/$name" "$dir/$name" 2>/dev/null; then
        echo "hardlinked from $main/$name: installs replace files; never edit them in place" >"$dir/$name/.wf-hardlinked"
        copied=()
        while IFS= read -r p; do
            [ -e "$main/$name/$p" ] || continue
            rm -rf "${dir:?}/$name/$p"
            cp -R "$main/$name/$p" "$dir/$name/$p"
            copied+=("$p")
        done < <(in_place_paths "$name")
        echo "wt-init: $name: hardlinked${copied[0]:+ (real copies: ${copied[*]})}" >&2
    else
        rm -rf "${dir:?}/$name"
        cow_copy "$main/$name" "$dir/$name"
        echo "wt-init: $name: plain copy (no reflinks or hardlinks here)" >&2
    fi
    sub="$(dirname "$name")"
    lock="" inst=""
    read -r lock inst <<<"$(install_for "$dir/$sub" "$(basename "$name")")" || true
    if [ -n "$lock" ] && ! cmp -s "$main/$sub/$lock" "$dir/$sub/$lock"; then
        echo "wt-init: $sub/$lock differs from main, running: $inst" >&2
        rc=0
        wf_timed "$setup_tmo" - "$dir/$sub" "$inst" "$pgfile" || rc=$?
        case "$rc" in
        0) ;;
        124) echo "wt-init: $inst killed after ${setup_tmo}s (worktree.setupTimeout)" >&2 ;;
        *) echo "wt-init: $inst failed" >&2 ;;
        esac
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
# Written even when empty: teardown runs worktree.teardown only where it exists.
mv "$dir/.workflow/env.tmp" "$dir/.workflow/env"

# Only task worktrees (.workflow/worktrees/<ID>) enter the ledger that wf prune
# and teardown act on; any other worktree stays the user's.
# shellcheck disable=SC2016 # jq variables
wf_is_task_dir "$dir" && wf_ledger_edit '.worktrees[$d] = ((.worktrees[$d] // {}) + {id: $id, branch: $b, db: $db}
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
    rc=0
    wf_timed "$setup_tmo" - "$dir" "$cmd" "$pgfile" || rc=$?
    if [ "$rc" = 124 ]; then
        echo "wt-init: $cmd killed after ${setup_tmo}s (worktree.setupTimeout)" >&2
        exit 124
    elif [ "$rc" != 0 ]; then
        echo "wt-init: $cmd failed (exit $rc)" >&2
        exit "$rc"
    fi
done < <(jq -r '.worktree.setup // [] | .[]' "$cfg")

echo "ready: $dir"
