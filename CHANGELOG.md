# Changelog

## 0.2.0 (2026-11-26)

Lessons from a second production project built in, a planning phase before
any card, and the deterministic parts of the loop moved into scripts.

### Lifecycle
- `wf start` creates the task branch and its own worktree (0.1 never created
  the task branch, so two tasks could share one checkout). `wf finish` lands
  per `finish.mode` (PR by default), runs `tracker.onMerge`, tears down the
  worktree, branch, DB and ports (`worktree.teardown`). PR mode needs
  `push: true` and parks the card in `owner-review` until the PR merges; a
  second `wf finish ID` after the merge moves it to `verifying` and deletes
  the branch. Teardown aborts rather than lose uncommitted work.
- High-risk cards without owner approval park in `owner-review` in every
  finish mode (`review.ownerHoldHigh`). `wf risk` has built-in high patterns
  when `risk.high` is unset; `wf risk --explain`.
- New status `verifying` between landing and `done`; `wf move ID done
  --verified "how"` closes a card. Merged is not done.
- `wf outcome` writes the record skeleton (gate table, diffstat, commits,
  risk); the model fills prose only. `wf risk`, `wf note`, `wf park`,
  `wf status`, `wf handoff`, `wf brief`, `wf plan-save`, `wf fix-sweep`;
  `wf cards-commit -m`.
- Task skill: review, verification and UX critique run in parallel after
  integration; one merged fix round by a fresh implementer; only the fix diff
  is re-reviewed; rounds capped by `review.maxRounds`, the tail becomes cards.
  High risk runs two independent reviewers at once plus `review.extraAgents`
  and holds for the owner. Simplify is skipped for light risk.
- `/workflow:next` advances every card independently with background agents.

### Planning
- `/workflow:plan-project`: stack survey (versions from `wf versions`, never
  recalled), two design directions, standards and gates before the first
  card. `wf detect`, `wf versions`, `wf plan`.

### Gates and health
- `wf gates --release` (the only landing gate; a subset is not green, skipped
  or pending is not proven, a missing tool is red), `--json`, `--last`;
  per-gate `cwd`, `timeout`, `pending`, `release`, `rerun`, `heavy`;
  `gatesJobs`, `gatesCacheKeys`, `release.cmd`, `testAffected`.
- `wf gate-log`, `wf doctor`, `wf orphans` (`--kill ID|DIR` scoped, `--all`),
  `wf prune` (`--apply [ID]`, only `.workflow/worktrees` and ledger
  entries), `wf test-affected`, `wf preview`.

### Verification and search
- `wf check` (one JSON line per page and viewport), `wf shots`, `wf flow`,
  `wf rgx`, `wf lang`. Checks run in `ux.widestLocale` at `dev.viewports`
  (default 375 and 1440).

### Agents
- Planner: exact file lists, required extractions up front, guard rules
  first, "why did no gate catch this", backfill plans, short streams.
- Implementer: gate table or "not run", asserted scripted edits, commit per
  step, locks instead of `pgrep` loops, cleanup of servers, DBs and scratch.
- Reviewer: grade table per touched area, fix diffs reviewed on their own,
  15 defect classes that shipped past green gates, never touches a checkout.
- Verifier: scripts first, look at the pixels, outcome and recovery path,
  served-bundle check. UX critic: scope to the card, empty and pending
  states, disabled reasons, verb collisions across locales, direction mode.
- Researcher: stack survey format. Mechanic: multi-step edits only.
- Read-only agents restricted by `tools` or `disallowedTools`.

### Defaults changed
- `push` defaults to false; `finish.mode` defaults to `pr`, which refuses to
  run until `push` is true (`merge` and `none` never push).
- `dev.viewports` defaults to `[375, 1440]`.
- Overnight runner uses `--permission-mode auto` and skips
  `overnight.exclude` tags (migration, deploy, hardware).

## 0.1.0 (2026-10-14)

First public release, extracted from a production web project where it
ran daily.

- Plugin + marketplace in one repo (`workflow@trongio`).
- Eight agents on model tiers: planner, reviewer, ux-critic (fable);
  implementer, researcher, verifier (opus); mechanic (sonnet); scout (haiku).
- Skills: `/workflow:init`, `/workflow:task`, `/workflow:next`,
  `/workflow:gates`, `/workflow:board`.
- `wf` CLI (Bun): markdown card board with WIP limit, dependencies, priorities,
  milestone progress, velocity and ETA; live board page.
- `wf gates`: parallel gates from `.claude/workflow.json` with `when` globs,
  content-hash cache and failure tails.
- Worktree helpers (`wf wt-init`, `wf merge` with a repo-wide lock),
  `wf review-diff`, `wf outline`, `wf doc`.
- Overnight runner (`wf night`): parallel headless `/workflow:task` runs in
  worktrees with usage-limit waits, resume on retry and a STOP file.
