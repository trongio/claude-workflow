#!/usr/bin/env bash
# Shared helpers for the workflow shell scripts. Source it; do not run it.
# Requires bash 4+, git and jq.

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "workflow: bash 4+ required (macOS: brew install bash)" >&2
    exit 2
fi

# Current worktree root, and the main checkout (shared by every worktree).
wf_root() { git rev-parse --show-toplevel; }
wf_main() { dirname "$(git rev-parse --path-format=absolute --git-common-dir)"; }

# Path of the project config (lives in the main checkout so worktrees share it).
wf_config() {
    local here main
    here="$(wf_root)"
    main="$(wf_main)"
    if [ -f "$here/.claude/workflow.json" ]; then
        echo "$here/.claude/workflow.json"
    else
        echo "$main/.claude/workflow.json"
    fi
}

wf_need() {
    command -v "$1" >/dev/null || {
        echo "workflow: $1 is required${2:+ ($2)}" >&2
        exit 2
    }
}

# wf_get JQ_FILTER [DEFAULT]: one value from workflow.json, or DEFAULT.
wf_get() {
    local cfg out
    cfg="$(wf_config)"
    [ -f "$cfg" ] || {
        printf '%s\n' "${2:-}"
        return 0
    }
    out="$(jq -r "($1) // empty" "$cfg")"
    if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '%s\n' "${2:-}"; fi
}

# Base branch: config baseBranch, else origin's HEAD, else main.
wf_base_branch() {
    local b
    b="$(wf_get .baseBranch)"
    [ -n "$b" ] || b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    printf '%s\n' "${b:-main}"
}

# Portable directory lock (no flock on macOS). wf_lock NAME; wf_unlock NAME.
wf_lock() {
    local dir i
    dir="$(git rev-parse --path-format=absolute --git-common-dir)/workflow-$1.lock"
    for i in $(seq 1 600); do
        if mkdir "$dir" 2>/dev/null; then
            echo "$$" >"$dir/pid"
            return 0
        fi
        # A lock whose owner is gone is stale.
        if [ -f "$dir/pid" ] && ! kill -0 "$(cat "$dir/pid" 2>/dev/null)" 2>/dev/null; then
            rm -rf "$dir"
            continue
        fi
        [ "$i" = 1 ] && echo "workflow: waiting for lock $1" >&2
        sleep 1
    done
    echo "workflow: lock $1 busy for 10 minutes ($dir)" >&2
    return 1
}
wf_unlock() { rm -rf "$(git rev-parse --path-format=absolute --git-common-dir)/workflow-$1.lock"; }

# Glob list -> one extended regex. `*` matches across directories, `?` one
# character, a trailing `/` means everything under that directory.
wf_globs_to_regex() {
    local g re parts=()
    for g in "$@"; do
        re="$(printf '%s' "$g" | sed -e 's/[].[^$+(){}|\\]/\\&/g' -e 's/\*\*/*/g' -e 's/\*/.*/g' -e 's/?/./g')"
        case "$g" in */) re="$re.*" ;; esac
        parts+=("$re")
    done
    local IFS='|'
    printf '^(%s)$' "${parts[*]}"
}
