---
name: next
description: Pick up work from the board. Claims the next cards (WIP limit from workflow.json), runs each through /workflow:task with background agents so every card advances independently, and keeps pulling cards as they finish. Invoke as /workflow:next, /workflow:next 1, or /workflow:next drain.
argument-hint: "[n | drain]"
---
You are the manager working the board in `tasks/`. Argument: $ARGUMENTS
(a number = how many to claim, default `wipLimit`; `drain` = keep going until
nothing is claimable). `wf` is on the Bash PATH while the plugin is enabled,
otherwise `${CLAUDE_PLUGIN_ROOT}/bin/wf`. Run `wf` commands yourself; never
spawn an agent for one command. When you spawn any agent and
`.claude/workflow.json` sets `models.<role>` for it, pass `model: <that value>`
on the Agent call. Gates, outcome and cleanup follow the /workflow:task rules:
you and implementers run `wf gates`, reviewers never do; `wf outcome` plus
your prose is the record.

1. `wf status` (stats, in flight, waiting on owner), then `wf claim <n>`. The
   claim respects `wipLimit`, skips blocked cards, cards with unfinished
   `depends` and cards tagged with `overnight.exclude` tags in headless runs,
   puts milestone cards first, and prefers different `area`s so parallel work
   rarely touches the same files. Nothing claimable: report what blocks it and
   stop.
2. Run every claimed card through the /workflow:task loop (its `wf start`
   makes the card's own branch and worktree). Each card advances
   independently: start its agents in the background and move that card to
   its next step as soon as its own agents report. Never wait for one card's
   reviewer before starting another card's implementer; there is no lockstep.
3. Only landing is serialised: `wf finish` holds the repo lock. Before a
   card lands after another one, rebase its branch on the updated base;
   `wf finish` then reruns `wf gates --release` for the new tip itself.
4. When a card lands in `verifying` or parks in `owner-review` (a decision,
   a high-risk hold, or in `pr` mode a PR waiting to merge) and the argument
   was `drain`, `wf claim 1` and continue. Otherwise stop when the claimed
   cards are landed or parked. A parked PR card returns to the loop only
   when you run `wf finish <ID>` again after its PR merged.
5. A card that fails or is abandoned is cleaned up like a landed one: park or
   move it, then `wf prune --apply <ID>` for its worktree, DB and ports, and
   `wf orphans --kill <ID>` for servers its agents left.
6. Keep your context small: agents return conclusions, not diffs. Never read
   card bodies you are not working on.

Before the final report run `wf doctor`; it must show no leftovers.

Final report (under 20 lines): per card, status and one line on what shipped;
then `wf status`; then the cards waiting on the owner; then the `wf doctor`
result.
