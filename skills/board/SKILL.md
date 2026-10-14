---
name: board
description: Show the task board - start the live board server (milestone progress, ETA, blocked cards, waiting on owner) or print the board stats in the terminal. Invoke as /workflow:board [stats|serve].
argument-hint: "[stats | serve]"
---
`wf` is on the Bash PATH while the plugin is enabled, otherwise
`${CLAUDE_PLUGIN_ROOT}/bin/wf`. Argument: $ARGUMENTS

- `stats` or no argument: run `wf stats` and `wf list`, and print them as-is.
- `serve`: start `wf board` in the background (Bash `run_in_background`), then
  tell the user the URL it prints (default http://127.0.0.1:8090; port from
  `board.port` in `.claude/workflow.json` or `--port N`). It updates live as
  card files and git refs change.

Card commands for reference: `wf list [status] [--milestone]`, `wf next [n]`,
`wf claim [n|ID]`, `wf move <ID> <status> [--branch b] [--blocked "text"]`,
`wf new "<title>" [--size M] [--area x] [--milestone] [--depends A-1,A-2]`,
`wf prio <ID> <n>`, `wf show <ID>`, `wf stats`, `wf queue [n]`.
