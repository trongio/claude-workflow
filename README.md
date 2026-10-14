# claude-workflow

A Claude Code plugin that turns your session into a **manager** that plans,
delegates to **tiered subagents**, runs your **quality gates**, scales
**review depth by risk**, verifies the result **in a browser**, and records
every task on a **markdown task board** in your repo.

It was extracted from a production e-commerce project where it shipped
hundreds of tasks, including unattended overnight runs. The repo is a
plugin and its own marketplace, so it installs with one line.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/trongio/claude-workflow/main/install.sh | bash
```

Or by hand, inside Claude Code or a shell:

```bash
claude plugin marketplace add trongio/claude-workflow
claude plugin install workflow@trongio                 # user scope (all repos)
claude plugin install workflow@trongio --scope project # this repo only, shared via .claude/settings.json
```

Add `--project` to the curl line (`... | bash -s -- --project`) for project
scope. Requirements: Claude Code, `git`, `jq`, [Bun](https://bun.sh) (the card
CLI and board), bash 4+ (macOS: `brew install bash`). Optional: `rg`, `fd`,
`ast-grep`, a Playwright MCP server for the verifier, `hyperfine` for the
smoke benchmarks.

Then, in the repo you want to run it in:

```
/workflow:init
```

It creates `tasks/`, detects your stack (package.json, bun.lock, composer.json,
pyproject.toml, go.mod, Cargo.toml, justfile) and writes `.claude/workflow.json`
with gate commands prefilled, then adds a short Workflow section to CLAUDE.md.

## Use

```
/workflow:task "Add CSV export to the orders page"   # one task, end to end
/workflow:task APP-12                                 # an existing card
/workflow:next                                        # claim 2 cards, run them in parallel
/workflow:next 1 | /workflow:next drain               # one card | until the board is empty
/workflow:gates                                       # run the gates now
/workflow:board serve                                 # live board on http://127.0.0.1:8090
```

From a shell (`wf` is on Claude's Bash PATH automatically; symlink
`~/.claude/plugins/cache/trongio/workflow/<version>/bin/wf` into `~/.local/bin`
for your own shell):

```bash
wf new "Export orders as CSV" --size M --area backend --milestone
wf list                # active cards
wf next                # what would be claimed next
wf claim 2             # claim two cards (WIP limit applies)
wf move APP-12 code-review
wf show APP-12
wf stats               # milestone progress, velocity, ETA, waiting on owner
wf board               # live board
wf gates [--fix]       # parallel gates
wf night 8             # queue 8 cards and run them unattended (see below)
```

## The loop

```
 owner: "build X"  or  a card in tasks/
        |
  1 intake     claim or create the card ............ wf claim / wf new
  2 plan       planner (+ researcher) -> file map, acceptance, risk level, workstreams
  3 mocks      UX-heavy only: 2-3 HTML mocks -> owner-review, owner picks
  4 delegate   one implementer per workstream, own worktree + branch, self-contained brief
  5 integrate  wf merge each branch -> card to code-review -> wf gates (mechanic)
  6 simplify   /simplify on the integrated diff -> wf gates
  7 review     reviewer x0 / x1 / x2 by risk -> fixes -> wf gates
  8 verify     card to ux-review -> verifier in the browser at each viewport
     critique  ux-critic on the screenshots when the look changed -> fixes
  9 record     ## Outcome on the card: shipped, risk, decisions, results, gates
 10 finish     merge + push + done, or owner-review for high risk and sign-offs
```

The manager writes code only for trivial one-file edits. Everything else goes
to an agent with a self-contained brief, so the manager's context holds
conclusions instead of file dumps.

### Risk levels

| Level | Covers | Required before done |
|---|---|---|
| light | copy, docs, styles, config text, test-only changes, card edits | gates + one spot check of the touched screen (none for docs/tests) |
| standard | normal features and bug fixes | gates, one reviewer, verifier, ux-critic if the look changed |
| high | money, auth and permissions, migrations that alter or drop data, infra and deploy, paths in `risk.high` | gates, two independent reviewers (the second re-examines the first), verifier, ux-critic if the look changed, then owner-review |

The highest-risk file in the diff sets the level; otherwise the manager takes
the cheapest level the diff allows.

### Agents and tiers

| Agent | Model | Job |
|---|---|---|
| `planner` | fable | file-level plan, acceptance criteria, risk level, workstream briefs (read-only) |
| `reviewer` | fable | adversarial review of the diff (read-only) |
| `ux-critic` | fable | design and usability critique of the screenshots (read-only) |
| `implementer` | opus | one workstream: code, tests, gates |
| `researcher` | opus | library internals, external APIs, sourced answers (read-only) |
| `verifier` | opus | drives the dev app at each viewport, reports what rendered |
| `mechanic` | sonnet | gate runs, formatter fixes, card moves, Outcome entries |
| `scout` | haiku | "where is X" lookups (read-only) |

Rule of thumb: pick the cheapest tier whose failure mode is acceptable. In a
session they appear as `workflow:planner`, `workflow:reviewer`, and so on.
`fable` is the strongest model alias; if your account has no access to it,
override those three agents (below) with `model: opus`.

## Task board

One markdown file per card in `tasks/` (done cards move to `tasks/archive/`).
Front matter: `id, title, status, milestone, size, area, priority, blocked,
depends, created, started, done, branch, links`; body: `## Goal`,
`## Acceptance` (checkboxes), `## Notes`, `## Outcome`. The full format is in
the `tasks/README.md` that `/workflow:init` writes.

Statuses: `backlog, todo, in-progress, code-review, ux-review, owner-review,
done`. `wf claim` respects the WIP limit (default 2), skips blocked cards and
cards with unfinished `depends`, puts milestone cards first and prefers
different areas so parallel work rarely collides. A `blocked` value starting
with `owner` lists the card under "waiting on owner".

The board page shows milestone progress by points (S=1, M=2, L=4, XL=8), an ETA
from 14-day velocity (blocked points excluded), who is blocked, recent commits,
and updates live. Cards always resolve to the **main checkout**, so every
worktree sees and edits the same board; `wf cards-commit "<msg>"` commits card
changes under the same lock `wf merge` uses.

## Gates

```json
"gates": [
  { "name": "test", "cmd": "bun run test", "when": ["src/", "tests/"] },
  { "name": "lint", "cmd": "bun run lint", "when": ["*.ts"], "fix": "bun run lint --fix" }
]
```

`wf gates` runs every selected gate in parallel and prints `gate | result | sec
| note`, plus the last 30 lines of each failure. A gate whose `when` globs
match no changed file (against the merge base, plus uncommitted and untracked
files) is skipped. A gate whose inputs (the content of its `when` paths, or the
whole tree) and command match its last PASS reports `cached` (stored in
`.git/workflow-gates-cache`; `--no-cache`, `"cache": false` or
`"gatesCache": false` to turn it off). Flags: `--all`, `--only a,b`, `--fix`,
`--base REF`, `--list`.

## Overnight runner

```bash
wf queue 8       # write the next 8 claimable cards to .workflow/queue/
wf run           # drain the queue          (wf night 8 does both)
touch .workflow/STOP   # stop; running cards stay queued
```

Each card runs as `claude -p "/workflow:task <ID> --headless"` in its own
worktree (`.workflow/worktrees/<ID>`, branch `wf/<ID>`), `overnight.parallel`
at a time. Headless runs never ask: owner decisions are parked in
`owner-review`. Usage-limit errors sleep until the reset time without spending
a retry, overloads back off, timed-out attempts resume the same session. Logs
and `summary.md` are in `.workflow/logs/`.

It passes `--dangerously-skip-permissions` by default, because an unattended
run cannot answer prompts. Only queue cards you would approve wholesale, on a
clean tree you can roll back, or set `overnight.permissionFlags`.

## Configuration (`.claude/workflow.json`)

A full example is in [`workflow.example.json`](workflow.example.json); the
schema with a description of every key is
[`schema/workflow.schema.json`](schema/workflow.schema.json).

| Key | Default | Meaning |
|---|---|---|
| `idPrefix` | repo initials | card id prefix (`APP` -> `APP-12`) |
| `baseBranch` | origin HEAD, else `main` | merge target and gate diff base |
| `wipLimit` | 2 | max active cards |
| `timezone` | system | zone for card dates |
| `push` | true | push after merging |
| `milestone.label` | `milestone` | name of the goal milestone cards count toward |
| `board.title/host/port` | `<repo> board`, 127.0.0.1, 8090 | board server |
| `gates[]` | detected | `{name, cmd, when?, fix?, cache?}` |
| `gatesCache`, `gatesTailLines` | true, 30 | gate cache switch, failure tail length |
| `worktree.link/copy/setup` | detected | dirs to hardlink, files to copy, commands to run in a new worktree |
| `ui` | detected | false makes the verifier use a non-UI surface and the ux-critic skip |
| `dev.url/login/viewports/check/screenshots` | | the local dev app for the verifier and ux-critic; `login` says where dev credentials live, never the secret |
| `docs.design`, `docs.spec` | [] | ground-truth docs for the critic and planner |
| `risk.high` | [] | paths that make a diff high risk |
| `overnight.*` | 2 parallel, 24h, 120 min, 2 retries, opus | runner settings |

## Customize

- **Override an agent**: put a file with the same `name` in your repo's
  `.claude/agents/` (for example `.claude/agents/reviewer.md` with your
  stack's gotchas). The skills prefer a project agent over `workflow:<name>`,
  and project agents outrank plugin agents in Claude Code's own lookup.
- **Add project skills**: anything in `.claude/skills/<name>/SKILL.md` sits
  next to the plugin's (for example a component inventory your implementers
  run before creating UI). Mention it in CLAUDE.md so agents use it.
- **Conventions** live in your CLAUDE.md; every agent reads it first. Keep
  stack rules, code standards and "never do X" there, not in the plugin.
- **Build tools, don't repeat work**: when a procedure repeats, turn it into a
  script, `just` recipe or skill and note it in CLAUDE.md.

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
