#!/usr/bin/env bash
# Compact review diff of a branch or range, sized for an agent's context.
#
# Usage: wf review-diff [BASE] [--file PATH] [--stat] [--max N]
#
#   BASE         diff base: a ref, or a range like main...feat/x
#                (default: merge-base of HEAD and the base branch; includes
#                uncommitted changes).
#   --file PATH  only this path (prefix match: a directory works too).
#   --stat       only the stat and per-file line counts.
#   --max N      above N diff lines print the stat only (default 400).
#
# Prints `git diff --stat`, then per-file hunks with -U2 --minimal. Skipped:
# lockfiles, build output, snapshots, source maps, *.min.*. Over the limit
# (without --file) it prints only the stat plus per-file counts and how to
# drill in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

max=400
base=""
only=""
stat_only=0
while [ $# -gt 0 ]; do
    case "$1" in
    --file)
        only="${2:?--file needs a path}"
        shift
        ;;
    --file=*) only="${1#--file=}" ;;
    --stat) stat_only=1 ;;
    --max)
        max="${2:?--max needs N}"
        shift
        ;;
    -h | --help)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "review-diff: unknown option $1" >&2
        exit 2
        ;;
    *) base="$1" ;;
    esac
    shift
done

cd "$(git rev-parse --show-toplevel)"

# Range args: "A...B" or "A..B" diff two commits; a single ref diffs against
# the working tree (so uncommitted work is included).
if [ -z "$base" ]; then
    base="$(git merge-base HEAD "$(wf_base_branch)")"
fi
range=("$base")
if [[ "$base" == *...* ]]; then
    range=("$(git merge-base "${base%%...*}" "${base##*...}")" "${base##*...}")
elif [[ "$base" == *..* ]]; then
    range=("${base%%..*}" "${base##*..}")
fi

skip_re='(^|/)(composer\.lock|bun\.lockb?|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|go\.sum|poetry\.lock|uv\.lock|Gemfile\.lock|Pipfile\.lock)$|(^|/)(dist|build|public/build)/|\.min\.(js|css)$|\.snap$|/__snapshots__/|\.map$'

pathspec=()
if [ -n "$only" ]; then
    pathspec=(-- "$only")
fi

mapfile -t files < <(git diff --name-only "${range[@]}" "${pathspec[@]}")
if [ "${#files[@]}" -eq 0 ]; then
    echo "no changes vs ${range[*]}"
    exit 0
fi

code_files=()
skipped=()
for f in "${files[@]}"; do
    if [[ "$f" =~ $skip_re ]]; then
        skipped+=("$f")
    else
        code_files+=("$f")
    fi
done

total=0
if [ "${#code_files[@]}" -gt 0 ]; then
    total="$(git diff -U2 --minimal "${range[@]}" -- "${code_files[@]}" | wc -l)"
fi

if [ "$stat_only" = 1 ] || { [ -z "$only" ] && [ "$total" -gt "$max" ]; }; then
    # One row per file: +added -deleted path, largest first (max 80 rows).
    git diff --shortstat "${range[@]}" "${pathspec[@]}" | sed 's/^ *//'
    [ "$stat_only" = 0 ] && echo "review diff is $total lines (> $max): stat only. Largest first:"
    git diff --numstat "${range[@]}" "${pathspec[@]}" |
        awk -v re="$skip_re" '{
            tag = ($3 ~ re) ? "  [skipped]" : ""
            printf "%7s %s\t+%s -%s  %s%s\n", ($1 == "-" ? 0 : $1 + $2), "", $1, $2, $3, tag
        }' | sort -rn | cut -f2- | awk 'NR <= 80 { print } END { if (NR > 80) printf "... %d more files\n", NR - 80 }'
    echo "drill in: wf review-diff ${base} --file PATH   (a directory works)"
    exit 0
fi

git diff --stat=100 --stat-graph-width=15 "${range[@]}" "${pathspec[@]}"
[ "${#skipped[@]}" -gt 0 ] && echo "skipped (generated/lock): ${skipped[*]}"

for f in "${code_files[@]}"; do
    echo
    # Drop the diff/index/---/+++ preamble: the header line names the file.
    git diff -U2 --minimal --no-prefix "${range[@]}" -- "$f" |
        awk -v f="$f" '
            /^@@/ { body = 1 }
            !body && /^(new|deleted) file/ { note = " (" $1 ")" }
            !body && /^rename from/ { note = " (renamed)" }
            body { if (!shown) { print "=== " f note; shown = 1 } print }
            END { if (!shown) print "=== " f note " (mode/binary only)" }
        '
done
