---
name: init
description: Bootstrap an existing repo for the workflow - detect the stack, write .claude/workflow.json with prefilled gates, create tasks/ with its README, add a Workflow section to CLAUDE.md, pick safe finish settings and run wf doctor. Safe to re-run. For an empty repo use /workflow:plan-project first. Invoke as /workflow:init.
argument-hint: "[--force]"
disable-model-invocation: true
---
Bootstrap this repo for the workflow plugin. `wf` is on the Bash PATH while
the plugin is enabled, otherwise `${CLAUDE_PLUGIN_ROOT}/bin/wf`. Arguments:
$ARGUMENTS

1. `wf detect`. On an empty repo, or one with no `docs/STACK.md` and no clear
   stack, stop and suggest `/workflow:plan-project` first (see
   `${CLAUDE_PLUGIN_ROOT}/skills/plan-project/SKILL.md`): it decides the
   stack, the standards and the gates before any card exists. Continue only
   if the owner says to.
2. `wf init --write $ARGUMENTS`. It creates `tasks/`, `tasks/archive/`,
   `tasks/README.md`, `.claude/workflow.json` (kept if it exists unless
   `--force`) and a `.gitignore` entry for `.workflow/`.
3. Review `.claude/workflow.json` against the repo (field reference:
   `${CLAUDE_PLUGIN_ROOT}/workflow.example.json`, schema:
   `${CLAUDE_PLUGIN_ROOT}/schema/workflow.schema.json`):
   - gates: prefer the project's own commands (a `just` or `make` recipe, CI
     steps), keep `when` globs tight, add `fix` for formatters, `cwd` per
     package in a monorepo, `heavy` on tests, builds and type checks. Set
     `release.cmd` when the project has one full CI command. Fill
     `testAffected` when the test layout maps from source names.
   - `ui`, `dev.url`, `dev.login`, `dev.viewports`, `ux.locales`,
     `ux.widestLocale`: from the README, `.env.example`, seeders, compose
     files, locale folders. Login hints say where dev credentials live, never
     the secret.
   - `docs.spec`, `docs.standards`, `docs.design`, `milestone.label`.
   - `worktree.copy`, `worktree.cache`, `worktree.env` (per-worktree DB names
     and ports) and the matching `worktree.teardown` (for example
     `dropdb --if-exists app_{slug}`), so every worktree is runnable and
     leaves nothing behind.
   - `finish.mode` and `push`, asked as one question: `pr` (the default)
     when the main checkout is served by a dev server, or other Claude
     sessions or people work in it (check `ps` for other `claude` processes
     and running dev servers whose cwd is the repo). `pr` needs `push: true`,
     `gh` and a remote; with `push` false, `wf finish` refuses. `merge` (never
     pushes) only for a solo repo nobody serves from. Set `push` true only
     when the owner chooses `pr`.
   - `risk.high`: leave unset to use `wf risk`'s built-in high patterns
     (migrations, auth, billing/payment, security, infra/deploy, CI
     workflows, Dockerfile, `*.sql`), or list the project's own paths;
     `wf risk --explain` shows what matched.
4. Hooks: `git config core.hooksPath`. If the repo has hooks in a tracked
   folder (`.husky/`, `.githooks/`, `.claude/hooks/`) and `core.hooksPath`
   does not point there, say so and offer the fix; a reset hooks path silently
   disables every pre-commit check.
5. `wf gates --list`, then `wf gates --all` once and report the table; fix
   only config mistakes, not the project's failing code. Mark gates whose tool
   is not installed yet as `pending`.
6. CLAUDE.md: create it if missing (a short project summary: stack, how to
   run, conventions you can see). If it has no `## Workflow` section, append
   `${CLAUDE_PLUGIN_ROOT}/templates/claude-md-section.md` verbatim.
7. If a justfile exists and has no such recipes, offer (do not force) `task
   *args:` -> `@wf {{args}}`, `board:` -> `@wf board`, `gates *args:` ->
   `@wf gates {{args}}`, `night n="8":` -> `@wf night {{n}}`; `wf` must be on
   the shell PATH for `just` (symlink `${CLAUDE_PLUGIN_ROOT}/bin/wf` into
   `~/.local/bin`).
8. `wf doctor` (prints only failures) and fix what is config.
9. Create a first card if the user named a task: `wf new "<title>" --size M
   --area <area>`.

Report in under 12 lines: what was created, the detected gates and their first
result, `finish.mode` and why, the `wf doctor` result, what the user should
fill in by hand, and the next step (`/workflow:task <ID>` or
`/workflow:next`). Do not commit unless asked.
