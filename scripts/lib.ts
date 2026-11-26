// Shared helpers for the card CLI, the cmd/ subcommands and the board server:
// repo root, config, card parsing and writing, the card lock, git, risk, teardown.
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

export type Card = {
    id: string;
    title: string;
    status: string;
    size: string;
    points: number;
    area: string;
    priority: number;
    milestone: boolean;
    blocked: string;
    depends: string[];
    links: string[];
    tags: string[];
    created?: string;
    started?: string;
    landed?: string;
    done?: string;
    verified?: string;
    branch?: string;
    acceptance: { done: number; total: number };
    body: string;
    file: string;
    broken?: boolean;
};

export type Config = {
    idPrefix?: string;
    baseBranch?: string;
    wipLimit?: number;
    timezone?: string;
    milestone?: { label?: string };
    board?: { title?: string; host?: string; port?: number };
    overnight?: { model?: string; batch?: number; exclude?: string[] };
    finish?: { mode?: 'pr' | 'merge' | 'none'; squash?: boolean; autoMerge?: boolean; cleanup?: boolean };
    tracker?: { kind?: string; requireLink?: boolean; onMerge?: string };
    risk?: { high?: string[] };
    docs?: { standards?: string[]; spec?: string[]; design?: string[] };
    [key: string]: unknown;
};

export const STATUSES = ['backlog', 'todo', 'in-progress', 'code-review', 'ux-review', 'owner-review', 'verifying', 'done'];
export const ACTIVE = ['in-progress', 'code-review', 'ux-review'];
// Landed on the base branch: dependents may start.
export const LANDED = ['verifying', 'done'];
export const POINTS: Record<string, number> = { S: 1, M: 2, L: 4, XL: 8 };
export const CARD_FILE = /^[A-Za-z][A-Za-z0-9]*-\d+.*\.md$/;
export const CARD_ID = /^[A-Za-z][A-Za-z0-9]*-\d+$/;
export const SCRIPTS = new URL('.', import.meta.url).pathname;
export const DAY = 864e5;

// Cards live in the MAIN checkout even when called from a worktree, so every
// worktree and the board see one board. WF_ROOT overrides.
function findRoot(): string {
    if (process.env.WF_ROOT) return process.env.WF_ROOT.replace(/\/?$/, '/');
    // Fast path without spawning git: walk up to .git; a worktree's .git file names the main one.
    for (let d = process.cwd(); d !== '/'; d = d.slice(0, d.lastIndexOf('/')) || '/') {
        let st: ReturnType<typeof statSync> | undefined;
        try {
            st = statSync(`${d}/.git`);
        } catch {
            continue;
        }
        if (st.isDirectory()) return `${d}/`;
        const gitdir = readFileSync(`${d}/.git`, 'utf8').match(/^gitdir: (.*)$/m)?.[1]?.trim() ?? '';
        const main = gitdir.match(/^(\/.*)\/\.git\/worktrees\/[^/]+$/)?.[1];
        if (main) return `${main}/`;
        break;
    }
    const r = Bun.spawnSync(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], { stderr: 'ignore' });
    const common = r.success ? r.stdout.toString().trim() : '';
    if (common.endsWith('/.git')) return common.slice(0, -4);
    return `${process.cwd()}/`;
}

export const root = findRoot();

export function loadConfig(): Config {
    const path = `${root}.claude/workflow.json`;
    if (!existsSync(path)) return {};
    try {
        return JSON.parse(readFileSync(path, 'utf8')) as Config;
    } catch (err) {
        console.error(`warning: ${path} is not valid JSON (${(err as Error).message}); using defaults`);
        return {};
    }
}

export const config = loadConfig();
export const WIP = Number(process.env.WF_WIP ?? config.wipLimit ?? 2);
// One default for `wf queue` and `wf night`.
export const OVERNIGHT_BATCH = Number(config.overnight?.batch ?? 8);
export const BOARD_PORT = 8095;
// Card tags the unattended runner never picks up.
export const OVERNIGHT_EXCLUDE = config.overnight?.exclude ?? ['migration', 'deploy', 'hardware'];

// Default id prefix from the repo name: initials of its words (claude-workflow -> CW), or its first 3 letters.
export function idPrefix(): string {
    if (config.idPrefix) return config.idPrefix;
    const words = basename(root.replace(/\/$/, '')).split(/[^A-Za-z0-9]+/).filter(Boolean);
    const p = words.length > 1 ? words.map((w) => w[0]).join('').slice(0, 4) : (words[0] ?? 'wf').slice(0, 3);
    return /^[A-Za-z]/.test(p) ? p.toUpperCase() : `WF${p}`.toUpperCase();
}

export const milestoneLabel = (): string => config.milestone?.label ?? 'milestone';

export const today = (): string =>
    config.timezone ? new Date().toLocaleDateString('en-CA', { timeZone: config.timezone }) : new Date().toLocaleDateString('en-CA');

export function fail(msg: string, code = 1): never {
    console.error(msg);
    process.exit(code);
}

// ---------------------------------------------------------------- parsing

// Front matter is a flat YAML subset: scalars, quoted strings, inline [lists].
export function parseValue(raw: string): unknown {
    const v = raw.trim();
    if (v === '') return '';
    if (v === 'true' || v === 'false') return v === 'true';
    if (v.startsWith('"')) return JSON.parse(v);
    if (v.startsWith("'")) return v.slice(1, -1);
    if (v.startsWith('[')) {
        const items = v.slice(1, -1).match(/"(?:[^"\\]|\\.)*"|'[^']*'|[^,\s][^,]*/g) ?? [];
        return items.map((item) => parseValue(item));
    }
    return v.replace(/\s+#.*$/, '');
}

// withBody false skips the body (acceptance counts stay 0): listing archived cards needs only the front matter.
export function parseCard(text: string, file: string, withBody = true): Card | null {
    const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    if (!m) return null;
    const meta: Record<string, unknown> = {};
    for (const line of m[1].split('\n')) {
        const kv = line.match(/^(\w+):\s?(.*)$/);
        if (kv) meta[kv[1]] = parseValue(kv[2]);
    }
    if (!meta.id) return null;
    const body = withBody ? m[2].trim() : '';
    const checks = body.match(/^\s*- \[[ xX]\]/gm) ?? [];
    const size = String(meta.size || 'M');
    const str = (k: string) => (meta[k] === undefined || meta[k] === '' ? undefined : String(meta[k]));
    return {
        id: String(meta.id),
        title: String(meta.title ?? ''),
        status: String(meta.status || 'backlog'),
        size,
        points: POINTS[size] ?? POINTS.M,
        area: String(meta.area ?? ''),
        priority: Number(meta.priority ?? 2),
        milestone: meta.milestone === true || meta.mvp === true, // legacy alias
        blocked: String(meta.blocked ?? ''),
        depends: Array.isArray(meta.depends) ? meta.depends.map(String) : [],
        links: Array.isArray(meta.links) ? meta.links.map(String) : [],
        tags: Array.isArray(meta.tags) ? meta.tags.map(String) : [],
        created: str('created'),
        started: str('started'),
        landed: str('landed'),
        done: str('done'),
        verified: str('verified'),
        branch: str('branch'),
        acceptance: { done: checks.filter((c) => /\[[xX]\]/.test(c)).length, total: checks.length },
        body,
        file,
    };
}

// A done card known only from its archive file name: enough for ids, counts and dependencies.
const stub = (name: string, file: string): Card => ({
    id: name.match(/^[A-Za-z][A-Za-z0-9]*-\d+/)?.[0] ?? name, title: '', status: 'done', size: 'M', points: POINTS.M, area: '', priority: 2,
    milestone: false, blocked: '', depends: [], links: [], tags: [], acceptance: { done: 0, total: 0 }, body: '', file,
});

// One readdir per folder. Open cards are parsed in full. Archived cards (all done) are
// read per `archive`: 'stub' (default) reads no file, only the id from the name; 'meta'
// the front matter; 'body' everything.
export function readCards(opts: { archive?: 'stub' | 'meta' | 'body' } = {}): Card[] {
    const cards: Card[] = [];
    const archive = opts.archive ?? 'stub';
    for (const dir of ['tasks', 'tasks/archive']) {
        const path = `${root}${dir}`;
        let names: string[];
        try {
            names = readdirSync(path).sort();
        } catch {
            continue;
        }
        const withBody = dir === 'tasks' || archive === 'body';
        for (const name of names) {
            if (!CARD_FILE.test(name)) continue;
            if (dir !== 'tasks' && archive === 'stub') {
                cards.push(stub(name, `${dir}/${name}`));
                continue;
            }
            try {
                const card = parseCard(readFileSync(`${path}/${name}`, 'utf8'), `${dir}/${name}`, withBody);
                if (card) cards.push(card);
            } catch (err) {
                cards.push({
                    id: name, title: `Unreadable: ${(err as Error).message}`, status: 'backlog', size: 'M', points: 0, area: '',
                    priority: 9, milestone: false, blocked: '', depends: [], links: [], tags: [], acceptance: { done: 0, total: 0 },
                    body: '', file: `${dir}/${name}`, broken: true,
                });
            }
        }
    }
    return cards;
}

export const findCard = (cards: Card[], id: string): Card =>
    cards.find((t) => t.id.toUpperCase() === String(id).toUpperCase()) ?? fail(`no card ${id}`);

// ---------------------------------------------------------------- writing

export function render(value: unknown): string {
    if (Array.isArray(value)) return `[${value.join(', ')}]`;
    if (value === '') return '""';
    if (typeof value === 'string' && (/[:#"[\]]/.test(value) || value !== value.trim())) return JSON.stringify(value);
    return String(value);
}

export function setField(text: string, key: string, value: unknown): string {
    const re = new RegExp(`^${key}:.*$`, 'm');
    const end = text.indexOf('\n---', 4);
    const line = `${key}: ${render(value)}`;
    // A function replacer: user text such as `$&` must not be read as a replacement pattern.
    if (re.test(text.slice(0, end))) return text.slice(0, end).replace(re, () => line) + text.slice(end);
    return `${text.slice(0, end)}\n${line}${text.slice(end)}`;
}

const sectionRe = (heading: string) => new RegExp(`^## ${heading}[ \\t]*\\n([\\s\\S]*?)(?=^## |(?![\\s\\S]))`, 'm');

// Text of `## heading` up to the next level-2 heading, or null.
export function section(body: string, heading: string): string | null {
    const m = body.match(sectionRe(heading));
    return m ? m[1].trim() : null;
}

// Appends a line to `## heading`, creating the section at the end when missing.
export function appendToSection(text: string, heading: string, line: string): string {
    const m = text.match(sectionRe(heading));
    if (!m || m.index === undefined) return `${text.replace(/\s*$/, '')}\n\n## ${heading}\n\n${line}\n`;
    const content = m[1].replace(/\s*$/, '');
    const after = m.index + m[0].length < text.length ? '\n' : '';
    return `${text.slice(0, m.index)}## ${heading}\n${content ? `${content}\n` : '\n'}${line}\n${after}${text.slice(m.index + m[0].length)}`;
}

// Ticks acceptance items by 1-based index; returns the text and the indexes that were not found.
export function tickAcceptance(text: string, indexes: number[]): { text: string; missing: number[] } {
    const m = text.match(sectionRe('Acceptance'));
    if (!m || m.index === undefined) return { text, missing: indexes };
    let n = 0;
    const found = new Set<number>();
    const ticked = m[0].replace(/^(\s*- \[)[ xX](\])/gm, (all, a, b) => {
        n++;
        if (!indexes.includes(n)) return all;
        found.add(n);
        return `${a}x${b}`;
    });
    return { text: text.slice(0, m.index) + ticked + text.slice(m.index + m[0].length), missing: indexes.filter((i) => !found.has(i)) };
}

// Writes fields (and an optional body edit) into a card; done cards move to
// tasks/archive/, reopened ones move back. Returns the new root-relative path.
export function update(card: Card, fields: Record<string, unknown>, edit?: (text: string) => string): string {
    const path = `${root}${card.file}`;
    let text = readFileSync(path, 'utf8');
    for (const [k, v] of Object.entries(fields)) text = setField(text, k, v);
    if (edit) text = edit(text);
    writeFileSync(path, text);
    const file = archivePath(card.file, fields.status as string | undefined);
    if (file !== card.file) {
        mkdirSync(`${root}${file.slice(0, file.lastIndexOf('/'))}`, { recursive: true });
        renameSync(path, `${root}${file}`);
    }
    return file;
}

// Root-relative only, so a parent directory called tasks/ is never touched.
export function archivePath(file: string, status?: string): string {
    if (status === 'done' && !file.startsWith('tasks/archive/')) return file.replace(/^tasks\//, 'tasks/archive/');
    if (status && status !== 'done' && file.startsWith('tasks/archive/')) return file.replace(/^tasks\/archive\//, 'tasks/');
    return file;
}

// ---------------------------------------------------------------- claiming

// Milestone cards first, then priority, then id.
export const byPriority = (a: Card, b: Card) =>
    Number(b.milestone) - Number(a.milestone) || a.priority - b.priority || a.id.localeCompare(b.id, undefined, { numeric: true });

// Claimable: todo, unblocked, every dependency landed. Prefer areas nobody is
// working in, so parallel workstreams rarely touch the same files.
export function claimable(cards: Card[], n: number, ignoreWip = false): Card[] {
    const landed = new Set(cards.filter((t) => LANDED.includes(t.status)).map((t) => t.id));
    const busy = new Set(ignoreWip ? [] : cards.filter((t) => ACTIVE.includes(t.status)).map((t) => t.area));
    const ready = cards.filter((t) => t.status === 'todo' && !t.blocked && t.depends.every((d) => landed.has(d))).sort(byPriority);
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

export function unknownDepends(cards: Card[], depends: string[]): string[] {
    const ids = new Set(cards.map((t) => t.id.toUpperCase()));
    return depends.filter((d) => !ids.has(d.toUpperCase()));
}

// ---------------------------------------------------------------- lock

// Same layout as common.sh wf_lock (a pid file inside the lock dir), so a lock
// left by a dead process is taken over and `wf doctor` can see it.
const lockDir = (name: string) => (existsSync(`${root}.git/HEAD`) ? `${root}.git/workflow-${name}.lock` : `${root}tasks/.${name}.lock`);
const held = new Set<string>();
process.on('exit', () => {
    for (const d of held) rmSync(d, { recursive: true, force: true });
});

function stale(dir: string): boolean {
    let pid = 0;
    try {
        pid = Number(readFileSync(`${dir}/pid`, 'utf8'));
    } catch {
        // No pid yet: the owner may be between mkdir and write, so only an old dir is stale.
        try {
            return Date.now() - statSync(dir).mtimeMs > 10_000;
        } catch {
            return false;
        }
    }
    try {
        process.kill(pid, 0);
        return false;
    } catch (err) {
        return (err as NodeJS.ErrnoException).code !== 'EPERM';
    }
}

export function withLock<T>(fn: () => T, name = 'cards', tries = 200): T {
    const dir = lockDir(name);
    for (let i = 0; ; i++) {
        try {
            mkdirSync(dir);
            held.add(dir);
            writeFileSync(`${dir}/pid`, String(process.pid));
            break;
        } catch {
            if (stale(dir)) {
                rmSync(dir, { recursive: true, force: true });
                continue;
            }
            if (i >= tries) fail(`card lock busy (${dir})`);
            Bun.sleepSync(25);
        }
    }
    try {
        return fn();
    } finally {
        rmSync(dir, { recursive: true, force: true });
        held.delete(dir);
    }
}

// ---------------------------------------------------------------- git

export function git(args: string[], cwd = root): { ok: boolean; out: string; err: string } {
    const r = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' });
    return { ok: r.success, out: r.stdout.toString().trim(), err: r.stderr.toString().trim() };
}

export function baseBranch(): string {
    if (config.baseBranch) return config.baseBranch;
    const r = git(['symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD']);
    return (r.ok && r.out.replace(/^origin\//, '')) || 'main';
}

export const taskBranch = (card: Card) => card.branch ?? `wf/${card.id}`;
export const worktreePath = (id: string) => `${root}.workflow/worktrees/${id}`;

// Worktree that has `branch` checked out, if any.
export function worktreeOf(branch: string): string | undefined {
    for (const b of git(['worktree', 'list', '--porcelain']).out.split('\n\n')) {
        if (b.split('\n').includes(`branch refs/heads/${branch}`)) return b.match(/^worktree (.*)$/m)?.[1];
    }
    return undefined;
}

// Files changed on `head` since it left `base`; with `dir`, uncommitted and untracked files there too.
export function changedFiles(base: string, head = 'HEAD', dir?: string): string[] {
    const cwd = dir ?? root;
    const mb = git(['merge-base', base, head], cwd);
    if (!mb.ok) fail(`no merge base between ${base} and ${head}`);
    const files = new Set(git(['diff', '--name-only', mb.out, head], cwd).out.split('\n'));
    if (dir) {
        for (const f of git(['diff', '--name-only', 'HEAD'], cwd).out.split('\n')) files.add(f);
        for (const f of git(['ls-files', '--others', '--exclude-standard'], cwd).out.split('\n')) files.add(f);
    }
    files.delete('');
    return [...files].sort();
}

// ---------------------------------------------------------------- risk

// Same glob rules as common.sh wf_globs_to_regex: `*` crosses directories,
// `?` is one character, a trailing `/` means everything under it.
export function globsToRegex(globs: string[]): RegExp {
    const parts = globs.map((g) => {
        let re = g.replace(/[.^$+(){}|\\[\]]/g, '\\$&').replace(/\*\*/g, '*').replace(/\*/g, '.*').replace(/\?/g, '.');
        if (g.endsWith('/')) re += '.*';
        return re;
    });
    return new RegExp(`^(${parts.join('|') || '(?!)'})$`);
}

export const LIGHT_GLOBS = ['*.md', 'docs/', 'tests/', '*.css'];
export type Risk = { level: 'high' | 'standard' | 'light'; file: string };

export function classifyRisk(files: string[], high: string[] = config.risk?.high ?? []): Risk {
    const hi = globsToRegex(high);
    const light = globsToRegex(LIGHT_GLOBS);
    const h = high.length ? files.find((f) => hi.test(f)) : undefined;
    if (h) return { level: 'high', file: h };
    const s = files.find((f) => !light.test(f));
    if (s) return { level: 'standard', file: s };
    return { level: 'light', file: files[0] ?? '(no changes)' };
}

// ---------------------------------------------------------------- gates

type GateRow = { name: string; status: string; seconds?: number };
// Tolerant reader for .workflow/gates-last.json (written by wf gates): an array
// of rows, or an object holding one under `gates`/`results`.
export function gateRows(json: unknown): GateRow[] {
    const o = json as Record<string, unknown> | undefined;
    const list = Array.isArray(json) ? json : (o?.gates ?? o?.results);
    if (!Array.isArray(list)) return [];
    return list.map((g: Record<string, unknown>) => ({
        name: String(g.name ?? g.gate ?? '?'),
        status: String(g.status ?? g.result ?? (g.ok === true ? 'pass' : g.ok === false ? 'fail' : '?')),
        seconds: typeof g.seconds === 'number' ? g.seconds : typeof g.duration === 'number' ? g.duration : undefined,
    }));
}

// Green only when explicitly green: a missing or skipped gate is not proven.
export function gatesGreen(json: unknown): boolean {
    const o = json as Record<string, unknown>;
    if (o && typeof o === 'object' && !Array.isArray(o) && (typeof o.ok === 'boolean' || typeof o.green === 'boolean')) return o.ok === true || o.green === true;
    const rows = gateRows(json);
    return rows.length > 0 && rows.every((r) => /^(pass|ok|cached|green)$/i.test(r.status));
}

export function readJson(path: string): unknown {
    try {
        return JSON.parse(readFileSync(path, 'utf8'));
    } catch {
        return undefined;
    }
}

// ---------------------------------------------------------------- teardown

// Removes a task's worktree and local branch through stream 2's wf_teardown
// (teardown commands, previews, ports, resource ledger) when it exists, else
// plain git. Returns what was cleaned, e.g. ["worktree", "branch", "db"].
export function teardown(dir: string | undefined, branch: string): { cleaned: string[]; error?: string } {
    const script = `. "$1/lib/common.sh"
if declare -f wf_teardown >/dev/null; then wf_teardown "$2"; exit; fi
if [ -n "$2" ] && [ -d "$2" ]; then
    # Landed work may leave untracked build output; uncommitted edits to tracked files block removal.
    if [ -n "$(git -C "$2" status --porcelain --untracked-files=no)" ]; then echo "$2 has uncommitted changes; left in place" >&2; exit 1; fi
    git worktree remove --force "$2" || exit 1
fi
if git show-ref --verify --quiet "refs/heads/$3"; then git branch -D "$3" >/dev/null; fi`;
    const hadDir = !!dir && existsSync(dir);
    const hadBranch = git(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`]).ok;
    const r = Bun.spawnSync(['bash', '-c', script, 'teardown', SCRIPTS.replace(/\/$/, ''), dir ?? '', branch], { cwd: root, stdout: 'pipe', stderr: 'pipe' });
    const out = r.stdout.toString();
    const reported = out.match(/^cleaned:\s*(.*)$/m)?.[1];
    const cleaned = reported ? reported.split(/,\s*/).filter(Boolean) : [];
    if (!reported) {
        if (hadDir && !existsSync(dir as string)) cleaned.push('worktree');
        if (hadBranch && !git(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`]).ok) cleaned.push('branch');
    }
    return { cleaned, error: r.success ? undefined : (r.stderr.toString().trim().split('\n').pop() ?? 'teardown failed') };
}

// Resource ledger written by stream 2: card ids holding a db, port or preview.
export function ledgerCards(): string[] {
    const common = existsSync(`${root}.git/HEAD`) ? `${root}.git` : git(['rev-parse', '--path-format=absolute', '--git-common-dir']).out;
    const json = readJson(`${common}/workflow-resources.json`);
    if (!json || typeof json !== 'object') return [];
    const ids = (list: Record<string, unknown>[]) => [...new Set(list.map((e) => String(e.card ?? e.id ?? '')).filter(Boolean))];
    if (Array.isArray(json)) return ids(json);
    const o = json as Record<string, unknown>;
    if (Array.isArray(o.entries)) return ids(o.entries);
    if (o.cards && typeof o.cards === 'object') return Object.keys(o.cards);
    return Object.keys(o);
}

// ---------------------------------------------------------------- args

// Strict flag parser for cmd/ scripts: unknown flags are an error, --help prints `help`.
export function parseArgs(argv: string[], spec: Record<string, 'bool' | 'string'>, help: string) {
    const flags: Record<string, string | boolean> = {};
    const args: string[] = [];
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '-h' || a === '--help') {
            console.log(help);
            process.exit(0);
        }
        if (!a.startsWith('--')) {
            args.push(a);
            continue;
        }
        const [k, inline] = a.slice(2).split(/=(.*)/s, 2);
        if (!(k in spec)) fail(`unknown flag --${k}\n${help}`, 2);
        if (spec[k] === 'bool') flags[k] = true;
        else {
            const v = inline ?? argv[++i];
            if (v === undefined) fail(`--${k} needs a value`, 2);
            flags[k] = v;
        }
    }
    return { flags, args };
}

// ---------------------------------------------------------------- outcome

// wf outcome writes the facts between these markers; the model writes the prose around them.
export const AUTO_START = '<!-- wf:auto -->';
export const AUTO_END = '<!-- /wf:auto -->';
export const PROSE_HINT = '<!-- what shipped and why, decisions, follow-ups -->';

// The Outcome's prose: everything but the generated block and the hint. Empty when only the skeleton is there.
export function outcomeProse(body: string): string {
    const s = section(body, 'Outcome');
    if (s === null) return '';
    const a = s.indexOf(AUTO_START);
    const b = s.indexOf(AUTO_END);
    const without = a >= 0 && b > a ? s.slice(0, a) + s.slice(b + AUTO_END.length) : s;
    return without.replace(PROSE_HINT, '').trim();
}
