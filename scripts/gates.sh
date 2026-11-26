#!/usr/bin/env bash
# Run the project's quality gates in parallel and print a compact table.
#
# Usage: gates.sh [--all] [--only a,b] [--base REF] [--fix] [--no-cache]
#                 [--timeout SEC] [--release] [--last] [--json] [--list]
#
#   (default)    gates whose `when` globs match a changed file (vs the base,
#                plus uncommitted and untracked files); no `when` = always.
#   --all        ignore `when`, run every gate.
#   --only a,b   just these gates (still subject to `when` unless --all).
#   --base REF   diff base. Default: merge base with the base branch, or the
#                first parent when HEAD is a merge commit on the base branch.
#   --fix        run each selected gate's `fix` command first (formatters).
#   --no-cache   do not skip gates whose inputs match a previous PASS.
#   --timeout S  override every gate's timeout (default per gate 900 s).
#   --release    the full pre-merge gate: release.cmd if set, else every gate
#                with release != false, uncached. Logged to release.log.
#                Gates with inner: false (full suites) run only here or with --all.
#   --last       reprint the previous table if the tree is unchanged.
#   --json       print .workflow/gates-last.json (one line) instead of the table.
#   --list       print the gates and whether each would run, then exit.
#
# Per gate: cwd, timeout (TIMEOUT kills the process group, red), pending
# (PENDING, not proven), heavy (capped by gatesJobs, default CPUs/2; one at a
# time below 2 GB free RAM), rerun.when (one rerun when the output matches,
# reported as PASS (rerun)). Exit 127 is NOT INSTALLED (red), never a skip.
# Cache: content key = command + cwd + `when` paths (whole tree without
# `when`) + lockfiles, from git object ids; gatesCacheKeys entries per gate in
# <git common dir>/workflow-gates-cache. Logs: .workflow/gates/<gate>.log.
# Exit 1 when a gate is red (or, with --release, not proven), 2 on bad usage
# (an unknown --only name). Killed (INT/TERM/HUP): every gate's process group
# is stopped first, then exit 130/143/129.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
wf_need jq "for reading .claude/workflow.json"

all=0 fix=0 use_cache=1 list=0 release=0 last=0 json=0 only="" base="" tmo=""
while [ $# -gt 0 ]; do
    case "$1" in
    --all) all=1 ;;
    --fix) fix=1 ;;
    --no-cache) use_cache=0 ;;
    --list) list=1 ;;
    --release) release=1 ;;
    --last) last=1 ;;
    --json) json=1 ;;
    --only | --base | --timeout)
        [ $# -ge 2 ] || {
            echo "gates: $1 needs a value" >&2
            exit 2
        }
        case "$1" in --only) only="$2" ;; --base) base="$2" ;; --timeout) tmo="$2" ;; esac
        shift
        ;;
    --only=*) only="${1#--only=}" ;;
    --base=*) base="${1#--base=}" ;;
    --timeout=*) tmo="${1#--timeout=}" ;;
    -h | --help)
        sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "gates: unknown argument: $1" >&2
        exit 2
        ;;
    esac
    shift
done
[ -z "$tmo" ] || [[ "$tmo" =~ ^[0-9]+$ ]] || {
    echo "gates: --timeout needs seconds" >&2
    exit 2
}

root="$(wf_root)"
if [ "$release" = 1 ] && [ "$(pwd -P)" != "$(cd "$root" && pwd -P)" ]; then
    echo "gates: --release must run from the worktree root ($root), not $(pwd)" >&2
    exit 2
fi
cd "$root"
cfg="$(wf_config)"
if [ ! -f "$cfg" ] || [ "$(jq '.gates // [] | length' "$cfg")" = 0 ]; then
    echo "gates: no gates in $cfg (run /workflow:init or add a \"gates\" list)" >&2
    exit 2
fi
state="$root/.workflow"
logdir="$state/gates"
mkdir -p "$logdir"
last_json="$state/gates-last.json"

# Globals in one jq call.
{
    read -r g_cache
    read -r tail_lines
    read -r jobs
    read -r keep_keys
    read -r base_branch
    read -r release_log
    IFS= read -r release_cmd
} < <(jq -r '(.gatesCache // true), (.gatesTailLines // 30), (.gatesJobs // 0), (.gatesCacheKeys // 8),
    (.baseBranch // ""), (.release.log // ".workflow/release.log"), ((.release.cmd // "") | gsub("\n"; " "))' "$cfg")
[ "$g_cache" = false ] && use_cache=0
[ "$release" = 1 ] && use_cache=0 && all=1
[ -n "$base_branch" ] || base_branch="$(wf_base_branch)"

# A fresh worktree missing its dependency dirs gets wt-init first.
if [ "$root" != "$(wf_main)" ]; then
    while IFS= read -r p; do
        if [ -n "$p" ] && [ ! -e "$p" ]; then
            "$here/wt-init.sh" "$root" >/dev/null
            break
        fi
    done < <(jq -r '.worktree.link // [] | .[]' "$cfg")
fi

head_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
if [ -z "$base" ]; then
    # On the base branch after a merge, merge-base == HEAD would select nothing:
    # diff against the first parent instead.
    if git rev-parse -q --verify HEAD^2 >/dev/null 2>&1 &&
        [ "$head_sha" = "$(git rev-parse -q --verify "$base_branch" 2>/dev/null)" ]; then
        base="$(git rev-parse HEAD^1)"
    else
        base="$(git merge-base HEAD "$base_branch" 2>/dev/null || echo "$head_sha")"
    fi
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gates.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pids=()
declare -A heavy_pid=()
# Killed: stop the runners, then every recorded gate/watchdog process group
# (each gate runs in its own group, so a signal to this script alone misses them).
# shellcheck disable=SC2329 # invoked by the traps below
on_signal() {
    local f p sig
    trap - INT TERM HUP
    for p in "${pids[@]}" "${!heavy_pid[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    for sig in TERM KILL; do
        for f in "$tmp"/pg.*; do
            [ -f "$f" ] || continue
            while read -r p; do kill -"$sig" -- "-$p" 2>/dev/null || true; done <"$f"
        done
        if [ "$sig" = TERM ]; then sleep 0.5; fi
    done
    rm -rf "$tmp"
    exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# The working tree as `oid<TAB>path` from the index plus dirty files only
# (one ls-files, one status, one hash-object): no file is read unless it is
# changed. .workflow/ (gate logs, runner state) never counts.
GIT_OPTIONAL_LOCKS=0 git -c core.quotepath=off status --porcelain=v1 -z --untracked-files=all --no-renames 2>/dev/null |
    tr '\0' '\n' | grep -v '^.. \.workflow/' >"$tmp/status" || true
cut -c4- "$tmp/status" >"$tmp/dirty"
{
    [ -n "$base" ] && git -c core.quotepath=off diff --name-only "$base" -- 2>/dev/null
    grep '^?? ' "$tmp/status" | cut -c4-
} | grep -v '^\.workflow/' | sort -u >"$tmp/changed" || true
export WF_BASE="$base" WF_CHANGED="$tmp/changed"

build_listing() {
    [ -f "$tmp/tree" ] && return 0
    : >"$tmp/dirty-oids"
    : >"$tmp/dirty-exist"
    if [ -s "$tmp/dirty" ]; then
        while IFS= read -r p; do
            if [ -f "$p" ]; then printf '%s\n' "$p" >>"$tmp/dirty-exist"; else printf -- '-\t%s\n' "$p" >>"$tmp/dirty-oids"; fi
        done <"$tmp/dirty"
        if [ -s "$tmp/dirty-exist" ]; then
            # shellcheck disable=SC2094 # reads dirty-exist, appends to dirty-oids
            git hash-object --stdin-paths <"$tmp/dirty-exist" | paste - "$tmp/dirty-exist" >>"$tmp/dirty-oids"
        fi
    fi
    git -c core.quotepath=off ls-files -s 2>/dev/null |
        awk -F'\t' 'NR == FNR { d[$2] = $1; next }
            { split($1, m, " "); p = $2; if (p in d) { if (d[p] != "-") print d[p] "\t" p; seen[p] = 1 } else print m[2] "\t" p }
            END { for (p in d) if (!(p in seen) && d[p] != "-") print d[p] "\t" p }' "$tmp/dirty-oids" - |
        grep -v $'\t\\.workflow/' | LC_ALL=C sort -t$'\t' -k2 -u >"$tmp/tree" || true
}
tree_hash() { git hash-object --stdin <"$tmp/tree"; }

# --last: reprint when nothing changed since the previous run.
if [ "$last" = 1 ] && [ -f "$state/gates-last.txt" ] && [ -f "$last_json" ]; then
    build_listing
    if [ "$(tree_hash)@$head_sha" = "$(jq -r '"\(.tree)@\(.sha)"' "$last_json")" ]; then
        if [ "$json" = 1 ]; then jq -c . "$last_json"; else cat "$state/gates-last.txt"; fi
        exit "$(jq -r '.exit // 0' "$last_json")"
    fi
    echo "gates: tree changed since the last run, running" >&2
fi

started_at="$(date +%s)"
log_release() { if [ "$release" = 1 ]; then printf '%s\n' "$*" >>"$root/$release_log"; fi; }
if [ "$release" = 1 ]; then
    mkdir -p "$(dirname "$root/$release_log")"
    log_release "=== release $(date '+%F %T') sha $head_sha"
fi

# A project release command replaces the gate list.
if [ "$release" = 1 ] && [ -n "$release_cmd" ]; then
    log_release "cmd: $release_cmd"
    set +e
    set -m
    bash -o pipefail -c "$release_cmd" >"$logdir/release.log" 2>&1 </dev/null &
    echo "$!" >"$tmp/pg.release"
    wait "$!"
    rc=$?
    set +m
    set -e
    secs=$(($(date +%s) - started_at))
    cat "$logdir/release.log" >>"$root/$release_log"
    log_release "exit $rc after ${secs}s sha $head_sha"
    status=PASS
    [ "$rc" = 0 ] || status=FAIL
    build_listing
    jq -n --arg sha "$head_sha" --arg tree "$(tree_hash)" --arg base "$base" --arg st "$status" \
        --argjson s "$secs" --argjson rc "$rc" \
        '{sha: $sha, tree: $tree, base: $base, release: true, exit: (if $rc == 0 then 0 else 1 end),
          results: [{name: "release", status: $st, seconds: $s, cached: false, rerun: 0}]}' >"$last_json"
    printf 'release | %s | %ss | exit %s | log %s\n' "$status" "$secs" "$rc" "$release_log" >"$state/gates-last.txt"
    if [ "$json" = 1 ]; then
        jq -c . "$last_json"
    else
        cat "$state/gates-last.txt"
        [ "$rc" = 0 ] || tail -n "$tail_lines" "$logdir/release.log"
    fi
    [ "$rc" = 0 ]
    exit
fi

# Gates: one NUL-separated record per gate.
names=() cmds=() whens=() fixes=() caches=() cwds=() tmos=() pendings=() releases=() rwhens=() rmaxs=() heavies=() inners=()
while IFS= read -r -d '' name && IFS= read -r -d '' cmd && IFS= read -r -d '' when &&
    IFS= read -r -d '' fixcmd && IFS= read -r -d '' cache && IFS= read -r -d '' cwd &&
    IFS= read -r -d '' gt && IFS= read -r -d '' pend && IFS= read -r -d '' rel &&
    IFS= read -r -d '' rw && IFS= read -r -d '' rmax && IFS= read -r -d '' hv && IFS= read -r -d '' inr; do
    names+=("$name") cmds+=("$cmd") whens+=("$when") fixes+=("$fixcmd") caches+=("$cache") cwds+=("$cwd")
    tmos+=("${tmo:-$gt}") pendings+=("$pend") releases+=("$rel") rwhens+=("$rw") rmaxs+=("$rmax") heavies+=("$hv") inners+=("$inr")
done < <(jq -j '.gates[] | .name, "\u0000", .cmd, "\u0000", ((.when // []) | join("\n")), "\u0000",
    (.fix // ""), "\u0000", (if .cache == false then "0" else "1" end), "\u0000", (.cwd // "."), "\u0000",
    (.timeout // 900 | tostring), "\u0000", (if .pending == true then "1" else "0" end), "\u0000",
    (if .release == false then "0" else "1" end), "\u0000", (.rerun.when // ""), "\u0000",
    (.rerun.max // 1 | tostring), "\u0000", (if .heavy == true then "1" else "0" end), "\u0000", (if .inner == false then "0" else "1" end), "\u0000"' "$cfg")

# --only names must exist: a typo would otherwise run nothing and pass.
if [ -n "$only" ]; then
    bad_names=()
    IFS=',' read -ra wanted <<<"$only"
    for x in "${wanted[@]}"; do
        [ -n "$x" ] || continue
        printf '%s\n' "${names[@]}" | grep -qxF -- "$x" || bad_names+=("$x")
    done
    if [ "${#bad_names[@]}" -gt 0 ]; then
        echo "gates: unknown gate name(s): ${bad_names[*]} (valid: $(printf '%s ' "${names[@]}" | sed 's/ $//; s/ /, /g'))" >&2
        exit 2
    fi
fi
# Name column: the longest gate name plus one space, at least 12.
w=12
for n in "${names[@]}"; do [ $((${#n} + 1)) -gt "$w" ] && w=$((${#n} + 1)); done

regex_for() {
    local globs=()
    mapfile -t globs <<<"$1"
    wf_globs_to_regex "${globs[@]}"
}

# Decide what runs.
selected=() reasons=()
for i in "${!names[@]}"; do
    reason=""
    if [ -n "$only" ] && [[ ",$only," != *",${names[$i]},"* ]]; then
        reason="not selected"
    elif [ "$release" = 1 ] && [ "${releases[$i]}" = 0 ]; then
        reason="not in release"
    elif [ "$release" = 0 ] && [ "$all" = 0 ] && [ "${inners[$i]}" = 0 ]; then
        reason="release only"
    elif [ "${pendings[$i]}" = 1 ]; then
        reason="pending"
    elif [ "$all" = 0 ] && [ -n "${whens[$i]}" ] && ! grep -qE "$(regex_for "${whens[$i]}")" "$tmp/changed"; then
        reason="no matching changes"
    fi
    reasons+=("$reason")
    [ -z "$reason" ] && selected+=("$i")
done

if [ "$list" = 1 ]; then
    for i in "${!names[@]}"; do
        printf '%-*s %-20s %s\n' "$w" "${names[$i]}" "${reasons[$i]:-runs}" "${cmds[$i]}"
    done
    exit 0
fi

if [ "$fix" = 1 ]; then
    for i in "${selected[@]}"; do
        [ -n "${fixes[$i]}" ] || continue
        echo "fix ${names[$i]}: ${fixes[$i]}"
        (cd "$root/${cwds[$i]}" && bash -c "${fixes[$i]}") >"$logdir/${names[$i]}.fix.log" 2>&1 ||
            tail -n 10 "$logdir/${names[$i]}.fix.log"
    done
    rm -f "$tmp/tree" # fixes change files
fi

# Cache keys: one hash-object call covers the tree and every gate.
cache_file="$(git rev-parse --path-format=absolute --git-common-dir)/workflow-gates-cache"
declare -A key=()
build_listing
lock_re='(^|/)(package-lock\.json|npm-shrinkwrap\.json|bun\.lockb?|yarn\.lock|pnpm-lock\.yaml|composer\.lock|go\.sum|Cargo\.lock|uv\.lock|poetry\.lock|Gemfile\.lock|mix\.lock)$'
printf '%s\n' "$tmp/tree" >"$tmp/keylist"
keyed=()
if [ "$use_cache" = 1 ]; then
    awk -F'\t' -v re="$lock_re" '$2 ~ re' "$tmp/tree" >"$tmp/locks"
    for i in "${selected[@]}"; do
        [ "${caches[$i]}" = 1 ] || continue
        {
            printf '%s\n%s\n' "${cmds[$i]}" "${cwds[$i]}"
            if [ -n "${whens[$i]}" ]; then
                awk -F'\t' -v re="$(regex_for "${whens[$i]}")" '$2 ~ re' "$tmp/tree"
                cat "$tmp/locks"
            else
                cat "$tmp/tree"
            fi
        } >"$tmp/key.$i"
        printf '%s\n' "$tmp/key.$i" >>"$tmp/keylist"
        keyed+=("$i")
    done
fi
mapfile -t hashes < <(git hash-object --stdin-paths <"$tmp/keylist")
tree="${hashes[0]}"
for j in "${!keyed[@]}"; do key[${names[${keyed[$j]}]}]="${hashes[$((j + 1))]}"; done

# Heavy gates share a job cap; low memory runs them one at a time.
[ "$jobs" -gt 0 ] 2>/dev/null || jobs=$((($(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) + 1) / 2))
free_mb="${WF_FREE_MB:-}"
if [ -z "$free_mb" ]; then
    if [ -r /proc/meminfo ]; then
        free_mb="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)"
    elif command -v vm_stat >/dev/null; then
        free_mb="$(vm_stat | awk '/page size of/ { ps = $8 } /Pages (free|inactive|speculative)/ { gsub("\\.", "", $NF); n += $NF } END { print int(n * ps / 1048576) }')"
    fi
fi
mem_note=""
heavy_n=0
for i in "${selected[@]}"; do [ "${heavies[$i]}" = 1 ] && heavy_n=$((heavy_n + 1)); done
if [ "$heavy_n" -gt 1 ] && [ -n "$free_mb" ] && [ "$free_mb" -lt 2048 ] 2>/dev/null; then
    jobs=1
    mem_note="low memory (${free_mb} MB free): heavy gates one at a time"
fi

# One gate in its own process group, so a timeout kills everything it spawned.
run_one() {
    local i="$1" n="${names[$1]}" try=0 rc pid wd start=$SECONDS
    local out="$tmp/res.$n" log="$logdir/$n.log"
    set +e
    set -m
    while :; do
        rm -f "$out.timeout"
        (cd "$root/${cwds[$i]}" && exec bash -c "${cmds[$i]}") >"$log" 2>&1 </dev/null &
        pid=$!
        echo "$pid" >"$tmp/pg.$n"
        (
            sleep "${tmos[$i]}"
            touch "$out.timeout"
            kill -TERM -- "-$pid"
            sleep 5
            kill -KILL -- "-$pid"
        ) >/dev/null 2>&1 &
        wd=$!
        echo "$wd" >>"$tmp/pg.$n"
        wait "$pid"
        rc=$?
        kill -- "-$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
        if [ -f "$out.timeout" ]; then
            rc=124
            break
        fi
        [ "$rc" = 0 ] && break
        if [ -z "${rwhens[$i]}" ] || [ "$try" -ge "${rmaxs[$i]}" ] || ! grep -qE -- "${rwhens[$i]}" "$log"; then break; fi
        try=$((try + 1))
        cp "$log" "$log.try$try"
    done
    printf '%s %s %s\n' "$rc" "$((SECONDS - start))" "$try" >"$out"
}

heavy_q=()
for i in "${selected[@]}"; do
    n="${names[$i]}"
    if [ -n "${key[$n]:-}" ] && grep -qxF "$n ${key[$n]}" "$cache_file" 2>/dev/null; then
        echo "cached 0 0" >"$tmp/res.$n"
        continue
    fi
    if [ "${heavies[$i]}" = 1 ]; then
        heavy_q+=("$i")
    else
        run_one "$i" 2>/dev/null &
        pids+=($!)
    fi
done
start_heavy() {
    while [ "${#heavy_q[@]}" -gt 0 ] && [ "${#heavy_pid[@]}" -lt "$jobs" ]; do
        run_one "${heavy_q[0]}" 2>/dev/null &
        heavy_pid[$!]=1
        heavy_q=("${heavy_q[@]:1}")
    done
}
start_heavy
while [ "${#heavy_pid[@]}" -gt 0 ]; do
    wait -n 2>/dev/null || true
    for p in "${!heavy_pid[@]}"; do kill -0 "$p" 2>/dev/null || unset "heavy_pid[$p]"; done
    start_heavy
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

# Record passes: gatesCacheKeys entries per gate, newest last, under a lock.
passed_keys=()
for i in "${selected[@]}"; do
    n="${names[$i]}"
    [ -n "${key[$n]:-}" ] || continue
    read -r rc _ <"$tmp/res.$n" 2>/dev/null || continue
    [ "$rc" = 0 ] && passed_keys+=("$n ${key[$n]}")
done
if [ "${#passed_keys[@]}" -gt 0 ]; then
    wf_lock gates-cache
    touch "$cache_file"
    printf '%s\n' "${passed_keys[@]}" >"$tmp/cache.add"
    awk -v keep="$keep_keys" 'NR == FNR { add[$0] = 1; order[++m] = $0; next }
        { if (!($0 in add)) line[++n] = $0 }
        END {
            for (a = 1; a <= m; a++) line[++n] = order[a]
            for (k = n; k >= 1; k--) { split(line[k], f, " "); if (++c[f[1]] <= keep) out[k] = 1 }
            for (k = 1; k <= n; k++) if (k in out) print line[k]
        }' "$tmp/cache.add" "$cache_file" >"$tmp/cache.new"
    cat "$tmp/cache.new" >"$cache_file"
    wf_unlock gates-cache
fi

# Table and JSON.
red=() unproven=() npass=0
: >"$tmp/rows"
: >"$tmp/table"
row() { printf '%-*s| %-13s| %5s | %s\n' "$w" "$1" "$2" "$3" "$4" >>"$tmp/table"; }
row gate result sec note
for i in "${!names[@]}"; do
    n="${names[$i]}"
    reason="${reasons[$i]}"
    if [ -n "$reason" ]; then
        if [ "$reason" = pending ]; then
            row "$n" PENDING - "not proven: tool not set up yet"
            st=PENDING
        else
            row "$n" skip - "$reason"
            st=SKIP
        fi
        [ "$reason" != "not selected" ] && [ "$reason" != "not in release" ] && unproven+=("$n")
        printf '%s\t%s\t0\tfalse\t0\n' "$n" "$st" >>"$tmp/rows"
        continue
    fi
    read -r rc secs try <"$tmp/res.$n" 2>/dev/null || {
        rc="none" secs=0 try=0
    }
    cached=false note=""
    case "$rc" in
    0)
        st=PASS res=PASS
        if [ "$try" -gt 0 ]; then res="PASS (rerun)" note="rerun $try: output matched rerun.when"; fi
        ;;
    cached) st=PASS res=PASS cached=true note="cached: inputs unchanged since a pass" ;;
    124) st=TIMEOUT res=TIMEOUT note="killed after ${tmos[$i]}s" ;;
    127) st=NOT_INSTALLED res="NOT INSTALLED" note="command not found: ${cmds[$i]%% *}" ;;
    *) st=FAIL res=FAIL note="exit $rc" ;;
    esac
    if [ "$st" = PASS ]; then npass=$((npass + 1)); else red+=("$n"); fi
    if [ "$st" != PASS ] && [ "$try" -gt 0 ]; then note="$note (after $try rerun)"; fi
    row "$n" "$res" "$([ "$cached" = true ] && echo - || echo "$secs")" "$note"
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$st" "$secs" "$cached" "$try" >>"$tmp/rows"
    log_release "$n $st ${secs}s"
done
summary="$npass passed, ${#red[@]} red"
if [ "${#unproven[@]}" -gt 0 ]; then summary="$summary; not proven: $(printf '%s ' "${unproven[@]}")"; fi
if [ -n "$mem_note" ]; then summary="$summary; $mem_note"; fi
printf '%s\n' "${summary% }" >>"$tmp/table"
esc="$(printf '\033')"
for n in "${red[@]}"; do
    printf '\n--- %s (last %s lines, full: .workflow/gates/%s.log) ---\n' "$n" "$tail_lines" "$n" >>"$tmp/table"
    sed -e "s/${esc}\[[0-9;]*[A-Za-z]//g" "$logdir/$n.log" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n "$tail_lines" >>"$tmp/table" ||
        echo "(no output)" >>"$tmp/table"
done

code=0
[ "${#red[@]}" -eq 0 ] || code=1
[ "$release" = 1 ] && [ "${#unproven[@]}" -gt 0 ] && code=1
log_release "exit $code after $(($(date +%s) - started_at))s sha $head_sha"

jq -Rn --arg sha "$head_sha" --arg tree "$tree" --arg base "$base" --argjson rel "$([ "$release" = 1 ] && echo true || echo false)" \
    --argjson code "$code" '{sha: $sha, tree: $tree, base: $base, release: $rel, exit: $code,
      results: [inputs | split("\t") | {name: .[0], status: .[1], seconds: (.[2] | tonumber),
        cached: (.[3] == "true"), rerun: (.[4] | tonumber)}]}' <"$tmp/rows" >"$last_json"
cp "$tmp/table" "$state/gates-last.txt"
if [ "$json" = 1 ]; then jq -c . "$last_json"; else cat "$tmp/table"; fi
exit "$code"
