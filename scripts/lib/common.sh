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

# ---- Resource ledger: everything wt-init and preview create, so cleanup is
# driven by records, not guesses. <git common dir>/workflow-resources.json:
#   {"worktrees": {"<abs dir>": {id, branch, port, db: [..], pids: [..], created}}}
wf_ledger() { echo "$(git rev-parse --path-format=absolute --git-common-dir)/workflow-resources.json"; }

# wf_ledger_edit JQ_FILTER [jq args...]: rewrite the ledger under the lock.
wf_ledger_edit() {
    local f tmpf filter="$1"
    shift
    f="$(wf_ledger)"
    wf_lock resources || return 1
    [ -s "$f" ] || echo '{"worktrees":{}}' >"$f"
    tmpf="$f.tmp.$$"
    if jq "$@" "$filter" "$f" >"$tmpf"; then mv "$tmpf" "$f"; else rm -f "$tmpf"; fi
    wf_unlock resources
}

# wf_ledger_get DIR JQ_PATH: one field of a worktree entry (empty when none).
wf_ledger_get() {
    local f
    f="$(wf_ledger)"
    [ -s "$f" ] || return 0
    jq -r --arg d "$1" ".worktrees[\$d]$2 // empty | if type == \"array\" then .[] else . end" "$f"
}

# Card id and slug of a worktree: .workflow/worktrees/<ID>, else the branch
# name without wf/. The slug is lower case with [a-z0-9_] only (db names).
wf_wt_id() {
    case "$1" in
    */.workflow/worktrees/*) basename "$1" ;;
    *) git -C "$1" branch --show-current 2>/dev/null | sed 's|^wf/||; s|/|-|g' ;;
    esac
}
wf_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'; }

# Is something listening on TCP port $1?
wf_port_busy() {
    if command -v ss >/dev/null; then
        ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
    elif command -v lsof >/dev/null; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
    fi
}

# wf_port DIR: the worktree's port (allocated on first use from WF_PORT_BASE,
# default 8100: free on the host and unused in the ledger), recorded under the lock.
wf_port() {
    local dir="$1" p f
    p="$(wf_ledger_get "$dir" .port)"
    [ -n "$p" ] && {
        echo "$p"
        return 0
    }
    f="$(wf_ledger)"
    wf_lock resources || return 1
    [ -s "$f" ] || echo '{"worktrees":{}}' >"$f"
    p="${WF_PORT_BASE:-8100}"
    while jq -e --argjson p "$p" '[.worktrees[].port] | index($p)' "$f" >/dev/null || wf_port_busy "$p"; do
        p=$((p + 1))
    done
    jq --arg d "$dir" --argjson p "$p" '.worktrees[$d].port = $p' "$f" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"
    wf_unlock resources
    echo "$p"
}

# wf_expand DIR TEXT: {id} {slug} {port} (port only allocated when used).
wf_expand() {
    local dir="$1" text="$2" id
    id="$(wf_wt_id "$dir")"
    text="${text//\{id\}/$id}"
    text="${text//\{slug\}/$(wf_slug "$id")}"
    [[ "$text" == *"{port}"* ]] && text="${text//\{port\}/$(wf_port "$dir")}"
    printf '%s' "$text"
}

# wf_kill_tree PID: TERM the process group (or the pid), KILL after 3 s.
wf_kill_tree() {
    local pid="$1" _
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    return 0
}

# wf_teardown DIR [--force]: run worktree.teardown (expanded, with the
# worktree's .workflow/env exported), stop what wf preview started, save
# uncommitted work as a wip commit, remove the worktree, delete its branch when
# merged into the base (any branch with --force), drop the ledger entry
# (releasing the port). Prints one line per action.
wf_teardown() {
    local dir="$1" force="${2:-}" branch cmd pid base main
    main="$(wf_main)"
    base="$(wf_base_branch)"
    branch="$(wf_ledger_get "$dir" .branch)"
    [ -n "$branch" ] || branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
    if [ -d "$dir" ]; then
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            cmd="$(wf_expand "$dir" "$cmd")"
            if (
                cd "$dir" || exit 1
                set -a
                # shellcheck disable=SC1091
                [ -f .workflow/env ] && . ./.workflow/env
                set +a
                bash -c "$cmd"
            ) >/dev/null 2>&1; then
                echo "teardown: $cmd"
            else
                echo "teardown: FAILED $cmd" >&2
            fi
        done < <(jq -r '.worktree.teardown // [] | .[]' "$(wf_config)")
    fi
    for pid in $(wf_ledger_get "$dir" .pids) $(cat "$dir/.workflow/preview.pid" 2>/dev/null); do
        kill -0 "$pid" 2>/dev/null && wf_kill_tree "$pid" && echo "stopped pid $pid"
    done
    if [ -d "$dir" ] && [ "$dir" != "$main" ]; then
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && [ -n "$branch" ]; then
            git -C "$dir" add -A >/dev/null 2>&1 &&
                git -C "$dir" commit -q --no-verify -m "wip($(wf_wt_id "$dir")): uncommitted work saved at teardown" >/dev/null 2>&1 &&
                echo "saved uncommitted work on $branch"
        fi
        git -C "$main" worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir"
        echo "removed worktree $dir"
    fi
    git -C "$main" worktree prune 2>/dev/null || true
    if [ -n "$branch" ] && [ "$branch" != "$base" ] && git -C "$main" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
        if git -C "$main" merge-base --is-ancestor "$branch" "$base" 2>/dev/null || [ "$force" = --force ]; then
            git -C "$main" branch -D "$branch" >/dev/null && echo "deleted branch $branch"
        else
            echo "kept branch $branch (not merged into $base)"
        fi
    fi
    # shellcheck disable=SC2016 # jq variables
    wf_ledger_edit 'del(.worktrees[$d])' --arg d "$dir"
}
