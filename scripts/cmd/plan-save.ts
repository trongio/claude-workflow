#!/usr/bin/env bun
// wf-help: store a planner's output as .workflow/plans/ID.md
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { fail, findCard, parseArgs, readCards, root } from '../lib.ts';

const HELP = `Usage: wf plan-save ID FILE

Copies FILE (the planner's output) to .workflow/plans/ID.md in the main checkout,
where wf brief reads it. Workstreams are "## Stream N" (or "Workstream N") headings.`;

const { args } = parseArgs(process.argv.slice(2), {}, HELP);
const [id, file] = args;
if (!id || !file) fail(HELP, 2);
if (!existsSync(file)) fail(`no such file: ${file}`);
const card = findCard(readCards(), id);
mkdirSync(`${root}.workflow/plans`, { recursive: true });
const dest = `${root}.workflow/plans/${card.id}.md`;
copyFileSync(file, dest);
console.log(`saved plan ${dest}`);
