#!/usr/bin/env bun
// wf init: bootstrap a repo for the workflow. Detects the stack and prints a
// suggested .claude/workflow.json; with --write also creates tasks/,
// tasks/archive/, tasks/README.md, the config (never overwritten without
// --force) and a .gitignore entry for .workflow/.
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { idPrefix, root } from './lib.ts';

const argv = process.argv.slice(2);
const write = argv.includes('--write');
const force = argv.includes('--force');
const has = (p: string) => existsSync(`${root}${p}`);
const read = (p: string) => (has(p) ? readFileSync(`${root}${p}`, 'utf8') : '');

type Gate = { name: string; cmd: string; when?: string[]; fix?: string };
const gates: Gate[] = [];
const link: string[] = [];
const copy: string[] = [];
const setup: string[] = [];
const stack: string[] = [];
let ui = false;
let devUrl = '';

// JavaScript / TypeScript
if (has('package.json')) {
    const pkg = JSON.parse(read('package.json')) as { scripts?: Record<string, string>; dependencies?: Record<string, string>; devDependencies?: Record<string, string> };
    const scripts = pkg.scripts ?? {};
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };
    const pm = has('bun.lock') || has('bun.lockb') ? 'bun' : has('pnpm-lock.yaml') ? 'pnpm' : has('yarn.lock') ? 'yarn' : 'npm';
    const lock = { bun: has('bun.lock') ? 'bun.lock' : 'bun.lockb', pnpm: 'pnpm-lock.yaml', yarn: 'yarn.lock', npm: 'package-lock.json' }[pm];
    const when = ['*.ts', '*.tsx', '*.js', '*.jsx', '*.mjs', '*.cjs', '*.vue', '*.svelte', '*.astro', '*.css', 'package.json', lock, 'tsconfig*.json'];
    stack.push(`node (${pm})`);
    const run = (s: string) => `${pm} run ${s}`;
    const typecheck = ['typecheck', 'type-check', 'tsc', 'check-types'].find((s) => scripts[s]);
    if (scripts.test && !/no test specified/.test(scripts.test)) gates.push({ name: 'test', cmd: run('test'), when });
    if (scripts.lint) gates.push({ name: 'lint', cmd: run('lint'), when, ...(scripts['lint:fix'] ? { fix: run('lint:fix') } : {}) });
    if (typecheck) gates.push({ name: 'typecheck', cmd: run(typecheck), when });
    if (scripts.build) gates.push({ name: 'build', cmd: run('build'), when });
    if (scripts.format && scripts['format:check']) gates.push({ name: 'format', cmd: run('format:check'), when, fix: run('format') });
    if (has('node_modules')) link.push('node_modules');
    else setup.push(`${pm} install`);
    if (['react', 'vue', 'svelte', 'next', 'nuxt', 'astro', 'vite', '@sveltejs/kit', 'solid-js', '@angular/core'].some((d) => deps[d])) ui = true;
    if (deps.next) devUrl = 'http://127.0.0.1:3000';
    else if (deps.vite || deps.astro) devUrl = 'http://127.0.0.1:5173';
}

// PHP
if (has('composer.json')) {
    const when = ['*.php', 'composer.json', 'composer.lock'];
    stack.push('php');
    if (has('vendor/bin/pest')) gates.push({ name: 'pest', cmd: './vendor/bin/pest --parallel', when });
    else if (has('vendor/bin/phpunit')) gates.push({ name: 'phpunit', cmd: './vendor/bin/phpunit', when });
    if (has('vendor/bin/pint')) gates.push({ name: 'pint', cmd: './vendor/bin/pint --test', when, fix: './vendor/bin/pint' });
    if (has('vendor/bin/phpstan')) gates.push({ name: 'phpstan', cmd: './vendor/bin/phpstan analyse --no-progress', when });
    link.push('vendor');
    if (has('artisan')) {
        ui = true;
        devUrl ||= 'http://127.0.0.1:8000';
    }
}

// Python
if (has('pyproject.toml') || has('requirements.txt')) {
    const py = read('pyproject.toml');
    const r = has('uv.lock') ? 'uv run ' : '';
    const when = ['*.py', 'pyproject.toml', 'uv.lock', 'requirements*.txt'];
    stack.push(r ? 'python (uv)' : 'python');
    gates.push({ name: 'pytest', cmd: `${r}pytest -q`, when });
    if (/ruff/.test(py)) gates.push({ name: 'ruff', cmd: `${r}ruff check . && ${r}ruff format --check .`, when, fix: `${r}ruff check --fix . && ${r}ruff format .` });
    if (/mypy/.test(py)) gates.push({ name: 'mypy', cmd: `${r}mypy .`, when });
    if (r) setup.push('uv sync');
    if (has('manage.py')) {
        ui = true;
        devUrl ||= 'http://127.0.0.1:8000';
    }
}

// Go
if (has('go.mod')) {
    const when = ['*.go', 'go.mod', 'go.sum'];
    stack.push('go');
    gates.push({ name: 'go-test', cmd: 'go test ./...', when });
    gates.push({ name: 'go-vet', cmd: 'go vet ./...', when });
    gates.push({ name: 'gofmt', cmd: 'test -z "$(gofmt -l .)"', when, fix: 'gofmt -w .' });
}

// Rust
if (has('Cargo.toml')) {
    const when = ['*.rs', 'Cargo.toml', 'Cargo.lock'];
    stack.push('rust');
    gates.push({ name: 'cargo-test', cmd: 'cargo test --quiet', when });
    gates.push({ name: 'clippy', cmd: 'cargo clippy --quiet -- -D warnings', when });
    gates.push({ name: 'rustfmt', cmd: 'cargo fmt --check', when, fix: 'cargo fmt' });
}

// Shell scripts
if (Bun.spawnSync(['git', 'ls-files', '*.sh'], { cwd: root, stderr: 'ignore' }).stdout.toString().trim()) {
    gates.push({ name: 'shellcheck', cmd: 'git ls-files -z "*.sh" | xargs -0 -r shellcheck', when: ['*.sh'] });
}

let justRecipes: string[] = [];
if (has('justfile') || has('Justfile')) {
    const r = Bun.spawnSync(['just', '--summary'], { cwd: root, stderr: 'ignore' });
    justRecipes = r.success ? r.stdout.toString().trim().split(/\s+/).filter(Boolean) : [];
    stack.push('just');
}
if (has('.env')) copy.push('.env');

const base = Bun.spawnSync(['git', 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD'], { cwd: root, stderr: 'ignore' }).stdout.toString().trim().replace(/^origin\//, '')
    || Bun.spawnSync(['git', 'branch', '--show-current'], { cwd: root, stderr: 'ignore' }).stdout.toString().trim() || 'main';

const config = {
    $schema: 'https://raw.githubusercontent.com/trongio/claude-workflow/main/schema/workflow.schema.json',
    idPrefix: idPrefix(),
    baseBranch: base,
    wipLimit: 2,
    milestone: { label: 'v1' },
    gates,
    worktree: { link, copy, setup },
    ui,
    dev: ui ? { url: devUrl || 'http://127.0.0.1:3000', login: '', viewports: [1440, 390] } : undefined,
    docs: { design: [] as string[] },
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
console.log(`gates: ${gates.map((g) => g.name).join(', ') || 'none detected'}`);
console.log(`created: ${made.join(', ') || 'nothing (already initialised)'}`);
