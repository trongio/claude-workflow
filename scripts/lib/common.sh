#!/usr/bin/env bash
# Shared helpers for the workflow shell scripts. Source it; do not run it.
# Requires bash 4.4+ (empty "${arr[@]}" under set -u, wait -n), git and jq.

wf_bash_ok() { [ "$1" -gt 4 ] || { [ "$1" = 4 ] && [ "$2" -ge 4 ]; }; }
if ! wf_bash_ok "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"; then
    echo "workflow: bash 4.4+ required, this is ${BASH_VERSION:-unknown} (macOS: brew install bash)" >&2
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
    wf_lock_dir "$(git rev-parse --path-format=absolute --git-common-dir)/workflow-$1.lock" 600 "workflow: waiting for lock $1" || {
        echo "workflow: lock $1 busy for 10 minutes" >&2
        return 1
    }
}

# wf_lock_dir DIR [WAIT_SECONDS] [WAIT_MESSAGE]: take the lock directory DIR,
# waiting up to WAIT_SECONDS (default 600, 0 = try once); 1 when still busy.
# A lock whose owner is gone is taken over by renaming its pid file (atomic):
# only the waiter whose rename moved the dead owner's pid removes the lock; a
# waiter that moved a live owner's pid (the lock was retaken meanwhile) puts it
# back. An empty pid file is an owner still starting up, never a dead one.
wf_lock_dir() {
    local dir="$1" wait="${2:-600}" waited=0 old taken
    while :; do
        if mkdir "$dir" 2>/dev/null; then
            echo "$$" >"$dir/pid"
            return 0
        fi
        old="$(cat "$dir/pid" 2>/dev/null || true)"
        if [ -n "$old" ] && ! kill -0 "$old" 2>/dev/null; then
            taken="$dir/pid.taken.$$.$RANDOM"
            if mv "$dir/pid" "$taken" 2>/dev/null; then
                if [ "$(cat "$taken" 2>/dev/null)" = "$old" ]; then
                    rm -rf "$dir"
                else
                    mv "$taken" "$dir/pid" 2>/dev/null || true
                fi
            fi
            continue
        fi
        [ "$waited" -lt "$wait" ] || return 1
        [ "$waited" = 0 ] && [ -n "${3:-}" ] && echo "$3" >&2
        sleep 1
        waited=$((waited + 1))
    done
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
# default 8100: free on the host and unused in the ledger), recorded under the
# lock for a task worktree (any other directory gets a free port, unrecorded).
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
    if wf_is_task_dir "$dir"; then
        jq --arg d "$dir" --argjson p "$p" '.worktrees[$d].port = $p' "$f" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"
    fi
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

# wf_kill_tree PID: TERM the process group (or the pid), KILL after 3 s. The
# group is still killed when its leader has already exited.
wf_kill_tree() {
    local pid="$1" _
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || return 0
    for _ in 1 2 3 4 5 6; do
        kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    return 0
}

# wf_timed SECS LOG DIR CMD [PGFILE]: run CMD (bash -c) in DIR in its own
# process group, output to LOG (- = this stderr, = = this stdout and stderr as
# they are), stdin from /dev/null. A watchdog TERMs then
# KILLs the whole group after SECS; the return code is then 124. The group
# and watchdog pids go to PGFILE when given (for a caller's signal trap).
# Turns job control on to start the jobs (each its own group) and restores it.
wf_timed() {
    local secs="$1" log="$2" wdir="$3" cmd="$4" pgfile="${5:-}" pid wd rc=0 mark had_m=0
    case "$-" in *m*) had_m=1 ;; esac
    mark="$(mktemp "${TMPDIR:-/tmp}/wf-timed.XXXXXX")"
    rm -f "$mark"
    set -m
    if [ "$log" = - ]; then
        (cd "$wdir" && exec bash -c "$cmd") >&2 </dev/null &
    elif [ "$log" = = ]; then
        (cd "$wdir" && exec bash -c "$cmd") </dev/null &
    else
        (cd "$wdir" && exec bash -c "$cmd") >"$log" 2>&1 </dev/null &
    fi
    pid=$!
    [ -z "$pgfile" ] || echo "$pid" >"$pgfile"
    (
        sleep "$secs"
        touch "$mark"
        kill -TERM -- "-$pid"
        sleep 5
        kill -KILL -- "-$pid"
    ) >/dev/null 2>&1 &
    wd=$!
    [ -z "$pgfile" ] || echo "$wd" >>"$pgfile"
    # Both groups exist now; off again before the wait, so a killed job prints no "Terminated".
    [ "$had_m" = 1 ] || set +m
    wait "$pid" || rc=$?
    kill -- "-$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    if [ -f "$mark" ]; then
        rm -f "$mark"
        rc=124
    fi
    return "$rc"
}

# wf_kill_groups PGFILE...: TERM, then KILL, every process group a wf_timed
# PGFILE lists (for a signal trap: a signal to the caller alone misses them).
wf_kill_groups() {
    local f p sig
    for sig in TERM KILL; do
        for f in "$@"; do
            [ -f "$f" ] || continue
            while read -r p; do kill -"$sig" -- "-$p" 2>/dev/null || true; done <"$f"
        done
        if [ "$sig" = TERM ]; then sleep 0.5; fi
    done
}

# Resolved path (symlinks followed) of an existing dir, else the path as given.
wf_real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# Is DIR a task worktree path: <main>/.workflow/worktrees/<ID> (it may be gone)?
# Only these are ever recorded in the ledger or torn down.
wf_is_task_dir() {
    local root rest
    root="$(wf_real "$(wf_main)")/.workflow/worktrees/"
    rest="$(wf_real "${1%/}")"
    case "$rest" in "$root"?*) rest="${rest#"$root"}" ;; *) return 1 ;; esac
    [[ "$rest" != */* ]]
}

# Print a script's header help: the comment block after the shebang up to the
# first line that is not a comment (`#` or `//`), markers stripped.
wf_help() {
    awk 'NR == 1 && /^#!/ { next } !/^(#|\/\/)/ { exit } { sub(/^(#|\/\/) ?/, ""); sub(/^wf-help: /, ""); if ($0 !~ /^shellcheck /) print }' "$1"
}

# pid<TAB>cwd for every process we can see.
wf_proc_cwds() {
    if [ -d /proc/self ] && find /proc/self/cwd -maxdepth 0 -printf '' 2>/dev/null; then
        # One process for all pids (GNU find), instead of a readlink per pid.
        find /proc/[0-9]*/cwd -maxdepth 0 -printf '%p\t%l\n' 2>/dev/null | sed 's|^/proc/\([0-9]*\)/cwd|\1|' || true
    elif [ -d /proc/self ]; then
        local d c
        for d in /proc/[0-9]*; do
            c="$(readlink "$d/cwd" 2>/dev/null)" || continue
            printf '%s\t%s\n' "${d#/proc/}" "$c"
        done
    elif command -v lsof >/dev/null; then
        lsof -nP -d cwd -Fpn 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }'
    fi
}

# Processes that are never killed by a sweep: the caller and its ancestors,
# claude processes and their descendants (MCP servers, a live session's
# tools). wf_proc_snapshot takes one ps snapshot; then wf_is_mine PID (the
# caller or an ancestor) and wf_under_claude PID (a claude process or below
# one) answer from it.
wf_proc_snapshot() {
    local p pp c
    declare -gA WF_PPID=() WF_COMM=() WF_MINE=()
    while read -r p pp c; do
        WF_PPID[$p]="$pp" WF_COMM[$p]="$c"
    done < <(ps -A -o pid= -o ppid= -o comm= 2>/dev/null)
    p="${BASHPID:-$$}"
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        WF_MINE[$p]=1
        pp="${WF_PPID[$p]:-}"
        [ -n "$pp" ] || pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
        p="$pp"
    done
}
wf_is_mine() { [ -n "${WF_MINE[$1]:-}" ]; }
wf_under_claude() {
    local p="$1" n=0
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
        [[ "${WF_COMM[$p]:-}" =~ ^claude ]] && return 0
        p="${WF_PPID[$p]:-}"
        n=$((n + 1))
    done
    return 1
}

# wf_sweep DIR: kill (wf_kill_tree) every process whose cwd is inside DIR,
# except the protected ones above. Prints `stopped pid N` per process.
wf_sweep() {
    local dir real pid cwd
    dir="${1%/}"
    real="$(wf_real "$dir")"
    wf_proc_snapshot
    while IFS=$'\t' read -r pid cwd; do
        cwd="${cwd% (deleted)}"
        case "$cwd/" in "$dir"/* | "$real"/*) ;; *) continue ;; esac
        if wf_is_mine "$pid" || wf_under_claude "$pid"; then continue; fi
        wf_kill_tree "$pid" && echo "stopped pid $pid"
    done < <(wf_proc_cwds)
}

# Is DIR a registered worktree of this repository (other than the main checkout)?
wf_is_worktree() {
    local want w main
    want="$(wf_real "$1")"
    main="$(wf_real "$(wf_main)")"
    [ "$want" != "$main" ] || return 1
    while IFS= read -r w; do
        [ "$(wf_real "$w")" = "$want" ] && return 0
    done < <(git -C "$(wf_main)" worktree list --porcelain | sed -n 's/^worktree //p')
    return 1
}

# Does the resource ledger hold an entry for DIR?
wf_ledger_has() {
    local f
    f="$(wf_ledger)"
    [ -s "$f" ] && jq -e --arg d "$1" '.worktrees | has($d)' "$f" >/dev/null 2>&1
}

# Working directory of a process (empty when it cannot be read).
wf_pid_cwd() {
    if [ -d "/proc/$1" ]; then
        readlink "/proc/$1/cwd" 2>/dev/null || true
    elif command -v lsof >/dev/null; then
        lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
    fi
}

# wf_pid_in DIR PID: is the process alive with its cwd inside DIR? A recorded
# pid may have been reused by an unrelated process; never kill one by number.
wf_pid_in() {
    local c
    kill -0 "$2" 2>/dev/null || return 1
    c="$(wf_pid_cwd "$2")"
    c="${c% (deleted)}"
    [ -n "$c" ] || return 1
    case "$c/" in "$1"/* | "$(wf_real "$1")"/*) return 0 ;; esac
    return 1
}

# wf_save_work DIR: commit uncommitted work (except .workflow/) as a wip commit,
# signing off and with a fallback identity so the commit cannot fail on gpg or
# a missing user.email. A detached HEAD gets a wf/rescue-<id>-<date> branch
# first. Prints `saved ...` when it committed. Returns 1 (and says why) when the
# work could not be saved or the tree is still dirty afterwards.
wf_save_work() {
    local dir="$1" br out id
    local ex=(-- . ':(exclude).workflow')
    if ! out="$(git -C "$dir" status --porcelain "${ex[@]}" 2>&1)"; then
        echo "teardown: git status failed in $dir: $out" >&2
        return 1
    fi
    [ -n "$out" ] || return 0
    br="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
    if [ -z "$br" ]; then
        id="$(basename "$dir")"
        br="wf/rescue-$(wf_slug "$id")-$(date +%Y%m%d-%H%M%S)"
        if ! out="$(git -C "$dir" checkout -q -b "$br" 2>&1)"; then
            echo "teardown: detached HEAD in $dir and could not create $br: $out" >&2
            return 1
        fi
        echo "created branch $br for the detached HEAD"
    fi
    local env=()
    git -C "$dir" var GIT_COMMITTER_IDENT >/dev/null 2>&1 ||
        env=(GIT_AUTHOR_NAME=workflow GIT_AUTHOR_EMAIL=workflow@localhost GIT_COMMITTER_NAME=workflow GIT_COMMITTER_EMAIL=workflow@localhost)
    # An ignored .workflow/ is skipped by add -A anyway (and an exclude pathspec
    # naming it makes add fail); a tracked or unignored one is excluded.
    local add=(-A)
    git -C "$dir" check-ignore -q .workflow 2>/dev/null || add+=("${ex[@]}")
    if ! out="$(git -C "$dir" add "${add[@]}" 2>&1 &&
        env "${env[@]}" git -C "$dir" -c commit.gpgsign=false -c user.useConfigOnly=false \
            commit -q --no-verify -m "wip($(wf_wt_id "$dir")): uncommitted work saved at teardown" 2>&1)"; then
        echo "teardown: could not save uncommitted work in $dir: $(printf '%s' "$out" | tail -1)" >&2
        return 1
    fi
    if [ -n "$(git -C "$dir" status --porcelain "${ex[@]}" 2>/dev/null)" ]; then
        echo "teardown: $dir is still dirty after the wip commit" >&2
        return 1
    fi
    echo "saved uncommitted work on $br"
}

# wf_teardown DIR [--force]: tear one task worktree down. Refuses the main
# checkout, anything outside <main>/.workflow/worktrees/ and any directory that
# is not a registered worktree. Order: save uncommitted work as a wip commit
# (abort, changing nothing, when that fails), run worktree.teardown (only for a
# worktree in the resource ledger with a .workflow/env from wt-init; the
# worktree.env keys are unset first so nothing leaks from the caller's
# environment), stop recorded processes still running inside it, `git worktree
# remove` (abort when it fails; never rm -rf), delete the branch when merged
# into the base (any branch with --force; never one that just got a wip commit
# or is checked out elsewhere), drop the ledger entry. DIR may be gone (a
# ledger leftover). Prints one line per action; returns 1 on abort.
wf_teardown() {
    local dir="$1" force="${2:-}" branch="" cmd pid base main saved="" out keys
    main="$(wf_main)"
    base="$(wf_base_branch)"
    [ -n "$dir" ] || {
        echo "teardown: no directory given" >&2
        return 2
    }
    if ! wf_is_task_dir "$dir"; then
        echo "teardown: $dir is not a task worktree (<main>/.workflow/worktrees/<ID>); left in place" >&2
        return 2
    fi
    if [ -e "$dir" ]; then
        if ! wf_is_worktree "$dir"; then
            echo "teardown: $dir is not a registered worktree of $main; left in place" >&2
            return 2
        fi
        branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
        out="$(wf_save_work "$dir")" || {
            [ -n "$out" ] && printf '%s\n' "$out"
            echo "teardown: aborted, $dir left in place" >&2
            return 1
        }
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            saved=1
            branch="$(git -C "$dir" branch --show-current)"
        fi
    fi
    [ -n "$branch" ] || branch="$(wf_ledger_get "$dir" .branch)"
    if [ -d "$dir" ] && wf_ledger_has "$dir" && [ ! -f "$dir/.workflow/env" ]; then
        jq -e '(.worktree.teardown // []) | length > 0' "$(wf_config)" >/dev/null 2>&1 &&
            echo "teardown: skipped worktree.teardown ($dir/.workflow/env missing: wt-init never ran there)"
    elif [ -d "$dir" ] && wf_ledger_has "$dir"; then
        keys="$(jq -r '.worktree.env // {} | keys[] | select(test("^[A-Za-z_][A-Za-z0-9_]*$"))' "$(wf_config)" | tr '\n' ' ')"
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            cmd="$(wf_expand "$dir" "$cmd")"
            if (
                cd "$dir" || exit 1
                # shellcheck disable=SC2086 # one word per key
                [ -z "$keys" ] || unset $keys
                set -a
                # shellcheck disable=SC1091
                . ./.workflow/env
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
        if wf_pid_in "$dir" "$pid"; then
            wf_kill_tree "$pid" && echo "stopped pid $pid"
        fi
    done
    if [ -e "$dir" ]; then
        if ! out="$(git -C "$main" worktree remove --force "$dir" 2>&1)"; then
            echo "teardown: could not remove worktree $dir: $(printf '%s' "$out" | tail -1); left in place" >&2
            return 1
        fi
        echo "removed worktree $dir"
    fi
    git -C "$main" worktree prune 2>/dev/null || true
    if [ -n "$branch" ] && [ "$branch" != "$base" ] && git -C "$main" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
        if [ -n "$saved" ]; then
            echo "kept branch $branch (holds the uncommitted work just saved)"
        elif git -C "$main" worktree list --porcelain | grep -qxF "branch refs/heads/$branch"; then
            echo "kept branch $branch (checked out in another worktree)"
        elif git -C "$main" merge-base --is-ancestor "$branch" "$base" 2>/dev/null || [ "$force" = --force ]; then
            git -C "$main" branch -D "$branch" >/dev/null && echo "deleted branch $branch"
        else
            echo "kept branch $branch (not merged into $base)"
        fi
    fi
    # shellcheck disable=SC2016 # jq variables
    wf_ledger_edit 'del(.worktrees[$d])' --arg d "$dir"
}
