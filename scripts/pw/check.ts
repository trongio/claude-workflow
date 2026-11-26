// The page check behind `wf check` and `wf shots`: load one url at one width,
// run every probe, take a full-page screenshot, return one compact result.
import { join } from 'node:path';
import { type Findings, type PW, absUrl, cfg, ensureDir, instrument, probe, scrollThrough, slug, trim, vpSize } from './lib.ts';

export type CheckOpts = {
    base: string;
    locale?: string; // expected <html lang>; also sent as the browser locale
    expect: string[];
    auth?: string; // storage state file
    advisory: Set<string>; // check names reported but not failing
    shotDir: string;
    timeout: number;
};

export type Result = {
    ok: boolean;
    url: string;
    vp: number;
    status?: number;
    finalUrl?: string;
    lang?: string;
    h1?: string;
    fail: string[];
    console?: { n: number; first: string[] };
    failed?: { n: number; first: string[] };
    overflow?: Findings['overflow'];
    clipped?: Findings['clipped'];
    nowrap?: Findings['nowrap'];
    midword?: Findings['midword'];
    img?: Findings['img'];
    tap?: Findings['tap'];
    missing?: string[];
    shot?: string;
    error?: string;
    ms: number;
};

export const CHECKS = ['status', 'console', 'requests', 'overflow', 'clipped', 'nowrap', 'midword', 'alt', 'size', 'tap', 'expect'];

// Expected <html lang>: --locale wins, else ux.widestLocale (visual checks run in it).
export const expectedLang = (locale?: string): string | undefined => locale || cfg<string | undefined>('ux.widestLocale', undefined);
const primary = (l: string) => l.toLowerCase().split(/[-_]/)[0];

export async function newContext(browser: PW, vp: number, o: CheckOpts): Promise<PW> {
    const ctx = await browser.newContext({
        viewport: vpSize(vp),
        deviceScaleFactor: 1,
        isMobile: false,
        hasTouch: vp < 768,
        ...(o.locale ? { locale: o.locale, extraHTTPHeaders: { 'Accept-Language': o.locale } } : {}),
        ...(o.auth ? { storageState: o.auth } : {}),
    });
    ctx.setDefaultTimeout(o.timeout);
    return ctx;
}

export async function checkOne(browser: PW, url: string, vp: number, o: CheckOpts, shotName?: string): Promise<Result> {
    const t0 = Date.now();
    const r: Result = { ok: false, url, vp, fail: [], ms: 0 };
    const ctx = await newContext(browser, vp, o);
    try {
        const page = await ctx.newPage();
        const st = instrument(page, o.base);
        const resp = await page.goto(absUrl(url, o.base), { waitUntil: 'load', timeout: o.timeout });
        await page.waitForLoadState('networkidle', { timeout: 2000 }).catch(() => {});
        r.status = resp?.status() ?? 0;
        const final = page.url().replace(new URL(o.base).origin, '');
        if (final !== url && absUrl(url, o.base) !== page.url()) r.finalUrl = final;
        const want = expectedLang(o.locale);
        const lang = await page.evaluate(() => document.documentElement.lang || '');
        r.lang = lang;
        if (want && primary(lang) !== primary(want)) {
            r.fail.push('wrong-locale');
            r.error = `wrong-locale: <html lang="${lang}">, expected ${want}`;
            return r;
        }
        await scrollThrough(page);
        const f = await probe(page, vp < 768);
        r.h1 = f.h1 || undefined;
        if (st.console.length) r.console = { n: st.console.length, first: st.console.slice(0, 3) };
        if (st.failed.length) r.failed = { n: st.failed.length, first: st.failed.slice(0, 3) };
        if (f.overflow) r.overflow = f.overflow;
        for (const k of ['clipped', 'nowrap', 'midword'] as const) if (f[k].n) r[k] = f[k];
        if (f.img.noAlt || f.img.noSize) r.img = f.img;
        if (f.tap?.n) r.tap = f.tap;
        const body = f.text.replace(/\s+/g, ' ');
        const missing = o.expect.filter((t) => !body.includes(t));
        if (missing.length) r.missing = missing;
        r.shot = ensureDir(join(o.shotDir, `${shotName ?? slug(url)}-${vp}.png`));
        await page.screenshot({ path: r.shot, fullPage: true });
        const failed: Record<string, boolean> = {
            status: !r.status || r.status >= 400,
            console: !!r.console,
            requests: !!r.failed,
            overflow: !!r.overflow,
            clipped: !!r.clipped,
            nowrap: !!r.nowrap,
            midword: !!r.midword,
            alt: f.img.noAlt > 0,
            size: f.img.noSize > 0,
            tap: !!r.tap,
            expect: !!r.missing,
        };
        r.fail = CHECKS.filter((k) => failed[k] && !o.advisory.has(k));
    } catch (e) {
        r.error = trim((e as Error).message.split('\n')[0], 200);
        r.fail.push('error');
    } finally {
        await ctx.close().catch(() => {});
        r.ok = r.fail.length === 0;
        r.ms = Date.now() - t0;
    }
    return r;
}

// One line, at most 120 characters, for a human or an agent skimming.
export function summary(r: Result): string {
    const bits: string[] = [];
    if (r.error) bits.push(r.error);
    if (r.status && r.status >= 400) bits.push(`status ${r.status}`);
    if (r.overflow) bits.push(`overflow ${r.overflow.px}px ${r.overflow.el ?? ''}`.trim());
    for (const k of ['clipped', 'nowrap', 'midword', 'tap', 'console', 'failed'] as const) if (r[k]) bits.push(`${k} ${r[k]?.n}`);
    if (r.img?.noAlt) bits.push(`no-alt ${r.img.noAlt}`);
    if (r.img?.noSize) bits.push(`no-size ${r.img.noSize}`);
    if (r.missing) bits.push(`missing "${r.missing[0]}"`);
    const head = `${r.ok ? 'ok  ' : 'FAIL'} ${String(r.vp).padStart(4)} ${trim(r.url, 40)}`;
    const tail = bits.length ? bits.join(', ') : `${r.status} ${r.h1 ? `"${r.h1}"` : ''}`.trim();
    const line = `${head}  ${tail}`;
    return line.length > 120 ? `${line.slice(0, 119)}~` : line;
}
