#!/usr/bin/env bash
# wf-help: tear down merged/done worktrees, ledger leftovers and merged wf/* branches (dry run unless --apply)
#
# Usage: wf prune [--apply] [--force] [ID|DIR...]
#   Only task worktrees are touched: those under .workflow/worktrees/ or in the
#   resource ledger. The main checkout and any other worktree (yours, another
#   tool's) are never touched. A task worktree is torn down (wf_teardown) when
#   its branch is merged into the base branch and the tree is clean, or its
#   card is done/verifying; a ledger entry whose worktree is gone is dropped.
#   Merged wf/* branches without a worktree are deleted; an unmerged one only
#   when its card is done/verifying and (finish.mode pr) `gh pr view` says
#   MERGED (squash merges), or when named with --force. Naming an ID or DIR
#   tears that worktree down regardless of status (uncommitted work is saved
#   first; the branch is kept unless merged, or --force). Databases matching
#   worktree.env templates (keys with DB or DATABASE) that no live worktree
#   uses are listed (psql or mysql; WF_DB_LIST_CMD overrides), never dropped.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq

apply=0 force="" targets=()
for a in "$@"; do
    case "$a" in
    --apply) apply=1 ;;
    --force) force=--force ;;
    -h | --help)
        sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'
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
wtroot="$main/.workflow/worktrees"
mode="$(wf_get .finish.mode pr)"
n=0 rc=0

card_status() { { "$wf" show "$1" 2>/dev/null || true; } | sed -n 's/^status: *//p' | head -1; }

# Squash-merged: the card landed and GitHub says the branch's PR merged.
pr_merged() {
    [ "$mode" = pr ] && command -v gh >/dev/null || return 1
    [ "$(gh pr view "$1" --json state -q .state 2>/dev/null || true)" = MERGED ]
}

# A task worktree: under .workflow/worktrees/ or in the ledger, never main.
is_task_dir() {
    [ "$(wf_real "$1")" != "$(wf_real "$main")" ] || return 1
    case "$(wf_real "$1")/" in "$(wf_real "$wtroot")"/*) return 0 ;; esac
    wf_ledger_has "$1"
}

act() { # act DIR REASON [--force]
    local dir="$1" foreign out
    n=$((n + 1))
    foreign="$([ -d "$dir" ] && find "$dir" ! -user "$(id -u)" -print -quit 2>/dev/null || true)"
    if [ -n "$foreign" ]; then
        echo "blocked $dir ($2): files owned by another user ($foreign); run: sudo chown -R $(id -un) '$dir' && wf prune --apply '$dir'"
        return
    fi
    if [ "$apply" = 1 ]; then
        echo "tear down $dir ($2)"
        out="$(wf_teardown "$dir" "${3:-}" 2>&1)" || rc=1
        printf '%s\n' "$out" | sed '/^$/d; s/^/  /'
    else
        echo "would tear down $dir ($2)"
    fi
}

delete_branch() { # delete_branch BRANCH REASON
    n=$((n + 1))
    if [ "$apply" = 1 ]; then
        git branch -D "$1" >/dev/null && echo "deleted branch $1 ($2)"
    else
        echo "would delete branch $1 ($2)"
    fi
}

if [ "${#targets[@]}" -gt 0 ]; then
    for t in "${targets[@]}"; do
        if [ -d "$t" ]; then d="$(cd "$t" && pwd)"; else d="$wtroot/$t"; fi
        if [ -e "$d" ]; then
            if ! is_task_dir "$d" || ! wf_is_worktree "$d"; then
                echo "prune: $t is not a task worktree (.workflow/worktrees/<ID> or a ledger entry); not touched" >&2
                rc=2
                continue
            fi
            act "$d" "named" "$force"
        elif wf_ledger_has "$d"; then
            act "$d" "named, worktree gone" "$force"
        elif [ ! -d "$t" ] && git rev-parse -q --verify "refs/heads/wf/$t" >/dev/null; then
            # A card ID with a branch but no worktree (abandoned card).
            if git merge-base --is-ancestor "wf/$t" "$base"; then
                delete_branch "wf/$t" "merged into $base"
            elif [ -n "$force" ]; then
                delete_branch "wf/$t" "named with --force"
            else
                echo "kept branch wf/$t (not merged into $base; name it with --force to delete)"
            fi
        else
            echo "prune: $t is not a task worktree, ledger entry or wf/* branch; not touched" >&2
            rc=2
        fi
    done
    exit "$rc"
fi

# Task worktrees (git worktrees under .workflow/worktrees/ or in the ledger).
declare -A seen=()
while IFS=$'\t' read -r d br; do
    is_task_dir "$d" || continue
    seen[$d]=1
    br="${br#refs/heads/}"
    id="$(wf_wt_id "$d")"
    st="$(card_status "$id")"
    case "$st" in in-progress | code-review | ux-review | owner-review) continue ;; esac
    dirty="$(git -C "$d" status --porcelain -- . ':(exclude).workflow' 2>/dev/null || echo dirty)"
    if [ "$st" = "done" ] || [ "$st" = verifying ]; then
        f=""
        [ -n "$br" ] && ! git merge-base --is-ancestor "$br" "$base" 2>/dev/null && pr_merged "$br" && f=--force
        act "$d" "card $id is $st" "$f"
    elif [ -z "$dirty" ] && [ -n "$br" ] && git merge-base --is-ancestor "$br" "$base" 2>/dev/null &&
        [ "$(git rev-parse "$br" 2>/dev/null)" != "$(git rev-parse "$base")" ]; then
        act "$d" "branch $br merged into $base"
    fi
done < <(git worktree list --porcelain | awk '/^worktree / { if (p) print p "\t" b; p = substr($0, 10); b = "" }
    /^branch / { b = $2 } END { if (p) print p "\t" b }')

# Ledger entries whose worktree is gone.
if [ -s "$ledger" ]; then
    while IFS= read -r d; do
        [ -n "${seen[$d]:-}" ] && continue
        [ -e "$d" ] && continue
        act "$d" "worktree gone, ledger entry left"
    done < <(jq -r '.worktrees | keys[]' "$ledger")
fi

# wf/* branches with no worktree: merged ones, and squash-merged landed cards.
while IFS= read -r br; do
    [ -n "$br" ] || continue
    git worktree list --porcelain | grep -qxF "branch refs/heads/$br" && continue
    if git merge-base --is-ancestor "$br" "$base" 2>/dev/null; then
        delete_branch "$br" "merged into $base"
    else
        st="$(card_status "${br#wf/}")"
        if { [ "$st" = "done" ] || [ "$st" = verifying ]; } && pr_merged "$br"; then
            delete_branch "$br" "card $st, PR merged"
        fi
    fi
done < <(git branch --format='%(refname:short)' --list 'wf/*')

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
exit "$rc"
