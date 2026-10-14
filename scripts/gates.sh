#!/usr/bin/env bash
# Run the project's quality gates in parallel and print a compact table.
#
# Usage: gates.sh [--all] [--only a,b] [--base REF] [--fix] [--no-cache] [--list]
#
# Gates come from .claude/workflow.json:
#   "gates": [{ "name": "test", "cmd": "npm test", "when": ["src/", "*.ts"], "fix": "...", "cache": true }]
#
#   (default)    every gate whose `when` globs match a changed file (vs the merge
#                base with the base branch, plus uncommitted and untracked
#                files); gates without `when` always run.
#   --all        ignore `when`, run every gate.
#   --only a,b   just these gates (still subject to `when` unless --all).
#   --base REF   diff base instead of the merge base.
#   --fix        run each selected gate's `fix` command first (formatters).
#   --no-cache   do not skip gates whose inputs match their last PASS.
#   --list       print the gates and whether each would run, then exit.
#
# Globs: `*` matches across directories, `?` one character, a trailing `/`
# means everything under it. Commands run with `bash -c` from the worktree
# root with WF_BASE (diff base) and WF_CHANGED (a file listing changed paths).
# Cache: a gate is skipped when the content hash of its `when` paths (the whole
# tree without `when`) plus its command equals the last PASS; stored in
# <git common dir>/workflow-gates-cache. Off per gate with "cache": false, or
# globally with "gatesCache": false.
#
# Output: `gate | result | sec | note`, then the last N lines (gatesTailLines,
# default 30) of each failing gate. Exit 1 when a gate fails, 2 on bad usage.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
wf_need jq "for reading .claude/workflow.json"

all=0 fix=0 use_cache=1 list=0 only="" base=""
while [ $# -gt 0 ]; do
    case "$1" in
    --all) all=1 ;;
    --fix) fix=1 ;;
    --no-cache) use_cache=0 ;;
    --list) list=1 ;;
    --only)
        only="${2:?--only needs names}"
        shift
        ;;
    --only=*) only="${1#--only=}" ;;
    --base)
        base="${2:?--base needs a ref}"
        shift
        ;;
    --base=*) base="${1#--base=}" ;;
    -h | --help)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "gates: unknown argument: $1" >&2
        exit 2
        ;;
    esac
    shift
done

root="$(wf_root)"
cd "$root"
cfg="$(wf_config)"
if [ ! -f "$cfg" ] || [ "$(jq '.gates // [] | length' "$cfg")" = 0 ]; then
    echo "gates: no gates in $cfg (run /workflow:init or add a \"gates\" list)" >&2
    exit 2
fi
[ "$(jq -r '.gatesCache // true' "$cfg")" = false ] && use_cache=0
tail_lines="$(wf_get .gatesTailLines 30)"

# A fresh worktree missing its linked dependency dirs gets wt-init first.
if [ "$root" != "$(wf_main)" ]; then
    while IFS= read -r p; do
        if [ -n "$p" ] && [ ! -e "$p" ]; then
            "$here/wt-init.sh" "$root" >/dev/null
            break
        fi
    done < <(jq -r '.worktree.link // [] | .[]' "$cfg")
fi

if [ -z "$base" ]; then
    base="$(git merge-base HEAD "$(wf_base_branch)" 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gates.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

{
    [ -n "$base" ] && git diff --name-only "$base" --
    git ls-files --others --exclude-standard
} 2>/dev/null | sort -u >"$tmp/changed"
export WF_BASE="$base" WF_CHANGED="$tmp/changed"

names=() cmds=() whens=() fixes=() caches=()
while IFS= read -r -d '' name && IFS= read -r -d '' cmd && IFS= read -r -d '' when &&
    IFS= read -r -d '' fixcmd && IFS= read -r -d '' cache; do
    names+=("$name")
    cmds+=("$cmd")
    whens+=("$when")
    fixes+=("$fixcmd")
    caches+=("$cache")
done < <(jq -j '.gates[] | .name, "\u0000", .cmd, "\u0000", ((.when // []) | join("\n")), "\u0000",
    (.fix // ""), "\u0000", (if .cache == false then "0" else "1" end), "\u0000"' "$cfg")

regex_for() {
    local globs=()
    mapfile -t globs <<<"$1"
    wf_globs_to_regex "${globs[@]}"
}

# Decide what runs: selected (by --only) and with matching changes.
selected=() reasons=()
for i in "${!names[@]}"; do
    reason=""
    if [ -n "$only" ] && [[ ",$only," != *",${names[$i]},"* ]]; then
        reason="not selected"
    elif [ "$all" = 0 ] && [ -n "${whens[$i]}" ] && ! grep -qE "$(regex_for "${whens[$i]}")" "$tmp/changed"; then
        reason="no matching changes"
    fi
    reasons+=("$reason")
    [ -z "$reason" ] && selected+=("$i")
done

if [ "$list" = 1 ]; then
    for i in "${!names[@]}"; do
        printf '%-12s %-24s %s\n' "${names[$i]}" "${reasons[$i]:-runs}" "${cmds[$i]}"
    done
    exit 0
fi

if [ "$fix" = 1 ]; then
    for i in "${selected[@]}"; do
        [ -n "${fixes[$i]}" ] || continue
        echo "fix ${names[$i]}: ${fixes[$i]}"
        bash -c "${fixes[$i]}" >"$tmp/fix-${names[$i]}.log" 2>&1 || tail -n 10 "$tmp/fix-${names[$i]}.log"
    done
fi

# Content hash of the working tree (tracked + untracked, minus ignored) via a
# throwaway index, so the real index is never touched.
cache_file="$(git rev-parse --path-format=absolute --git-common-dir)/workflow-gates-cache"
tree=""
if [ "$use_cache" = 1 ] && [ "${#selected[@]}" -gt 0 ]; then
    idx="$(git rev-parse --path-format=absolute --git-path index)"
    [ -f "$idx" ] && cp "$idx" "$tmp/index"
    if GIT_INDEX_FILE="$tmp/index" git add -A . 2>/dev/null; then
        tree="$(GIT_INDEX_FILE="$tmp/index" git write-tree)"
        git ls-tree -r --full-tree "$tree" >"$tmp/tree"
    fi
fi
cache_key() {
    local i="$1"
    {
        printf '%s\n' "${cmds[$i]}"
        if [ -n "${whens[$i]}" ]; then
            awk -F'\t' -v re="$(regex_for "${whens[$i]}")" '$2 ~ re' "$tmp/tree"
        else
            echo "$tree"
        fi
    } | git hash-object --stdin
}

declare -A key=()
pids=()
for i in "${selected[@]}"; do
    n="${names[$i]}"
    if [ -n "$tree" ] && [ "${caches[$i]}" = 1 ]; then
        key[$n]="$(cache_key "$i")"
        if grep -qxF "$n ${key[$n]}" "$cache_file" 2>/dev/null; then
            echo cached >"$tmp/$n.rc"
            echo "-" >"$tmp/$n.sec"
            continue
        fi
    fi
    (
        start=$SECONDS
        set +e
        bash -c "${cmds[$i]}" >"$tmp/$n.log" 2>&1 </dev/null
        echo $? >"$tmp/$n.rc"
        echo $((SECONDS - start)) >"$tmp/$n.sec"
    ) &
    pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done

failed=()
printf '%-12s| %-7s| %5s | %s\n' gate result sec note
for i in "${!names[@]}"; do
    n="${names[$i]}"
    if [ -n "${reasons[$i]}" ]; then
        printf '%-12s| %-7s| %5s | %s\n' "$n" skip - "${reasons[$i]}"
        continue
    fi
    rc="$(cat "$tmp/$n.rc" 2>/dev/null || echo "no result")"
    note=""
    case "$rc" in
    0)
        res=PASS
        if [ -n "${key[$n]:-}" ]; then
            touch "$cache_file"
            { grep -v "^$n " "$cache_file" || true; } >"$tmp/cache.new"
            echo "$n ${key[$n]}" >>"$tmp/cache.new"
            cat "$tmp/cache.new" >"$cache_file"
        fi
        ;;
    cached)
        res=PASS
        note="cached: inputs unchanged since last pass"
        ;;
    *)
        res=FAIL
        note="exit $rc"
        failed+=("$n")
        ;;
    esac
    printf '%-12s| %-7s| %5s | %s\n' "$n" "$res" "$(cat "$tmp/$n.sec" 2>/dev/null || echo -)" "$note"
done

for n in "${failed[@]}"; do
    printf '\n--- %s (last %s lines) ---\n' "$n" "$tail_lines"
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$tmp/$n.log" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n "$tail_lines" || echo "(no output)"
done

[ "${#failed[@]}" -eq 0 ]
