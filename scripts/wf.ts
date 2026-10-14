#!/usr/bin/env bun
// wf: the task CLI. One cheap call instead of reading and hand-editing card files.
//
//   list [status] [--milestone]     one line per active card
//   next [n]                        the next n claimable cards, no side effects
//   claim [n] | claim <ID>          claim up to n cards (default: WIP limit) or one named card
//   move <ID> <status> [--branch b] [--blocked "text"|""]
//   new "<title>" [--size M] [--area x] [--milestone] [--status todo] [--priority 2] [--depends A-1,A-2]
//   prio <ID> <n> [<ID> <n> ...]    set priority (lower runs first)
//   show <ID>                       print the card file
//   stats                           milestone progress, velocity, ETA, who is blocked
//   queue [n]                       write the next n claimable cards to .workflow/queue/ for the overnight runner
//   board [--port N]                serve the live board
//   root                            print the board root (main checkout)
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmdirSync, writeFileSync } from 'node:fs';
import { ACTIVE, CARD_ID, STATUSES, type Card, config, idPrefix, milestoneLabel, readCards, root, today } from './lib.ts';

const WIP = Number(process.env.WF_WIP ?? config.wipLimit ?? 2);
const DAY = 864e5;

const [cmd = 'list', ...rest] = process.argv.slice(2);
const flags: Record<string, string | true> = {};
const args: string[] = [];
for (let i = 0; i < rest.length; i++) {
    if (rest[i].startsWith('--')) {
        const key = rest[i].slice(2);
        const next = rest[i + 1];
        flags[key] = next === undefined || next.startsWith('--') ? true : (i++, next);
    } else args.push(rest[i]);
}
if (flags.mvp) flags.milestone = flags.mvp;

let heldLock: string | null = null;
function fail(msg: string): never {
    console.error(msg);
    if (heldLock) rmdirSync(heldLock);
    process.exit(1);
}
const find = (cards: Card[], id: string) => cards.find((t) => t.id.toUpperCase() === String(id).toUpperCase()) ?? fail(`no card ${id}`);
const line = (t: Card) =>
    `${t.id.padEnd(7)} ${t.status.padEnd(12)} ${t.size.padEnd(2)} ${t.area.padEnd(10)} ${t.milestone ? 'ms ' : '   '}${t.title}${t.blocked ? `  [BLOCKED: ${t.blocked}]` : ''}`;
// Milestone cards first, then priority, then id.
const byPriority = (a: Card, b: Card) =>
    Number(b.milestone) - Number(a.milestone) || a.priority - b.priority || a.id.localeCompare(b.id, undefined, { numeric: true });

function render(value: unknown): string {
    if (Array.isArray(value)) return `[${value.join(', ')}]`;
    if (typeof value === 'string' && /[:#"[\]]/.test(value)) return JSON.stringify(value);
    return String(value);
}

function setField(text: string, key: string, value: unknown): string {
    const re = new RegExp(`^${key}:.*$`, 'm');
    const end = text.indexOf('\n---', 4);
    if (re.test(text.slice(0, end))) return text.replace(re, `${key}: ${render(value)}`);
    return `${text.slice(0, end)}\n${key}: ${render(value)}${text.slice(end)}`;
}

// Writes fields into the front matter; done cards move to tasks/archive/, reopened ones move back.
function update(card: Card, fields: Record<string, unknown>): string {
    const path = `${root}${card.file}`;
    let text = readFileSync(path, 'utf8');
    for (const [k, v] of Object.entries(fields)) text = setField(text, k, v);
    let target = path;
    if (fields.status === 'done' && !card.file.startsWith('tasks/archive/')) target = path.replace('/tasks/', '/tasks/archive/');
    if (fields.status && fields.status !== 'done' && card.file.startsWith('tasks/archive/')) target = path.replace('/tasks/archive/', '/tasks/');
    writeFileSync(path, text);
    if (target !== path) {
        mkdirSync(target.slice(0, target.lastIndexOf('/')), { recursive: true });
        renameSync(path, target);
    }
    return target.replace(root, '');
}

// Claimable: todo, unblocked, every dependency done. Prefer areas nobody is working in,
// so parallel workstreams rarely touch the same files.
function claimable(cards: Card[], n: number, ignoreWip = false): Card[] {
    const done = new Set(cards.filter((t) => t.status === 'done').map((t) => t.id));
    const busy = new Set(ignoreWip ? [] : cards.filter((t) => ACTIVE.includes(t.status)).map((t) => t.area));
    const ready = cards.filter((t) => t.status === 'todo' && !t.blocked && t.depends.every((d) => done.has(d))).sort(byPriority);
    const picked: Card[] = [];
    for (const t of ready) {
        if (picked.length >= n) break;
        if (!busy.has(t.area)) {
            picked.push(t);
            busy.add(t.area);
        }
    }
    for (const t of ready) {
        if (picked.length >= n) break;
        if (!picked.includes(t)) picked.push(t);
    }
    return picked;
}

function withLock<T>(fn: () => T): T {
    const lock = `${root}tasks/.claim.lock`;
    for (let i = 0; i < 50; i++) {
        try {
            mkdirSync(lock);
            heldLock = lock;
            break;
        } catch {
            if (i === 49) fail(`card lock busy (${lock}); remove it if no claim is running`);
            Bun.sleepSync(100);
        }
    }
    try {
        return fn();
    } finally {
        rmdirSync(lock);
        heldLock = null;
    }
}

const needsTasksDir = !['board', 'root'].includes(cmd);
if (needsTasksDir && !existsSync(`${root}tasks`)) fail(`no tasks/ folder in ${root}; run /workflow:init first`);
const cards = needsTasksDir ? readCards() : [];

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
            if (!Number.isInteger(n) || n < 1) fail('usage: claim [n] | claim <ID>');
            const slots = Math.min(n, WIP - active);
            if (slots <= 0) fail(`WIP limit reached: ${active} active (limit ${WIP}). Finish or move one first.`);
            const picked = byId
                ? claimable(fresh, Infinity).filter((t) => t.id.toUpperCase() === args[0].toUpperCase())
                : claimable(fresh, slots);
            if (byId && !picked.length) fail(`${args[0]} is not claimable (needs status todo, unblocked, dependencies done)`);
            if (!picked.length) fail('nothing claimable: no unblocked todo card with its dependencies done');
            for (const t of picked) {
                update(t, { status: 'in-progress', started: today() });
                console.log(`claimed ${t.id}  ${t.title}\n        ${t.file}`);
            }
        });
        break;
    case 'move': {
        const [id, status] = args;
        if (!STATUSES.includes(status)) fail(`status must be one of: ${STATUSES.join(', ')}`);
        const t = find(cards, id);
        const fields: Record<string, unknown> = { status };
        if (status === 'done') fields.done = today();
        if (ACTIVE.includes(status) && !t.started) fields.started = today();
        if (typeof flags.branch === 'string') fields.branch = flags.branch;
        if ('blocked' in flags) fields.blocked = flags.blocked === true ? '' : flags.blocked;
        console.log(`${t.id} ${t.status} -> ${status}  ${update(t, fields)}`);
        break;
    }
    case 'prio': {
        if (args.length === 0 || args.length % 2 !== 0) fail('usage: prio <ID> <n> [<ID> <n> ...]');
        for (let i = 0; i < args.length; i += 2) {
            const t = find(cards, args[i]);
            const n = Number(args[i + 1]);
            if (!Number.isFinite(n)) fail(`priority must be a number: ${args[i + 1]}`);
            update(t, { priority: n });
            console.log(`${t.id} priority ${t.priority} -> ${n}`);
        }
        break;
    }
    case 'new': {
        const title = args[0] ?? fail('usage: new "<title>" [--size M] [--area x] [--milestone] [--status todo] [--priority 2] [--depends A-1,A-2]');
        const prefix = idPrefix();
        const max = Math.max(0, ...cards.filter((t) => t.id.startsWith(`${prefix}-`)).map((t) => Number(t.id.slice(prefix.length + 1)) || 0));
        const id = `${prefix}-${max + 1}`;
        const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 50);
        const file = `tasks/${id}${slug ? `-${slug}` : ''}.md`;
        const status = typeof flags.status === 'string' ? flags.status : 'todo';
        if (!STATUSES.includes(status)) fail(`bad status ${status}`);
        const depends = typeof flags.depends === 'string' ? flags.depends.split(',').map((s) => s.trim()).filter(Boolean) : [];
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
links: []
---

## Goal

## Acceptance

- [ ]
`,
        );
        console.log(`${id}  ${file}`);
        break;
    }
    case 'queue': {
        // One .task file per claimable card; the overnight runner moves each card to in-progress as it starts it.
        const dir = `${root}.workflow/queue`;
        mkdirSync(dir, { recursive: true });
        const queued = new Set(readdirSync(dir).map((f) => f.replace(/\.task$/, '')));
        const picked = claimable(cards.filter((t) => !queued.has(t.id)), Number(args[0] ?? 6), true);
        const model = typeof flags.model === 'string' ? flags.model : (config.overnight?.model ?? 'opus');
        for (const t of picked) {
            writeFileSync(`${dir}/${t.id}.task`, `# model: ${model}\n${t.id}\n`);
            console.log(`queued ${t.id}  ${t.title}`);
        }
        if (!picked.length) console.log('nothing claimable to queue');
        break;
    }
    case 'show':
        console.log(readFileSync(`${root}${find(cards, args[0]).file}`, 'utf8'));
        break;
    case 'stats': {
        const ms = cards.filter((t) => t.milestone);
        const sum = (list: Card[]) => list.reduce((s, t) => s + t.points, 0);
        const total = sum(ms);
        const done = sum(ms.filter((t) => t.status === 'done'));
        const open = ms.filter((t) => t.status !== 'done');
        const blocked = sum(open.filter((t) => t.blocked));
        const vel = (d: number) => sum(cards.filter((t) => t.status === 'done' && t.done && new Date(`${t.done}T12:00`).getTime() >= Date.now() - d * DAY)) / d;
        const v = vel(14);
        const eta = v ? new Date(Date.now() + ((sum(open) - blocked) / v) * DAY).toISOString().slice(0, 10) : 'unknown';
        console.log(`${milestoneLabel()}: ${done}/${total} pts (${total ? Math.round((done / total) * 100) : 0}%), ${open.length} cards open, ${blocked} pts blocked on people`);
        console.log(`velocity pts/day: 7d ${vel(7).toFixed(1)}  14d ${v.toFixed(1)}  28d ${vel(28).toFixed(1)}  ->  ETA ${eta} (excludes blocked)`);
        for (const s of STATUSES.filter((s) => s !== 'done')) {
            const list = cards.filter((t) => t.status === s);
            if (list.length) console.log(`  ${s.padEnd(12)} ${String(list.length).padStart(3)} cards ${String(sum(list)).padStart(4)} pts`);
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
        fail(`unknown command ${cmd}; see the header of scripts/wf.ts`);
}
