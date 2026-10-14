// Shared helpers for the task CLI and the board server: repo root, config, card parsing.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
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
    created?: string;
    started?: string;
    done?: string;
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
    overnight?: { model?: string };
    [key: string]: unknown;
};

export const STATUSES = ['backlog', 'todo', 'in-progress', 'code-review', 'ux-review', 'owner-review', 'done'];
export const ACTIVE = ['in-progress', 'code-review', 'ux-review'];
export const POINTS: Record<string, number> = { S: 1, M: 2, L: 4, XL: 8 };
export const CARD_FILE = /^[A-Za-z][A-Za-z0-9]*-\d+.*\.md$/;
export const CARD_ID = /^[A-Za-z][A-Za-z0-9]*-\d+$/;

// Cards live in the MAIN checkout even when called from a worktree, so every
// worktree and the board see one board. WF_ROOT overrides.
function findRoot(): string {
    if (process.env.WF_ROOT) return process.env.WF_ROOT.replace(/\/?$/, '/');
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

export function parseCard(text: string, file: string): Card | null {
    const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    if (!m) return null;
    const meta: Record<string, unknown> = {};
    for (const line of m[1].split('\n')) {
        const kv = line.match(/^(\w+):\s?(.*)$/);
        if (kv) meta[kv[1]] = parseValue(kv[2]);
    }
    if (!meta.id) return null;
    const body = m[2].trim();
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
        // `mvp` is accepted as an alias for `milestone`.
        milestone: meta.milestone === true || meta.mvp === true,
        blocked: String(meta.blocked ?? ''),
        depends: Array.isArray(meta.depends) ? meta.depends.map(String) : [],
        links: Array.isArray(meta.links) ? meta.links.map(String) : [],
        created: str('created'),
        started: str('started'),
        done: str('done'),
        branch: str('branch'),
        acceptance: { done: checks.filter((c) => /\[[xX]\]/.test(c)).length, total: checks.length },
        body,
        file,
    };
}

export function readCards(): Card[] {
    const cards: Card[] = [];
    for (const dir of ['tasks', 'tasks/archive']) {
        const path = `${root}${dir}`;
        if (!existsSync(path)) continue;
        for (const name of readdirSync(path).sort()) {
            if (!CARD_FILE.test(name)) continue;
            try {
                const card = parseCard(readFileSync(`${path}/${name}`, 'utf8'), `${dir}/${name}`);
                if (card) cards.push(card);
            } catch (err) {
                cards.push({
                    id: name, title: `Unreadable: ${(err as Error).message}`, status: 'backlog', size: 'M', points: 0, area: '',
                    priority: 9, milestone: false, blocked: '', depends: [], links: [], acceptance: { done: 0, total: 0 },
                    body: '', file: `${dir}/${name}`, broken: true,
                });
            }
        }
    }
    return cards;
}
