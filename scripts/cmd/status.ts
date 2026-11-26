#!/usr/bin/env bun
// wf-help: one-screen status: counts, in flight with age, waiting on owner, verifying, leftovers
import { ACTIVE, DAY, STATUSES, type Card, goneHint, ledgerCards, parseArgs, readCards, worktreeGone, worktrees } from '../lib.ts';

const HELP = `Usage: wf status [--json]

At most 25 lines: cards per status, cards in flight with their age, cards waiting on the
owner with the full question, cards verifying, started cards whose worktree is gone, and
resources left behind by cards that are neither in flight nor waiting on the owner. The
owner's questions are wrapped, never cut; the other lists shrink first.

Example: wf status`;

const { flags } = parseArgs(process.argv.slice(2), { json: 'bool' }, HELP);
const LINES = 25;
const WIDTH = 100;
const cards = readCards();
const trees = worktrees();
const age = (t: Card) => (t.started ? `${Math.max(0, Math.floor((Date.now() - new Date(`${t.started}T12:00`).getTime()) / DAY))}d` : '?');
const inFlight = cards.filter((t) => ACTIVE.includes(t.status));
const owner = cards.filter((t) => t.status !== 'done' && (t.status === 'owner-review' || /^owner/i.test(t.blocked)));
const verifying = cards.filter((t) => t.status === 'verifying');
const gone = inFlight.filter((t) => worktreeGone(t, trees)).map((t) => t.id);
// A card waiting on the owner keeps its worktree on purpose: that is not a leftover.
const holding = new Set([...inFlight, ...owner].map((t) => t.id));
const leftovers = ledgerCards().filter((id) => !holding.has(id));
const counts = Object.fromEntries(STATUSES.map((s) => [s, cards.filter((t) => t.status === s).length]));

if (flags.json) {
    const brief = (t: Card) => ({ id: t.id, status: t.status, title: t.title, started: t.started, blocked: t.blocked || undefined, branch: t.branch });
    console.log(JSON.stringify({ counts, inFlight: inFlight.map(brief), owner: owner.map(brief), verifying: verifying.map(brief), worktreeGone: gone, leftovers }));
    process.exit(0);
}

const cut = (s: string, n = 50) => (s.length > n ? `${s.slice(0, n - 1)}~` : s);
// Word-wrapped to WIDTH under a hanging indent.
const wrap = (head: string, text: string): string[] => {
    const lines: string[] = [];
    let line = head;
    for (const w of text.split(/\s+/).filter(Boolean)) {
        if (line.length > head.length && line.length + 1 + w.length > WIDTH) {
            lines.push(line);
            line = ' '.repeat(head.length) + w;
        } else line += (line.length > head.length ? ' ' : '') + w;
    }
    return [...lines, line];
};
// A titled list in at most `max` lines; an entry is shown whole or counted in "+N more".
const block = (title: string, rows: string[][], max: number): string[] => {
    if (!rows.length || max < 1) return [];
    if (max < 2) return [`${title} (${rows.length}): +${rows.length} more`];
    const out = [`${title} (${rows.length}):`];
    let shown = 0;
    for (const r of rows) {
        if (r.length > max - out.length - (shown + 1 < rows.length ? 1 : 0)) break;
        out.push(...r);
        shown++;
    }
    if (shown < rows.length) out.push(`  +${rows.length - shown} more`);
    return out;
};

const header = STATUSES.filter((s) => counts[s]).map((s) => `${s} ${counts[s]}`).join('  ') || 'no cards';
const extra = [
    ...(gone.length ? [`worktree gone: ${gone.slice(0, 6).join(', ')}${gone.length > 6 ? ` +${gone.length - 6}` : ''} (${goneHint(gone.length === 1 ? gone[0] : 'ID')})`] : []),
    ...(leftovers.length ? [`leftovers: ${leftovers.slice(0, 8).join(', ')}${leftovers.length > 8 ? ` +${leftovers.length - 8}` : ''} (run wf prune)`] : []),
];
// The owner's block takes what it needs first (leaving a summary line for each other list); in flight and verifying share the rest.
let room = LINES - 1 - extra.length;
const ownerBlock = block('waiting on owner', owner.map((t) => wrap(`  ${t.id.padEnd(8)} `, t.blocked || 'review and decide')), room - (inFlight.length ? 1 : 0) - (verifying.length ? 1 : 0));
room -= ownerBlock.length;
const flightBlock = block('in flight', inFlight.map((t) => [`  ${t.id.padEnd(8)} ${t.status.padEnd(12)} ${age(t).padStart(4)}  ${cut(t.title)}`]), Math.min(7, room - (verifying.length ? 1 : 0)));
room -= flightBlock.length;
const verifyBlock = block('verifying', verifying.map((t) => [`  ${t.id.padEnd(8)} since ${t.landed ?? '?'}  ${cut(t.title)}`]), Math.min(5, room));
console.log([header, ...flightBlock, ...ownerBlock, ...verifyBlock, ...extra].join('\n'));
