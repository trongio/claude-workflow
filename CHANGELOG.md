# Changelog

## 0.1.0 (2026-10-14)

First public release, extracted from a production e-commerce project where it
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
