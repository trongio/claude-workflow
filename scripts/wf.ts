#!/usr/bin/env bun
// wf: the task CLI. One cheap call instead of reading and hand-editing card files.
//
//   list [status] [--milestone]     one line per active card
//   next [n]                        the next n claimable cards, no side effects
//   claim [n] | claim <ID> [--dry-run] [--headless]   claim up to n cards (default: WIP limit) or one named card;
//                                   --headless (the overnight runner) skips cards tagged overnight.exclude
//   move <ID> <status> [--branch b] [--blocked "text"|""] [--verified "how"] [--approve] [--force]
//                                   --approve records owner-approved (lets a high-risk card land); done commits the card
//   new "<title>" [--size M] [--area x] [--milestone] [--status todo] [--priority 2] [--depends A-1,A-2] [--links "#12"] [--tags a,b]
//   prio <ID> <n> [<ID> <n> ...]    set priority (lower runs first)
//   show <ID>                       print the card file
//   stats                           milestone progress, velocity, ETA, who is blocked
//   queue [n]                       write the next n claimable cards (default 8) to .workflow/queue/ for the overnight runner
//   board [--port N]                serve the live board
//   root                            print the board root (main checkout)
// More card commands (start, finish, outcome, status, ...) live in scripts/cmd/; `wf help` lists them.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import {
    ACTIVE, CARD_ID, DAY, cardsCommit, LANDED, OVERNIGHT_BATCH, OVERNIGHT_EXCLUDE, STATUSES, WIP, type Card, byPriority, claimable, config, fail, findCard,
    idPrefix, milestoneLabel, readCards, root, taskBranch, teardown, today, unknownDepends, update, withLock, worktreeOf,
} from './lib.ts';

const [cmd = 'list', ...rest] = process.argv.slice(2);
const flags: Record<string, string | true> = {};
const args: string[] = [];
// Switches never take a value, so `claim --headless T-1` keeps T-1 as the argument.
const SWITCHES = ['milestone', 'mvp', 'dry-run', 'headless', 'approve', 'force'];
for (let i = 0; i < rest.length; i++) {
    if (rest[i].startsWith('--')) {
        const key = rest[i].slice(2);
        const next = rest[i + 1];
        flags[key] = SWITCHES.includes(key) || next === undefined || next.startsWith('--') ? true : (i++, next);
    } else args.push(rest[i]);
}
if (flags.mvp) flags.milestone = flags.mvp;

const line = (t: Card) =>
    `${t.id.padEnd(7)} ${t.status.padEnd(12)} ${t.size.padEnd(2)} ${t.area.padEnd(10)} ${t.milestone ? 'ms ' : '   '}${t.title}${t.blocked ? `  [BLOCKED: ${t.blocked}]` : ''}`;
const list = (v: string | true | undefined) => (typeof v === 'string' ? v.split(',').map((s) => s.trim()).filter(Boolean) : []);
const warnDepends = (cards: Card[], t: { id: string; depends: string[] }) => {
    const unknown = unknownDepends(cards, t.depends);
    if (unknown.length) console.error(`warning: ${t.id} depends on unknown card(s): ${unknown.join(', ')}`);
};

const needsTasksDir = !['board', 'root'].includes(cmd);
if (needsTasksDir && !existsSync(`${root}tasks`)) fail(`no tasks/ folder in ${root}; run /workflow:init first`);
// Archived cards are read only where their details show; claim and new re-read under the lock.
const archive = cmd === 'stats' || (cmd === 'list' && args[0] === 'done') ? 'meta' : 'stub';
const cards = needsTasksDir && !['claim', 'new'].includes(cmd) ? readCards({ archive }) : [];

const seen = new Map<string, string>();
for (const t of cards) {
    if (seen.has(t.id)) console.error(`warning: duplicate id ${t.id}: ${seen.get(t.id)} and ${t.file}`);
    seen.set(t.id, t.file);
}

switch (cmd) {
    case 'list': {
        const status = args[0];
        cards
            .filter((t) => (status ? t.status === status : t.status !== 'done' && t.status !== 'backlog'))
            .filter((t) => !flags.milestone || t.milestone)
            .sort((a, b) => STATUSES.indexOf(a.status) - STATUSES.indexOf(b.status) || byPriority(a, b))
            .forEach((t) => console.log(line(t)));
        break;
    }
    case 'next':
        claimable(cards, Number(args[0] ?? WIP)).forEach((t) => console.log(`${line(t)}\n        ${t.file}`));
        break;
    case 'claim':
        withLock(() => {
            const fresh = readCards();
            const active = fresh.filter((t) => ACTIVE.includes(t.status)).length;
            const byId = CARD_ID.test(args[0] ?? '');
            const n = byId ? 1 : Number(args[0] ?? WIP);
            if (!Number.isInteger(n) || n < 1) fail('usage: claim [n] | claim <ID> [--dry-run]');
            const slots = Math.min(n, WIP - active);
            if (slots <= 0) fail(`WIP limit reached: ${active} active (limit ${WIP}). Finish or move one first.`);
            const exclude = flags.headless ? OVERNIGHT_EXCLUDE : [];
            const picked = byId
                ? claimable(fresh, Infinity, false, exclude).filter((t) => t.id.toUpperCase() === args[0].toUpperCase())
                : claimable(fresh, slots, false, exclude);
            if (byId && !picked.length)
                fail(`${args[0]} is not claimable (needs status todo, unblocked, dependencies landed${exclude.length ? `, no tag in overnight.exclude: ${exclude.join(', ')}` : ''})`);
            if (!picked.length) fail('nothing claimable: no unblocked todo card with its dependencies landed');
            for (const t of picked) {
                if (!flags['dry-run']) update(t, { status: 'in-progress', started: today() });
                console.log(`${flags['dry-run'] ? 'would claim' : 'claimed'} ${t.id}  ${t.title}\n        ${t.file}`);
            }
        });
        break;
    case 'move': {
        const [id, status] = args;
        if (!STATUSES.includes(status)) fail(`status must be one of: ${STATUSES.join(', ')}`);
        const t = findCard(cards, id);
        const fields: Record<string, unknown> = { status };
        if (status === 'done') {
            const { done, total } = t.acceptance;
            if (done < total && !flags.force) fail(`${t.id}: ${done}/${total} acceptance items ticked; tick them (wf outcome ${t.id} --tick 1,2) or pass --force`);
            if (t.status === 'verifying' && typeof flags.verified !== 'string' && !t.verified)
                fail(`${t.id} is verifying: say how it was verified with --verified "how" (e.g. "checked on prod 2026-11-26")`);
            fields.done = today();
        }
        if (typeof flags.verified === 'string') fields.verified = flags.verified;
        if (flags.approve) fields['owner-approved'] = today();
        if (status === 'verifying' && !t.landed) fields.landed = today();
        if (ACTIVE.includes(status) && !t.started) fields.started = today();
        if (typeof flags.branch === 'string') fields.branch = flags.branch;
        if ('blocked' in flags) fields.blocked = flags.blocked === true ? '' : flags.blocked;
        console.log(`${t.id} ${t.status} -> ${status}  ${update(t, fields)}${flags.approve ? ' (owner-approved)' : ''}`);
        // A card leaving the active flow takes its worktree, branch and resources with it.
        if (status === 'done' || status === 'backlog') {
            const dir = worktreeOf(taskBranch(t));
            if (dir && `${dir}/` !== root) {
                const r = teardown(dir, taskBranch(t));
                if (r.error) console.error(`teardown: ${r.error}`);
                if (r.cleaned.length) console.log(`cleaned: ${r.cleaned.join(', ')}`);
            }
        }
        // The archive move is a card change like any other: commit it, as wf finish does.
        if (status === 'done') {
            const c = cardsCommit(`docs(tasks): ${t.id} done`);
            if (c.ok) console.log(c.out);
            else console.error(`cards-commit failed (commit tasks/ with wf cards-commit):\n${c.out}`);
        }
        break;
    }
    case 'prio': {
        if (args.length === 0 || args.length % 2 !== 0) fail('usage: prio <ID> <n> [<ID> <n> ...]');
        for (let i = 0; i < args.length; i += 2) {
            const t = findCard(cards, args[i]);
            const n = Number(args[i + 1]);
            if (!Number.isFinite(n)) fail(`priority must be a number: ${args[i + 1]}`);
            update(t, { priority: n });
            warnDepends(cards, t);
            console.log(`${t.id} priority ${t.priority} -> ${n}`);
        }
        break;
    }
    case 'new': {
        const title = args[0] ?? fail('usage: new "<title>" [--size M] [--area x] [--milestone] [--status todo] [--priority 2] [--depends A-1,A-2] [--links "#12"] [--tags a,b]');
        const status = typeof flags.status === 'string' ? flags.status : 'todo';
        if (!STATUSES.includes(status)) fail(`bad status ${status}`);
        const depends = list(flags.depends);
        const links = list(flags.links);
        const tags = list(flags.tags);
        if (config.tracker?.requireLink && !links.some((l) => /^#\d+$/.test(l))) fail('tracker.requireLink is set: pass --links "#<issue>"');
        const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 50);
        // Locked and re-read, so parallel sessions never mint the same id.
        withLock(() => {
            const fresh = readCards();
            const prefix = idPrefix();
            const max = Math.max(0, ...fresh.filter((t) => t.id.startsWith(`${prefix}-`)).map((t) => Number(t.id.slice(prefix.length + 1)) || 0));
            const id = `${prefix}-${max + 1}`;
            warnDepends(fresh, { id, depends });
            const file = `tasks/${id}${slug ? `-${slug}` : ''}.md`;
            writeFileSync(
                `${root}${file}`,
                `---
id: ${id}
title: ${JSON.stringify(title)}
status: ${status}
milestone: ${flags.milestone === true}
size: ${typeof flags.size === 'string' ? flags.size : 'M'}
area: ${typeof flags.area === 'string' ? flags.area : ''}
priority: ${typeof flags.priority === 'string' ? flags.priority : 2}
blocked: ""
depends: [${depends.join(', ')}]
created: ${today()}
started:
done:
branch:
links: [${links.map((l) => JSON.stringify(l)).join(', ')}]
tags: [${tags.join(', ')}]
---

## Goal

## Acceptance

<!-- acceptance: add - [ ] items -->
`,
            );
            console.log(`${id}  ${file}`);
        });
        break;
    }
    case 'queue': {
        // One .task file per claimable card; the overnight runner moves each card to in-progress as it starts it.
        const dir = `${root}.workflow/queue`;
        mkdirSync(dir, { recursive: true });
        const queued = new Set(readdirSync(dir).map((f) => f.replace(/\.task$/, '')));
        const picked = claimable(cards.filter((t) => !queued.has(t.id)), Number(args[0] ?? OVERNIGHT_BATCH), true, OVERNIGHT_EXCLUDE);
        const model = typeof flags.model === 'string' ? flags.model : (config.overnight?.model ?? 'opus');
        for (const t of picked) {
            writeFileSync(`${dir}/${t.id}.task`, `# model: ${model}\n${t.id}\n`);
            console.log(`queued ${t.id}  ${t.title}`);
        }
        if (!picked.length) console.log('nothing claimable to queue');
        break;
    }
    case 'show':
        console.log(readFileSync(`${root}${findCard(cards, args[0]).file}`, 'utf8'));
        break;
    case 'stats': {
        // Progress, velocity and remaining work are all milestone-scoped, so the ETA divides like by like.
        const ms = cards.filter((t) => t.milestone);
        const sum = (l: Card[]) => l.reduce((s, t) => s + t.points, 0);
        const total = sum(ms);
        const done = sum(ms.filter((t) => t.status === 'done'));
        const open = ms.filter((t) => !LANDED.includes(t.status));
        const blocked = sum(open.filter((t) => t.blocked));
        const since = (d: number) => Date.now() - d * DAY;
        const shipped = (t: Card) => (LANDED.includes(t.status) ? (t.landed ?? t.done) : undefined);
        const vel = (d: number) => sum(ms.filter((t) => { const at = shipped(t); return !!at && new Date(`${at}T12:00`).getTime() >= since(d); })) / d;
        const v = vel(14);
        const eta = v ? new Date(Date.now() + ((sum(open) - blocked) / v) * DAY).toISOString().slice(0, 10) : 'unknown';
        console.log(`${milestoneLabel()}: ${done}/${total} pts (${total ? Math.round((done / total) * 100) : 0}%), ${open.length} cards open, ${blocked} pts blocked on people`);
        console.log(`velocity pts/day: 7d ${vel(7).toFixed(1)}  14d ${v.toFixed(1)}  28d ${vel(28).toFixed(1)}  ->  ETA ${eta} (excludes blocked)`);
        for (const s of STATUSES.filter((s) => s !== 'done')) {
            const l = cards.filter((t) => t.status === s);
            if (l.length) console.log(`  ${s.padEnd(12)} ${String(l.length).padStart(3)} cards ${String(sum(l)).padStart(4)} pts`);
        }
        const you = cards.filter((t) => t.status !== 'done' && (t.status === 'owner-review' || /^owner/i.test(t.blocked)));
        if (you.length) console.log(`waiting on owner (${you.length}):\n${you.map((t) => `  ${t.id} ${t.title}  [${t.blocked || 'review'}]`).join('\n')}`);
        break;
    }
    case 'board':
        await import('./board/server.ts').then((m) => m.serve(typeof flags.port === 'string' ? Number(flags.port) : undefined));
        break;
    case 'root':
        console.log(root);
        break;
    default:
        fail(`unknown command ${cmd}; see the header of scripts/wf.ts or run wf help`);
}
