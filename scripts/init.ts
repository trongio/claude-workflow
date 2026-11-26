#!/usr/bin/env bun
// wf init: bootstrap a repo for the workflow. Detects the stack (wf detect) and prints a
// short summary of the suggested .claude/workflow.json (stacks, gates, where it goes);
// --full prints the whole config. With --write also creates tasks/, tasks/archive/,
// tasks/README.md, the config (never overwritten without --force) and a .gitignore
// entry for .workflow/.
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { baseBranch, detect, gatesFor, missingTools, notInstalled } from './cmd/detect.ts';
import { idPrefix, root } from './lib.ts';

const argv = process.argv.slice(2);
const write = argv.includes('--write');
const force = argv.includes('--force');
const full = argv.includes('--full');
if (argv.includes('--help') || argv.includes('-h')) {
    console.log('Usage: wf init [--write] [--force] [--full]\n  (no flag)  summary of the suggested .claude/workflow.json\n  --full     print the whole suggested config\n  --write    create tasks/, the config (kept unless --force) and the .gitignore entry');
    process.exit(0);
}
const has = (p: string) => existsSync(`${root}${p}`);
const read = (p: string) => (has(p) ? readFileSync(`${root}${p}`, 'utf8') : '');

// Manifests at depth <= 3: monorepos get one gate set per package, with cwd.
const det = detect(root);
const { gates, link, setup, testAffected } = gatesFor(det);
const copy = det.env.includes('.env') ? ['.env'] : [];
const stack = det.packages.map((p) => `${p.dir || '.'}: ${p.kind}${p.pm ? ` (${p.pm})` : ''}${p.installed ? '' : ` [${notInstalled(p)}]`}`);
const ui = det.packages.some((p) => p.ui);
const devUrl = det.packages.find((p) => p.devUrl)?.devUrl ?? '';
const justRecipes = det.just;
// The project's own CI recipe, when it has one, is the release gate.
const releaseCmd = det.just.includes('ci') ? 'just ci' : det.make.includes('ci') ? 'make ci' : '';
const standards = ['docs/ENGINEERING-STANDARDS.md', 'docs/UI-UX-STANDARDS.md'].filter(has);
const base = baseBranch(root);

const config = {
    $schema: 'https://raw.githubusercontent.com/trongio/claude-workflow/main/schema/workflow.schema.json',
    idPrefix: idPrefix(),
    baseBranch: base,
    wipLimit: 2,
    milestone: { label: 'milestone' },
    gates,
    ...(testAffected ? { testAffected } : {}),
    ...(releaseCmd ? { release: { cmd: releaseCmd } } : {}),
    worktree: { link, copy, setup },
    ui,
    dev: ui ? { url: devUrl || 'http://127.0.0.1:3000', login: '', viewports: [375, 1440] } : undefined,
    docs: { design: [] as string[], ...(standards.length ? { standards } : {}) },
    overnight: { parallel: 2, model: 'opus' },
};
const json = `${JSON.stringify(config, null, 2)}\n`;

// One row per gate: name, cwd, how many `when` globs, and flags; a pending gate names what it needs.
function summary(): string {
    const rows = gates.map((g) => {
        const needs = g.pending ? missingTools(g.cmd, join(root, g.cwd ?? '')) : [];
        const fl = [g.heavy ? 'heavy' : '', g.inner === false ? 'release-only' : '', g.release === false ? 'inner-only' : '', g.fix ? 'fix' : '', g.pending ? `pending (needs ${needs.join(', ') || 'install'})` : ''];
        return [g.name, g.cwd ?? '.', String(g.when.length), fl.filter(Boolean).join(', ') || '-'];
    });
    const head = ['gate', 'cwd', 'when', 'flags'];
    const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i].length)));
    const fmt = (r: string[]) => r.map((c, i) => (i === r.length - 1 ? c : c.padEnd(w[i]))).join('  ');
    return [`stack: ${stack.join(', ') || 'unknown'}${justRecipes.length ? `; just recipes: ${justRecipes.join(' ')}` : ''}`, ...(rows.length ? [fmt(head), ...rows.map(fmt)] : ['gates: none detected']), ...(releaseCmd ? [`release: ${releaseCmd}`] : [])].join('\n');
}

if (!write) {
    if (full) console.log(json);
    else console.log(`${summary()}\nsuggested config for ${root}.claude/workflow.json (risk.high: built-in, see wf risk --explain); --full prints it, --write writes it`);
    process.exit(0);
}

const made: string[] = [];
for (const d of ['tasks', 'tasks/archive', '.claude']) {
    if (!has(d)) {
        mkdirSync(`${root}${d}`, { recursive: true });
        made.push(`${d}/`);
    }
}
if (!has('tasks/README.md')) {
    writeFileSync(`${root}tasks/README.md`, readFileSync(new URL('../templates/tasks-README.md', import.meta.url), 'utf8').replaceAll('{{PREFIX}}', config.idPrefix));
    made.push('tasks/README.md');
}
if (!has('tasks/archive/.gitkeep')) writeFileSync(`${root}tasks/archive/.gitkeep`, '');
if (!has('.claude/workflow.json') || force) {
    writeFileSync(`${root}.claude/workflow.json`, json);
    made.push('.claude/workflow.json');
} else {
    console.log(`kept existing .claude/workflow.json (pass --force to replace${full ? '' : '; wf init --full prints the suggestion'})`);
    if (full) console.log(json);
}
if (!/^\/?\.workflow\/?$/m.test(read('.gitignore'))) {
    appendFileSync(`${root}.gitignore`, `${read('.gitignore') && !read('.gitignore').endsWith('\n') ? '\n' : ''}.workflow/\n`);
    made.push('.gitignore: .workflow/');
}
console.log(summary());
console.log(`created: ${made.join(', ') || 'nothing (already initialised)'}`);
