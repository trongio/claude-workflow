---
name: board
description: Show the task board - start the live board server (milestone progress, ETA, blocked cards, waiting on owner) or print the board summary in the terminal. Invoke as /workflow:board [stats|serve].
argument-hint: "[stats | serve]"
---
`wf` is on the Bash PATH while the plugin is enabled, otherwise
`${CLAUDE_PLUGIN_ROOT}/bin/wf`. Argument: $ARGUMENTS

- `stats` or no argument: run `wf status` (stats, in flight, waiting on owner,
  at most 25 lines) and print it as-is.
- `serve`: start `wf board` in the background (Bash `run_in_background`), then
  tell the user the URL it prints (default http://127.0.0.1:8095; port from
  `board.port` in `.claude/workflow.json` or `--port N`). It updates live as
  card files and git refs change.

Card commands for reference: `wf list [status] [--milestone]`, `wf next [n]`,
`wf claim [n|ID]`, `wf start <ID>`, `wf move <ID> <status> [--blocked
"text"] [--verified "how"]`, `wf note <ID> "text"`, `wf park <ID> "owner:
question"`, `wf new "<title>" [--size M] [--area x] [--milestone] [--depends
A-1,A-2]`, `wf prio <ID> <n>`, `wf show <ID>`, `wf status`, `wf queue [n]`,
`wf handoff`.
