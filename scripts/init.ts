#!/usr/bin/env bun
// wf init: bootstrap a repo for the workflow. Detects the stack (wf detect) and prints a
// suggested .claude/workflow.json; with --write also creates tasks/,
// tasks/archive/, tasks/README.md, the config (never overwritten without
// --force) and a .gitignore entry for .workflow/.
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { baseBranch, detect, gatesFor } from './cmd/detect.ts';
import { idPrefix, root } from './lib.ts';

const argv = process.argv.slice(2);
const write = argv.includes('--write');
const force = argv.includes('--force');
const has = (p: string) => existsSync(`${root}${p}`);
const read = (p: string) => (has(p) ? readFileSync(`${root}${p}`, 'utf8') : '');

// Manifests at depth <= 3: monorepos get one gate set per package, with cwd.
const det = detect(root);
const { gates, link, setup, testAffected } = gatesFor(det);
const copy = det.env.includes('.env') ? ['.env'] : [];
const stack = det.packages.map((p) => `${p.dir || '.'}: ${p.kind}${p.pm ? ` (${p.pm})` : ''}`);
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
    milestone: { label: 'v1' },
    gates,
    ...(testAffected ? { testAffected } : {}),
    ...(releaseCmd ? { release: { cmd: releaseCmd } } : {}),
    worktree: { link, copy, setup },
    ui,
    dev: ui ? { url: devUrl || 'http://127.0.0.1:3000', login: '', viewports: [1440, 390] } : undefined,
    docs: { design: [] as string[], ...(standards.length ? { standards } : {}) },
    risk: { high: [] as string[] },
    overnight: { parallel: 2, model: 'opus' },
};
const json = `${JSON.stringify(config, null, 2)}\n`;

if (!write) {
    console.log(`# stack: ${stack.join(', ') || 'unknown'}${justRecipes.length ? `; just recipes: ${justRecipes.join(' ')}` : ''}`);
    console.log(json);
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
    console.log('kept existing .claude/workflow.json (pass --force to replace); suggested config:');
    console.log(json);
}
if (!/^\/?\.workflow\/?$/m.test(read('.gitignore'))) {
    appendFileSync(`${root}.gitignore`, `${read('.gitignore') && !read('.gitignore').endsWith('\n') ? '\n' : ''}.workflow/\n`);
    made.push('.gitignore: .workflow/');
}
console.log(`stack: ${stack.join(', ') || 'unknown'}${justRecipes.length ? `; just recipes: ${justRecipes.join(' ')}` : ''}`);
console.log(`gates: ${gates.map((g) => `${g.name}${g.pending ? ' (pending)' : ''}`).join(', ') || 'none detected'}`);
console.log(`created: ${made.join(', ') || 'nothing (already initialised)'}`);
