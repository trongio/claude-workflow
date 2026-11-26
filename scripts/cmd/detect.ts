#!/usr/bin/env bun
// wf-help: detect the stack (manifests to depth 3, lockfile versions, CI, recipes, tests, tokens, locales, docs) [--json] [--save]
// Usage: wf detect [--json] [--save] [--dir DIR]
//   --json   print the full detection as JSON (consumed by wf init and wf plan)
//   --save   also write it to .workflow/plan/detect.json
// Imported by scripts/init.ts for gate generation (detect, gatesFor, baseBranch).
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';

export type Kind = 'node' | 'php' | 'python' | 'go' | 'rust';
export type Pkg = {
    dir: string; // '' for the repo root, else a relative path without trailing slash
    kind: Kind;
    manifest: string;
    pm?: string; // node package manager
    lockfile?: string; // relative to the repo root
    frameworks: Record<string, string>; // notable deps -> locked (or declared) version
    deps: string[]; // every direct dependency name
    scripts: string[]; // package.json scripts / composer scripts
    installed: boolean; // node_modules / vendor / .venv present
    ui: boolean;
    devUrl?: string;
};
export type Detection = {
    root: string;
    greenfield: boolean;
    packages: Pkg[];
    ci: string[];
    make: string[];
    just: string[];
    testDirs: string[];
    tokens: string[];
    locales: { dir: string; locales: string[] }[];
    docs: string[];
    shell: boolean;
    env: string[];
};
export type Gate = {
    name: string;
    cmd: string;
    when: string[];
    fix?: string;
    cwd?: string;
    heavy?: boolean;
    release?: boolean;
    inner?: boolean; // false: release-only (skipped by the inner loop)
    pending?: boolean;
    cache?: boolean;
};

const SKIP = new Set(['node_modules', 'vendor', '.git', 'target', 'dist', 'build', '.venv', 'venv', '.workflow', '.next', '.nuxt', '.svelte-kit', 'coverage', '__pycache__', '.idea', '.vscode', 'storage', 'public']);
const MANIFESTS: Record<string, Kind> = { 'package.json': 'node', 'composer.json': 'php', 'pyproject.toml': 'python', 'requirements.txt': 'python', 'go.mod': 'go', 'Cargo.toml': 'rust' };
const NOTABLE = [
    'next', 'react', 'vue', 'svelte', '@sveltejs/kit', 'nuxt', 'astro', 'vite', 'hono', 'express', 'fastify', '@nestjs/core', '@inertiajs/react', '@inertiajs/vue3',
    'tailwindcss', '@mantine/core', 'vitest', 'jest', '@playwright/test', 'typescript', 'eslint', '@biomejs/biome', 'prettier', 'knip', 'drizzle-orm', 'prisma',
    'laravel/framework', 'inertiajs/inertia-laravel', 'pestphp/pest', 'phpunit/phpunit', 'larastan/larastan', 'phpstan/phpstan', 'laravel/pint', 'laravel/octane', 'symfony/framework-bundle',
    'django', 'fastapi', 'flask', 'pytest', 'ruff', 'mypy', 'pyright', 'django-htmx',
    'axum', 'actix-web', 'tokio', 'sqlx', 'serde',
    'github.com/gin-gonic/gin', 'github.com/labstack/echo/v4', 'github.com/go-chi/chi/v5', 'github.com/gofiber/fiber/v2',
];
const UI_DEPS = ['react', 'vue', 'svelte', 'next', 'nuxt', 'astro', 'vite', '@sveltejs/kit', 'solid-js', '@angular/core'];

function walk(root: string, rel: string, depth: number, visit: (rel: string, names: string[]) => void): void {
    let names: string[];
    try {
        names = readdirSync(join(root, rel));
    } catch {
        return;
    }
    visit(rel, names);
    if (depth >= 3) return;
    for (const n of names) {
        if (SKIP.has(n) || (n.startsWith('.') && n !== '.github')) continue;
        const p = rel ? `${rel}/${n}` : n;
        try {
            if (statSync(join(root, p)).isDirectory()) walk(root, p, depth + 1, visit);
        } catch {
            // unreadable entry: skip
        }
    }
}

const readSafe = (p: string) => {
    try {
        return readFileSync(p, 'utf8');
    } catch {
        return '';
    }
};
const json = (p: string): Record<string, unknown> => {
    try {
        return JSON.parse(readFileSync(p, 'utf8')) as Record<string, unknown>;
    } catch {
        return {};
    }
};
const haveCmd = (c: string) => Bun.spawnSync(['bash', '-c', `command -v ${c}`], { stdout: 'ignore', stderr: 'ignore' }).success;

const rec = (v: unknown) => (v && typeof v === 'object' ? (v as Record<string, string>) : {});
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

// Nearest file named one of `names` in dir or any ancestor up to the root.
function upFind(root: string, dir: string, names: string[]): string | undefined {
    let d = dir;
    for (;;) {
        for (const n of names) {
            const p = d ? `${d}/${n}` : n;
            if (existsSync(join(root, p))) return p;
        }
        if (!d) return undefined;
        d = d.includes('/') ? dirname(d) : '';
    }
}

// Locked version of `dep` from a lockfile's text (several formats), else undefined.
function lockedVersion(lockPath: string, text: string, dep: string): string | undefined {
    const name = basename(lockPath);
    if (name === 'package-lock.json') {
        const pk = rec((json(lockPath) as { packages?: unknown }).packages);
        const hit = Object.entries(pk).find(([k]) => k.endsWith(`node_modules/${dep}`));
        return hit ? (hit[1] as unknown as { version?: string }).version : undefined;
    }
    if (name === 'bun.lock') return text.match(new RegExp(`"${esc(dep)}": \\["${esc(dep)}@([^"]+)"`))?.[1];
    if (name === 'pnpm-lock.yaml') return text.match(new RegExp(`\\n\\s+'?/?${esc(dep)}@([0-9][^(:'\\s]*)`))?.[1];
    if (name === 'yarn.lock') return text.match(new RegExp(`\\n"?${esc(dep)}@[^\\n]*:\\n\\s+version:? "?([^"\\n]+)`))?.[1];
    if (name === 'composer.lock') {
        const all = [...((json(lockPath).packages as { name: string; version: string }[]) ?? []), ...((json(lockPath)['packages-dev'] as { name: string; version: string }[]) ?? [])];
        return all.find((p) => p.name === dep)?.version?.replace(/^v/, '');
    }
    // TOML lockfiles: uv.lock, poetry.lock, Cargo.lock
    return text.match(new RegExp(`\\[\\[package\\]\\]\\nname = "${esc(dep)}"\\nversion = "([^"]+)"`, 'i'))?.[1];
}

function parsePkg(root: string, dir: string, manifest: string): Pkg {
    const kind = MANIFESTS[manifest];
    const at = (n: string) => join(root, dir, n);
    const pkg: Pkg = { dir, kind, manifest: dir ? `${dir}/${manifest}` : manifest, frameworks: {}, deps: [], scripts: [], installed: false, ui: false };
    let declared: Record<string, string> = {};
    let locks: string[] = [];
    if (kind === 'node') {
        const m = json(at('package.json'));
        declared = { ...rec(m.dependencies), ...rec(m.devDependencies) };
        pkg.scripts = Object.keys(rec(m.scripts));
        locks = ['bun.lock', 'pnpm-lock.yaml', 'yarn.lock', 'package-lock.json', 'bun.lockb'];
        const lock = upFind(root, dir, locks);
        pkg.lockfile = lock;
        const ln = lock ? basename(lock) : '';
        pkg.pm = ln.startsWith('bun') ? 'bun' : ln === 'pnpm-lock.yaml' ? 'pnpm' : ln === 'yarn.lock' ? 'yarn' : 'npm';
        pkg.installed = !!upFind(root, dir, ['node_modules']);
        pkg.ui = UI_DEPS.some((d) => declared[d]);
        if (declared.next) pkg.devUrl = 'http://127.0.0.1:3000';
        else if (declared['@sveltejs/kit'] || declared.vite || declared.astro) pkg.devUrl = 'http://127.0.0.1:5173';
    } else if (kind === 'php') {
        const m = json(at('composer.json'));
        declared = { ...rec(m.require), ...rec(m['require-dev']) };
        pkg.scripts = Object.keys(rec(m.scripts));
        locks = ['composer.lock'];
        pkg.installed = existsSync(at('vendor'));
        if (existsSync(at('artisan'))) {
            pkg.ui = true;
            pkg.devUrl = 'http://127.0.0.1:8000';
        }
    } else if (kind === 'python') {
        const text = readSafe(at(manifest)) + readSafe(at('requirements-dev.txt'));
        for (const m of text.matchAll(/^\s*"?([A-Za-z0-9_.-]+)\s*(?:\[[^\]]*\])?\s*(?:[=<>~!]=?\s*"?([0-9][^",;\s]*))?/gm)) {
            if (!/^(name|version|description|requires-python|readme|license|authors|dependencies|build-backend|requires)$/i.test(m[1])) declared[m[1].toLowerCase()] = m[2] ?? '*';
        }
        locks = ['uv.lock', 'poetry.lock'];
        pkg.installed = existsSync(at('.venv'));
        if (existsSync(at('manage.py'))) {
            pkg.ui = true;
            pkg.devUrl = 'http://127.0.0.1:8000';
        }
    } else if (kind === 'go') {
        for (const m of readSafe(at('go.mod')).matchAll(/^\s*(?:require\s+)?([a-z0-9.-]+\.[a-z]+\/[^\s]+)\s+v([^\s]+)/gm)) declared[m[1]] = m[2];
        pkg.installed = haveCmd('go');
    } else if (kind === 'rust') {
        const text = readSafe(at('Cargo.toml'));
        const deps = text.split(/^\[/m).filter((s) => /^(workspace\.)?(dev-)?dependencies\]/.test(s));
        for (const sec of deps) for (const m of sec.matchAll(/^([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]+)"|\{[^}]*?version\s*=\s*"([^"]+)")?/gm)) declared[m[1]] = m[2] ?? m[3] ?? '*';
        locks = ['Cargo.lock'];
        pkg.installed = haveCmd('cargo');
    }
    if (kind !== 'node' && locks.length) pkg.lockfile = upFind(root, dir, locks);
    pkg.deps = Object.keys(declared);
    const lockText = pkg.lockfile && !pkg.lockfile.endsWith('.lockb') ? readSafe(join(root, pkg.lockfile)) : '';
    for (const d of NOTABLE) {
        if (!(d in declared)) continue;
        pkg.frameworks[d] = (pkg.lockfile && lockedVersion(join(root, pkg.lockfile), lockText, d)) || String(declared[d]);
    }
    return pkg;
}

function recipes(root: string): { make: string[]; just: string[] } {
    const mk = readSafe(join(root, 'Makefile'));
    const make = [...new Set([...mk.matchAll(/^([A-Za-z0-9][A-Za-z0-9_.-]*):(?!=)/gm)].map((m) => m[1]))];
    const jf = readSafe(join(root, 'justfile')) || readSafe(join(root, 'Justfile')) || readSafe(join(root, '.justfile'));
    const just = [...new Set([...jf.matchAll(/^@?([A-Za-z0-9][A-Za-z0-9_-]*)(?:\s+[^:=\n]*)?:(?!=)/gm)].map((m) => m[1]))];
    return { make, just };
}

export function detect(rootDir: string): Detection {
    const root = rootDir.replace(/\/$/, '');
    const det: Detection = { root, greenfield: true, packages: [], ci: [], ...recipes(root), testDirs: [], tokens: [], locales: [], docs: [], shell: false, env: [] };
    const LOCALE = /^[a-z]{2}(?:[-_][A-Za-z]{2,4})?$/;
    let files = 0;
    walk(root, '', 0, (rel, names) => {
        const p = (n: string) => (rel ? `${rel}/${n}` : n);
        files += names.length;
        const here = new Set(names);
        for (const [m] of Object.entries(MANIFESTS)) {
            if (!here.has(m)) continue;
            if (m === 'requirements.txt' && here.has('pyproject.toml')) continue;
            det.packages.push(parsePkg(root, rel, m));
        }
        if (rel === '.github/workflows') det.ci.push(...names.filter((n) => /\.ya?ml$/.test(n)).map(p));
        if (!rel) for (const n of ['.gitlab-ci.yml', 'bitbucket-pipelines.yml', '.circleci', 'azure-pipelines.yml', 'Jenkinsfile']) if (here.has(n)) det.ci.push(n);
        for (const n of names) {
            const full = p(n);
            if (['tests', 'test', '__tests__', 'spec', 'e2e'].includes(n)) det.testDirs.push(full);
            if (/^(tailwind\.config\.[cm]?[jt]s|components\.json|tokens\.json|design-tokens\.json|theme\.css|tokens\.css|variables\.css)$/.test(n)) det.tokens.push(full);
            if (['lang', 'locales', 'locale', 'i18n', 'translations', 'messages'].includes(n)) {
                let entries: string[] = [];
                try {
                    entries = readdirSync(join(root, full));
                } catch {
                    // not a directory
                }
                const locales = [...new Set(entries.map((e) => e.replace(/\.(json|php|ya?ml|po|ts|js)$/, '')).filter((e) => LOCALE.test(e)))];
                if (locales.length) det.locales.push({ dir: full, locales: locales.sort() });
            }
            if (/\.md$/i.test(n) && (!rel || rel === 'docs' || rel.startsWith('docs/')) && !/^(CHANGELOG|LICENSE)/i.test(n)) det.docs.push(full);
            if (/\.sh$/.test(n)) det.shell = true;
            if (!rel && /^\.env(\.example|\.sample|\.dist)?$/.test(n)) det.env.push(n);
        }
    });
    // A css file that declares custom properties counts as tokens (shallow check, root resources/ and src/ only).
    for (const p of ['resources/css/app.css', 'src/app.css', 'src/index.css', 'app/globals.css', 'src/styles/globals.css']) if (/--[a-z][\w-]*\s*:/.test(readSafe(join(root, p)))) det.tokens.push(p);
    det.greenfield = det.packages.length === 0 && files < 25;
    det.packages.sort((a, b) => a.dir.length - b.dir.length || a.dir.localeCompare(b.dir));
    return det;
}

// Base branch: origin's HEAD, else the first of main/master/trunk/develop that exists, else main.
// Never the current branch: a feature branch is not a base.
export function baseBranch(root: string): string {
    const git = (...a: string[]) => Bun.spawnSync(['git', ...a], { cwd: root, stderr: 'ignore' });
    const head = git('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD').stdout.toString().trim().replace(/^origin\//, '');
    if (head) return head;
    return ['main', 'master', 'trunk', 'develop'].find((b) => git('show-ref', '--verify', '--quiet', `refs/heads/${b}`).success) ?? 'main';
}

export type GateResult = { gates: Gate[]; testAffected?: { cmd: string; map: { src: string; tests: string }[] }; link: string[]; setup: string[] };

// Gates for every detected package. Nested packages get cwd and path-prefixed `when`
// globs; every gate has `when`; test/build/typecheck gates are heavy; where the runner
// has an affected-only mode the inner-loop test gate uses it (release: false) and the
// full suite is a separate release-only gate.
export function gatesFor(det: Detection, has: (c: string) => boolean = haveCmd): GateResult {
    const out: GateResult = { gates: [], link: [], setup: [] };
    const kinds = new Map<Kind, number>();
    for (const p of det.packages) kinds.set(p.kind, (kinds.get(p.kind) ?? 0) + 1);
    for (const p of det.packages) {
        const pre = p.dir ? `${p.dir}/` : '';
        const W = (globs: string[]) => globs.map((g) => (g.startsWith('/') ? g.slice(1) : pre + g));
        const suffix = p.dir && (kinds.get(p.kind) ?? 0) > 1 ? `-${p.dir.replace(/[^A-Za-z0-9_.-]+/g, '-')}` : p.dir ? `-${basename(p.dir)}` : '';
        const add = (g: Gate) => {
            let name = g.name + suffix;
            if (out.gates.some((o) => o.name === name)) name += `-${p.kind}`;
            out.gates.push({ ...g, name, ...(p.dir ? { cwd: p.dir } : {}), ...(p.installed ? {} : { pending: true }) });
        };
        const f = p.frameworks;
        const has_ = (d: string) => p.deps.includes(d);
        if (p.kind === 'node') {
            const lock = p.lockfile ? [`/${p.lockfile}`] : [];
            const when = W(['*.ts', '*.tsx', '*.js', '*.jsx', '*.mjs', '*.cjs', '*.vue', '*.svelte', '*.astro', '*.css', 'package.json', 'tsconfig*.json', ...lock]);
            const pm = p.pm ?? 'npm';
            const run = (s: string) => `${pm} run ${s}`;
            const x = { bun: 'bunx', pnpm: 'pnpm exec', yarn: 'yarn', npm: 'npx' }[pm] ?? 'npx';
            const s = new Set(p.scripts);
            const typecheck = ['typecheck', 'type-check', 'check-types', 'tsc', 'check'].find((n) => s.has(n));
            const full = s.has('test') ? run('test') : has_('vitest') ? `${x} vitest run` : has_('jest') ? `${x} jest` : '';
            if (has_('vitest') || has_('jest')) {
                const affected = has_('vitest') ? `${x} vitest run --changed "$WF_BASE" --passWithNoTests` : `${x} jest --changedSince "$WF_BASE" --passWithNoTests`;
                add({ name: 'test', cmd: affected, when, heavy: true, release: false });
                add({ name: 'test-full', cmd: full, when, heavy: true, inner: false });
            } else if (full) add({ name: 'test', cmd: full, when, heavy: true });
            if (s.has('lint')) add({ name: 'lint', cmd: run('lint'), when, ...(s.has('lint:fix') ? { fix: run('lint:fix') } : {}) });
            else if (has_('@biomejs/biome')) add({ name: 'biome', cmd: `${x} biome ci .`, when, fix: `${x} biome check --write .` });
            if (typecheck) add({ name: 'typecheck', cmd: run(typecheck), when, heavy: true });
            else if (has_('typescript')) add({ name: 'typecheck', cmd: `${x} tsc --noEmit`, when, heavy: true });
            if (s.has('build')) add({ name: 'build', cmd: run('build'), when, heavy: true });
            if (s.has('format') && s.has('format:check')) add({ name: 'format', cmd: run('format:check'), when, fix: run('format') });
            if (s.has('e2e') || s.has('test:e2e')) add({ name: 'e2e', cmd: run(s.has('e2e') ? 'e2e' : 'test:e2e'), when, heavy: true, inner: false, cache: false });
            if (p.installed && existsSync(join(det.root, p.dir, 'node_modules'))) out.link.push(`${pre}node_modules`);
            else if (!p.installed) out.setup.push(p.dir ? `cd ${p.dir} && ${pm} install` : `${pm} install`);
        } else if (p.kind === 'php') {
            const when = W(['*.php', 'composer.json', 'composer.lock', 'phpstan.neon*', 'phpunit.xml*']);
            const runner = has_('pestphp/pest') || existsSync(join(det.root, p.dir, 'vendor/bin/pest')) ? './vendor/bin/pest' : has_('phpunit/phpunit') ? './vendor/bin/phpunit' : '';
            const runnerName = basename(runner);
            if (runner) {
                // testAffected has no cwd and its paths are root-relative, so only a root package can use it.
                if (!out.testAffected && !p.dir) {
                    out.testAffected = { cmd: `${runner} {files}`, map: [{ src: 'app/*.php', tests: 'tests/*{name}Test.php' }, { src: 'src/*.php', tests: 'tests/*{name}Test.php' }] };
                    add({ name: runnerName, cmd: 'wf test-affected "$WF_BASE"', when, heavy: true, release: false });
                    add({ name: `${runnerName}-full`, cmd: `${runner}${runner.endsWith('pest') ? ' --parallel' : ''}`, when, heavy: true, inner: false });
                } else add({ name: runnerName, cmd: `${runner}${runner.endsWith('pest') ? ' --parallel' : ''}`, when, heavy: true });
            }
            if (has_('laravel/pint')) add({ name: 'pint', cmd: './vendor/bin/pint --test', when, fix: './vendor/bin/pint' });
            if (has_('larastan/larastan') || has_('phpstan/phpstan')) add({ name: 'phpstan', cmd: './vendor/bin/phpstan analyse --no-progress', when, heavy: true });
            if (p.installed) out.link.push(`${pre}vendor`);
            else out.setup.push(p.dir ? `cd ${p.dir} && composer install` : 'composer install');
        } else if (p.kind === 'python') {
            const uv = p.lockfile?.endsWith('uv.lock') || has('uv');
            const r = uv ? 'uv run ' : '';
            const when = W(['*.py', 'pyproject.toml', 'requirements*.txt', 'uv.lock']);
            const hasTests = has_('pytest') || ['tests', 'test'].some((t) => det.testDirs.includes(`${pre}${t}`));
            if (hasTests) {
                if (!out.testAffected && !p.dir) {
                    out.testAffected = { cmd: `${r}pytest -q {files}`, map: [{ src: '*.py', tests: 'tests/*test_{name}.py' }] };
                    add({ name: 'pytest', cmd: 'wf test-affected "$WF_BASE"', when, heavy: true, release: false });
                    add({ name: 'pytest-full', cmd: `${r}pytest -q`, when, heavy: true, inner: false });
                } else add({ name: 'pytest', cmd: `${r}pytest -q`, when, heavy: true });
            }
            if (has_('ruff')) add({ name: 'ruff', cmd: `${r}ruff check . && ${r}ruff format --check .`, when, fix: `${r}ruff check --fix . && ${r}ruff format .` });
            if (has_('mypy')) add({ name: 'mypy', cmd: `${r}mypy .`, when, heavy: true });
            if (has_('pyright')) add({ name: 'pyright', cmd: `${r}pyright`, when, heavy: true });
            if (uv) out.setup.push(p.dir ? `cd ${p.dir} && uv sync` : 'uv sync');
        } else if (p.kind === 'go') {
            const when = W(['*.go', 'go.mod', 'go.sum', '.golangci.y*ml']);
            // go's own test cache makes `go test ./...` affected-only; the release run disables it and adds -race.
            add({ name: 'go-test', cmd: 'go test ./...', when, heavy: true, release: false });
            add({ name: 'go-test-full', cmd: 'go test -race -count=1 ./...', when, heavy: true, inner: false });
            add({ name: 'go-vet', cmd: 'go vet ./...', when, heavy: true });
            add({ name: 'gofmt', cmd: 'test -z "$(gofmt -l .)"', when, fix: 'gofmt -w .' });
            if (['.golangci.yml', '.golangci.yaml', '.golangci.toml'].some((c) => existsSync(join(det.root, p.dir, c)))) {
                out.gates.push({ name: `golangci-lint${suffix}`, cmd: 'golangci-lint run', when, heavy: true, ...(p.dir ? { cwd: p.dir } : {}), ...(has('golangci-lint') ? {} : { pending: true }) });
            }
        } else if (p.kind === 'rust') {
            const when = W(['*.rs', 'Cargo.toml', 'Cargo.lock']);
            // No affected-only mode for cargo: the inner loop runs unit tests only, the full suite is release-only.
            add({ name: 'cargo-test', cmd: 'cargo test --quiet --workspace --lib --bins', when, heavy: true, release: false });
            add({ name: 'cargo-test-full', cmd: 'cargo test --quiet --workspace --all-targets', when, heavy: true, inner: false });
            add({ name: 'clippy', cmd: 'cargo clippy --quiet --workspace --all-targets -- -D warnings', when, heavy: true });
            add({ name: 'rustfmt', cmd: 'cargo fmt --check', when, fix: 'cargo fmt' });
        }
    }
    if (det.shell) out.gates.push({ name: 'shellcheck', cmd: 'git ls-files -z "*.sh" | xargs -0 -r shellcheck', when: ['*.sh'], ...(has('shellcheck') ? {} : { pending: true }) });
    return out;
}

if (import.meta.main) {
    const argv = process.argv.slice(2);
    if (argv.includes('--help') || argv.includes('-h')) {
        console.log(readFileSync(import.meta.path, 'utf8').split('\n').slice(2, 6).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
        process.exit(0);
    }
    const di = argv.indexOf('--dir');
    const top = di >= 0 ? argv[di + 1] : Bun.spawnSync(['git', 'rev-parse', '--show-toplevel'], { stderr: 'ignore' }).stdout.toString().trim() || process.cwd();
    if (!top || !existsSync(top)) {
        console.error(`detect: no such directory ${top}`);
        process.exit(1);
    }
    const det = detect(top);
    if (argv.includes('--save')) {
        mkdirSync(join(top, '.workflow/plan'), { recursive: true });
        writeFileSync(join(top, '.workflow/plan/detect.json'), `${JSON.stringify(det, null, 2)}\n`);
    }
    if (argv.includes('--json')) {
        console.log(JSON.stringify(det, null, 2));
        process.exit(0);
    }
    const fw = (p: Pkg) => Object.entries(p.frameworks).map(([k, v]) => `${k}@${v}`).join(' ');
    console.log(`greenfield: ${det.greenfield ? 'yes' : 'no'}`);
    for (const p of det.packages) console.log(`package ${p.dir || '.'} ${p.kind}${p.pm ? ` (${p.pm})` : ''}${p.installed ? '' : ' not installed'}: ${fw(p) || '-'}`);
    const line = (k: string, v: string[]) => v.length && console.log(`${k}: ${v.slice(0, 12).join(' ')}${v.length > 12 ? ` (+${v.length - 12})` : ''}`);
    line('ci', det.ci);
    line('make', det.make);
    line('just', det.just);
    line('tests', det.testDirs);
    line('tokens', det.tokens);
    line('locales', det.locales.map((l) => `${l.dir}[${l.locales.join(',')}]`));
    line('docs', det.docs);
    if (argv.includes('--save')) console.log('saved: .workflow/plan/detect.json');
}
