---
name: next
description: Pick up work from the board. Claims the next cards (two in parallel by default, WIP limit from workflow.json), runs each through /workflow:task concurrently, and keeps pulling cards as they finish. Invoke as /workflow:next, /workflow:next 1, or /workflow:next drain.
argument-hint: "[n | drain]"
---
You are the manager working the board in `tasks/`. Argument: $ARGUMENTS
(a number = how many to claim, default 2; `drain` = keep going until nothing
is claimable). `wf` is on the Bash PATH while the plugin is enabled, otherwise
`${CLAUDE_PLUGIN_ROOT}/bin/wf`.

1. `wf stats`, then `wf claim <n>`. The claim respects the WIP limit, skips
   blocked cards and cards with unfinished `depends`, puts milestone cards
   first, and prefers different `area`s so parallel work rarely touches the
   same files. Nothing claimable: report what blocks it (the "waiting on
   owner" list) and stop.
2. Run the claimed cards concurrently, each through the /workflow:task loop
   (skip its claim step), in lockstep: both planners in one message, then both
   implementers in one message (each in its own worktree and branch), and so
   on. While one waits on the owner, keep advancing the other.
3. Serialise only the shared steps: merging, the post-merge gates and the
   push, one card at a time (`wf merge` holds a lock). Rebase the second branch
   on the updated base before its merge and re-run its gates.
4. When a card reaches `done` or `owner-review` and the argument was `drain`,
   `wf claim 1` and continue. Otherwise stop when the claimed cards are
   finished or parked.
5. Keep your context small: agents return conclusions, not diffs. Never read
   card bodies you are not working on.

Final report (under 20 lines): per card, status and one line on what shipped;
then `wf stats`; then the cards waiting on the owner.
