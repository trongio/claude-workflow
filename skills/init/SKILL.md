---
name: init
description: Bootstrap the current repo for the workflow - create tasks/ with its README, detect the stack and write .claude/workflow.json with prefilled gates, and add a Workflow section to CLAUDE.md. Safe to re-run. Invoke as /workflow:init.
argument-hint: "[--force]"
disable-model-invocation: true
---
Bootstrap this repo for the workflow plugin. `wf` is on the Bash PATH while
the plugin is enabled, otherwise `${CLAUDE_PLUGIN_ROOT}/bin/wf`. Arguments:
$ARGUMENTS

1. `wf init --write $ARGUMENTS`. It creates `tasks/`, `tasks/archive/`,
   `tasks/README.md`, `.claude/workflow.json` (kept if it exists unless
   `--force`) and a `.gitignore` entry for `.workflow/`, and prints the
   detected stack, gates and `just` recipes.
2. Review `.claude/workflow.json` against the repo (field reference:
   `${CLAUDE_PLUGIN_ROOT}/workflow.example.json`):
   - gates: prefer the project's own commands where they exist (a `just test`
     or `make check` recipe, CI steps in `.github/workflows/`), keep `when`
     globs tight so unrelated changes skip slow gates, add `fix` for
     formatters. Run `wf gates --list`, then `wf gates --all` once and report
     the table; fix only config mistakes, not the project's failing code.
   - `ui`, `dev.url`, `dev.login`, `dev.viewports`: fill from the README,
     `.env.example`, seeders or docker compose files. Write login hints as
     where to find dev credentials, never the secret itself.
   - `docs.design`, `risk.high` (paths like `migrations/`, `auth/`,
     `payments/`, `deploy/`), `milestone.label`.
3. CLAUDE.md: create it if missing (a short project summary: stack, how to
   run, conventions you can see). If it has no `## Workflow` section, append
   `${CLAUDE_PLUGIN_ROOT}/templates/claude-md-section.md` verbatim.
4. If a justfile exists and has no such recipes, offer (do not force) these:
   `task *args:` -> `@wf {{args}}`, `board:` -> `@wf board`, `gates *args:` ->
   `@wf gates {{args}}`, `night n="8":` -> `@wf night {{n}}`; note that `wf`
   must be on the shell PATH for `just` (symlink `${CLAUDE_PLUGIN_ROOT}/bin/wf`
   into `~/.local/bin`).
5. Create a first card if the user named a task:
   `wf new "<title>" --size M --area <area>`.

Report in under 12 lines: what was created, the detected gates and their first
result, what the user should fill in by hand, and the next step
(`/workflow:task <ID>` or `/workflow:next`). Do not commit unless asked.
