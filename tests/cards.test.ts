// Unit tests for the card library: bun test tests/
import { afterAll, describe, expect, test } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';

// The board root sits under a parent directory named tasks/, which an archive
// move must never rewrite. WF_ROOT is read when lib.ts loads.
const tmp = mkdtempSync(`${tmpdir()}/wf-unit-`);
const projectRoot = `${tmp}/tasks/proj/`;
mkdirSync(`${projectRoot}tasks`, { recursive: true });
process.env.WF_ROOT = projectRoot;
const lib = await import('../scripts/lib.ts');
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const CARD = `---
id: T-1
title: "One"
status: todo
milestone: true
size: L
area: api
priority: 1
blocked: ""
depends: [T-2, "T-3"]
links: ["#12"]
tags: [migration, deploy]
---

## Goal

Ship it.

## Acceptance

- [x] first
- [ ] second
`;

const card = (over: Partial<ReturnType<typeof lib.parseCard>> & { id: string }) =>
    ({ ...(lib.parseCard(CARD, 'tasks/T-1.md') as NonNullable<ReturnType<typeof lib.parseCard>>), depends: [], blocked: '', status: 'todo', milestone: false, priority: 2, area: '', ...over });

describe('parseCard', () => {
    test('reads front matter fields, lists and points', () => {
        const c = lib.parseCard(CARD, 'tasks/T-1.md');
        expect(c).toMatchObject({ id: 'T-1', title: 'One', milestone: true, size: 'L', points: 4, priority: 1, depends: ['T-2', 'T-3'], links: ['#12'], tags: ['migration', 'deploy'] });
    });
    test('counts acceptance checkboxes', () => {
        expect(lib.parseCard(CARD, 'x')?.acceptance).toEqual({ done: 1, total: 2 });
    });
    test('an empty checkbox is a placeholder, not a criterion', () => {
        expect(lib.parseCard('---\nid: A-1\n---\n## Acceptance\n\n- [ ]\n- [ ] real\n', 'x')?.acceptance).toEqual({ done: 0, total: 1 });
    });
    test('skips the body when asked (archived cards)', () => {
        const c = lib.parseCard(CARD, 'x', false);
        expect(c?.body).toBe('');
        expect(c?.id).toBe('T-1');
    });
    test('accepts the legacy mvp alias for milestone', () => {
        expect(lib.parseCard('---\nid: A-1\nmvp: true\n---\n', 'x')?.milestone).toBe(true);
    });
    test('returns null without front matter or id', () => {
        expect(lib.parseCard('no front matter', 'x')).toBeNull();
        expect(lib.parseCard('---\ntitle: x\n---\n', 'x')).toBeNull();
    });
});

describe('render and setField', () => {
    test('render quotes strings with YAML-significant characters, lists stay inline', () => {
        expect(lib.render('owner: pick')).toBe('"owner: pick"');
        expect(lib.render('plain')).toBe('plain');
        expect(lib.render('')).toBe('""');
        expect(lib.render(['A-1', 'A-2'])).toBe('[A-1, A-2]');
        expect(lib.render(3)).toBe('3');
    });
    test('setField keeps $& and $1 in user text literally', () => {
        const out = lib.setField(CARD, 'blocked', 'owner: costs $& and $1?');
        const c = lib.parseCard(out, 'x');
        expect(c?.blocked).toBe('owner: costs $& and $1?');
    });
    test('setField adds a missing key inside the front matter only', () => {
        const text = `${CARD}\nbranch: in the body\n`;
        const out = lib.setField(text, 'branch', 'wf/T-1');
        expect(lib.parseCard(out, 'x')?.branch).toBe('wf/T-1');
        expect(out).toContain('branch: in the body');
    });
    test('setField replaces an existing key', () => {
        expect(lib.parseCard(lib.setField(CARD, 'status', 'verifying'), 'x')?.status).toBe('verifying');
    });
});

describe('claimable', () => {
    test('milestone first, then priority, then numeric id', () => {
        const cards = [
            card({ id: 'T-10', area: 'a' }),
            card({ id: 'T-2', area: 'b' }),
            card({ id: 'T-3', area: 'c', priority: 1 }),
            card({ id: 'T-4', area: 'd', milestone: true, priority: 5 }),
        ];
        expect(lib.claimable(cards, 4, true).map((t) => t.id)).toEqual(['T-4', 'T-3', 'T-2', 'T-10']);
    });
    test('prefers idle areas, then fills from busy ones', () => {
        const cards = [card({ id: 'T-1', area: 'api', status: 'in-progress' }), card({ id: 'T-2', area: 'api' }), card({ id: 'T-3', area: 'ui', priority: 3 })];
        expect(lib.claimable(cards, 2).map((t) => t.id)).toEqual(['T-3', 'T-2']);
    });
    test('dependencies must have landed (verifying or done); blocked cards wait', () => {
        const cards = [
            card({ id: 'T-1', status: 'verifying' }),
            card({ id: 'T-2', status: 'in-progress' }),
            card({ id: 'T-3', depends: ['T-1'] }),
            card({ id: 'T-4', depends: ['T-2'] }),
            card({ id: 'T-5', blocked: 'owner: x' }),
        ];
        expect(lib.claimable(cards, 5, true).map((t) => t.id)).toEqual(['T-3']);
    });
    test('unknownDepends lists ids no card has', () => {
        expect(lib.unknownDepends([card({ id: 'T-1' })], ['t-1', 'T-9'])).toEqual(['T-9']);
    });
});

describe('archive path', () => {
    test('only the root-relative tasks/ is rewritten', () => {
        expect(lib.archivePath('tasks/T-1-x.md', 'done')).toBe('tasks/archive/T-1-x.md');
        expect(lib.archivePath('tasks/archive/T-1-x.md', 'todo')).toBe('tasks/T-1-x.md');
        expect(lib.archivePath('tasks/T-1-x.md', 'verifying')).toBe('tasks/T-1-x.md');
    });
    test('update moves the card under a root whose parent is named tasks', () => {
        writeFileSync(`${projectRoot}tasks/T-1-one.md`, CARD);
        const c = lib.readCards()[0];
        const moved = lib.update(c, { status: 'done' });
        expect(moved).toBe('tasks/archive/T-1-one.md');
        expect(existsSync(`${projectRoot}tasks/archive/T-1-one.md`)).toBe(true);
        expect(existsSync(`${tmp}/tasks/archive`)).toBe(false);
        expect(readFileSync(`${projectRoot}${moved}`, 'utf8')).toContain('status: done');
    });
    test('archived cards are stubs by default and read in full on request', () => {
        expect(lib.readCards()[0]).toMatchObject({ id: 'T-1', status: 'done', title: '' });
        expect(lib.readCards({ archive: 'meta' })[0]).toMatchObject({ id: 'T-1', status: 'done', title: 'One', body: '' });
        expect(lib.readCards({ archive: 'body' })[0].body).toContain('Ship it.');
    });
});

describe('sections', () => {
    test('appendToSection appends inside an existing section and creates a missing one', () => {
        const once = lib.appendToSection(CARD, 'Notes', '- a');
        const twice = lib.appendToSection(once, 'Notes', '- b $&');
        expect(lib.section(twice, 'Notes')).toBe('- a\n- b $&');
        const mid = lib.appendToSection(CARD, 'Goal', 'More.');
        expect(lib.section(mid, 'Goal')).toBe('Ship it.\nMore.');
        expect(lib.section(mid, 'Acceptance')).toContain('- [ ] second');
    });
    test('tickAcceptance ticks by number and reports missing items', () => {
        const { text, missing } = lib.tickAcceptance(CARD, [2, 5]);
        expect(lib.parseCard(text, 'x')?.acceptance).toEqual({ done: 2, total: 2 });
        expect(missing).toEqual([5]);
    });
    test('outcomeProse ignores the generated block and the hint', () => {
        const skeleton = `${CARD}\n## Outcome\n\n${lib.PROSE_HINT}\n\n${lib.AUTO_START}\n- risk: light\n${lib.AUTO_END}\n`;
        expect(lib.outcomeProse(skeleton)).toBe('');
        expect(lib.outcomeProse(skeleton.replace(lib.PROSE_HINT, 'Shipped.'))).toBe('Shipped.');
    });
});

describe('risk', () => {
    const high = ['db/', 'src/auth/*', '*.sql'];
    test('a risk.high path decides high', () => {
        expect(lib.classifyRisk(['README.md', 'src/auth/login.ts'], high)).toEqual({ level: 'high', file: 'src/auth/login.ts' });
        expect(lib.classifyRisk(['x/y/m.sql'], high).level).toBe('high');
    });
    test('only docs, tests, markdown and css is light', () => {
        expect(lib.classifyRisk(['docs/a.txt', 'tests/x.ts', 'web/a.css', 'pkg/README.md'], high)).toEqual({ level: 'light', file: 'docs/a.txt' });
        expect(lib.classifyRisk([], high)).toEqual({ level: 'light', file: '(no changes)' });
    });
    test('anything else is standard, named by the first non-light file', () => {
        expect(lib.classifyRisk(['docs/a.md', 'src/app.ts'], high)).toEqual({ level: 'standard', file: 'src/app.ts' });
        expect(lib.classifyRisk(['src/app.ts'], [])).toEqual({ level: 'standard', file: 'src/app.ts' });
    });
});

describe('gates', () => {
    test('green only when every gate passed or an explicit ok flag says so', () => {
        expect(lib.gatesGreen([{ name: 'lint', status: 'pass' }, { name: 'test', status: 'cached' }])).toBe(true);
        expect(lib.gatesGreen({ gates: [{ name: 'lint', status: 'skip' }] })).toBe(false);
        expect(lib.gatesGreen({ ok: false, gates: [{ name: 'lint', status: 'pass' }] })).toBe(false);
        expect(lib.gatesGreen([])).toBe(false);
        expect(lib.gatesGreen(undefined)).toBe(false);
    });
});

describe('lock', () => {
    test('a lock left by a dead process is taken over', () => {
        const dir = `${projectRoot}tasks/.cards.lock`;
        mkdirSync(dir);
        writeFileSync(`${dir}/pid`, '999999999');
        expect(lib.withLock(() => 'ran', 'cards', 2)).toBe('ran');
        expect(existsSync(dir)).toBe(false);
    });
});

describe('risk defaults', () => {
    test('without risk.high in the config the built-in patterns make high risk', () => {
        expect(lib.highGlobs().source).toBe('built-in');
        for (const f of ['db/migrations/0001.sql', 'migrations/x.py', 'src/auth/login.ts', 'app/billing/plan.php', 'infra/main.tf', 'deploy/k8s.yaml', '.github/workflows/ci.yml', 'Dockerfile', 'prisma/schema.prisma'])
            expect(lib.classifyRisk([f]).level).toBe('high');
        expect(lib.classifyRisk(['src/author.ts']).level).toBe('standard');
    });
    test('an explicit list replaces the built-in one', () => {
        expect(lib.classifyRisk(['infra/main.tf'], ['db/']).level).toBe('standard');
    });
});

describe('claimable milestone tier', () => {
    test('a milestone card in a busy area still beats a non-milestone card in an idle one', () => {
        const cards = [card({ id: 'T-1', area: 'api', status: 'in-progress' }), card({ id: 'T-2', area: 'api', milestone: true, priority: 3 }), card({ id: 'T-3', area: 'ui' })];
        expect(lib.claimable(cards, 1).map((t) => t.id)).toEqual(['T-2']);
    });
    test('excluded tags are skipped', () => {
        const cards = [card({ id: 'T-1', tags: ['deploy'] }), card({ id: 'T-2', tags: [] })];
        expect(lib.claimable(cards, 2, true, ['deploy']).map((t) => t.id)).toEqual(['T-2']);
    });
});

describe('lock takeover', () => {
    test('a waiter that renamed a fresh lock (another inode) puts it back', () => {
        const dir = `${projectRoot}tasks/.race.lock`;
        mkdirSync(dir);
        writeFileSync(`${dir}/pid`, String(process.pid));
        expect(lib.takeOver(dir, 1)).toBe(false);
        expect(readFileSync(`${dir}/pid`, 'utf8')).toBe(String(process.pid));
        rmSync(dir, { recursive: true });
    });
    test('the stale dir judged by inode is removed', () => {
        const dir = `${projectRoot}tasks/.race.lock`;
        mkdirSync(dir);
        expect(lib.takeOver(dir, statSync(dir).ino)).toBe(true);
        expect(existsSync(dir)).toBe(false);
    });
});

describe('help and prefixes', () => {
    test('headerHelp stops at the first line of code', () => {
        const f = `${tmp}/cmd.ts`;
        writeFileSync(f, "#!/usr/bin/env bun\n// wf-help: one line\n// Usage: x\n//   --flag  does y\nimport { a } from 'b';\n// later\n");
        expect(lib.headerHelp(f)).toBe('Usage: x\n  --flag  does y');
    });
    test('prefixFrom takes initials or the first letters', () => {
        expect(lib.prefixFrom('Acme Billing')).toBe('AB');
        expect(lib.prefixFrom('claude-workflow')).toBe('CW');
        expect(lib.prefixFrom('aegis')).toBe('AEG');
    });
});
