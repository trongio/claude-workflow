#!/usr/bin/env bash
# Unattended runner: drains the card queue through headless Claude Code.
#
# Usage: wf night [N]        queue the next N claimable cards (default 8), then run
#        wf run              run what is already queued
#
# Each queued card is claimed with `wf claim ID` (WIP limit, status and
# dependencies, like a manual claim), skipped when its tags include an
# overnight.exclude entry, and run as `claude -p "/workflow:task <ID> --headless"`
# in its own worktree (.workflow/worktrees/<ID>, branch wf/<ID>), up to
# PARALLEL at a time. The runner sleeps in `wait -n` until a card finishes.
#
#   .workflow/queue/<ID>.task   one card per file; optional `# model: opus` line
#   .workflow/done/ failed/ skipped/   finished queue files land here
#   .workflow/logs/             one log per attempt + summary.md
#   .workflow/runner/state.json pid, started, deadline, running/done/failed
#   .workflow/STOP              create to stop: sessions end within ~5 s, cards stay queued
#
# Usage limits are read only from the CLI's own error output (stderr and an
# error result's short message), never from model text. A limit sleeps until
# the parsed reset time (30 min when unparsable) without spending a retry;
# three limit waits in a row on one card count as an attempt. Finished and
# failed cards are torn down (wf_teardown: teardown commands, preview, worktree;
# an unmerged branch is kept with any uncommitted work saved as a wip commit).
#
# Settings (env beats .claude/workflow.json "overnight"):
#   PARALLEL (parallel, 2)  MAX_HOURS (maxHours, 24, decimals ok)  TIMEOUT_MIN (timeoutMinutes, 120)
#   RETRIES (retries, 2)    MODEL (model, opus)    WAIT_WHEN_EMPTY=1 idles for new cards
#   PERMISSION_FLAGS (permissionFlags, "--permission-mode auto")
#   LIMIT_WAIT_MAX caps a limit sleep in seconds (tests).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

case "${1:-}" in -h | --help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
wf_need jq
wf_need claude "the Claude Code CLI"
wf_need git

main="$(wf_main)"
cd "$main" || exit 2
wf="$here/../bin/wf"
dir="$main/.workflow"
queue="$dir/queue" done_dir="$dir/done" failed_dir="$dir/failed" skipped_dir="$dir/skipped" logs="$dir/logs" stop="$dir/STOP"
state_dir="$dir/runner"
mkdir -p "$queue" "$done_dir" "$failed_dir" "$skipped_dir" "$logs" "$dir/worktrees" "$dir/run" "$state_dir"

PARALLEL="${PARALLEL:-$(wf_get .overnight.parallel 2)}"
MAX_HOURS="${MAX_HOURS:-$(wf_get .overnight.maxHours 24)}"
TIMEOUT_MIN="${TIMEOUT_MIN:-$(wf_get .overnight.timeoutMinutes 120)}"
RETRIES="${RETRIES:-$(wf_get .overnight.retries 2)}"
MODEL="${MODEL:-$(wf_get .overnight.model opus)}"
PERMISSION_FLAGS="${PERMISSION_FLAGS:-$(wf_get .overnight.permissionFlags "--permission-mode auto")}"
WAIT_WHEN_EMPTY="${WAIT_WHEN_EMPTY:-0}"
EXCLUDE="$(wf_get '.overnight.exclude // ["migration","deploy","hardware"] | join(",")')"
base_branch="$(wf_base_branch)"
started="$(date +%s)"
deadline=$((started + $(awk -v h="$MAX_HOURS" 'BEGIN { printf "%d", h * 3600 }')))

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

# The CLI's own error text for one attempt: stderr plus, for an error result,
# its message when it is short (CLI errors are one line; model prose is not).
cli_errors() {
    local logfile="$1" outfile="$2"
    cat "$logfile" 2>/dev/null
    jq -r 'select(.is_error == true) | .result // "" | select(length < 300)' "$outfile" 2>/dev/null
}
is_limit() { grep -qiE '(usage|rate|session|weekly|5-hour|daily) limit|limit reached|hit your ([a-z-]+ )?limit|too many requests|\b429\b'; }

# Seconds until the usage window resets, parsed from CLI error text.
# Understands `...|<epoch>` and `resets 3pm`, `resets at 3:30 PM`, `resets 15:00 (Europe/Berlin)`.
# Time-of-day math uses only `date +%H %M %S` (same on GNU and BSD date).
limit_wait() {
    local text="$1" now epoch spec h m ap zone tod target w
    now="$(date +%s)"
    epoch="$(printf '%s' "$text" | grep -oE '\|[0-9]{10}' | tr -d '|' | head -1)"
    if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ] && [ "$epoch" -lt $((now + 8 * 86400)) ]; then
        w=$((epoch - now + 90))
    else
        spec="$(printf '%s' "$text" | grep -oiE 'resets?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?( \([A-Za-z_/+-]+\))?' | head -1)"
        if [[ "$spec" =~ ([0-9]{1,2})(:([0-9]{2}))?\ ?([AaPp][Mm])?(\ \(([^\)]+)\))? ]]; then
            h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[3]:-0})) ap="${BASH_REMATCH[4],,}" zone="${BASH_REMATCH[6]}"
            [ "$ap" = pm ] && [ "$h" -lt 12 ] && h=$((h + 12))
            [ "$ap" = am ] && [ "$h" = 12 ] && h=0
            tod="$(if [ -n "$zone" ]; then TZ="$zone" date '+%H %M %S'; else date '+%H %M %S'; fi |
                awk '{ print $1 * 3600 + $2 * 60 + $3 }')"
            target=$((h * 3600 + m * 60))
            w=$((target - tod))
            [ "$w" -le 0 ] && w=$((w + 86400))
            w=$((w + 90))
        else
            w=1800
        fi
    fi
    [ -n "${LIMIT_WAIT_MAX:-}" ] && [ "$w" -gt "$LIMIT_WAIT_MAX" ] && w="$LIMIT_WAIT_MAX"
    echo "$w"
}

# Run one claude invocation in a worktree, in its own process group, with a
# watchdog for STOP, the attempt timeout and the deadline.
# supervise <wt> <logfile> <outfile> <claude args...>; rc 124 timeout, 143 STOP.
supervise() {
    local wt="$1" logfile="$2" outfile="$3" pid wd rc limit marker="$3.killed"
    shift 3
    limit=$((TIMEOUT_MIN * 60))
    [ $((deadline - $(date +%s))) -lt "$limit" ] && limit=$((deadline - $(date +%s)))
    rm -f "$marker"
    set -m
    (cd "$wt" && exec claude "$@" >"$outfile" 2>>"$logfile" </dev/null) &
    pid=$!
    (
        end=$(($(date +%s) + limit))
        while [ ! -f "$stop" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 5; done
        if [ -f "$stop" ]; then echo stop >"$marker"; else echo timeout >"$marker"; fi
        wf_kill_tree "$pid"
    ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid"
    rc=$?
    kill -- "-$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    set +m
    case "$(cat "$marker" 2>/dev/null)" in
    stop) rc=143 ;;
    timeout) rc=124 ;;
    esac
    rm -f "$marker"
    return "$rc"
}

card_field() { "$wf" show "$1" 2>/dev/null | sed -n "s/^$2: *//p" | head -1; }

# Claim a queued card. Prints ok | wip | skip:<reason>.
claim_card() {
    local id="$1" tags t out
    tags="$(card_field "$id" tags | tr -d '[]"'"'" | tr ',' ' ')"
    for t in $tags; do
        [[ ",$EXCLUDE," == *",$t,"* ]] && {
            echo "skip:tag $t is in overnight.exclude"
            return
        }
    done
    # A card left in progress by a stopped run resumes in its worktree.
    if [ "$(card_field "$id" status)" = in-progress ] && [ -d "$dir/worktrees/$id" ]; then
        echo ok
        return
    fi
    if out="$("$wf" claim "$id" 2>&1)"; then
        echo ok
    elif printf '%s' "$out" | grep -q 'WIP limit'; then
        echo wip
    else
        echo "skip:$(printf '%s' "$out" | head -1)"
    fi
}

# Run one card to completion. Writes done|failed|stopped to .workflow/run/<ID>.
run_card() {
    local id="$1" file="$queue/$1.task" wt="$dir/worktrees/$1" branch="wf/$1"
    local model attempt=1 overloads=0 limits=0 resume=0 sid rc stamp logfile outfile out wait_s status errs newsid
    model="$(sed -nE 's/^#[[:space:]]*model:[[:space:]]*([^[:space:]]+).*/\1/p' "$file" | head -1)"
    model="${model:-$MODEL}"
    set_result() { echo "$1" >"$dir/run/$id"; }
    finish_card() {
        set_result "$1"
        wf_teardown "$wt" >>"$logs/$id-setup.log" 2>&1
    }

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
        newsid="$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)"
        [ -n "$newsid" ] && sid="$newsid"

        if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.is_error == false' >/dev/null 2>&1; then
            status="$(card_field "$id" status)"
            summary "$id" "finished (card status: ${status:-unknown}, cost \$$(printf '%s' "$out" | jq -r '.total_cost_usd // "?"'))"
            # A session that ended with the card still in progress needs a human look.
            case "$status" in
            todo | in-progress | "") finish_card failed ;;
            *) finish_card "done" ;;
            esac
            return
        fi
        [ "$rc" = 143 ] && {
            set_result stopped
            return
        }
        if [ "$rc" = 124 ]; then
            summary "$id" "attempt $attempt timed out after ${TIMEOUT_MIN}m"
            resume=1 limits=0
            attempt=$((attempt + 1))
            continue
        fi
        printf '%s\n' "$out" >>"$logfile.out"
        errs="$(cli_errors "$logfile" "$outfile")"
        if printf '%s' "$errs" | is_limit; then
            limits=$((limits + 1))
            wait_s="$(limit_wait "$errs")"
            log "$id: usage limit ($limits in a row), sleeping ${wait_s}s"
            summary "$id" "usage limit, waited ${wait_s}s"
            snooze "$wait_s" || {
                set_result stopped
                return
            }
            resume=1
            if [ "$limits" -ge 3 ]; then
                summary "$id" "attempt $attempt counted after 3 limit waits in a row"
                attempt=$((attempt + 1)) limits=0
            fi
            continue
        fi
        limits=0
        if printf '%s' "$errs" | grep -qiE 'overloaded|529|internal server error|connection (error|refused|reset)|ETIMEDOUT|fetch failed' && [ "$overloads" -lt 5 ]; then
            overloads=$((overloads + 1))
            snooze $((120 * overloads)) || {
                set_result stopped
                return
            }
            resume=1
            continue
        fi
        if [ "$resume" = 1 ] && printf '%s' "$errs" | grep -qiE 'no conversation found|session.*(not found|invalid)'; then
            resume=0
            sid="$(new_uuid)"
            continue
        fi
        summary "$id" "attempt $attempt failed (rc $rc, see $logfile)"
        resume=1
        attempt=$((attempt + 1))
    done
    finish_card failed
}

declare -A running=()
done_ids=() failed_ids=()
jarr() { printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'; }
write_state() {
    jq -n --argjson pid $$ --argjson started "$started" --argjson deadline "$deadline" \
        --argjson running "$(jarr "${!running[@]}")" --argjson finished "$(jarr "${done_ids[@]}")" \
        --argjson failed "$(jarr "${failed_ids[@]}")" \
        '{pid: $pid, started: ($started | todate), deadline: ($deadline | todate), running: $running,
          done: $finished, failed: $failed, active: true}' >"$state_dir/state.json"
}
reap() {
    local id
    for id in "${!running[@]}"; do
        kill -0 "${running[$id]}" 2>/dev/null && continue
        wait "${running[$id]}" 2>/dev/null
        case "$(cat "$dir/run/$id" 2>/dev/null)" in
        "done") mv "$queue/$id.task" "$done_dir/" 2>/dev/null && log "$id done" && done_ids+=("$id") ;;
        failed) mv "$queue/$id.task" "$failed_dir/" 2>/dev/null && log "$id FAILED" && failed_ids+=("$id") ;;
        *) log "$id stopped, left queued" ;;
        esac
        rm -f "$dir/run/$id"
        unset "running[$id]"
    done
}

# Start queued cards into free slots. Returns 1 when the WIP limit blocks.
fill() {
    local f id verdict
    for f in "$queue"/*.task; do
        [ -e "$f" ] || break
        [ "${#running[@]}" -ge "$PARALLEL" ] && return 0
        id="$(basename "$f" .task)"
        [ -n "${running[$id]:-}" ] && continue
        verdict="$(claim_card "$id")"
        case "$verdict" in
        ok)
            run_card "$id" &
            running[$id]=$!
            log "$id started (pid ${running[$id]})"
            ;;
        wip) return 1 ;;
        skip:*)
            mv "$f" "$skipped_dir/"
            log "$id skipped: ${verdict#skip:}"
            summary "$id" "skipped: ${verdict#skip:}"
            ;;
        esac
    done
    return 0
}

url="$(wf_get .dev.url)"
if [ -n "$url" ] && command -v curl >/dev/null && ! curl -s -o /dev/null -m 5 "$url"; then
    log "warning: dev.url $url does not answer; UI verification in these runs will fail"
fi

log "runner: parallel $PARALLEL, max ${MAX_HOURS}h, model $MODEL, queue $queue"
while true; do
    blocked=0
    stopped || fill || blocked=1
    write_state
    if [ "${#running[@]}" -eq 0 ]; then
        stopped && break
        if [ "$blocked" = 1 ]; then
            log "WIP limit reached by cards outside this runner; nothing to run"
        fi
        if [ "$WAIT_WHEN_EMPTY" = 1 ]; then
            snooze 60 || break
            continue
        fi
        break
    fi
    wait -n 2>/dev/null
    reap
done
write_state
jq '.active = false' "$state_dir/state.json" >"$state_dir/state.tmp" && mv "$state_dir/state.tmp" "$state_dir/state.json"
log "runner: finished (${#done_ids[@]} done, ${#failed_ids[@]} failed); summary in $logs/summary.md"
