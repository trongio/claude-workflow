#!/usr/bin/env bun
// wf-help: latest stable versions from the registries (npm, Packagist, PyPI, crates.io, Go proxy, endoflife.date) [--check docs/STACK.md]
// Usage: wf versions ECO:NAME... [--json] [--table] [--refresh]
//        wf versions --check docs/STACK.md
//   ECO is npm, composer, pypi, crates, go or eol (endoflife.date product, e.g. eol:php).
//   --table    print markdown rows for the STACK.md version table
//   --check F  re-verify the version table in F and print only drift (exit 1 on minor/major drift)
//   --refresh  ignore the 24 h cache (.workflow/plan/versions.json)
// Env WF_VERSIONS_FIXTURE=file.json answers every URL from that file ({url: body}); no network.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export type Version = { id: string; version: string; released: string; note: string; source: string; verified: string; error?: string };

const TTL = 24 * 3600e3;
const UA = { 'User-Agent': 'claude-workflow-versions (https://github.com/trongio/claude-workflow)' };
const PRE = /(alpha|beta|rc|dev|preview|canary|next|snapshot|pre)/i;
const today = () => new Date().toISOString().slice(0, 10);

function repoRoot(): string {
    const r = Bun.spawnSync(['git', 'rev-parse', '--show-toplevel'], { stderr: 'ignore' });
    return r.success ? r.stdout.toString().trim() : process.cwd();
}

type Cache = Record<string, { fetched: string; body: unknown }>;
const cachePath = () => join(repoRoot(), '.workflow/plan/versions.json');
function loadCache(): Cache {
    try {
        return JSON.parse(readFileSync(cachePath(), 'utf8')) as Cache;
    } catch {
        return {};
    }
}

// Registry endpoint for one ECO:NAME.
export function urlFor(id: string): string {
    const i = id.indexOf(':');
    const eco = id.slice(0, i);
    const name = id.slice(i + 1);
    if (i < 1 || !name) throw new Error(`bad package id ${id} (want ECO:NAME)`);
    switch (eco) {
        case 'npm':
            return `https://registry.npmjs.org/${name.replace('/', '%2F')}/latest`;
        case 'composer':
        case 'packagist':
            return `https://repo.packagist.org/p2/${name}.json`;
        case 'pypi':
            return `https://pypi.org/pypi/${name}/json`;
        case 'crates':
            return `https://crates.io/api/v1/crates/${name}`;
        case 'go':
            // The proxy escapes capitals as !lower.
            return `https://proxy.golang.org/${name.replace(/[A-Z]/g, (c) => `!${c.toLowerCase()}`)}/@latest`;
        case 'eol':
            return `https://endoflife.date/api/${name}.json`;
        default:
            throw new Error(`unknown ecosystem ${eco} in ${id} (npm, composer, pypi, crates, go, eol)`);
    }
}

const day = (s: unknown) => (typeof s === 'string' ? s.slice(0, 10) : '');

// Parse a registry body into the latest stable version.
export function parse(id: string, body: unknown): Pick<Version, 'version' | 'released' | 'note'> {
    const eco = id.slice(0, id.indexOf(':'));
    const name = id.slice(id.indexOf(':') + 1);
    const b = body as Record<string, any>;
    switch (eco) {
        case 'npm':
            return { version: String(b.version), released: '', note: '' };
        case 'composer':
        case 'packagist': {
            const list = (b.packages?.[name] ?? []) as { version: string; time?: string }[];
            const stable = list.find((v) => !PRE.test(v.version) && !v.version.startsWith('dev-'));
            if (!stable) throw new Error('no stable release');
            return { version: stable.version.replace(/^v/, ''), released: day(stable.time), note: '' };
        }
        case 'pypi': {
            const v = String(b.info?.version);
            return { version: v, released: day(b.releases?.[v]?.[0]?.upload_time_iso_8601 ?? b.releases?.[v]?.[0]?.upload_time), note: PRE.test(v) ? 'prerelease' : '' };
        }
        case 'crates': {
            const v = b.crate?.max_stable_version ?? b.crate?.newest_version;
            const rel = (b.versions as { num: string; created_at: string }[] | undefined)?.find((x) => x.num === v)?.created_at;
            return { version: String(v), released: day(rel), note: '' };
        }
        case 'go':
            return { version: String(b.Version).replace(/^v/, ''), released: day(b.Time), note: '' };
        case 'eol': {
            const now = today();
            const cycles = b as unknown as { cycle: string; latest: string; latestReleaseDate?: string; releaseDate?: string; eol: boolean | string; lts?: boolean | string }[];
            const supported = cycles.filter((c) => c.eol === false || (typeof c.eol === 'string' && c.eol > now));
            // Products with LTS lines (Node, Django, Ubuntu): the newest active LTS beats a newer current line.
            const isLts = (c: (typeof cycles)[number]) => c.lts === true || (typeof c.lts === 'string' && c.lts <= now);
            const live = supported.find(isLts) ?? supported[0] ?? cycles[0];
            if (!live) throw new Error('no release cycles');
            return { version: String(live.latest), released: day(live.latestReleaseDate ?? live.releaseDate), note: `cycle ${live.cycle}${isLts(live) ? ' LTS' : ''}, eol ${live.eol === false ? 'not set' : live.eol}` };
        }
    }
    throw new Error(`unknown ecosystem in ${id}`);
}

async function fetchBody(url: string, cache: Cache, refresh: boolean): Promise<unknown> {
    const fx = process.env.WF_VERSIONS_FIXTURE;
    if (fx) {
        const all = JSON.parse(readFileSync(fx, 'utf8')) as Record<string, unknown>;
        if (!(url in all)) throw new Error(`not in fixture: ${url}`);
        return all[url];
    }
    const hit = cache[url];
    if (!refresh && hit && Date.now() - Date.parse(hit.fetched) < TTL) return hit.body;
    const res = await fetch(url, { headers: UA, signal: AbortSignal.timeout(10000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = await res.json();
    cache[url] = { fetched: new Date().toISOString(), body };
    return body;
}

export async function versions(ids: string[], refresh = false): Promise<Version[]> {
    const cache = loadCache();
    const out = await Promise.all(
        ids.map(async (id): Promise<Version> => {
            let source = '';
            try {
                source = urlFor(id);
                const v = parse(id, await fetchBody(source, cache, refresh));
                // A 0.x core dependency is a maturity question the decision record must answer.
                if (/^0\./.test(v.version)) v.note = [v.note, 'pre-1.0'].filter(Boolean).join(', ');
                return { id, ...v, source, verified: today() };
            } catch (err) {
                return { id, version: '?', released: '', note: '', source, verified: '', error: (err as Error).message };
            }
        }),
    );
    if (!process.env.WF_VERSIONS_FIXTURE) {
        mkdirSync(dirname(cachePath()), { recursive: true });
        writeFileSync(cachePath(), `${JSON.stringify(cache)}\n`);
    }
    return out;
}

export const TABLE_START = '<!-- versions:start (generated by wf versions; never hand-edit a version) -->';
export const TABLE_END = '<!-- versions:end -->';
export function table(rows: Version[]): string {
    const lines = ['| Package | Version | Released | Notes | Source | Verified |', '| --- | --- | --- | --- | --- | --- |'];
    for (const r of rows) lines.push(`| \`${r.id}\` | ${r.error ? 'UNVERIFIED' : r.version} | ${r.released || '-'} | ${r.error ? `fetch failed: ${r.error}` : r.note || '-'} | ${r.source} | ${r.verified || '-'} |`);
    return `${TABLE_START}\n${lines.join('\n')}\n${TABLE_END}`;
}

// Rows of a STACK.md version table: id -> pinned version and verified date.
export function readTable(text: string): { id: string; version: string; verified: string }[] {
    const s = text.indexOf('<!-- versions:start');
    const e = text.indexOf(TABLE_END);
    if (s < 0 || e < s) return [];
    return text
        .slice(s, e)
        .split('\n')
        .map((l) => l.match(/^\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|(?:[^|]*\|){3}\s*([^|]*?)\s*\|/))
        .filter((m): m is RegExpMatchArray => !!m)
        .map((m) => ({ id: m[1], version: m[2], verified: m[3] }));
}

const mm = (v: string) => v.split(/[.+-]/).slice(0, 2).join('.');

if (import.meta.main) {
    const argv = process.argv.slice(2);
    if (argv.includes('--help') || argv.includes('-h') || argv.length === 0) {
        console.log(readFileSync(import.meta.path, 'utf8').split('\n').slice(2, 10).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
        process.exit(argv.length === 0 ? 1 : 0);
    }
    const refresh = argv.includes('--refresh');
    const ci = argv.indexOf('--check');
    if (ci >= 0) {
        const file = argv[ci + 1];
        if (!file || !existsSync(file)) {
            console.error(`versions: no such file ${file ?? '(missing)'}`);
            process.exit(1);
        }
        const pinned = readTable(readFileSync(file, 'utf8'));
        if (!pinned.length) {
            console.error(`versions: no version table in ${file} (expected the ${TABLE_START.slice(0, 22)} block)`);
            process.exit(1);
        }
        const live = await versions(pinned.map((p) => p.id), refresh);
        let drift = 0;
        let unverified = 0;
        for (const [i, p] of pinned.entries()) {
            const l = live[i];
            if (l.error || p.version === 'UNVERIFIED') {
                unverified++;
                console.log(`? ${p.id}: ${l.error ? `fetch failed (${l.error})` : `unverified in ${file}, latest ${l.version}`}`);
            } else if (mm(l.version) !== mm(p.version)) {
                drift++;
                console.log(`DRIFT ${p.id}: ${p.version} -> ${l.version}`);
            } else if (l.version !== p.version) console.log(`patch ${p.id}: ${p.version} -> ${l.version}`);
        }
        const oldest = pinned.map((p) => p.verified).filter(Boolean).sort()[0];
        const age = oldest ? Math.floor((Date.now() - Date.parse(oldest)) / 864e5) : -1;
        console.log(`checked ${pinned.length}: ${drift} minor/major drift, ${unverified} unverified${age >= 0 ? `, table verified ${age} days ago` : ''}`);
        process.exit(drift || unverified ? 1 : 0);
    }
    const ids = argv.filter((a) => !a.startsWith('--'));
    const rows = await versions(ids, refresh);
    if (argv.includes('--json')) console.log(JSON.stringify(rows, null, 2));
    else if (argv.includes('--table')) console.log(table(rows));
    else {
        const w = Math.max(8, ...rows.map((r) => r.id.length));
        for (const r of rows) console.log(`${r.id.padEnd(w)}  ${(r.error ? '?' : r.version).padEnd(12)} ${(r.released || '-').padEnd(10)}  ${r.error ? `error: ${r.error}` : r.note}`);
    }
    process.exit(rows.some((r) => r.error) ? 1 : 0);
}
