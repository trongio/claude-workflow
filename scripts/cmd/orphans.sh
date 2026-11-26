#!/usr/bin/env bash
# wf-help: dev servers, test runners and browsers left running in worktrees (pid port cwd age); --kill
#
# Usage: wf orphans [--all] [--kill] [--json]
#   Lists processes whose working directory is a worktree of this repo (other
#   than the main checkout) or under .workflow/worktrees. --all includes the
#   main checkout. `stale` = its worktree was removed (the process outlived it).
#   --kill stops each listed process group.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq

all=0 kill_them=0 json=0
for a in "$@"; do
    case "$a" in
    --all) all=1 ;;
    --kill) kill_them=1 ;;
    --json) json=1 ;;
    -h | --help)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "orphans: unknown argument $a" >&2
        exit 2
        ;;
    esac
done

main="$(wf_main)"
mapfile -t wts < <(git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p' | grep -vxF "$main" || true)

# Our own ancestors (the agent session running this) never count.
declare -A mine=()
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    mine[$p]=1
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
done

re='node|vite|next|nuxt|webpack|esbuild|tsx|bun|deno|php|artisan|pest|phpunit|vitest|jest|playwright|chrom|firefox|webkit|go|air|python|uvicorn|gunicorn|pytest|cargo|ruby|rails|puma|java|gradle|frankenphp|caddy|npm|pnpm|yarn'

# pid<TAB>cwd for every process we can see.
proc_cwds() {
    if [ -d /proc/self ]; then
        local d c
        for d in /proc/[0-9]*; do
            c="$(readlink "$d/cwd" 2>/dev/null)" || continue
            printf '%s\t%s\n' "${d#/proc/}" "$c"
        done
    elif command -v lsof >/dev/null; then
        lsof -nP -d cwd -Fpn 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }'
    fi
}
ports_of() {
    if command -v ss >/dev/null; then
        ss -Hltnp 2>/dev/null | grep -E "pid=$1[,)]" | awk '{ n = split($4, a, ":"); print a[n] }' | sort -u | paste -sd, -
    elif command -v lsof >/dev/null; then
        lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*://p' | sort -u | paste -sd, -
    fi
}

rows=()
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
    if [ -z "$hit" ] && [ "$all" = 1 ]; then
        case "$cwd/" in "$main"/*) hit="$main" ;; esac
    fi
    [ -n "$hit" ] || continue
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || continue
    [[ "$comm" =~ $re ]] || continue
    [[ "$comm" =~ ^claude ]] && continue
    if [ "$hit" != "$main" ] && { [ ! -d "$hit" ] || ! printf '%s\n' "${wts[@]}" | grep -qxF "$hit"; }; then stale=true; fi
    age="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    rows+=("$pid"$'\t'"$(ports_of "$pid")"$'\t'"$cwd"$'\t'"$age"$'\t'"$comm"$'\t'"$stale")
done < <(proc_cwds)

if [ "$json" = 1 ]; then
    printf '%s\n' "${rows[@]}" | jq -Rc 'select(. != "") | split("\t") | {pid: (.[0] | tonumber), ports: .[1], cwd: .[2], age: .[3], cmd: .[4], stale: (.[5] == "true")}' | jq -sc .
    exit 0
fi
if [ "${#rows[@]}" -eq 0 ]; then
    echo "orphans: none"
    exit 0
fi
printf '%-8s %-12s %-10s %-12s %s\n' pid port age cmd cwd
for r in "${rows[@]}"; do
    IFS=$'\t' read -r pid ports cwd age comm stale <<<"$r"
    printf '%-8s %-12s %-10s %-12s %s%s\n' "$pid" "${ports:--}" "$age" "$comm" "$cwd" "$([ "$stale" = true ] && echo "  (stale)")"
    if [ "$kill_them" = 1 ]; then wf_kill_tree "$pid"; fi
done
[ "$kill_them" = 1 ] && echo "orphans: stopped ${#rows[@]}"
exit 0
