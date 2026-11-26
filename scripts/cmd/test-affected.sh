#!/usr/bin/env bash
# wf-help: run only the tests affected by the change (testAffected map, else per-stack related tests)
#
# Usage: wf test-affected [BASE] [--dry]
#   Changed files = diff vs BASE (default: merge base with the base branch)
#   plus untracked. With testAffected.map ([{src: glob, tests: template}],
#   {name} = source basename without extension) and testAffected.cmd
#   ({files} = the selected tests), runs the mapped tests that exist. Without
#   a map: vitest related, jest --findRelatedTests, pest --dirty, or go test of
#   the changed packages. Prints the mapping, then runs it (--dry: print only).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq

base="" dry=0
for a in "$@"; do
    case "$a" in
    --dry) dry=1 ;;
    -h | --help)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "test-affected: unknown flag $a" >&2
        exit 2
        ;;
    *) base="$a" ;;
    esac
done
root="$(wf_root)"
cd "$root"
cfg="$(wf_config)"
[ -n "$base" ] || base="$(git merge-base HEAD "$(wf_base_branch)" 2>/dev/null || git rev-parse HEAD)"
mapfile -t changed < <({
    git diff --name-only --diff-filter=d "$base" --
    git ls-files --others --exclude-standard
} | grep -v '^\.workflow/' | sort -u)
if [ "${#changed[@]}" -eq 0 ]; then
    echo "test-affected: no changed files vs $base"
    exit 0
fi

run() { # run CMD...
    echo "run: $*"
    [ "$dry" = 1 ] && return 0
    "$@"
}

if [ "$(jq '.testAffected.map // [] | length' "$cfg" 2>/dev/null || echo 0)" -gt 0 ]; then
    tcmd="$(wf_get .testAffected.cmd)"
    [ -n "$tcmd" ] || {
        echo "test-affected: testAffected.map needs testAffected.cmd" >&2
        exit 2
    }
    declare -A pick=()
    while IFS=$'\t' read -r src tpl; do
        re="$(wf_globs_to_regex "$src")"
        for f in "${changed[@]}"; do
            [[ "$f" =~ $re ]] || continue
            name="$(basename "$f")"
            name="${name%.*}"
            t="${tpl//\{name\}/$name}"
            # A template may be a glob (tests/**/{name}.test.ts): expand it.
            for m in $t; do
                [ -e "$m" ] || continue
                echo "$f -> $m"
                pick[$m]=1
            done
        done
    done < <(jq -r '.testAffected.map[] | "\(.src)\t\(.tests)"' "$cfg")
    # A changed test file runs itself.
    for f in "${changed[@]}"; do
        [[ "$f" =~ (\.|_)(test|spec)\.|Test\.php$|_test\.go$ ]] && [ -e "$f" ] && pick[$f]=1
    done
    if [ "${#pick[@]}" -eq 0 ]; then
        echo "test-affected: no mapped tests for ${#changed[@]} changed files"
        exit 0
    fi
    files="$(printf '%s\n' "${!pick[@]}" | sort | paste -sd' ' -)"
    run bash -c "${tcmd//\{files\}/$files}"
    exit
fi

# Per-stack fallbacks.
src=()
for f in "${changed[@]}"; do [ -e "$f" ] && src+=("$f"); done
if [ -f package.json ] && jq -e '(.devDependencies // {}) + (.dependencies // {}) | has("vitest")' package.json >/dev/null; then
    echo "${#src[@]} changed files -> vitest related"
    run npx vitest related --run "${src[@]}"
elif [ -f package.json ] && jq -e '(.devDependencies // {}) + (.dependencies // {}) | has("jest")' package.json >/dev/null; then
    echo "${#src[@]} changed files -> jest --findRelatedTests"
    run npx jest --findRelatedTests "${src[@]}"
elif [ -x vendor/bin/pest ]; then
    echo "${#src[@]} changed files -> pest --dirty"
    run vendor/bin/pest --dirty
elif [ -f go.mod ]; then
    mapfile -t pkgs < <(printf '%s\n' "${src[@]}" | grep '\.go$' | xargs -r -n1 dirname | sort -u | sed 's|^|./|')
    if [ "${#pkgs[@]}" -eq 0 ]; then
        echo "test-affected: no changed go packages"
        exit 0
    fi
    printf '%s\n' "${pkgs[@]}" | sed 's/^/package /'
    run go test "${pkgs[@]}"
else
    echo "test-affected: no testAffected.map and no known stack (vitest, jest, pest, go)" >&2
    exit 2
fi
