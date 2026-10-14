---
name: gates
description: Run every quality gate configured in .claude/workflow.json for the current change set, in parallel, and report a compact pass/fail table with only the failing output. Use before every review, commit, and at the end of every task.
argument-hint: "[--all] [--only a,b] [--fix] [--no-cache] [--base REF]"
---
Run once, from the repo root or any worktree (`wf` is on the Bash PATH while
the plugin is enabled, otherwise `${CLAUDE_PLUGIN_ROOT}/bin/wf`):

```bash
wf gates $ARGUMENTS
```

Gates whose `when` globs match no changed file are skipped, gates whose inputs
match their last PASS report `cached`, the rest run in parallel. Only the tail
of each failing gate is printed. `--fix` runs each gate's `fix` command
(formatters) first; `--all` ignores `when`; `--no-cache` forces a rerun.

Paste the table as-is. Never type the gate commands by hand. To add or change
a gate, edit `gates` in `.claude/workflow.json` (`wf gates --list` shows what
would run). Prefer delegating gate runs to the `mechanic` agent.
