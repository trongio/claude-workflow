#!/usr/bin/env bun
// wf-help: write a card's ## Outcome skeleton (gates, diffstat, commits, risk); tick acceptance
import { existsSync } from 'node:fs';
import {
    AUTO_END, AUTO_START, PROSE_HINT, baseBranch, changedFiles, classifyRisk, fail, findCard, gateRows, git, parseArgs,
    readCards, readJson, root, section, taskBranch, tickAcceptance, update, withLock, worktreeOf,
} from '../lib.ts';

const HELP = `Usage: wf outcome ID [--tick 1,2]

Writes the facts of "## Outcome" between wf:auto markers: risk, diffstat and
commits of the task branch against the base branch, and the gate table from
.workflow/gates-last.json. Every run regenerates that block and keeps the prose
around it; write the prose above the markers. --tick ticks acceptance items by
number. (--refresh is accepted for compatibility; refreshing is the default.)`;

const { flags, args } = parseArgs(process.argv.slice(2), { tick: 'string', refresh: 'bool' }, HELP);
const id = args[0] ?? fail(HELP, 2);
const ticks = typeof flags.tick === 'string' ? flags.tick.split(',').map((s) => Number(s.trim())) : [];
if (ticks.some((n) => !Number.isInteger(n) || n < 1)) fail('--tick takes item numbers, e.g. --tick 1,3', 2);

function facts(branch: string): string {
    const base = baseBranch();
    if (!git(['rev-parse', '--verify', '--quiet', `${branch}^{commit}`]).ok) return `- branch ${branch} not found; no diff facts`;
    const dir = worktreeOf(branch);
    const risk = classifyRisk(changedFiles(base, branch, dir));
    const log = git(['log', '--format=%h %s', `${base}..${branch}`]).out.split('\n').filter(Boolean);
    const stat = git(['diff', '--shortstat', `${base}...${branch}`]).out || 'no changes';
    const lines = [`- risk: ${risk.level} (${risk.file})`, `- diff: ${stat}`, `- commits (${log.length} on ${branch}):`];
    lines.push(...log.slice(0, 10).map((l) => `  - ${l}`));
    if (log.length > 10) lines.push(`  - ... ${log.length - 10} more`);
    const gatesFile = [dir, root.replace(/\/$/, '')].filter(Boolean).map((d) => `${d}/.workflow/gates-last.json`).find(existsSync);
    const rows = gatesFile ? gateRows(readJson(gatesFile)) : [];
    if (!rows.length) lines.push('- gates: not run (no .workflow/gates-last.json): not proven');
    else {
        lines.push('- gates:', '', '  | gate | status | s |', '  |---|---|---|');
        lines.push(...rows.map((r) => `  | ${r.name} | ${r.status} | ${r.seconds ?? ''} |`));
    }
    return lines.join('\n');
}

withLock(() => {
    const card = findCard(readCards(), id);
    const auto = `${AUTO_START}\n${facts(taskBranch(card))}\n${AUTO_END}`;
    const has = section(card.body, 'Outcome') !== null;
    let missing: number[] = [];
    update(card, {}, (text) => {
        if (ticks.length) ({ text, missing } = tickAcceptance(text, ticks));
        if (!has) return `${text.replace(/\s*$/, '')}\n\n## Outcome\n\n${PROSE_HINT}\n\n${auto}\n`;
        const a = text.indexOf(AUTO_START);
        const b = text.indexOf(AUTO_END);
        if (a < 0 || b < a) return text.replace(/^## Outcome[ \t]*\n/m, () => `## Outcome\n\n${auto}\n`);
        return text.slice(0, a) + auto + text.slice(b + AUTO_END.length);
    });
    const after = findCard(readCards(), card.id);
    console.log(`${card.id} outcome ${has ? 'refreshed' : 'written'}; acceptance ${after.acceptance.done}/${after.acceptance.total}  ${root}${after.file}`);
    if (ticks.length && !card.acceptance.total) fail('no acceptance criteria on the card: add - [ ] items or pass --force');
    if (missing.length) console.error(`warning: no acceptance item(s) ${missing.join(', ')} (the card has ${after.acceptance.total})`);
});
