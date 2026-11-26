// Scripted journey behind `wf flow` (and the login of `wf shots`): one browser,
// steps in order, stop at the first failure with a screenshot and the console tail.
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { type PW, absUrl, ensureDir, here, trim, vpSize } from './lib.ts';

export type Step = Record<string, unknown>;
export type FlowFile = { base?: string; viewport?: number; locale?: string; auth?: string; steps: Step[] };
export type FlowOpts = { base: string; viewport?: number; auth?: string; shotDir: string; saveState?: string; timeout: number };
export type StepResult = { n: number; step: string; ok: boolean; ms: number; error?: string; shot?: string; console?: string[] };

const ACTIONS = ['goto', 'click', 'fill', 'select', 'press', 'expectText', 'expectNoText', 'expectUrl', 'screenshot', 'saveState', 'wait'];

// {{env.NAME}} pulls a value from the environment so flow files never hold secrets.
function expand(v: unknown): unknown {
    if (typeof v === 'string') {
        return v.replace(/\{\{env\.([A-Za-z_][A-Za-z0-9_]*)\}\}/g, (_, name) => {
            const val = process.env[name];
            if (val === undefined) throw new Error(`env ${name} is not set`);
            return val;
        });
    }
    if (Array.isArray(v)) return v.map(expand);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, expand(x)]));
    return v;
}

// Read a flow file and splice its includes (relative to the including file).
export function loadFlow(file: string, seen: string[] = []): FlowFile {
    const path = resolve(file);
    if (seen.includes(path)) throw new Error(`include cycle: ${[...seen, path].join(' -> ')}`);
    if (!existsSync(path)) throw new Error(`no flow file ${file}`);
    const raw = JSON.parse(readFileSync(path, 'utf8')) as FlowFile | Step[];
    const flow: FlowFile = Array.isArray(raw) ? { steps: raw } : raw;
    if (!Array.isArray(flow.steps)) throw new Error(`${file}: needs a "steps" array`);
    const steps: Step[] = [];
    for (const s of flow.steps) {
        if (typeof s.include === 'string') steps.push(...loadFlow(join(dirname(path), s.include), [...seen, path]).steps);
        else {
            const action = Object.keys(s).find((k) => ACTIONS.includes(k));
            if (!action) throw new Error(`${file}: step ${JSON.stringify(s)} has no action (${ACTIONS.join(', ')}, include)`);
            steps.push(expand(s) as Step);
        }
    }
    return { ...flow, steps };
}

// A target: "text" (a button, then a link, then any text; a field: its label,
// then its placeholder), or {role, name}, {text}, {label}, {placeholder}, {testid}, {selector}.
async function locate(page: PW, t: unknown, timeout: number, field = false): Promise<PW> {
    if (typeof t === 'string') {
        const tiers = field
            ? [page.getByLabel(t), page.getByPlaceholder(t)]
            : [page.getByRole('button', { name: t }), page.getByRole('link', { name: t }), page.getByText(t)];
        // Wait for any tier to appear, then take the best one present (an h1 "Sign in" loses to the button).
        await tiers.reduce((a, b) => a.or(b)).first().waitFor({ timeout });
        for (const l of tiers) if (await l.count()) return l.first();
    }
    const o = (t ?? {}) as Record<string, string>;
    if (o.role) return page.getByRole(o.role, o.name ? { name: o.name } : {}).first();
    if (o.text) return page.getByText(o.text).first();
    if (o.label) return page.getByLabel(o.label).first();
    if (o.placeholder) return page.getByPlaceholder(o.placeholder).first();
    if (o.testid) return page.getByTestId(o.testid).first();
    if (o.selector) return page.locator(o.selector).first();
    throw new Error(`bad target ${JSON.stringify(t)}`);
}

export const describe = (s: Step): string => {
    const action = Object.keys(s).find((k) => ACTIONS.includes(k)) ?? '?';
    const v = s[action];
    return trim(`${action} ${typeof v === 'string' || typeof v === 'number' ? v : JSON.stringify(v)}`, 70);
};

async function run(page: PW, ctx: PW, s: Step, o: FlowOpts, timeout: number): Promise<string | undefined> {
    if ('goto' in s) await page.goto(absUrl(String(s.goto), o.base), { waitUntil: 'load', timeout });
    else if ('click' in s) (await locate(page, s.click, timeout)).click({ timeout });
    else if ('fill' in s) (await locate(page, s.fill, timeout, true)).fill(String(s.value ?? ''), { timeout });
    else if ('select' in s) (await locate(page, s.select, timeout, true)).selectOption(String(s.value ?? ''), { timeout });
    else if ('press' in s) await page.keyboard.press(String(s.press));
    else if ('wait' in s) {
        if (typeof s.wait === 'number') await page.waitForTimeout(s.wait);
        else await page.locator(String(s.wait)).first().waitFor({ timeout });
    } else if ('expectText' in s) await page.getByText(String(s.expectText)).first().waitFor({ timeout });
    else if ('expectNoText' in s) {
        await page.waitForLoadState('networkidle', { timeout: 2000 }).catch(() => {});
        if (await page.getByText(String(s.expectNoText)).count()) throw new Error(`text present: ${s.expectNoText}`);
    } else if ('expectUrl' in s) {
        const want = String(s.expectUrl);
        const re = /^\/.+\/$/.test(want) && want.length > 2 ? new RegExp(want.slice(1, -1)) : null;
        await page.waitForURL((u: URL) => (re ? re.test(u.href) : u.href.includes(want)), { timeout });
    } else if ('screenshot' in s) {
        const file = ensureDir(join(o.shotDir, `${String(s.screenshot).replace(/\.png$/, '')}.png`));
        await page.screenshot({ path: file, fullPage: true });
        return file;
    } else if ('saveState' in s) await ctx.storageState({ path: ensureDir(resolve(here, String(s.saveState))) });
    if (['goto', 'click', 'press', 'select'].some((k) => k in s)) await page.waitForLoadState('networkidle', { timeout: 3000 }).catch(() => {});
    return undefined;
}

// Runs every step; calls onStep as each finishes. Returns false at the first failure.
export async function runFlow(browser: PW, flow: FlowFile, o: FlowOpts, onStep: (r: StepResult) => void): Promise<boolean> {
    const vp = o.viewport ?? flow.viewport ?? 1440;
    const auth = o.auth ?? flow.auth;
    const ctx = await browser.newContext({
        viewport: vpSize(vp),
        ...(flow.locale ? { locale: flow.locale, extraHTTPHeaders: { 'Accept-Language': flow.locale } } : {}),
        ...(auth ? { storageState: auth } : {}),
    });
    const page = await ctx.newPage();
    const tail: string[] = [];
    page.on('console', (m: PW) => tail.push(`${m.type()}: ${trim(m.text(), 160)}`));
    page.on('pageerror', (e: Error) => tail.push(`pageerror: ${trim(e.message, 160)}`));
    try {
        for (const [i, s] of flow.steps.entries()) {
            const t0 = Date.now();
            const r: StepResult = { n: i + 1, step: describe(s), ok: true, ms: 0 };
            try {
                r.shot = await run(page, ctx, s, o, Number(s.timeout ?? o.timeout));
            } catch (e) {
                r.ok = false;
                r.error = trim((e as Error).message.split('\n')[0], 200);
                r.shot = ensureDir(join(o.shotDir, `fail-step-${i + 1}.png`));
                await page.screenshot({ path: r.shot, fullPage: true }).catch(() => (r.shot = undefined));
                r.console = tail.slice(-20);
            }
            r.ms = Date.now() - t0;
            onStep(r);
            if (!r.ok) return false;
        }
        if (o.saveState) await ctx.storageState({ path: ensureDir(o.saveState) });
        return true;
    } finally {
        await ctx.close().catch(() => {});
    }
}
