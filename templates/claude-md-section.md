## Workflow

This repo runs the `workflow` Claude Code plugin: a manager session plans and
delegates to tiered subagents (planner, reviewer, ux-critic on the strongest
model; implementer, researcher, verifier on opus; mechanic on sonnet; scout on
haiku). Config: `.claude/workflow.json`.

- Work queue: `tasks/` (format in `tasks/README.md`), driven only by `wf`
  (`wf list|claim|start|move|note|park|show|status`, `wf board` for the live
  board). Statuses end `verifying -> done`: merged is not done.
- One task end to end: `/workflow:task <ID | description>`; work the board:
  `/workflow:next`, `/workflow:next drain`.
- Gates: `wf gates` is the fast inner loop, `wf gates --release` the only
  gate that authorizes landing. Paste the table, never type gate commands by
  hand. Skipped, pending or a missing tool is not proven.
- Precedence when rules disagree: the docs in `docs.standards` > this file >
  skills > framework defaults.
- Single home per rule: each rule lives in exactly one place; others link to
  it. A copied rule drifts.
- The third time a sequence repeats, it becomes a script (or `wf` command) and
  gets a line here.
- The main checkout is shared and may be served: never `checkout`, `stash`,
  `reset` or `switch` there. Work in the task worktree (`wf start`).
- Landing: `finish.mode` `pr` needs `push: true` and parks the card in
  `owner-review` until the PR merges, then `wf finish <ID>` again; `merge`
  and `none` never push. High risk without owner approval parks in every mode.
- Leave nothing behind: every worktree, DB, port and process you create is
  torn down when the card lands or is abandoned (`wf finish` does it via
  `worktree.teardown`; `wf prune --apply <ID>` for an abandoned card,
  `wf orphans --kill <ID>` for its servers). `wf doctor` shows what is left.
- Before clearing a session or stopping work: `wf handoff`, so the next
  session resumes from `.workflow/HANDOFF.md` with nothing lost.
- Token discipline: `wf rgx`, `wf outline FILE`, `wf doc FILE [section]` and
  `wf check URL` instead of reading whole files, whole logs (`wf gate-log`) or
  clicking through a browser MCP. Anything unbounded goes through `head`.
- Reuse before create; review depth scales with risk (`wf risk`).
