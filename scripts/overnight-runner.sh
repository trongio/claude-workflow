#!/usr/bin/env bash
# Unattended runner: drains the card queue through headless Claude Code.
#
# Usage: wf night [N]        queue the next N claimable cards (default 8), then run
#        wf run              run what is already queued
#
# Each queued card runs as `claude -p "/workflow:task <ID> --headless"` in its own
# git worktree (.workflow/worktrees/<ID>, branch wf/<ID>), up to PARALLEL at a
# time. The task skill merges through `wf merge`, which holds a repo-wide lock,
# so parallel cards never merge at the same moment.
#
#   .workflow/queue/<ID>.task   one card per file (`wf queue N` writes them);
#                               optional first line `# model: opus`
#   .workflow/done/  failed/    finished queue files land here
#   .workflow/logs/             one log per attempt + summary.md
#   .workflow/STOP              create to stop: running sessions are terminated
#                               within ~15s and their cards stay queued
#
# Resilience: a usage-limit error sleeps until the reset time printed in the
# message (or 30 minutes) without spending a retry; overloads back off; a
# timed-out or failed attempt resumes the same session (`--resume`).
#
# Settings (env beats .claude/workflow.json "overnight"):
#   PARALLEL (parallel, 2)  MAX_HOURS (maxHours, 24)  TIMEOUT_MIN (timeoutMinutes, 120)
#   RETRIES (retries, 2)    MODEL (model, opus)       WAIT_WHEN_EMPTY=1 idles for new cards
#   PERMISSION_FLAGS (permissionFlags, "--dangerously-skip-permissions")
# The default permission flag is what makes a run truly unattended: only queue
# cards you would approve wholesale, on a clean tree you can roll back.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
wf_need jq
wf_need claude "the Claude Code CLI"
wf_need git

main="$(wf_main)"
cd "$main" || exit 2
wf="$here/../bin/wf"
dir="$main/.workflow"
queue="$dir/queue" done_dir="$dir/done" failed_dir="$dir/failed" logs="$dir/logs" stop="$dir/STOP"
mkdir -p "$queue" "$done_dir" "$failed_dir" "$logs" "$dir/worktrees" "$dir/run"

PARALLEL="${PARALLEL:-$(wf_get .overnight.parallel 2)}"
MAX_HOURS="${MAX_HOURS:-$(wf_get .overnight.maxHours 24)}"
TIMEOUT_MIN="${TIMEOUT_MIN:-$(wf_get .overnight.timeoutMinutes 120)}"
RETRIES="${RETRIES:-$(wf_get .overnight.retries 2)}"
MODEL="${MODEL:-$(wf_get .overnight.model opus)}"
PERMISSION_FLAGS="${PERMISSION_FLAGS:-$(wf_get .overnight.permissionFlags --dangerously-skip-permissions)}"
WAIT_WHEN_EMPTY="${WAIT_WHEN_EMPTY:-0}"
POLL="${POLL:-15}"
base_branch="$(wf_base_branch)"
deadline=$(($(date +%s) + MAX_HOURS * 3600))

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
summary() { printf -- '- %s %s: %s\n' "$(date '+%F %T')" "$1" "$2" >>"$logs/summary.md"; }
new_uuid() { uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || cat /proc/sys/kernel/random/uuid; }
stopped() { [ -f "$stop" ] || [ "$(date +%s)" -ge "$deadline" ]; }

# Single instance.
if ! mkdir "$dir/.runner.lock" 2>/dev/null; then
    if kill -0 "$(cat "$dir/.runner.lock/pid" 2>/dev/null)" 2>/dev/null; then
        log "another runner is active ($dir/.runner.lock)"
        exit 1
    fi
    rm -rf "$dir/.runner.lock" && mkdir "$dir/.runner.lock"
fi
echo $$ >"$dir/.runner.lock/pid"
trap 'rm -rf "$dir/.runner.lock"' EXIT

# Sleep in chunks, waking for STOP or the deadline. Returns 1 when interrupted.
snooze() {
    local left="$1" chunk
    while [ "$left" -gt 0 ]; do
        stopped && return 1
        chunk=$((left < 30 ? left : 30))
        sleep "$chunk"
        left=$((left - chunk))
    done
    ! stopped
}

# Seconds until the usage window resets, parsed from the error text.
limit_wait() {
    local logfile="$1" epoch now hhmm
    now="$(date +%s)"
    epoch="$(grep -oE 'limit[^0-9]*\|?[0-9]{10}' "$logfile" | grep -oE '[0-9]{10}' | head -1)"
    if [ -z "$epoch" ]; then
        hhmm="$(grep -oiE 'resets?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)' "$logfile" | head -1 | grep -oiE '[0-9]{1,2}(:[0-9]{2})? ?(am|pm)')"
        if [ -n "$hhmm" ] && epoch="$(date -d "$hhmm" +%s 2>/dev/null)"; then
            [ "$epoch" -le "$now" ] && epoch=$((epoch + 86400))
        fi
    fi
    if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ] && [ "$epoch" -lt $((now + 8 * 86400)) ]; then
        echo $((epoch - now + 90))
    else
        echo 1800
    fi
}

# Run one claude invocation in a worktree under supervision.
# supervise <wt> <logfile> <outfile> <claude args...>; rc 124 timeout, 143 STOP.
supervise() {
    local wt="$1" logfile="$2" outfile="$3" pid start
    shift 3
    (cd "$wt" && exec claude "$@" >"$outfile" 2>>"$logfile" </dev/null) &
    pid=$!
    start="$(date +%s)"
    while kill -0 "$pid" 2>/dev/null; do
        sleep "$POLL"
        if [ -f "$stop" ] || [ $(($(date +%s) - start)) -ge $((TIMEOUT_MIN * 60)) ] || [ "$(date +%s)" -ge "$deadline" ]; then
            pkill -TERM -P "$pid" 2>/dev/null
            kill -TERM "$pid" 2>/dev/null
            sleep 5
            pkill -KILL -P "$pid" 2>/dev/null
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            [ -f "$stop" ] && return 143
            return 124
        fi
    done
    wait "$pid"
}

# Run one card to completion. Writes done|failed|stopped to .workflow/run/<ID>.
run_card() {
    local id="$1" file="$queue/$1.task" wt="$dir/worktrees/$1" branch="wf/$1"
    local model attempt=1 overloads=0 resume=0 sid rc stamp logfile outfile out wait_s status
    model="$(sed -nE 's/^#[[:space:]]*model:[[:space:]]*([^[:space:]]+).*/\1/p' "$file" | head -1)"
    model="${model:-$MODEL}"
    set_result() { echo "$1" >"$dir/run/$id"; }

    if [ ! -d "$wt" ]; then
        git worktree add -q -B "$branch" "$wt" "$base_branch" >>"$logs/$id-setup.log" 2>&1 || {
            summary "$id" "could not create worktree (see $logs/$id-setup.log)"
            set_result failed
            return
        }
    fi
    "$here/wt-init.sh" "$wt" >>"$logs/$id-setup.log" 2>&1
    "$wf" move "$id" in-progress --branch "$branch" >/dev/null 2>&1

    sid="$(new_uuid)"
    read -ra perm <<<"$PERMISSION_FLAGS"
    while [ "$attempt" -le "$RETRIES" ]; do
        stopped && {
            set_result stopped
            return
        }
        stamp="$(date +%Y%m%d-%H%M%S)"
        logfile="$logs/$stamp-$id-a$attempt.log"
        outfile="$logs/$stamp-$id-a$attempt.json"
        log "$id attempt $attempt/$RETRIES (model $model$([ "$resume" = 1 ] && echo ", resuming"))"
        local args=()
        if [ "$resume" = 1 ]; then
            args=(-p "You were interrupted. Your context is intact: continue the task exactly where you left off and finish every remaining step." --resume "$sid")
        else
            args=(-p "/workflow:task $id --headless" --session-id "$sid")
        fi
        supervise "$wt" "$logfile" "$outfile" "${args[@]}" --model "$model" "${perm[@]}" --output-format json
        rc=$?
        out="$(cat "$outfile" 2>/dev/null)"
        local newsid
        newsid="$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)"
        [ -n "$newsid" ] && sid="$newsid"

        if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.is_error == false' >/dev/null 2>&1; then
            status="$("$wf" show "$id" 2>/dev/null | sed -n 's/^status: *//p' | head -1)"
            summary "$id" "finished (card status: ${status:-unknown}, cost \$$(printf '%s' "$out" | jq -r '.total_cost_usd // "?"'))"
            # A session that ended with the card still in progress needs a human look.
            case "$status" in
            todo | in-progress | "") set_result failed ;;
            *) set_result "done" ;;
            esac
            # Merged and clean: drop the worktree and its branch.
            if git merge-base --is-ancestor "$branch" "$base_branch" 2>/dev/null && [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
                git worktree remove "$wt" 2>/dev/null && git branch -d "$branch" >/dev/null 2>&1
            fi
            return
        fi
        [ "$rc" = 143 ] && {
            set_result stopped
            return
        }
        if [ "$rc" = 124 ]; then
            summary "$id" "attempt $attempt timed out after ${TIMEOUT_MIN}m"
            resume=1
            attempt=$((attempt + 1))
            continue
        fi
        printf '%s\n' "$out" >>"$logfile"
        if grep -qiE 'usage limit|rate.?limit|limit reached|hit your ([a-z]+ )?limit|session limit|weekly limit' "$logfile"; then
            wait_s="$(limit_wait "$logfile")"
            log "$id: usage limit, sleeping ${wait_s}s"
            summary "$id" "usage limit, waited ${wait_s}s"
            snooze "$wait_s" || {
                set_result stopped
                return
            }
            resume=1
            continue
        fi
        if grep -qiE 'overloaded|529|internal server error|connection (error|refused|reset)|ETIMEDOUT|fetch failed' "$logfile" && [ "$overloads" -lt 5 ]; then
            overloads=$((overloads + 1))
            snooze $((120 * overloads)) || {
                set_result stopped
                return
            }
            resume=1
            continue
        fi
        if [ "$resume" = 1 ] && grep -qiE 'no conversation found|session.*(not found|invalid)' "$logfile"; then
            resume=0
            sid="$(new_uuid)"
            continue
        fi
        summary "$id" "attempt $attempt failed (rc $rc, see $logfile)"
        resume=1
        attempt=$((attempt + 1))
    done
    set_result failed
}

log "runner: parallel $PARALLEL, max ${MAX_HOURS}h, model $MODEL, queue $queue"
declare -A running=()
while true; do
    for id in "${!running[@]}"; do
        kill -0 "${running[$id]}" 2>/dev/null && continue
        wait "${running[$id]}" 2>/dev/null
        case "$(cat "$dir/run/$id" 2>/dev/null)" in
        "done") mv "$queue/$id.task" "$done_dir/" 2>/dev/null && log "$id done" ;;
        failed) mv "$queue/$id.task" "$failed_dir/" 2>/dev/null && log "$id FAILED" ;;
        *) log "$id stopped, left queued" ;;
        esac
        rm -f "$dir/run/$id"
        unset "running[$id]"
    done
    stopped && [ "${#running[@]}" -eq 0 ] && break
    if ! stopped; then
        for f in "$queue"/*.task; do
            [ -e "$f" ] || break
            [ "${#running[@]}" -ge "$PARALLEL" ] && break
            id="$(basename "$f" .task)"
            [ -n "${running[$id]:-}" ] && continue
            run_card "$id" &
            running[$id]=$!
            log "$id started (pid ${running[$id]})"
        done
    fi
    if [ "${#running[@]}" -eq 0 ] && ! compgen -G "$queue/*.task" >/dev/null; then
        [ "$WAIT_WHEN_EMPTY" = 1 ] || break
    fi
    sleep "$POLL"
done
log "runner: finished; summary in $logs/summary.md"
