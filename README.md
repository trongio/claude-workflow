# claude-workflow

![claude-workflow: a manager session, tiered subagents and a task board](docs/images/hero.png)

A Claude Code plugin that turns your session into an engineering manager. It
plans the project, splits each task into briefs, delegates them to tiered
subagents working in their own git worktrees, runs your quality gates, scales
review depth by risk, checks the result in a real browser, and records every
task on a markdown board in your repo.

The bookkeeping is scripted. Branches, worktrees, gate runs, page checks,
outcome records and cleanup are `wf` commands that print a few lines, so the
model spends its tokens on judgment instead of on clicking and reading logs.

> This is a community plugin for [Claude Code](https://docs.claude.com/en/docs/claude-code).
> It is not an Anthropic product and is not endorsed by Anthropic.

## Set it up with one prompt

Open Claude Code in the repo you want to use it in and paste this:

```text
Set up the claude-workflow plugin (github.com/trongio/claude-workflow) in this repo, end to end.
Ask me before anything destructive (deleting, overwriting, force flags) and never push.

1. Install it at project scope with Bash:
   claude plugin marketplace add trongio/claude-workflow --scope project
   claude plugin install workflow@trongio --scope project
   (if the marketplace is already added: claude plugin marketplace update trongio)
2. Check that bun, jq, git and gh are on PATH, plus bash 4 or newer. For each missing tool,
   tell me the install command for this OS and ask before running it.
3. Ask me to type /reload-plugins so the workflow skills load, and wait until I have.
4. If this repo is empty or has no docs/STACK.md and no clear stack, ask me to run
   /workflow:plan-project. Otherwise ask me to run /workflow:init. Answer its questions with me.
5. Run `wf doctor` and fix every failure that is configuration; list the rest for me.
6. Show `wf status` and explain in a few lines what was set up, what I should fill in by hand
   in .claude/workflow.json, and how to start the first task (/workflow:task "<what to build>").
Do not commit unless I ask.
```

Prefer a shell? `curl -fsSL
https://raw.githubusercontent.com/trongio/claude-workflow/main/install.sh |
bash` adds the marketplace and installs the plugin (`bash -s -- --project`
for project scope).

## Why

It comes from two production projects (a multi-tenant SaaS with hardware in
the loop, and a commerce platform) where it ran daily, including unattended
overnight runs. Every rule in the prompts and scripts exists because its
absence once cost a shipped defect or a lost afternoon. A few of them:

- **A scripted page check returns one JSON line** (status, console errors,
  overflow, clipped text, screenshot path) instead of 1,000 to 3,000 tokens
  per browser-automation step. The verifier runs scripts first and opens a
  browser only for what a script cannot judge.
- **Merged is not done.** A fully green merge once shipped two critical bugs
  that a review loop caught only afterwards. Cards now land in `verifying`,
  and reach `done` only with a note on how the change was observed working.
- **Zero overflow is not visual verification.** A layout check passed while a
  label in the widest locale broke mid-word and a sentence clipped inside a
  scrolling cell. Checks run in the locale with the longest strings, and the
  screenshots are opened and looked at.
- **A disabled gate looks exactly like a green one.** A reset git hooks path
  silently switched off every pre-commit check for an unknown period. Now a
  skipped, pending or missing gate reports "not proven", and `wf doctor`
  checks the hooks path.
- **A comment is not a mechanism.** "Kept in sync with X" sat above a copy
  that had already drifted. The reviewer flags such comments and asks for a
  shared import.
- **Scripts beat repetition.** One seven-step integration sequence was typed
  by hand seven times before it became a script. The rule now: the third
  repetition becomes a command.

## The lifecycle

![Card lifecycle from todo to done](docs/images/lifecycle.svg)

```
 wf start      branch wf/<ID> + its own worktree, card -> in-progress
 plan          planner reads the spec and standards -> file map, risk, briefs
 mocks         UX-heavy only: 2-3 HTML mocks, the owner's pick is the spec
 delegate      implementers in parallel, each in a worktree, brief from wf brief
 integrate     merge streams -> wf gates (fast: affected tests only)
 review        IN PARALLEL: reviewer(s) + verifier (wf shots, wf check) + ux-critic
 fix           one merged fix round by a fresh implementer; only the fix diff is re-reviewed
 release       wf gates --release: every gate, uncached; a subset is not green
 outcome       wf outcome writes the record; the model fills the prose
 owner hold    high risk stops in owner-review (wf park)
 wf finish     land per finish.mode (PR by default), card -> verifying, tear down
               the worktree, branch, DB and ports; wf doctor shows no leftovers
 done          wf move <ID> done --verified "how it was observed"
```

Review depth scales with risk. `wf risk` decides it from the diff:

| Level | Covers | Required |
|---|---|---|
| light | copy, docs, styles, config text, test-only | gates + one spot check; no simplify pass |
| standard | normal features and fixes | gates, one reviewer, verifier, ux-critic if the look changed |
| high | auth, money, data migrations, infra, paths in `risk.high` | two independent reviewers at once plus `review.extraAgents.high`, verifier, ux-critic, then the owner |

Fix rounds are capped (`review.maxRounds`, `ux.maxFixRounds`); remaining
minors become cards instead of another round.

## The planning phase

![Planning: stack survey, design directions, standards, gates, first cards](docs/images/planning.svg)

Before the first card, `/workflow:plan-project` (details in
[`skills/plan-project/SKILL.md`](skills/plan-project/SKILL.md)) runs a short
planning phase on an empty or young repo:

1. `wf detect` reads what exists; the researcher surveys candidate stacks with
   versions from `wf versions` (each with its release URL and fetch date,
   never recalled), support windows, ecosystem and hosting cost.
2. The ux-critic proposes two design directions (system, type scale, density,
   colour use, tone) under anti-template rules.
3. The owner decides; the decision is recorded in `docs/STACK.md`, the
   standards in `docs.standards`, and the gates that enforce them in
   `.claude/workflow.json`.
4. `wf plan scaffold` and `wf plan cards` turn the plan into a skeleton and a
   first milestone of cards.

On an existing repo, `/workflow:init` does the setup part only.

## Agents

| Agent | Model | Job |
|---|---|---|
| `planner` | fable | file-level plan, acceptance criteria, risk, self-contained briefs (read-only) |
| `reviewer` | fable | adversarial review with a grade per touched area (read-only) |
| `ux-critic` | fable | design critique of the screenshots; design directions (read-only) |
| `implementer` | opus | one workstream: code, tests, gates, cleanup |
| `researcher` | opus | library internals, external APIs, stack surveys (read-only) |
| `verifier` | opus | scripted page checks first, browser second, at every viewport |
| `mechanic` | sonnet | multi-step mechanical edits (never a single command) |
| `scout` | haiku | "where is X" lookups (read-only) |

`fable` is the strongest model alias; without access to it, set `models` in
`.claude/workflow.json` (for example `{"planner": "opus"}`) or override the
agent in `.claude/agents/`.

## Commands

Skills (type them in Claude Code):

| Skill | What it does |
|---|---|
| `/workflow:plan-project` | stack decision, standards and gates before any card |
| `/workflow:init` | set up an existing repo: config, board, CLAUDE.md section, doctor |
| `/workflow:task <ID or text>` | one task through the whole lifecycle |
| `/workflow:next [n or drain]` | claim cards and run each independently in the background |
| `/workflow:gates [--release]` | run the gates and print the table |
| `/workflow:board [serve]` | board summary, or the live board page |

`wf` (on Claude's Bash PATH while the plugin is enabled; for your own shell,
`ln -s ~/.claude/plugins/cache/trongio/workflow/*/bin/wf ~/.local/bin/wf`):

| Area | Commands |
|---|---|
| Cards | `wf new`, `wf list`, `wf next`, `wf claim`, `wf show`, `wf move ID STATUS [--verified "how"]`, `wf note`, `wf park ID "owner: ..."`, `wf prio`, `wf status`, `wf board` |
| Task lifecycle | `wf start ID`, `wf plan-save ID FILE`, `wf brief ID --stream N`, `wf risk [BASE]`, `wf outcome ID [--tick 1,2]`, `wf finish ID`, `wf cards-commit -m "msg"`, `wf handoff` |
| Gates | `wf gates [--release] [--json] [--last] [--fix]`, `wf gate-log [GATE]`, `wf test-affected [BASE]` |
| Health | `wf doctor`, `wf orphans [--kill]`, `wf prune [--apply]`, `wf fix-sweep [--since DATE]` |
| Verification | `wf check URL... [--viewports] [--locale] [--expect TEXT]`, `wf shots ID [paths]`, `wf flow FILE.json`, `wf preview up or down ID` |
| Search and text | `wf rgx PATTERN [PATH]`, `wf outline FILE`, `wf doc FILE [section]`, `wf review-diff [BASE]`, `wf lang get or set or missing` |
| Planning | `wf detect [--json]`, `wf versions PKG... or --check docs/STACK.md`, `wf plan set or scaffold or cards` |
| Overnight | `wf queue N`, `wf run`, `wf night N` (stop with `touch .workflow/STOP`) |

Every command has `--help`; `wf help` lists them all.

## Configuration

`.claude/workflow.json`. A full example is
[`workflow.example.json`](workflow.example.json); every key is described in
[`schema/workflow.schema.json`](schema/workflow.schema.json).

| Key | Default | Meaning |
|---|---|---|
| `idPrefix`, `baseBranch`, `wipLimit`, `timezone` | repo initials, origin HEAD, 2, system | card ids, landing target, max active cards, card dates |
| `push` | false | whether finishing a task pushes |
| `gates[]` | detected | `{name, cmd, when, fix, cache, cwd, timeout, pending, release, rerun, heavy}` |
| `gatesJobs`, `gatesCacheKeys` | CPU/2, 8 | heavy gates at once; cache entries per gate so parallel worktrees do not evict each other |
| `release.cmd` | all release gates | the full CI command that authorizes landing |
| `testAffected` | | map from source globs to tests for the inner loop |
| `worktree.copy`, `cache`, `setup`, `env`, `pool` | detected | make each worktree runnable: files to copy, copy-on-write build caches, setup commands, per-worktree env (`{id}`, `{slug}`, `{port}`), warm pool |
| `worktree.teardown` | [] | commands run when a worktree is removed, same placeholders, e.g. `dropdb --if-exists app_{slug}` |
| `finish` | `pr`, squash, no auto merge, cleanup | how `wf finish` lands a task |
| `tracker` | none | mirror cards to GitHub issues; `onMerge` runs on landing |
| `planner.skipFor` | `["S"]` | sizes that skip the planner |
| `review` | 1 pass, 3 rounds, owner hold on high | review depth, round cap, extra agents per risk |
| `ui`, `dev.*` | detected | the local dev app, login hints (where credentials live, never the secret), viewports |
| `ux` | | locales, the widest locale, UX fix round cap |
| `docs.spec`, `docs.standards`, `docs.design` | [] | ground truth for planner, every agent, the critic |
| `risk.high` | [] | paths that make a diff high risk |
| `models` | | model per agent role |
| `overnight` | 2 parallel, auto permission mode | the unattended runner; `exclude` tags it never picks |

## Safety defaults

- **PR mode.** `finish.mode` is `pr`: the task branch is pushed only when you
  allow pushing, and the main checkout is never checked out or merged into, so
  a served dev app and other sessions keep running.
- **Push off.** `push` defaults to false. Pushing is an explicit project
  choice.
- **Auto permission mode overnight.** The runner passes `--permission-mode
  auto`, not `--dangerously-skip-permissions`, and skips cards tagged
  `migration`, `deploy` or `hardware` (`overnight.exclude`).
- **High risk waits for you.** Auth, money, migrations and infra stop in
  `owner-review` before landing.
- **Read-only agents stay read-only.** Planner, reviewer, scout and
  researcher have no edit tools; verifier and ux-critic cannot edit files.
  None of them may check out, stash or reset in any checkout.
- **Nothing left behind.** `wf finish` tears down the worktree, branch, test
  database and ports; `wf doctor` reports leftovers, `wf prune` and `wf
  orphans` remove them.

## FAQ

**Does it work without a UI?** Yes. Set `ui` to false; the verifier uses the
nearest real surface (CLI, HTTP API, a read-back script) and the ux-critic
skips.

**My project has its own reviewer prompt.** Put it in
`.claude/agents/reviewer.md`. Project agents win over the plugin's.

**Is it slow?** The inner loop runs only changed gates and affected tests,
caches by content hash, and runs review, verification and critique in
parallel. The full suite runs once, at `wf gates --release`.

**Does it need GitHub?** No. `tracker.kind` defaults to none and
`finish.mode` can be `merge` for a solo repo nobody serves from.

**What if a session dies mid-task?** Implementers commit each finished step.
`wf handoff` writes a snapshot (branch, cards in flight, unpushed commits,
live worktrees) that a fresh session resumes from.

**Can I run it overnight?** `wf night 8` queues eight claimable cards and runs
them headless in their own worktrees. Owner decisions are parked, not
guessed. Queue only cards you would approve wholesale.

## Update and uninstall

```bash
claude plugin marketplace update trongio
claude plugin update workflow@trongio
claude plugin uninstall workflow@trongio
claude plugin marketplace remove trongio
```

Uninstalling leaves your `tasks/`, `.claude/workflow.json` and CLAUDE.md alone.

## Development

```bash
tests/smoke.sh          # manifests, card CLI, board, gates, worktrees, lint, timings
claude plugin validate .
```

Shell scripts are kept `shellcheck` clean and `shfmt -i 4` formatted.

## License

MIT, see [LICENSE](LICENSE).
