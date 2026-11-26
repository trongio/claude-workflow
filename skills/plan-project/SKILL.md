---
name: plan-project
description: Plan a new project before any cards exist - detect what is there, interview the owner, research 2-3 candidate stacks in parallel, score them, confirm the stack and design direction, then scaffold docs/STACK.md (with a registry-verified version table), engineering and UI/UX standards, CLAUDE.md and .claude/workflow.json, and seed the first cards. Resumable. Invoke as /workflow:plan-project [idea | --resume | --refresh | --defaults].
argument-hint: "[idea | --resume | --refresh | --defaults]"
disable-model-invocation: true
---
You plan this project so the stack is tuned to the brief and work starts under strict, enforced
standards. Scripts do everything deterministic; you spend tokens only on judgment (questions the
scripts cannot answer, the stack decision, tuning prose). `wf` is on the Bash PATH while the plugin is
enabled, otherwise `${CLAUDE_PLUGIN_ROOT}/bin/wf`. Arguments: $ARGUMENTS

State lives in `.workflow/plan/` (`brief.json`, `detect.json`, `versions.json`, `research/*.md`,
`options.md`, `cards.json`), so a cleared context resumes from the files. `wf plan status` prints the
phase checklist and the next phase.

**Hard rule: never write a version number you did not get from `wf versions`.** Not in prose, config,
a researcher brief or a card. If you need one, run `wf versions ECO:NAME` (npm, composer, pypi, crates,
go, eol). Researchers and the planner get the same rule in their briefs.

Modes:
- `--resume`: run `wf plan status` and continue at `next:`. Do not redo finished phases.
- `--refresh`: re-run phases 1 and 3 (detect, versions, research) against the existing brief, then
  `wf versions --check docs/STACK.md`; propose a revision entry in `docs/STACK.md` only for real drift
  or a revisit trigger that fired. Do not re-interview.
- `--defaults` (or a headless run): never ask. `wf plan defaults` records every unanswered question as
  an assumption (they are listed in `docs/STACK.md`), then continue; the stack decision is parked for
  the owner (phase 4).
- Otherwise the argument is the idea (product summary and jobs); ask in chat only for what is missing.

## 1. Detect (script, background)

Start both in ONE message with `run_in_background: true`, before the interview:
- `wf detect --save` (manifests to depth 3, lockfile versions, CI files, make/just recipes, test dirs,
  design tokens, locale files, existing docs, greenfield yes/no).
- `wf versions eol:nodejs eol:php eol:python eol:go eol:postgresql` (warms the cache; runtimes only).

Do not wait for them; the interview starts now.

## 2. Interview (you, at most three rounds)

1. From the idea, record the text answers: `wf plan set product.summary "..."`,
   `wf plan set product.jobs '["verb a thing", "...", "..."]'` (exactly the three core jobs),
   `wf plan set product.name "..."`. Missing ones: one plain chat question, not AskUserQuestion.
2. `wf plan questions --json` returns the next <= 4 unanswered questions as AskUserQuestion payloads
   (header, question, multiSelect, options), with anything detect answered already filled in. Pass them
   to ONE AskUserQuestion call unchanged. Record each answer with `wf plan set KEY "<label>"` (multi
   select: a JSON array of labels; "Other" text as typed, e.g. locale codes `"en, de, fi"`). The script
   maps labels to values.
3. Repeat for rounds 2 and 3. After round 3, `wf plan defaults` records the rest as assumptions.

As soon as round 1 is answered (product kind, surfaces, data sensitivity, scale), start phase 3 in the
background, then continue with rounds 2 and 3 while it runs.

## 3. Research (parallel agents, background)

`wf plan stacks --json` lists the stack profiles. Pick the 2-3 families that fit round 1 (for example a
batteries-included monolith, a single-language TypeScript stack, an API-first service). In ONE message
launch, all with `run_in_background: true`:
- one `researcher` per family (2-3 researchers). Brief: the brief so far (`wf plan get`), the profile's `packages`,
  `fits` and `avoid`, and the questions: maturity and maintenance of each core dependency (no alpha or
  beta core deps; flag 0.x), auth/queues/i18n/admin batteries, hosting cost at the stated scale and
  budget, known production gotchas, agent fluency (how well current tooling and models write it). Rule:
  "quote versions only from `wf versions` output; never from memory". Return <= 60 lines with sources.
- one `ux-critic` in **direction mode** (when any surface has a UI). Brief: "No screenshots: propose 2
  design directions for this product (who, devices, jobs, locales, widest locale from `wf plan get`).
  For each: a name, the feeling in 5 words, layout and density, type scale, colour approach (status
  colour only), the signature component, and what it must never look like (the slop list). <= 40 lines.
  Do not write files."

When each returns, save its report verbatim: `.workflow/plan/research/<family>.md` and
`.workflow/plan/research/design-directions.md`. Run `wf versions <every package in the candidate
profiles>` once so the table facts are cached for scaffold.

## 4. Decide (planner, then one owner question)

Give the `planner` the brief, the research notes and the version output, with this task: score the 2-3
options 1-5 on a fixed matrix and recommend one. Criteria, in this order: delivery speed to the
deadline; type safety and how strictly gates can enforce it; ecosystem batteries (auth, queues, i18n,
admin); hosting cost at the stated scale; agent fluency; performance fit; team familiarity (the
languages the reviewer reads); lock-in; dependency maturity (no alpha/beta core deps). Return markdown:
the scored table, the recommendation with reasons, each rejected option with why, the UI kit
(`shadcn-tailwind | plain-css | mantine | native`) and the design direction it fits, and 3-5 **revisit
triggers** (observable conditions that would reopen the decision). Save it as `.workflow/plan/options.md`.

Then ONE AskUserQuestion with two questions: the stack (recommended first, marked "(Recommended)",
then the alternatives) and the design direction (the two from research). Record with
`wf plan set decision.stack ID` and `wf plan set decision.direction "<name>"`.

Headless / `--defaults`: do not ask. `wf new "STACK decision: confirm <recommended>" --size S --area
planning`, write the options summary into its `## Notes`, `wf park <ID> "owner: confirm stack and
design direction (see .workflow/plan/options.md)"`, then continue with the recommendation so the
scaffold exists for review.

## 5. Scaffold (script)

`wf plan scaffold --stack <ID> --ui <UI>`. It renders `docs/STACK.md` (brief, decision with
options.md, the version table from the registries with source URL and verified-on date, layout, gates),
`docs/ENGINEERING-STANDARDS.md`, `docs/UI-UX-STANDARDS.md` (UI projects), `CLAUDE.md` and
`.claude/workflow.json` (gates with `when`, `heavy`, affected-only inner loop, release-only full suite,
`pending` for tools not installed yet; worktree, risk, ux locales and widest locale, docs.standards,
stack). It never overwrites: existing files are kept and the rendered copy lands in
`.workflow/plan/rendered/` for you to merge by hand (`--force` replaces). It prints created and kept.
UNVERIFIED version rows mean a fetch failed: rerun before continuing.

## 6. Tune (planner writes, you paste)

Give the `planner` the rendered files, the brief, `options.md` and `design-directions.md`. It returns
replacement text for each `<!-- tune: ... -->` block (it is read-only); paste each one in place. Every
block is short and specific to this product:
- STACK.md decision block (already holds options.md; tighten it), UI-UX "Who and what" and
  "Project-specific UI rules" (the chosen direction from `design-directions.md`), ENGINEERING
  "Definition of done" verification line and "Project-specific rules" (domain invariants, each with an
  enforcer tag), CLAUDE.md conventions.
Every rule names its enforcer (`[hook] [ci: gate] [guard-test] [review] [not yet: X]`); `[ci: X]` only
for a gate that exists in `.claude/workflow.json`, otherwise `[not yet: X]`. Nothing outside the tune
blocks changes; no version numbers. Then `wf plan set phase.tuned true`.

## 7. Verify (script)

`wf doctor` and `wf gates --list`. Pending gates are expected on an empty project (tools not installed);
anything else that fails is a config mistake to fix now. `wf versions --check docs/STACK.md` must print
no drift. Then `wf plan set phase.verified true`.

## 8. Seed cards (planner JSON, script)

Ask the `planner` for the milestones after the first cards, as JSON only, written to
`.workflow/plan/cards.json`:
`{"milestones":[{"name":"...","cards":[{"key":"short-id","title":"...","size":"S|M|L","area":"...","milestone":true,"priority":2,"depends":["scaffold","other-key"],"goal":"...","acceptance":["user-terms criterion", "..."]}]}]}`.
Cards are vertical slices of the core jobs, each <= L, acceptance in user terms. The first cards are
added by the script, never by the planner: scaffold the app with every gate green on the empty project;
the release gate script; design tokens + component catalog + gallery page (UI projects); auth and
tenancy skeleton (when the product has users or tenants); the first vertical slice. The planner's cards
may depend on their keys (`scaffold`, `release-gate`, `design-system`, `auth`, `slice`).
Run `wf plan cards .workflow/plan/cards.json` (idempotent: re-running keeps existing cards).

## 9. Hand off

`/workflow:init` can only be started by the owner (it is not model-invocable): ask them to type it, or
run its steps yourself (`wf init --write`, review `.claude/workflow.json`, append
`${CLAUDE_PLUGIN_ROOT}/templates/claude-md-section.md` to CLAUDE.md if it has no `## Workflow` section,
`wf doctor`). Then report in <= 15 lines: stack and UI kit with the one-line reason, assumptions to confirm, pending gates,
files created and kept, cards created (first IDs), and the next step: `/workflow:next` (or the parked
STACK decision card when headless). Do not commit unless asked; if asked, `wf cards-commit` for tasks/
and a normal commit for docs and config.
