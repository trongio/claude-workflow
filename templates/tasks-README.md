# Tasks

One markdown card per task. `wf board` serves a live board from this folder
and `tasks/archive/`; `wf list|claim|start|move|note|park|show|status` drive
it. Never hand-edit the front matter: the CLI keeps dates, archive moves and
the WIP limit right.

- Active cards: `tasks/{{PREFIX}}-<n>-<slug>.md`
- Done cards move to `tasks/archive/` when they reach `done`

## Front matter

```yaml
---
id: {{PREFIX}}-12
title: "Export orders as CSV"
status: todo            # backlog | todo | in-progress | code-review | ux-review | owner-review | verifying | done
milestone: true         # counts toward the milestone progress bar and ETA
size: M                 # S=1, M=2, L=4, XL=8 points
area: backend           # free text; parallel claims prefer different areas
priority: 2             # lower runs first
blocked: ""             # non-empty = waiting on someone, e.g. "owner: pick a provider"
depends: [{{PREFIX}}-10]       # ids that must be done first
tags: []                # e.g. migration, deploy, hardware: the overnight runner skips overnight.exclude tags
created: 2026-01-05
started:                # set when the card first leaves todo
done:                   # set when status becomes done
branch:                 # wf/<ID>, set by wf start
links: []               # e.g. ["#123"] when a tracker is configured
---
```

Body: `## Goal`, `## Acceptance` (checkbox list), then `## Notes` and
`## Outcome` as the task moves. `## Outcome` is the permanent record, written
by `wf outcome` (gate table, diffstat, commits, risk) with prose for what
shipped, decisions and deviations with reasons, review, verify and critique
results, and follow-up cards.

## Columns

| Status | Meaning | Moved by |
|---|---|---|
| backlog | wanted, not scheduled | owner or manager |
| todo | scheduled, ready to pick up | owner or manager |
| in-progress | planner + implementers working | `wf start` |
| code-review | gates, reviewers, verifier, critic | manager after integrate |
| ux-review | UX fix round in flight | manager |
| owner-review | needs the owner: a choice, a sign-off | `wf park` |
| verifying | landed (merged or PR open), not yet observed working where it runs | `wf finish` |
| done | observed working; `--verified` says how | `wf move <ID> done --verified "..."` |

Only the owner moves a card out of `owner-review`, unless the card says the
manager may finish it alone. A `blocked` value starting with `owner` lists the
card under "waiting on owner".

## ETA

Velocity is the points done in the last 14 days; the ETA divides the remaining
unblocked milestone points by it. Blocked points are shown separately.
