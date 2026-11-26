#!/usr/bin/env bun
// wf-help: one-screen status: counts, in flight with age, waiting on owner, verifying, leftovers
import { ACTIVE, DAY, STATUSES, type Card, ledgerCards, parseArgs, readCards } from '../lib.ts';

const HELP = `Usage: wf status [--json]

At most 25 lines: cards per status, cards in flight with their age, cards waiting
on the owner with the question, cards verifying, and resources left behind by
cards that are no longer in flight.`;

const { flags } = parseArgs(process.argv.slice(2), { json: 'bool' }, HELP);
const cards = readCards();
const age = (t: Card) => (t.started ? `${Math.max(0, Math.floor((Date.now() - new Date(`${t.started}T12:00`).getTime()) / DAY))}d` : '?');
const inFlight = cards.filter((t) => ACTIVE.includes(t.status));
const owner = cards.filter((t) => t.status !== 'done' && (t.status === 'owner-review' || /^owner/i.test(t.blocked)));
const verifying = cards.filter((t) => t.status === 'verifying');
const flying = new Set(inFlight.map((t) => t.id));
const leftovers = ledgerCards().filter((id) => !flying.has(id));
const counts = Object.fromEntries(STATUSES.map((s) => [s, cards.filter((t) => t.status === s).length]));

if (flags.json) {
    const brief = (t: Card) => ({ id: t.id, status: t.status, title: t.title, started: t.started, blocked: t.blocked || undefined, branch: t.branch });
    console.log(JSON.stringify({ counts, inFlight: inFlight.map(brief), owner: owner.map(brief), verifying: verifying.map(brief), leftovers }));
    process.exit(0);
}

const out: string[] = [STATUSES.filter((s) => counts[s]).map((s) => `${s} ${counts[s]}`).join('  ') || 'no cards'];
// Each list gets a share of the 25 lines; the rest is summarised as "+N more".
const block = (title: string, list: Card[], fmt: (t: Card) => string, max: number) => {
    if (!list.length) return;
    out.push(`${title} (${list.length}):`);
    out.push(...list.slice(0, max).map((t) => `  ${fmt(t)}`));
    if (list.length > max) out.push(`  +${list.length - max} more`);
};
const cut = (s: string, n = 70) => (s.length > n ? `${s.slice(0, n - 1)}~` : s);
block('in flight', inFlight, (t) => `${t.id.padEnd(8)} ${t.status.padEnd(12)} ${age(t).padStart(4)}  ${cut(t.title, 50)}`, 6);
block('waiting on owner', owner, (t) => `${t.id.padEnd(8)} ${cut(t.blocked || 'review and decide')}`, 6);
block('verifying', verifying, (t) => `${t.id.padEnd(8)} since ${t.landed ?? '?'}  ${cut(t.title, 50)}`, 4);
if (leftovers.length) out.push(`leftovers: ${leftovers.slice(0, 8).join(', ')}${leftovers.length > 8 ? ` +${leftovers.length - 8}` : ''} (wf prune / wf_teardown)`);
console.log(out.slice(0, 25).join('\n'));
