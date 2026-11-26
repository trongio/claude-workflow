#!/usr/bin/env bash
# wf-help: tear down merged/done worktrees, ledger leftovers and merged wf/* branches (dry run unless --apply)
#
# Usage: wf prune [--apply] [ID|DIR...]
#   A worktree is torn down (wf_teardown: teardown commands, preview, worktree,
#   branch, ledger entry) when its branch is merged into the base branch or its
#   card is done/verifying; a ledger entry whose worktree is gone is dropped.
#   Merged wf/* branches without a worktree are deleted. Databases matching
#   the worktree.env templates (keys with DB or DATABASE) that no live worktree
#   uses are listed (via psql or mysql; WF_DB_LIST_CMD overrides). Naming IDs
#   or dirs tears those down regardless. Root-owned files get a printed command.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq

apply=0 targets=()
for a in "$@"; do
    case "$a" in
    --apply) apply=1 ;;
    -h | --help)
        sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "prune: unknown flag $a" >&2
        exit 2
        ;;
    *) targets+=("$a") ;;
    esac
done

main="$(wf_main)"
cd "$main"
base="$(wf_base_branch)"
wf="$here/../bin/wf"
ledger="$(wf_ledger)"
n=0

card_status() { "$wf" show "$1" 2>/dev/null | sed -n 's/^status: *//p' | head -1; }

act() { # act DIR REASON
    local dir="$1" foreign
    n=$((n + 1))
    foreign="$([ -d "$dir" ] && find "$dir" ! -user "$(id -u)" -print -quit 2>/dev/null || true)"
    if [ -n "$foreign" ]; then
        echo "blocked $dir ($2): files owned by another user ($foreign); run: sudo rm -rf '$dir' && git -C '$main' worktree prune && wf prune --apply"
        return
    fi
    if [ "$apply" = 1 ]; then
        echo "tear down $dir ($2)"
        wf_teardown "$dir" | sed 's/^/  /'
    else
        echo "would tear down $dir ($2)"
    fi
}

declare -A seen=()
if [ "${#targets[@]}" -gt 0 ]; then
    for t in "${targets[@]}"; do
        if [ -d "$t" ]; then d="$(cd "$t" && pwd)"; else d="$main/.workflow/worktrees/$t"; fi
        act "$d" "named"
    done
    exit 0
fi

# Live git worktrees other than main.
while IFS=$'\t' read -r d br; do
    [ "$d" = "$main" ] && continue
    seen[$d]=1
    br="${br#refs/heads/}"
    id="$(wf_wt_id "$d")"
    st="$(card_status "$id")"
    case "$st" in in-progress | code-review | ux-review | owner-review) continue ;; esac
    if [ -n "$br" ] && [ "$(git rev-list --count "$base..$br" 2>/dev/null || echo 1)" = 0 ] &&
        [ "$(git rev-parse "$br" 2>/dev/null)" != "$(git rev-parse "$base")" ]; then
        act "$d" "branch $br merged into $base"
    elif [ "$st" = "done" ] || [ "$st" = verifying ]; then
        act "$d" "card $id is $st"
    fi
done < <(git worktree list --porcelain | awk '/^worktree / { if (p) print p "\t" b; p = substr($0, 10); b = "" }
    /^branch / { b = $2 } END { if (p) print p "\t" b }')

# Ledger entries whose worktree is gone.
if [ -s "$ledger" ]; then
    while IFS= read -r d; do
        [ -n "${seen[$d]:-}" ] && continue
        [ -d "$d" ] && continue
        act "$d" "worktree gone, ledger entry left"
    done < <(jq -r '.worktrees | keys[]' "$ledger")
fi

# Merged wf/* branches with no worktree.
while IFS= read -r br; do
    [ -n "$br" ] || continue
    git worktree list --porcelain | grep -qx "branch refs/heads/$br" && continue
    n=$((n + 1))
    if [ "$apply" = 1 ]; then
        git branch -d "$br" >/dev/null && echo "deleted merged branch $br"
    else
        echo "would delete merged branch $br"
    fi
done < <(git branch --format='%(refname:short)' --merged "$base" --list 'wf/*')

# Databases from the env templates with no live worktree.
pats=()
while IFS= read -r t; do
    [ -n "$t" ] && pats+=("$(printf '%s' "$t" | sed -e 's/[.[\*^$]/\\&/g' -e 's/{id}/.*/g' -e 's/{slug}/.*/g' -e 's/{port}/.*/g')")
done < <(jq -r '.worktree.env // {} | to_entries[] | select(.key | test("DB|DATABASE")) | .value' "$(wf_config)")
if [ "${#pats[@]}" -gt 0 ]; then
    list_cmd="${WF_DB_LIST_CMD:-}"
    if [ -z "$list_cmd" ]; then
        if command -v psql >/dev/null; then
            list_cmd="psql -Atc 'select datname from pg_database' postgres"
        elif command -v mysql >/dev/null; then list_cmd="mysql -N -e 'show databases'"; fi
    fi
    if [ -n "$list_cmd" ] && dbs="$(bash -c "$list_cmd" 2>/dev/null)"; then
        live="$([ -s "$ledger" ] && jq -r '.worktrees[] | .db[]?' "$ledger" || true)"
        re="^($(
            IFS='|'
            echo "${pats[*]}"
        ))\$"
        while IFS= read -r db; do
            [ -n "$db" ] || continue
            printf '%s\n' "$live" | grep -qxF "$db" && continue
            n=$((n + 1))
            echo "orphan database $db (no live worktree; drop it with your worktree.teardown command)"
        done < <(printf '%s\n' "$dbs" | grep -E "$re" || true)
    else
        echo "prune: cannot list databases (no psql/mysql; set WF_DB_LIST_CMD)" >&2
    fi
fi

if [ "$n" = 0 ]; then
    echo "prune: nothing to clean"
elif [ "$apply" = 0 ]; then
    echo "prune: $n item(s); run wf prune --apply"
fi
