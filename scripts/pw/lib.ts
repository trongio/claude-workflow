// Shared helpers for wf check / flow / shots: config, Playwright resolution,
// browser launch, page instrumentation and the layout probes. No npm deps:
// Playwright comes from the target project or a cached install.
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

// Pinned for `wf check --install`; its headless shell is a ~100 MB one-time download.
export const PW_VERSION = '1.63.0';
export const PW_CACHE = join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'claude-workflow', 'pw');

const git = (...args: string[]): string => {
    const r = Bun.spawnSync(['git', ...args], { stderr: 'ignore' });
    return r.success ? r.stdout.toString().trim() : '';
};

// Worktree root (outputs land here) and the main checkout (shared config fallback).
export const here = process.env.WF_ROOT?.replace(/\/$/, '') || git('rev-parse', '--show-toplevel') || process.cwd();
const common = git('rev-parse', '--path-format=absolute', '--git-common-dir');
export const main = common.endsWith('/.git') ? common.slice(0, -5) : here;

type Json = Record<string, unknown>;
function loadConfig(): Json {
    for (const dir of [here, main]) {
        const p = join(dir, '.claude', 'workflow.json');
        if (!existsSync(p)) continue;
        try {
            return JSON.parse(readFileSync(p, 'utf8')) as Json;
        } catch (e) {
            console.error(`warning: ${p} is not valid JSON (${(e as Error).message})`);
            return {};
        }
    }
    return {};
}
export const config = loadConfig();

// cfg('dev.url', 'http://localhost') reads a dotted key with a default.
export function cfg<T>(key: string, fallback: T): T {
    let v: unknown = config;
    for (const k of key.split('.')) v = v && typeof v === 'object' ? (v as Json)[k] : undefined;
    return (v ?? fallback) as T;
}

export const devBase = (): string => (process.env.WF_DEV_URL || cfg('dev.url', 'http://localhost:3000')).replace(/\/$/, '');
export const viewportsDefault = (): number[] => cfg<number[]>('dev.viewports', [1440, 390]);
export const shotsDir = (): string => resolve(here, cfg('dev.screenshots', '.workflow/shots'));
export const absUrl = (u: string, base = devBase()): string => (/^https?:\/\//.test(u) ? u : base + (u.startsWith('/') ? u : `/${u}`));
export const slug = (u: string): string =>
    u.replace(/^https?:\/\/[^/]+/, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'root';
export const trim = (s: string, n = 80): string => {
    const t = String(s ?? '').replace(/\s+/g, ' ').trim();
    return t.length > n ? `${t.slice(0, n - 1)}~` : t;
};
export const ensureDir = (file: string): string => {
    mkdirSync(dirname(file), { recursive: true });
    return file;
};

// Playwright: WF_PLAYWRIGHT dir, the project's node_modules (worktree, then main),
// then the cached install. Returns the module and where it came from.
export type PW = any;
export function pwCandidates(): string[] {
    const dirs: string[] = [];
    if (process.env.WF_PLAYWRIGHT) dirs.push(process.env.WF_PLAYWRIGHT);
    for (const root of [...new Set([here, main])]) {
        for (const m of ['playwright-core', 'playwright', '@playwright/test']) dirs.push(join(root, 'node_modules', m));
    }
    dirs.push(join(PW_CACHE, 'node_modules', 'playwright-core'));
    return dirs.filter((d) => existsSync(join(d, 'package.json')));
}

export async function launch(): Promise<{ browser: PW; from: string }> {
    const tried: string[] = [];
    for (const dir of pwCandidates()) {
        try {
            const mod = await import(join(dir, 'index.js'));
            const chromium = mod.chromium ?? mod.default?.chromium;
            const browser = await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage'] });
            return { browser, from: dir };
        } catch (e) {
            tried.push(`${dir}: ${trim((e as Error).message.split('\n')[0], 120)}`);
        }
    }
    const hint = tried.length ? tried.join('; ') : 'no playwright in node_modules or the cache';
    throw new Error(`playwright unavailable (${hint}); run: wf check --install`);
}

// launch() for a CLI: print the reason and exit 2 when there is no Playwright.
export async function launchOrExit(cmd: string): Promise<PW> {
    try {
        return (await launch()).browser;
    } catch (e) {
        console.error(`wf ${cmd}: ${(e as Error).message}`);
        process.exit(2);
    }
}

export async function install(): Promise<number> {
    mkdirSync(PW_CACHE, { recursive: true });
    const pkg = join(PW_CACHE, 'package.json');
    if (!existsSync(pkg)) await Bun.write(pkg, '{"name":"wf-pw","private":true}\n');
    const have = join(PW_CACHE, 'node_modules', 'playwright-core', 'package.json');
    const current = existsSync(have) ? (JSON.parse(readFileSync(have, 'utf8')) as { version: string }).version : '';
    if (current !== PW_VERSION) {
        const npm = Bun.which('npm');
        const cmd = npm
            ? [npm, 'install', '--prefix', PW_CACHE, '--no-audit', '--no-fund', '--silent', `playwright-core@${PW_VERSION}`]
            : ['bun', 'add', '--cwd', PW_CACHE, `playwright-core@${PW_VERSION}`];
        const r = Bun.spawnSync(cmd, { stdout: 'inherit', stderr: 'inherit' });
        if (!r.success) return 1;
    }
    const cli = join(PW_CACHE, 'node_modules', 'playwright-core', 'cli.js');
    const r = Bun.spawnSync(['bun', cli, 'install', '--only-shell', '--no-progress', 'chromium'], { stdout: 'ignore', stderr: 'inherit' });
    console.log(r.success ? `playwright-core ${PW_VERSION} ready in ${PW_CACHE}` : 'browser install failed');
    return r.success ? 0 : 1;
}

export const vpSize = (w: number) => ({ width: w, height: w < 768 ? 844 : 900 });

// Console errors, page errors and failed same-origin requests on one page.
export type Instr = { console: string[]; failed: string[] };
export function instrument(page: PW, base: string): Instr {
    const origin = new URL(base).origin;
    const st: Instr = { console: [], failed: [] };
    const same = (u: string) => {
        try {
            return new URL(u).origin === origin;
        } catch {
            return false;
        }
    };
    page.on('console', (m: PW) => {
        if (m.type() === 'error' && !/^Failed to load resource/.test(m.text())) st.console.push(trim(m.text(), 160));
    });
    page.on('pageerror', (e: Error) => st.console.push(trim(e.message, 160)));
    page.on('response', (r: PW) => {
        const req = r.request();
        if (r.status() < 400 || !same(r.url())) return;
        if (req.isNavigationRequest() && req.frame() === page.mainFrame()) return;
        st.failed.push(`${r.status()} ${new URL(r.url()).pathname}`);
    });
    page.on('requestfailed', (req: PW) => {
        const err = req.failure()?.errorText ?? '';
        if (same(req.url()) && !/ABORTED/.test(err)) st.failed.push(`ERR ${new URL(req.url()).pathname} ${err}`);
    });
    return st;
}

// Scroll to the bottom in screen steps so lazy images load, then back to the top.
export async function scrollThrough(page: PW): Promise<void> {
    await page.evaluate(async () => {
        const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
        for (let i = 0; i < 40; i++) {
            const before = scrollY;
            scrollBy(0, innerHeight);
            await wait(60);
            if (scrollY === before) break;
        }
        await Promise.all(
            [...document.images].filter((i) => !i.complete).map((i) => new Promise((r) => {
                i.addEventListener('load', r, { once: true });
                i.addEventListener('error', r, { once: true });
                setTimeout(r, 1500);
            })),
        );
        scrollTo(0, 0);
    });
}

export type Findings = {
    lang: string;
    h1: string;
    overflow: { px: number; el: string | null } | null;
    clipped: { n: number; first: string[] };
    nowrap: { n: number; first: string[] };
    midword: { n: number; first: string[] };
    img: { noAlt: number; noSize: number; first: string[] };
    tap: { n: number; first: string[] } | null;
    text: string;
};

// Every layout probe in one page.evaluate. Each list keeps its first 3 hits.
export async function probe(page: PW, mobile: boolean): Promise<Findings> {
    return page.evaluate((mobile: boolean) => {
        const sel = (el: Element): string => {
            if (el.id) return `#${el.id}`;
            const cls = [...el.classList].slice(0, 2).join('.');
            return el.tagName.toLowerCase() + (cls ? `.${cls}` : '');
        };
        const words = (s: string) => s.trim().split(/\s+/).filter(Boolean).length;
        const own = (el: Element) => [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent ?? '').join(' ').trim();
        const shown = (el: Element) => {
            const cs = getComputedStyle(el);
            return el.getClientRects().length > 0 && cs.visibility !== 'hidden' && cs.display !== 'none';
        };
        const list = () => ({ n: 0, first: [] as string[] });
        const push = (l: { n: number; first: string[] }, el: Element, text: string) => {
            l.n++;
            if (l.first.length < 3) l.first.push(`${sel(el)} "${text.replace(/\s+/g, ' ').trim().slice(0, 40)}"`);
        };
        const vw = document.documentElement.clientWidth;
        const sw = Math.max(document.documentElement.scrollWidth, document.body?.scrollWidth ?? 0);
        let overflow: { px: number; el: string | null } | null = null;
        if (sw > vw + 1) {
            let worst: Element | null = null;
            let worstPx = 0;
            for (const el of document.body.querySelectorAll('*')) {
                const r = el.getBoundingClientRect();
                const px = r.right + scrollX - vw;
                if (r.width && px > worstPx + 0.5) {
                    worst = el;
                    worstPx = px;
                }
            }
            overflow = { px: Math.round(sw - vw), el: worst ? sel(worst) : null };
        }
        const clipped = list();
        const nowrap = list();
        const midword = list();
        for (const el of document.body?.querySelectorAll('*') ?? []) {
            if (!shown(el) || /^(SCRIPT|STYLE|SVG|INPUT|TEXTAREA|SELECT|OPTION)$/.test(el.tagName)) continue;
            const cs = getComputedStyle(el);
            const text = (el as HTMLElement).innerText ?? '';
            if (!text.trim()) continue;
            const hides = cs.overflowX === 'hidden' || cs.overflowX === 'clip' || cs.textOverflow === 'ellipsis';
            const clamp = cs.webkitLineClamp && cs.webkitLineClamp !== 'none' && el.scrollHeight > el.clientHeight + 1;
            if ((hides && el.scrollWidth > el.clientWidth + 1) || clamp) push(clipped, el, text);
            const mine = own(el);
            if (/^(nowrap|pre)$/.test(cs.whiteSpace) && words(mine) > 4) push(nowrap, el, mine);
        }
        // A word whose letters sit on two lines was broken mid-word.
        const walker = document.createTreeWalker(document.body ?? document.documentElement, NodeFilter.SHOW_TEXT);
        const range = document.createRange();
        let seen = 0;
        for (let node = walker.nextNode(); node && seen < 4000; node = walker.nextNode()) {
            const parent = node.parentElement;
            if (!parent || !shown(parent) || /^(SCRIPT|STYLE|TEXTAREA|OPTION)$/.test(parent.tagName)) continue;
            const data = node.textContent ?? '';
            for (const m of data.matchAll(/[\p{L}\p{N}]{4,}/gu)) {
                if (++seen > 4000) break;
                range.setStart(node, m.index ?? 0);
                range.setEnd(node, (m.index ?? 0) + m[0].length);
                const rects = [...range.getClientRects()].filter((r) => r.width > 0);
                if (rects.length > 1 && rects[rects.length - 1].top > rects[0].bottom - 2) {
                    push(midword, parent, m[0]);
                    break;
                }
            }
        }
        const img = { noAlt: 0, noSize: 0, first: [] as string[] };
        for (const i of document.images) {
            const src = (i.getAttribute('src') ?? '').split('/').pop() ?? '';
            const noAlt = !i.hasAttribute('alt');
            const noSize = !i.hasAttribute('width') || !i.hasAttribute('height');
            img.noAlt += +noAlt;
            img.noSize += +noSize;
            if ((noAlt || noSize) && img.first.length < 3) img.first.push(`${src}${noAlt ? ' no-alt' : ''}${noSize ? ' no-size' : ''}`);
        }
        let tap: { n: number; first: string[] } | null = null;
        if (mobile) {
            tap = list();
            const q = 'a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[tabindex]:not([tabindex="-1"])';
            for (const el of document.querySelectorAll(q)) {
                if (!shown(el)) continue;
                const r = el.getBoundingClientRect();
                // An inline link inside running text is exempt (WCAG 2.5.8).
                const inline = el.tagName === 'A' && getComputedStyle(el).display === 'inline' && words(el.parentElement?.textContent ?? '') > words(el.textContent ?? '') + 3;
                if (!inline && (r.width < 44 || r.height < 44)) push(tap, el, (el.textContent || el.getAttribute('aria-label') || '').trim());
            }
        }
        const h1 = document.querySelector('h1');
        return {
            lang: document.documentElement.lang || '',
            h1: (h1?.textContent ?? '').replace(/\s+/g, ' ').trim().slice(0, 80),
            overflow,
            clipped,
            nowrap,
            midword,
            img,
            tap,
            text: document.body?.innerText ?? '',
        };
    }, mobile);
}

export const out = (o: unknown): void => console.log(JSON.stringify(o));
