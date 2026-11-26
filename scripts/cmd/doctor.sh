#!/usr/bin/env bash
# wf-help: check config, gate tools, hooks, dev url, locks, leftovers, stack doc age (prints failures only)
#
# Usage: wf doctor
# Checks: workflow.json against the schema (types and enums of top-level keys
# and their direct properties, unknown keys); every gate's first command word
# exists; core.hooksPath (worktrees match main, a hooks dir is wired); dev.url
# answers; stale locks; leftovers (merged or done worktrees, ledger entries
# without a live worktree, merged wf/* branches, orphan databases, processes
# outliving their worktree); docs/STACK.md newer than 90 days.
# Exit 1 when anything fails.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$here/lib/common.sh"
wf_need jq
case "${1:-}" in -h | --help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

root="$(wf_root)"
main="$(wf_main)"
cd "$root" || exit 2
cfg="$(wf_config)"
schema="$here/../schema/workflow.schema.json"
fails=0 checks=0
bad() {
    fails=$((fails + 1))
    echo "FAIL $*"
}
check() { checks=$((checks + 1)); }

# 1. Config vs schema.
check
if [ ! -f "$cfg" ]; then
    bad "no $cfg (run wf init --write)"
elif ! jq -e . "$cfg" >/dev/null 2>&1; then
    bad "$cfg is not valid JSON"
else
    while IFS= read -r msg; do bad "config: $msg"; done < <(jq -r --slurpfile s "$schema" '
        def jt: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
        def ok($t): ($t == null) or (jt == $t) or ($t == "number" and jt == "integer");
        def check($path; $sch):
          (if ($sch.type // null) != null and (ok($sch.type) | not) then "\($path): expected \($sch.type), got \(jt)" else empty end),
          (if ($sch.enum // null) != null and (. as $v | $sch.enum | index([$v]) | not) then "\($path): \(tojson) not one of \($sch.enum | join(", "))" else empty end);
        $s[0].properties as $p
        | to_entries[]
        | .key as $k | .value as $v
        | if $p[$k] == null then "unknown key \($k)"
          else ($v | check($k; $p[$k])),
               (if ($v | type) == "object" and ($p[$k].properties // null) != null then
                  $v | to_entries[] | .key as $k2 | .value as $v2
                  | if $p[$k].properties[$k2] == null then
                      (if ($p[$k].additionalProperties // true) == false then "unknown key \($k).\($k2)" else empty end)
                    else ($v2 | check("\($k).\($k2)"; $p[$k].properties[$k2])) end
                else empty end),
               (if $k == "gates" and ($v | type) == "array" then
                  $v | to_entries[] | .key as $i | .value as $g
                  | (if ($g.name // null) == null or ($g.cmd // null) == null then "gates[\($i)]: needs name and cmd" else empty end),
                    ($g | to_entries[] | .key as $k3 | .value
                     | if $p.gates.items.properties[$k3] == null then "unknown key gates[\($i)].\($k3)"
                       else check("gates[\($i)].\($k3)"; $p.gates.items.properties[$k3]) end)
                else empty end)
          end' "$cfg")

    # 2. Gate tools.
    while IFS=$'\t' read -r name cwd pending cmd; do
        check
        [ "$pending" = true ] && {
            echo "pending gate $name: not proven until its tool is set up"
            continue
        }
        word="$(printf '%s\n' "$cmd" | awk '{ for (i = 1; i <= NF; i++) if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { print $i; exit } }')"
        [ -n "$word" ] || continue
        if [[ "$word" == */* ]]; then
            [ -x "$root/$cwd/$word" ] || [ -x "$word" ] || bad "gate $name: $word not found (cwd $cwd)"
        else
            (cd "$root/$cwd" 2>/dev/null && command -v "$word" >/dev/null) || bad "gate $name: $word is not installed"
        fi
    done < <(jq -r '.gates // [] | .[] | [.name, (.cwd // "."), (.pending // false | tostring), .cmd] | @tsv' "$cfg")
fi

# 3. Hooks.
check
want="$(git -C "$main" config --get core.hooksPath || true)"
for d in .claude/hooks .githooks .husky; do
    if [ -d "$main/$d" ] && [ -z "$want" ] && [ -n "$(ls "$main/$d" 2>/dev/null)" ]; then
        bad "core.hooksPath is unset but $d exists (git config core.hooksPath $d)"
    fi
done
while IFS= read -r w; do
    [ "$w" = "$main" ] && continue
    [ -d "$w" ] || continue
    have="$(git -C "$w" config --get core.hooksPath || true)"
    [ "$have" = "$want" ] || bad "worktree $w: core.hooksPath '$have' differs from main '$want' (wf wt-init $w fixes it)"
done < <(git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p')

# 4. Dev url.
url="$(wf_get .dev.url)"
if [ -n "$url" ]; then
    check
    if command -v curl >/dev/null; then
        curl -s -o /dev/null -m 5 "$url" || bad "dev.url $url does not answer (start the dev stack)"
    fi
fi

# 5. Stale locks.
check
common="$(git rev-parse --path-format=absolute --git-common-dir)"
for l in "$common"/workflow-*.lock "$main/.workflow/.runner.lock"; do
    [ -d "$l" ] || continue
    pid="$(cat "$l/pid" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then bad "stale lock $l (owner ${pid:-unknown} gone): rm -rf '$l'"; fi
done
if [ -d "$main/tasks/.claim.lock" ] && [ -n "$(find "$main/tasks/.claim.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    bad "stale card lock $main/tasks/.claim.lock: rmdir it"
fi

# 6. Leftovers: worktrees, ledger, branches, databases, processes.
check
while IFS= read -r line; do
    case "$line" in would* | blocked* | orphan*) bad "leftover: $line" ;; esac
done < <("$here/cmd/prune.sh" 2>/dev/null)
check
while IFS= read -r line; do bad "orphan process: $line"; done < <("$here/cmd/orphans.sh" --json 2>/dev/null |
    jq -r '.[] | select(.stale) | "\(.pid) \(.cmd) in removed worktree \(.cwd) (wf orphans --kill)"')

# 7. Stack doc age.
if [ -f "$main/docs/STACK.md" ]; then
    check
    newest="$(grep -oE '20[0-9]{2}-[01][0-9]-[0-3][0-9]' "$main/docs/STACK.md" | sort | tail -1)"
    decided="$(wf_get .stack.decided)"
    [[ "$decided" > "$newest" ]] && newest="$decided"
    if [ -z "$newest" ]; then
        bad "docs/STACK.md has no dated version table (wf versions --check docs/STACK.md)"
    else
        cutoff="$(date -d '90 days ago' +%F 2>/dev/null || date -v-90d +%F)"
        [[ "$newest" < "$cutoff" ]] && bad "docs/STACK.md versions last checked $newest (> 90 days): wf versions --check docs/STACK.md"
    fi
fi

if [ "$fails" = 0 ]; then
    echo "doctor: OK ($checks checks)"
else
    echo "doctor: $fails problem(s)"
    exit 1
fi
