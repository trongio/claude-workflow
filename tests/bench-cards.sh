#!/usr/bin/env bash
# Benchmark the card CLI on a large board: 1,500 cards (550 open, 950 archived)
# in a scratch repo; times `wf list`, `wf status` and `wf claim --dry-run`.
# Uses hyperfine when installed, else a 10-run timed loop. Target: < 150 ms each.
#
# Usage: tests/bench-cards.sh [SCRATCH_DIR]
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$repo/bin/wf"
dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/wf-bench.XXXXXX")}"
cd "$dir"
git init -q -b main
mkdir -p tasks/archive .claude
echo '{ "idPrefix": "B", "wipLimit": 1000 }' >.claude/workflow.json
statuses=(todo todo todo in-progress code-review owner-review verifying backlog)
for i in $(seq 1 1500); do
    if [ "$i" -le 950 ]; then f="tasks/archive/B-$i-card.md" s="done"; else f="tasks/B-$i-card.md" s="${statuses[$((i % 8))]}"; fi
    printf -- '---\nid: B-%d\ntitle: "Card %d"\nstatus: %s\nmilestone: %s\nsize: M\narea: a%d\npriority: 2\nblocked: ""\ndepends: []\nlinks: []\ntags: []\ncreated: 2026-10-01\nstarted: 2026-10-02\ndone: 2026-10-03\n---\n\n## Goal\n\nSome goal text for card %d.\n\n## Acceptance\n\n- [x] one\n- [ ] two\n\n## Outcome\n\nShipped.\n' \
        "$i" "$i" "$s" "$([ $((i % 3)) = 0 ] && echo true || echo false)" $((i % 12)) "$i" >"$f"
done
git add -A >/dev/null && git -c user.email=b@example.invalid -c user.name=b commit -qm init

cmds=("$wf list" "$wf status" "$wf claim --dry-run")
if command -v hyperfine >/dev/null; then
    hyperfine -N --warmup 2 --runs 15 --style basic --export-json "$dir/bench.json" "${cmds[@]}" >/dev/null 2>&1
    jq -r '.results[] | "\(.command | sub(".*/bin/"; "")): mean \(.mean * 1000 | floor) ms, max \(.max * 1000 | floor) ms"' "$dir/bench.json"
else
    for c in "${cmds[@]}"; do
        start=$(date +%s%N)
        for _ in $(seq 1 10); do $c >/dev/null; done
        echo "${c##*/bin/}: mean $((($(date +%s%N) - start) / 10000000)) ms"
    done
fi
echo "board: $dir (1500 cards, target < 150 ms)"
