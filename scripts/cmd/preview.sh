#!/usr/bin/env bash
# wf-help: start or stop a worktree's dev server on its own port (preview up|down ID)
#
# Usage: wf preview up ID|DIR      allocate the worktree's port, start preview.cmd
#        wf preview down ID|DIR    stop it (the port stays reserved until teardown)
# preview.cmd (workflow.json) expands {id} {slug} {port} and runs in the
# worktree with .workflow/env exported and PORT set; output goes to
# .workflow/preview.log, the pid to .workflow/preview.pid and the ledger.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq

action="${1:-}" target="${2:-}"
case "$action" in
up | down) [ -n "$target" ] || action=usage ;;
-h | --help)
    wf_help "$0"
    exit 0
    ;;
*) action=usage ;;
esac
if [ "$action" = usage ]; then
    echo "usage: wf preview up|down ID|DIR" >&2
    exit 2
fi
main="$(wf_main)"
if [ -d "$target" ]; then dir="$(cd "$target" && pwd)"; else dir="$main/.workflow/worktrees/$target"; fi
[ -d "$dir" ] || {
    echo "preview: no worktree $dir" >&2
    exit 2
}
pidf="$dir/.workflow/preview.pid"

if [ "$action" = down ]; then
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$pid" ] && wf_pid_in "$dir" "$pid"; then
        wf_kill_tree "$pid"
        echo "preview $(wf_wt_id "$dir"): stopped pid $pid"
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "preview $(wf_wt_id "$dir"): pid $pid is not running in $dir (reused by another process); not killed"
    else
        echo "preview $(wf_wt_id "$dir"): not running"
    fi
    rm -f "$pidf"
    # shellcheck disable=SC2016 # jq variables
    [[ "$pid" =~ ^[0-9]+$ ]] && wf_ledger_has "$dir" && wf_ledger_edit '.worktrees[$d].pids = ((.worktrees[$d].pids // []) - [$p])' --arg d "$dir" --argjson p "$pid"
    exit 0
fi

port="$(wf_port "$dir")"
if [ -f "$pidf" ] && wf_pid_in "$dir" "$(cat "$pidf")"; then
    echo "preview $(wf_wt_id "$dir"): already running, http://127.0.0.1:$port (pid $(cat "$pidf"))"
    exit 0
fi
cmd="$(wf_get '.preview.cmd')"
if [ -z "$cmd" ]; then
    echo "preview: no preview.cmd in workflow.json. Port $port is reserved for $(wf_wt_id "$dir")."
    echo "  add e.g. \"preview\": {\"cmd\": \"npm run dev -- --port {port}\"} (also {id} {slug})"
    exit 2
fi
cmd="$(wf_expand "$dir" "$cmd")"
mkdir -p "$dir/.workflow"
set -m
(
    cd "$dir" || exit 1
    set -a
    # shellcheck disable=SC1091
    [ -f .workflow/env ] && . ./.workflow/env
    set +a
    PORT="$port" exec nohup bash -c "$cmd"
) >"$dir/.workflow/preview.log" 2>&1 </dev/null &
pid=$!
set +m
echo "$pid" >"$pidf"
# shellcheck disable=SC2016 # jq variables
wf_is_task_dir "$dir" && wf_ledger_edit '.worktrees[$d].pids = (((.worktrees[$d].pids // []) + [$p]) | unique)' --arg d "$dir" --argjson p "$pid"
for _ in $(seq 1 60); do
    wf_port_busy "$port" && break
    kill -0 "$pid" 2>/dev/null || {
        echo "preview: server exited; last lines of $dir/.workflow/preview.log:" >&2
        tail -n 10 "$dir/.workflow/preview.log" >&2
        exit 1
    }
    sleep 0.5
done
wf_port_busy "$port" || echo "preview: port $port not listening after 30 s (still starting? see .workflow/preview.log)" >&2
echo "preview $(wf_wt_id "$dir"): http://127.0.0.1:$port (pid $pid, log $dir/.workflow/preview.log)"
