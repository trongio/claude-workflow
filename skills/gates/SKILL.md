---
name: gates
description: Run the quality gates configured in .claude/workflow.json - the fast affected-only inner loop (wf gates) or the full release gate that authorizes landing (wf gates --release) - and report the compact pass/fail table. Use before every review, commit, and before a task lands.
argument-hint: "[--release] [--all] [--only a,b] [--fix] [--no-cache] [--base REF] [--last]"
---
Run once, from the repo root or any worktree (`wf` is on the Bash PATH while
the plugin is enabled, otherwise `${CLAUDE_PLUGIN_ROOT}/bin/wf`):

```bash
wf gates $ARGUMENTS
```

Two modes:

- `wf gates` is the inner loop. Gates whose `when` globs match no changed file
  are skipped, gates whose inputs match a recent PASS report `cached`, tests
  run for affected files only, the rest run in parallel (heavy gates capped by
  `gatesJobs`). Fast, and never proof that the change can land.
- `wf gates --release` is the full gate: every gate with `release` not false,
  uncached, or the project's `release.cmd`. Only this table authorizes
  `wf finish`.

Reading the table:
- A subset of gates is not green. `wf gates` passing says nothing about the
  gates it skipped.
- `skipped`, `pending` and `cached` from another tree mean not proven, never
  green. A missing tool is red, not a skip.
- `TIMEOUT` is red. A gate with a `rerun` rule may rerun once on its known
  flake signature; the table names the rerun, and a second failure is real.

On red, `wf gate-log [GATE]` prints the first failing test names and 20 lines
of context. Use it instead of reading the log. `wf gates --last` reprints the
previous table when nothing changed. `--fix` runs each gate's `fix` command
(formatters) first; `--json` for scripts.

Paste the table as-is. Never type gate commands by hand, and never "fix" a red
gate with an ignore, a baseline entry or a skipped test. To add or change a
gate, edit `gates` in `.claude/workflow.json` (`wf gates --list` shows what
would run, `wf doctor` checks the tools exist).
