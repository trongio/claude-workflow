#!/usr/bin/env bun
// wf-help: assemble a self-contained implementer brief from the card and its saved plan
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { config, fail, findCard, parseArgs, plural, readCards, root, section, taskBranch } from '../lib.ts';

const HELP = `Usage: wf brief ID --stream N [--print]

Builds .workflow/briefs/ID-sN.md from the card (goal, acceptance), the plan saved
by wf plan-save (its preamble and the "Stream N" / "Workstream N" section) and the
project rules. Prints the path; --print also prints the brief.`;

const { flags, args } = parseArgs(process.argv.slice(2), { stream: 'string', print: 'bool' }, HELP);
const id = args[0] ?? fail(HELP, 2);
const n = Number(flags.stream);
if (!Number.isInteger(n) || n < 1) fail('--stream N is required (1, 2, ...)', 2);
const card = findCard(readCards(), id);
const planPath = `${root}.workflow/plans/${card.id}.md`;
if (!existsSync(planPath)) fail(`no plan for ${card.id}; run wf plan-save ${card.id} FILE first`);
const plan = readFileSync(planPath, 'utf8');

// The stream's section runs to the next heading of the same or a higher level.
const heads = [...plan.matchAll(/^(#{1,6})\s+(.*)$/gm)];
const streamRe = /^(?:work)?stream\s*(\d+)\b/i;
const first = heads.find((h) => streamRe.test(h[2].replace(/^[\W_]+/, '')));
const mine = heads.find((h) => Number(h[2].replace(/^[\W_]+/, '').match(streamRe)?.[1]) === n);
if (!mine || mine.index === undefined) fail(`plan ${planPath} has no "Stream ${n}" heading`);
const level = mine[1].length;
const next = heads.find((h) => (h.index ?? 0) > (mine.index ?? 0) && h[1].length <= level);
const stream = plan.slice(mine.index, next?.index).trim();
const preamble = plan.slice(0, first?.index ?? 0).trim();

const branch = taskBranch(card);
const standards = config.docs?.standards ?? [];
const brief = `# Brief: ${card.id} stream ${n}: ${card.title}

Branch: \`${branch}-s${n}\` from \`${branch}\`, in an isolated worktree (run \`wf wt-init\` once).
Review base: \`${branch}\`.

## Card goal

${section(card.body, 'Goal') || '(none)'}

## Card acceptance

${section(card.body, 'Acceptance') || '(none)'}
${preamble ? `\n## Plan context\n\n${preamble}\n` : ''}
## Your stream

${stream}

## Rules

- Project facts come from CLAUDE.md and .claude/workflow.json; they win over your defaults.${standards.length ? `\n- Standards: ${standards.join(', ')}.` : ''}
- Touch only the files your stream names. Verify library calls against the installed version.
- Tests are part of the feature: one behavior per test, each fails without the change.
- Small conventional commits on your branch; do not push.
- Run \`wf gates\` before reporting and paste its table as-is.
- Report: files changed, decisions and deviations, the gate table, anything undone.
`;
mkdirSync(`${root}.workflow/briefs`, { recursive: true });
const out = `${root}.workflow/briefs/${card.id}-s${n}.md`;
writeFileSync(out, brief);
if (flags.print) console.log(brief);
console.log(`brief ${out} (${plural(brief.split('\n').length, 'line')})`);
