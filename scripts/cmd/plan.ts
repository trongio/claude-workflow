#!/usr/bin/env bun
// wf-help: project planning state (.workflow/plan): set|get|questions|defaults|status|stacks|scaffold|cards|unpend
// Usage:
//   wf plan set KEY VALUE [--assumed]   record an interview answer (labels or values; JSON for lists)
//   wf plan get [KEY]                   print the brief, or one answer
//   wf plan questions [--json] [--max 4]  next unanswered questions (detect answers prefilled)
//   wf plan defaults                    record the default for every unanswered question as an assumption
//   wf plan status                      phase checklist and the next phase (for --resume)
//   wf plan stacks [--json]             the stack profiles scaffold can render
//   wf plan scaffold --stack ID --ui ID [--force] [--dry-run] [--no-versions]
//                                       render docs/STACK.md, the standards, CLAUDE.md, .claude/workflow.json
//   wf plan cards FILE.json [--dry-run] create the first cards plus the planner's milestones (idempotent)
//   wf plan unpend                      clear `pending` on gates whose tools are now installed
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { baseBranch, detect, haveCmd, missingTools, type Detection } from './detect.ts';
import { table, versions } from './versions.ts';
import { headerHelp, idPrefix, prefixFrom, readCards, root as mainRoot, today } from '../lib.ts';

const PLUGIN = join(dirname(import.meta.path), '../..');
const T = (p: string) => join(PLUGIN, 'templates', p);
const root = mainRoot.replace(/\/$/, '');
const PLAN = join(root, '.workflow/plan');
const BRIEF = join(PLAN, 'brief.json');

type Option = { label: string; value: unknown; description: string };
type Question = { key: string; round: number; header: string; question: string; multiSelect: boolean; type?: string; detect?: string; default: unknown; options: Option[] };
type TextQ = { key: string; prompt: string; type?: string; default: unknown };
type QFile = { text: TextQ[]; questions: Question[]; widthFactor: Record<string, number | string> };
type Brief = { answers: Record<string, unknown>; source: Record<string, string>; created: string; updated: string; cards?: Record<string, string> };
type StackGate = { name: string; cmd: string; when: string[]; requires?: string[]; [k: string]: unknown };
type Stack = {
    id: string; title: string; summary: string; fits: string[]; avoid: string[]; languages: string[]; ui: boolean; uiDefault: string; uiOptions: string[];
    packages: string[]; commands: Record<string, string>; dev: { url: string }; layout: string[]; gates: StackGate[];
    testAffected?: unknown; worktree: Record<string, unknown>; risk: { high: string[] }; standards: string;
};

const argv = process.argv.slice(2);
const [sub = 'status', ...rest] = argv;
const flags: Record<string, string | true> = {};
const args: string[] = [];
for (let i = 0; i < rest.length; i++) {
    if (rest[i].startsWith('--')) {
        const k = rest[i].slice(2);
        const n = rest[i + 1];
        flags[k] = n === undefined || n.startsWith('--') || ['json', 'force', 'dry-run', 'no-versions', 'assumed'].includes(k) ? true : (i++, n);
    } else args.push(rest[i]);
}
function fail(msg: string): never {
    console.error(`plan: ${msg}`);
    process.exit(1);
}

const qfile = (): QFile => JSON.parse(readFileSync(T('plan/questions.json'), 'utf8')) as QFile;
function loadBrief(): Brief {
    try {
        return JSON.parse(readFileSync(BRIEF, 'utf8')) as Brief;
    } catch {
        return { answers: {}, source: {}, created: today(), updated: today() };
    }
}
function saveBrief(b: Brief): void {
    mkdirSync(PLAN, { recursive: true });
    b.updated = today();
    writeFileSync(BRIEF, `${JSON.stringify(b, null, 2)}\n`);
}

// A label or value from AskUserQuestion -> the stored value. Lists: JSON, or comma-separated labels.
function normalize(key: string, raw: string): unknown {
    const q = qfile().questions.find((x) => x.key === key);
    const t = qfile().text.find((x) => x.key === key);
    let v: unknown;
    try {
        v = JSON.parse(raw);
    } catch {
        v = raw;
    }
    const one = (s: unknown) => {
        if (!q || typeof s !== 'string') return s;
        const o = q.options.find((x) => x.label.toLowerCase() === s.toLowerCase() || JSON.stringify(x.value) === JSON.stringify(s));
        return o ? o.value : s.trim();
    };
    const list = q?.multiSelect || q?.type === 'list' || t?.type === 'list';
    if (typeof v === 'string' && list) {
        const whole = one(v);
        if (whole !== v.trim() || !v.includes(',')) v = Array.isArray(whole) ? whole : [whole];
        else v = v.split(',').map((s) => one(s.trim()));
    }
    if (Array.isArray(v)) {
        const flat = v.flatMap((x) => {
            const o = one(x);
            return Array.isArray(o) && q?.type === 'list' ? o : [o];
        });
        return [...new Set(flat)];
    }
    return one(v);
}

// Values of a fixed-option question that match none of its options (free-text and list questions take anything).
function invalid(key: string, v: unknown): string[] {
    const q = qfile().questions.find((x) => x.key === key);
    if (!q || q.type === 'list' || !q.options.length) return [];
    const ok = (x: unknown) => q.options.some((o) => JSON.stringify(o.value) === JSON.stringify(x));
    return (Array.isArray(v) && q.multiSelect ? v : [v]).filter((x) => !ok(x)).map((x) => (typeof x === 'string' ? x : JSON.stringify(x)));
}

// Facts wf detect can answer without asking.
function detectedAnswers(det: Detection): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    const locales = [...new Set(det.locales.flatMap((l) => l.locales.map((x) => x.slice(0, 2).toLowerCase())))];
    if (locales.length) out.locales = locales;
    if (!det.greenfield) out.assets = ['code', ...(det.tokens.length ? ['brand'] : [])];
    return out;
}
function loadDetect(): Detection {
    const p = join(PLAN, 'detect.json');
    if (existsSync(p)) return JSON.parse(readFileSync(p, 'utf8')) as Detection;
    const det = detect(root);
    mkdirSync(PLAN, { recursive: true });
    writeFileSync(p, `${JSON.stringify(det, null, 2)}\n`);
    return det;
}

const arr = (v: unknown): string[] => (Array.isArray(v) ? v.map(String) : v === undefined || v === '' ? [] : [String(v)]);
function label(key: string, v: unknown): string {
    const q = qfile().questions.find((x) => x.key === key);
    const name = (x: unknown) => q?.options.find((o) => JSON.stringify(o.value) === JSON.stringify(x))?.label ?? String(x);
    if (q?.type === 'list') return arr(v).join(', ') || '-';
    if (Array.isArray(v)) return v.map(name).join(', ') || '-';
    return v === undefined || v === '' ? '-' : name(v);
}

function widest(locales: string[]): string {
    const f = qfile().widthFactor;
    return [...locales].sort((a, b) => Number(f[b.slice(0, 2)] ?? 1.2) - Number(f[a.slice(0, 2)] ?? 1.2))[0] ?? 'en';
}

function flagsOf(a: Record<string, unknown>, uiId: string): Record<string, boolean> {
    const sens = arr(a['data.sensitivity']);
    const caps = arr(a.capabilities);
    const integ = arr(a.integrations);
    return {
        multiTenant: sens.includes('multi-tenant'),
        pii: sens.includes('pii'),
        money: sens.includes('money') || integ.includes('payments'),
        i18n: arr(a.locales).length > 1,
        ui: uiId !== 'native',
        offline: caps.includes('offline'),
        realtime: caps.includes('realtime'),
        jobs: caps.includes('jobs'),
        hardware: integ.includes('hardware'),
        sso: integ.includes('sso'),
        auth: !(a['product.kind'] === 'api' && sens.length === 1 && sens[0] === 'none'),
        ownerReviewsHigh: a.review !== 'outcomes',
    };
}

// {{#if flag}}...{{/if}}, {{#unless flag}}...{{/unless}} (block or inline, not nested), then {{VAR}}.
export function render(text: string, vars: Record<string, string>, fl: Record<string, boolean>): string {
    const keep = (kind: string, f: string) => (kind === 'if' ? !!fl[f] : !fl[f]);
    let s = text.replace(/^[ \t]*\{\{#(if|unless) (\w+)\}\}[ \t]*\n([\s\S]*?)^[ \t]*\{\{\/\1\}\}[ \t]*\n/gm, (_, k, f, body) => (keep(k, f) ? body : ''));
    s = s.replace(/\{\{#(if|unless) (\w+)\}\}([\s\S]*?)\{\{\/\1\}\}/g, (_, k, f, body) => (keep(k, f) ? body : ''));
    return s.replace(/\{\{([A-Z_]+)\}\}/g, (m, k: string) => vars[k] ?? m);
}
const leftovers = (s: string) => [...new Set(s.match(/\{\{[^}]*\}\}/g) ?? [])];

function loadStack(id: string): Stack {
    const p = T(`stacks/${id}.json`);
    if (!existsSync(p)) fail(`unknown stack ${id}; run wf plan stacks`);
    return JSON.parse(readFileSync(p, 'utf8')) as Stack;
}
const UIS = () => readdirSync(T('ui')).filter((f) => f.endsWith('.md')).map((f) => f.slice(0, -3));
const missing = (g: { requires?: string[]; cwd?: unknown }) =>
    (g.requires ?? []).some((r) => (r.includes('/') ? !existsSync(join(root, typeof g.cwd === 'string' ? g.cwd : '', r)) : !haveCmd(r)));

function vars(b: Brief, stack: Stack, uiId: string, versionTable: string, gates: StackGate[]): Record<string, string> {
    const a = b.answers;
    const locales = arr(a.locales).length ? arr(a.locales) : ['en'];
    const jobs = arr(a['product.jobs']);
    const bullets = (xs: string[], indent = '') => (xs.length ? xs.map((x) => `${indent}- ${x}`).join('\n') : `${indent}- (none recorded)`);
    const assumed = Object.keys(b.source).filter((k) => b.source[k] === 'assumed' && arr(a[k]).length);
    const options = existsSync(join(PLAN, 'options.md')) ? readFileSync(join(PLAN, 'options.md'), 'utf8').trim() : '_No scored options recorded yet: the Decide phase of /workflow:plan-project writes .workflow/plan/options.md; rerun scaffold with --force or paste it here._';
    const gateTable = ['| Gate | Command | Runs | Notes |', '| --- | --- | --- | --- |', ...gates.map((g) => `| \`${g.name}\` | \`${g.cmd.replace(/\|/g, '\\|')}\` | ${g.release === false ? 'inner loop only' : g.inner === false ? 'release only' : 'inner loop and release'} | ${[g.heavy ? 'heavy' : '', g.pending ? 'pending: tool not installed' : '', g.fix ? 'has fix' : ''].filter(Boolean).join(', ') || '-'} |`)].join('\n');
    return {
        PROJECT: String(a['product.name'] || root.split('/').pop()),
        PROJECT_NAME: typeof a['product.name'] === 'string' ? a['product.name'].trim() : '',
        DATE: today(),
        PRODUCT_SUMMARY: String(a['product.summary'] || '(one sentence: what it is and who it is for)'),
        PRODUCT_KIND: label('product.kind', a['product.kind']),
        JOBS: bullets(jobs, '  '),
        FIRST_JOB: jobs[0] ?? 'the first core job',
        SURFACES: label('surfaces', a.surfaces),
        SENSITIVITY: label('data.sensitivity', a['data.sensitivity']),
        SCALE: label('scale', a.scale),
        LANGUAGES: label('team.languages', a['team.languages']),
        HOSTING: label('hosting', a.hosting),
        BUDGET: label('budget', a.budget),
        DEADLINE: label('deadline', a.deadline),
        CAPABILITIES: label('capabilities', a.capabilities),
        LOCALES: locales.join(', '),
        WIDEST_LOCALE: widest(locales),
        INTEGRATIONS: label('integrations', a.integrations),
        ASSETS: label('assets', a.assets),
        REVIEW: label('review', a.review),
        ASSUMPTIONS: assumed.length ? assumed.map((k) => `- ${k}: ${label(k, a[k])}`).join('\n') : '- none',
        STACK_ID: stack.id,
        STACK_TITLE: stack.title,
        STACK_SUMMARY: stack.summary,
        STACK_FITS: bullets(stack.fits),
        STACK_AVOID: bullets(stack.avoid),
        UI_ID: uiId,
        OPTIONS: options,
        VERSION_TABLE: versionTable,
        LAYOUT: stack.layout.join('\n'),
        GATE_TABLE: gateTable,
        DEV_URL: stack.dev.url,
        CMD_INSTALL: stack.commands.install ?? '-',
        CMD_DEV: stack.commands.dev ?? '-',
        CMD_TEST: stack.commands.test ?? '-',
        CMD_FMT: stack.commands.fmt ?? '-',
        RISK_HIGH: stack.risk.high.map((r) => `\`${r}\``).join(', '),
        STACK_STANDARDS: readFileSync(T(`stacks/${stack.standards}`), 'utf8').trim(),
        UI_RULES: readFileSync(T(`ui/${uiId}.md`), 'utf8').trim(),
    };
}

function stackGates(stack: Stack, uiId: string): StackGate[] {
    return stack.gates
        .filter((g) => !(uiId === 'native' && g.name === 'tokens'))
        .map((g) => {
            let cmd = g.cmd;
            // Plain CSS has no utility scale, so raw px values in component CSS are magic numbers too.
            if (g.name === 'tokens' && uiId === 'plain-css') cmd = cmd.replace(/style=\\x22'/, "style=\\x22|(?<![\\w.-])[1-9][0-9]*(?:\\.[0-9]+)?px\\b'");
            const { requires, ...rest } = g;
            // A `<tool>.config.*` glob only means something when the gate runs that tool or the stack
            // ships it (vitest reads vite.config.*; next build does not, and Next ships no vite).
            const when = g.when.filter((w) => {
                const tool = w.match(/^(?:.*\/)?([a-z][\w-]*)\.config\.\*$/)?.[1];
                const name = (p: string) => p.split(':').pop()?.split('/').pop() ?? '';
                return !tool || g.cmd.includes(tool) || stack.packages.some((p) => name(p) === tool || name(p).startsWith(`${tool}-`));
            });
            return { ...rest, cmd, when, ...(missing(g) ? { pending: true } : {}) } as StackGate;
        });
}

function workflowConfig(stack: Stack, uiId: string, fl: Record<string, boolean>, gates: StackGate[], v: Record<string, string>): Record<string, unknown> {
    const standards = ['docs/ENGINEERING-STANDARDS.md', ...(fl.ui ? ['docs/UI-UX-STANDARDS.md'] : [])];
    return {
        $schema: 'https://raw.githubusercontent.com/trongio/claude-workflow/main/schema/workflow.schema.json',
        // The product's name when the brief has one, else the configured prefix or the repo name.
        idPrefix: v.PROJECT_NAME ? prefixFrom(v.PROJECT_NAME) : idPrefix(),
        baseBranch: baseBranch(root),
        wipLimit: 2,
        milestone: { label: 'v1' },
        gates,
        ...(stack.testAffected ? { testAffected: stack.testAffected } : {}),
        worktree: stack.worktree,
        ui: fl.ui,
        dev: fl.ui ? { url: stack.dev.url, login: '', viewports: [375, 1440] } : { url: stack.dev.url },
        docs: { spec: ['docs/STACK.md'], design: fl.ui ? ['docs/UI-UX-STANDARDS.md'] : [], standards },
        risk: { high: stack.risk.high },
        ux: { locales: v.LOCALES.split(', '), widestLocale: v.WIDEST_LOCALE, maxFixRounds: 2 },
        review: { minPasses: 1, maxRounds: 3, ownerHoldHigh: fl.ownerReviewsHigh },
        stack: { id: stack.id, ui: uiId, decided: today() },
    };
}

async function scaffold(): Promise<void> {
    const stackId = typeof flags.stack === 'string' ? flags.stack : fail('scaffold needs --stack ID (wf plan stacks)');
    const stack = loadStack(stackId);
    const uiId = typeof flags.ui === 'string' ? flags.ui : stack.uiDefault;
    if (!UIS().includes(uiId)) fail(`unknown ui ${uiId} (${UIS().join(', ')})`);
    if (!stack.uiOptions.includes(uiId)) console.log(`note: ui ${uiId} is not one of ${stack.id}'s usual kits (${stack.uiOptions.join(', ')})`);
    const b = loadBrief();
    const fl = flagsOf(b.answers, uiId);
    let versionTable: string;
    let unverified = 0;
    if (flags['no-versions']) {
        versionTable = table(stack.packages.map((id) => ({ id, version: '?', released: '', note: '', source: '', verified: '', error: 'not fetched (--no-versions)' })));
        unverified = stack.packages.length;
    } else {
        const rows = await versions(stack.packages);
        unverified = rows.filter((r) => r.error).length;
        versionTable = table(rows);
    }
    const gates = stackGates(stack, uiId);
    const v = vars(b, stack, uiId, versionTable, gates);
    const outputs: [string, string][] = [
        ['docs/STACK.md', render(readFileSync(T('plan/STACK.md.tmpl'), 'utf8'), v, fl)],
        ['docs/ENGINEERING-STANDARDS.md', render(readFileSync(T('plan/ENGINEERING-STANDARDS.md.tmpl'), 'utf8').replace('{{STACK_STANDARDS}}', v.STACK_STANDARDS), v, fl)],
        ...(fl.ui ? [['docs/UI-UX-STANDARDS.md', render(readFileSync(T('plan/UI-UX-STANDARDS.md.tmpl'), 'utf8').replace('{{UI_RULES}}', v.UI_RULES), v, fl)] as [string, string]] : []),
        ['CLAUDE.md', render(readFileSync(T('plan/claude-md-project.md.tmpl'), 'utf8'), v, fl)],
        ['.claude/workflow.json', `${JSON.stringify(workflowConfig(stack, uiId, fl, gates, v), null, 2)}\n`],
    ];
    const bad = outputs.flatMap(([f, s]) => leftovers(s).map((l) => `${f}: ${l}`));
    if (bad.length) fail(`unrendered placeholders (template bug):\n  ${bad.join('\n  ')}`);
    const created: string[] = [];
    const kept: string[] = [];
    for (const [f, s] of outputs) {
        const path = join(root, f);
        if (existsSync(path) && !flags.force) {
            // Keep the project's file; leave the rendered version next to the plan for a manual merge.
            const alt = join(PLAN, 'rendered', f);
            if (!flags['dry-run']) {
                mkdirSync(dirname(alt), { recursive: true });
                writeFileSync(alt, s);
            }
            kept.push(f);
            continue;
        }
        if (!flags['dry-run']) {
            mkdirSync(dirname(path), { recursive: true });
            writeFileSync(path, s);
        }
        created.push(f);
    }
    // Worktrees, plans and gate results live in .workflow/: never committed (as wf init does).
    const ignore = join(root, '.gitignore');
    const ignored = existsSync(ignore) ? readFileSync(ignore, 'utf8') : '';
    if (!/^\/?\.workflow\/?$/m.test(ignored)) {
        if (!flags['dry-run']) writeFileSync(ignore, `${ignored}${ignored && !ignored.endsWith('\n') ? '\n' : ''}.workflow/\n`);
        created.push('.gitignore: .workflow/');
    }
    if (!flags['dry-run']) {
        b.answers['decision.stack'] = stack.id;
        b.answers['decision.ui'] = uiId;
        b.source['decision.stack'] = b.source['decision.ui'] = 'owner';
        saveBrief(b);
    }
    const pend = gates.filter((g) => g.pending).map((g) => g.name);
    console.log(`${flags['dry-run'] ? 'would create' : 'created'}: ${created.join(', ') || 'nothing'}`);
    if (kept.length) console.log(`kept (exists; pass --force to replace, rendered copy in .workflow/plan/rendered/): ${kept.join(', ')}`);
    console.log(`gates: ${gates.length}${pend.length ? `, pending until installed: ${pend.join(' ')}` : ''}`);
    if (unverified) console.log(`versions: ${unverified} UNVERIFIED rows in docs/STACK.md; rerun without --no-versions or check the network`);
}

async function cards(): Promise<void> {
    const file = args[0] ?? fail('usage: wf plan cards FILE.json');
    type CardIn = { key?: string; title: string; size?: string; area?: string; milestone?: boolean; priority?: number; depends?: string[]; goal?: string; acceptance?: string[]; if?: string };
    const input = JSON.parse(readFileSync(file, 'utf8')) as { milestones?: { name?: string; cards: CardIn[] }[]; cards?: CardIn[] };
    const planned: CardIn[] = [...(input.milestones ?? []).flatMap((m) => m.cards), ...(input.cards ?? [])];
    const b = loadBrief();
    const stackId = String(b.answers['decision.stack'] ?? '');
    const uiId = String(b.answers['decision.ui'] ?? 'native');
    const fl = flagsOf(b.answers, uiId);
    const stack = stackId && existsSync(T(`stacks/${stackId}.json`)) ? loadStack(stackId) : undefined;
    const v: Record<string, string> = stack
        ? vars(b, stack, uiId, '', [])
        : { STACK_TITLE: 'chosen stack', DEV_URL: 'the dev URL', WIDEST_LOCALE: widest(arr(b.answers.locales)), FIRST_JOB: arr(b.answers['product.jobs'])[0] ?? 'the first core job' };
    const keys = new Set(planned.map((c) => c.key).filter(Boolean));
    const first = (JSON.parse(readFileSync(T('plan/milestones.json'), 'utf8')) as { first: CardIn[] }).first.filter((c) => (!c.if || fl[c.if]) && !keys.has(c.key));
    const all = [...first.map((c) => ({ ...c, priority: c.priority ?? 1 })), ...planned];
    const ids: Record<string, string> = { ...(b.cards ?? {}) };
    const existing = readCards();
    const wf = join(PLUGIN, 'scripts/wf.ts');
    if (!flags['dry-run']) mkdirSync(join(root, 'tasks/archive'), { recursive: true });
    for (const c0 of all) {
        const r = (s: string) => render(s, v, fl);
        const c = { ...c0, title: r(c0.title), goal: c0.goal ? r(c0.goal) : '', acceptance: (c0.acceptance ?? []).map(r).filter((x) => x.trim()) };
        const leftover = leftovers(JSON.stringify(c));
        if (leftover.length) fail(`card "${c.title}": unrendered ${leftover.join(' ')}`);
        const have = (c.key && ids[c.key] && existing.find((t) => t.id === ids[c.key as string])) || existing.find((t) => t.title === c.title);
        if (have) {
            if (c.key) ids[c.key] = have.id;
            console.log(`kept    ${have.id}  ${c.title}`);
            continue;
        }
        const unknown = (c.depends ?? []).filter((d) => !ids[d] && !/^[A-Za-z][A-Za-z0-9]*-\d+$/.test(d));
        if (unknown.length) console.error(`warning: "${c.title}" depends on unknown key(s) ${unknown.join(', ')}: no earlier card has that key; dependency dropped`);
        const deps = (c.depends ?? []).map((d) => ids[d] ?? (/^[A-Za-z][A-Za-z0-9]*-\d+$/.test(d) ? d : '')).filter(Boolean);
        const cmd = ['bun', wf, 'new', c.title, '--size', c.size ?? 'M', '--area', c.area ?? '', '--priority', String(c.priority ?? 2), ...(deps.length ? ['--depends', deps.join(',')] : []), ...(c.milestone ? ['--milestone'] : [])];
        if (flags['dry-run']) {
            console.log(`would   ${c.title}${deps.length ? ` (after ${deps.join(',')})` : ''}`);
            if (c.key) ids[c.key] = `${c.key}?`;
            continue;
        }
        const res = Bun.spawnSync(cmd, { cwd: root, env: { ...process.env, WF_ROOT: root } });
        if (!res.success) fail(`wf new failed for "${c.title}": ${res.stderr.toString().trim()}`);
        const [id, path] = res.stdout.toString().trim().split(/\s+/);
        const body = `## Goal\n\n${c.goal || c.title}\n\n## Acceptance\n\n${(c.acceptance.length ? c.acceptance : ['(define)']).map((x) => `- [ ] ${x}`).join('\n')}\n`;
        const cardPath = join(root, path);
        writeFileSync(cardPath, readFileSync(cardPath, 'utf8').replace(/## Goal\n[\s\S]*$/, body));
        if (c.key) ids[c.key] = id;
        console.log(`created ${id}  ${c.title}`);
    }
    if (!flags['dry-run']) {
        b.cards = ids;
        saveBrief(b);
    }
}

function status(): void {
    const b = loadBrief();
    const q = qfile();
    const all = [...q.text.map((t) => t.key), ...q.questions.map((x) => x.key)];
    const answered = all.filter((k) => k in b.answers).length;
    const research = existsSync(join(PLAN, 'research')) ? readdirSync(join(PLAN, 'research')).filter((f) => f.endsWith('.md')) : [];
    const phases: [string, boolean, string][] = [
        ['detect', existsSync(join(PLAN, 'detect.json')), 'wf detect --save'],
        ['interview', answered === all.length, `${answered}/${all.length} answered; wf plan questions`],
        ['research', research.length >= 2, `${research.length} notes in .workflow/plan/research/`],
        ['decide', existsSync(join(PLAN, 'options.md')), '.workflow/plan/options.md'],
        ['scaffold', !!b.answers['decision.stack'] && existsSync(join(root, 'docs/STACK.md')), 'wf plan scaffold --stack ID --ui ID'],
        ['tune', b.answers['phase.tuned'] === true, 'edit <!-- tune --> blocks, then wf plan set phase.tuned true'],
        ['verify', b.answers['phase.verified'] === true, 'wf doctor && wf gates --list, then wf plan set phase.verified true'],
        ['cards', Object.keys(b.cards ?? {}).length > 0, 'wf plan cards .workflow/plan/cards.json'],
    ];
    for (const [name, done, how] of phases) console.log(`${done ? '[x]' : '[ ]'} ${name.padEnd(9)} ${how}`);
    const next = phases.find((p) => !p[1]);
    console.log(next ? `next: ${next[0]}` : 'next: /workflow:init, then /workflow:next');
}

function unpend(): void {
    const p = join(root, '.claude/workflow.json');
    if (!existsSync(p)) fail('no .claude/workflow.json');
    const cfg = JSON.parse(readFileSync(p, 'utf8')) as { gates?: StackGate[]; stack?: { id?: string } };
    const stack = cfg.stack?.id && existsSync(T(`stacks/${cfg.stack.id}.json`)) ? loadStack(cfg.stack.id) : undefined;
    const cleared: string[] = [];
    const still: string[] = [];
    for (const g of cfg.gates ?? []) {
        if (!g.pending) continue;
        // A scaffolded gate keeps its stack's `requires`; any other gate (wf init) needs its command's tools.
        const src = stack?.gates.find((s) => s.name === g.name);
        const lacking = src?.requires ? (missing({ ...src, cwd: g.cwd }) ? src.requires : []) : missingTools(g.cmd, join(root, typeof g.cwd === 'string' ? g.cwd : ''));
        if (!lacking.length) {
            delete g.pending;
            cleared.push(g.name);
        } else still.push(`${g.name} (needs ${lacking.join(', ')})`);
    }
    writeFileSync(p, `${JSON.stringify(cfg, null, 2)}\n`);
    console.log(`cleared: ${cleared.join(' ') || 'none'}${still.length ? `; still pending: ${still.join(', ')}` : ''}`);
}

switch (sub) {
    case 'set': {
        const [key, value] = args;
        if (!key || value === undefined) fail('usage: wf plan set KEY VALUE [--assumed]');
        const b = loadBrief();
        const v = normalize(key, value);
        const bad = invalid(key, v);
        if (bad.length) {
            const q = qfile().questions.find((x) => x.key === key);
            console.error(`plan: ${key}: not an option: ${bad.join(', ')}\nvalid: ${q?.options.map((o) => JSON.stringify(o.label)).join(', ')}${q?.multiSelect ? ' (several: comma-separated or a JSON list)' : ''}`);
            process.exit(2);
        }
        b.answers[key] = v;
        b.source[key] = flags.assumed ? 'assumed' : 'owner';
        saveBrief(b);
        console.log(`${key} = ${JSON.stringify(b.answers[key])}${flags.assumed ? ' (assumed)' : ''}`);
        break;
    }
    case 'get': {
        const b = loadBrief();
        console.log(JSON.stringify(args[0] ? b.answers[args[0]] ?? null : b, null, 2));
        break;
    }
    case 'questions': {
        const b = loadBrief();
        const det = loadDetect();
        for (const [k, val] of Object.entries(detectedAnswers(det))) {
            if (k in b.answers) continue;
            b.answers[k] = val;
            b.source[k] = 'detected';
        }
        saveBrief(b);
        const q = qfile();
        const max = Number(flags.max ?? 4);
        const text = q.text.filter((t) => !(t.key in b.answers));
        const open = q.questions.filter((x) => !(x.key in b.answers));
        const batch = open.slice(0, max).map((x) => ({ key: x.key, header: x.header, question: x.question, multiSelect: x.multiSelect, options: x.options.map((o) => ({ label: o.label, description: o.description })) }));
        if (flags.json) {
            console.log(JSON.stringify({ text: text.map((t) => ({ key: t.key, prompt: t.prompt })), questions: batch, remaining: open.length - batch.length }, null, 2));
            break;
        }
        for (const t of text) console.log(`text  ${t.key}: ${t.prompt}`);
        for (const x of batch) console.log(`ask   ${x.key} [${x.header}${x.multiSelect ? ', multi' : ''}] ${x.question} | ${x.options.map((o) => o.label).join(' / ')}`);
        console.log(`${open.length - batch.length} more after this batch${open.length ? '' : ' (interview complete)'}`);
        break;
    }
    case 'defaults': {
        const b = loadBrief();
        const q = qfile();
        const set: string[] = [];
        for (const x of [...q.text, ...q.questions]) {
            if (x.key in b.answers) continue;
            b.answers[x.key] = x.default;
            b.source[x.key] = 'assumed';
            set.push(x.key);
        }
        saveBrief(b);
        console.log(`assumed: ${set.join(', ') || 'nothing (all answered)'}`);
        break;
    }
    case 'status':
        status();
        break;
    case 'stacks': {
        const list = readdirSync(T('stacks')).filter((f) => f.endsWith('.json')).map((f) => loadStack(f.slice(0, -5)));
        if (flags.json) console.log(JSON.stringify(list.map((s) => ({ id: s.id, title: s.title, summary: s.summary, fits: s.fits, avoid: s.avoid, languages: s.languages, ui: s.ui, uiOptions: s.uiOptions, packages: s.packages })), null, 2));
        else for (const s of list) console.log(`${s.id.padEnd(22)} ${s.title} [ui: ${s.uiOptions.join('|')}]`);
        break;
    }
    case 'scaffold':
        await scaffold();
        break;
    case 'cards':
        await cards();
        break;
    case 'unpend':
        unpend();
        break;
    case '-h':
    case '--help':
    case 'help':
        console.log(headerHelp(import.meta.path));
        break;
    default:
        fail(`unknown subcommand ${sub} (wf plan --help)`);
}
