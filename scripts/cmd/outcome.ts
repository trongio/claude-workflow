#!/usr/bin/env bun
// wf-help: write a card's ## Outcome skeleton (gates, diffstat, commits, risk); tick acceptance
import { fail, findCard, parseArgs, readCards, refreshOutcome, root, section, tickAcceptance, withLock } from '../lib.ts';

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

withLock(() => {
    const card = findCard(readCards(), id);
    const has = section(card.body, 'Outcome') !== null;
    let missing: number[] = [];
    refreshOutcome(card, (text) => {
        if (!ticks.length) return text;
        const r = tickAcceptance(text, ticks);
        missing = r.missing;
        return r.text;
    });
    const after = findCard(readCards(), card.id);
    console.log(`${card.id} outcome ${has ? 'refreshed' : 'written'}; acceptance ${after.acceptance.done}/${after.acceptance.total}  ${root}${after.file}`);
    if (ticks.length && !card.acceptance.total) fail('no acceptance criteria on the card: add - [ ] items or pass --force');
    if (missing.length) console.error(`warning: no acceptance ${missing.length === 1 ? 'item' : 'items'} ${missing.join(', ')} (the card has ${after.acceptance.total})`);
});
