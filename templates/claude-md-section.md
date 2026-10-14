## Workflow

This repo runs the `workflow` Claude Code plugin: a manager session plans and
delegates to tiered subagents (planner, reviewer, ux-critic on the strongest
model; implementer, researcher, verifier on opus; mechanic on sonnet; scout on
haiku).

- Work queue: `tasks/` (format in `tasks/README.md`), driven only by `wf`
  (`wf list|next|claim|move|new|show|stats`, `wf board` for the live board).
- One task end to end: `/workflow:task <ID | description>`; work the board:
  `/workflow:next` (two cards in parallel), `/workflow:next drain`.
- Quality gates: `wf gates` (config in `.claude/workflow.json`). Run them before
  every review and commit; paste the table, never type gate commands by hand.
- Review depth scales with risk (light, standard, high); see the task skill.
- Cheap lookups first: `rg`/`fd`/`ast-grep` before reading, `wf outline FILE`
  before reading a file whole, anything unbounded through `head`/`tail`.
- Simplify always: every task ends with a `/simplify` pass on its diff.
- Reuse before create; when a procedure repeats, make it a script or skill.
- Project facts for agents (dev URL, login hints, design docs, high-risk paths)
  live in `.claude/workflow.json`.
