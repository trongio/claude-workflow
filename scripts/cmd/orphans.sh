#!/usr/bin/env bash
# wf-help: dev servers, test runners and browsers left running in worktrees (pid port cwd age); --kill
#
# Usage: wf orphans [--with-main] [--json] [--kill ID|DIR | --kill --all]
#   Lists processes whose working directory is a worktree of this repo (other
#   than the main checkout) or under .workflow/worktrees. --with-main lists the
#   main checkout's too (never killed). `stale` = its worktree was removed.
#   --kill ID|DIR stops only the processes inside that worktree; --kill --all
#   stops every listed one. A bare --kill refuses: parallel sessions' servers
#   and runners would die with it. Never killed: children of a live claude
#   process (MCP servers, a running session's tools; listed as `under claude`)
#   and the caller's own ancestors. --json --kill kills, then prints the JSON.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq

with_main=0 kill_them=0 kill_all=0 json=0 target=""
while [ $# -gt 0 ]; do
    case "$1" in
    --with-main) with_main=1 ;;
    --all) kill_all=1 ;;
    --kill)
        kill_them=1
        if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
            target="$2"
            shift
        fi
        ;;
    --json) json=1 ;;
    -h | --help)
        wf_help "$0"
        exit 0
        ;;
    *)
        echo "orphans: unknown argument $1" >&2
        exit 2
        ;;
    esac
    shift
done
if [ "$kill_them" = 1 ] && [ -z "$target" ] && [ "$kill_all" = 0 ]; then
    echo "orphans: name the card or worktree (wf orphans --kill ID|DIR); --kill --all kills every listed one" >&2
    exit 2
fi
[ "$kill_all" = 0 ] || [ "$kill_them" = 1 ] || {
    echo "orphans: --all goes with --kill (listing the main checkout too is --with-main)" >&2
    exit 2
}

main="$(wf_main)"
want=""
if [ -n "$target" ]; then
    if [ -d "$target" ]; then
        want="$(cd "$target" && pwd)"
    elif [[ "$target" == /* ]]; then
        want="${target%/}" # a removed worktree
    else
        want="$main/.workflow/worktrees/$target"
    fi
    if [ "$(wf_real "$want")" = "$(wf_real "$main")" ]; then
        echo "orphans: $target is the main checkout; its processes are never killed" >&2
        exit 2
    fi
fi
mapfile -t wts < <(git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p' | grep -vxF "$main" || true)

# Our own ancestors (the agent session running this) never count.
declare -A mine=()
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    mine[$p]=1
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
done

re='node|vite|next|nuxt|webpack|esbuild|tsx|bun|deno|php|artisan|pest|phpunit|vitest|jest|playwright|chrom|firefox|webkit|go|air|python|uvicorn|gunicorn|pytest|cargo|ruby|rails|puma|java|gradle|frankenphp|caddy|npm|pnpm|yarn'

ports_of() {
    if command -v ss >/dev/null; then
        ss -Hltnp 2>/dev/null | { grep -E "pid=$1[,)]" || true; } | awk '{ n = split($4, a, ":"); print a[n] }' | sort -u | paste -sd, -
    elif command -v lsof >/dev/null; then
        { lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null || true; } | sed -n 's/^n.*://p' | sort -u | paste -sd, -
    fi
    return 0
}

rows=() us=$'\x1f'
while IFS=$'\t' read -r pid cwd; do
    [ -n "${mine[$pid]:-}" ] && continue
    cwd="${cwd% (deleted)}"
    hit="" stale=false
    for w in "${wts[@]}"; do
        case "$cwd/" in "$w"/*) hit="$w" ;; esac
    done
    case "$cwd/" in "$main/.workflow/worktrees/"*)
        [ -n "$hit" ] || hit="$main/.workflow/worktrees/$(printf '%s' "${cwd#"$main/.workflow/worktrees/"}" | cut -d/ -f1)"
        ;;
    esac
    if [ -z "$hit" ] && [ "$with_main" = 1 ]; then
        case "$cwd/" in "$main"/*) hit="$main" ;; esac
    fi
    [ -n "$hit" ] || continue
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || continue
    [[ "$comm" =~ $re ]] || continue
    [[ "$comm" =~ ^claude ]] && continue
    if [ "$hit" != "$main" ] && { [ ! -d "$hit" ] || ! printf '%s\n' "${wts[@]}" | grep -qxF "$hit"; }; then stale=true; fi
    if [ -n "$want" ] && [ "$hit" != "$want" ] && [ "$(wf_real "$hit")" != "$(wf_real "$want")" ]; then continue; fi
    age="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    # Unit separator, not tab: an empty port field must not collapse under read.
    rows+=("$pid$us$(ports_of "$pid")$us$cwd$us$age$us$comm$us$stale$us$hit")
done < <(
    # Only lines that can match: cwd under main (worktrees dir) or a worktree.
    pre=(-e "$main/")
    for w in "${wts[@]}"; do pre+=(-e "$w/" -e "$w (deleted)"); done
    wf_proc_cwds | sed 's|$|/|' | { grep -F "${pre[@]}" || true; } | sed 's|/$||'
)

# Processes with a claude ancestor (MCP servers, a live session's tools): one ps snapshot.
declare -A ppid_of=() comm_of=()
while read -r p pp c; do
    ppid_of[$p]="$pp" comm_of[$p]="$c"
done < <(ps -A -o pid= -o ppid= -o comm= 2>/dev/null)
under_claude() {
    local p="${ppid_of[$1]:-}" n=0
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
        [[ "${comm_of[$p]:-}" =~ ^claude ]] && return 0
        p="${ppid_of[$p]:-}"
        n=$((n + 1))
    done
    return 1
}

killed=0 kept=0
for i in "${!rows[@]}"; do
    IFS="$us" read -r pid ports cwd age comm stale hit <<<"${rows[$i]}"
    owned=false
    under_claude "$pid" && owned=true
    rows[i]="${rows[$i]}$us$owned"
    [ "$kill_them" = 1 ] && [ "$hit" != "$main" ] || continue
    if [ "$owned" = true ]; then
        kept=$((kept + 1))
    else
        wf_kill_tree "$pid"
        killed=$((killed + 1))
    fi
done
report="orphans: stopped $killed$([ "$kept" = 0 ] || echo ", kept $kept under a claude process")"

if [ "$json" = 1 ]; then
    printf '%s\n' "${rows[@]}" | jq -Rc 'select(. != "") | split("\u001f") | {pid: (.[0] | tonumber), ports: .[1], cwd: .[2], age: .[3], cmd: .[4], stale: (.[5] == "true"), worktree: .[6], underClaude: (.[7] == "true")}' | jq -sc .
    [ "$kill_them" = 0 ] || echo "$report" >&2
    exit 0
fi
if [ "${#rows[@]}" -eq 0 ]; then
    echo "orphans: none${want:+ in $want}"
    exit 0
fi
printf '%-8s %-12s %-10s %-12s %s\n' pid port age cmd cwd
for r in "${rows[@]}"; do
    IFS="$us" read -r pid ports cwd age comm stale hit owned <<<"$r"
    printf '%-8s %-12s %-10s %-12s %s%s%s\n' "$pid" "${ports:--}" "$age" "$comm" "$cwd" "$([ "$stale" = true ] && echo "  (stale)")" "$([ "$owned" = true ] && echo "  (under claude)")"
done
[ "$kill_them" = 0 ] || echo "$report"
exit 0
