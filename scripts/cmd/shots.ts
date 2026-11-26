#!/usr/bin/env bun
// wf-help: screenshot a card's surfaces at every dev viewport in the widest locale; writes a manifest
import { existsSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { readCards } from '../lib.ts';
import { checkOne, expectedLang, summary } from '../pw/check.ts';
import { loadFlow, runFlow } from '../pw/flow.ts';
import { cfg, devBase, devUrlSet, here, launchOrExit, main, NO_DEV_URL, shotsDir, viewportsDefault } from '../pw/lib.ts';

const HELP = `wf shots ID [PATH...] [--viewports 375,1440] [--locale X] [--base URL]

Takes a full-page screenshot and runs the wf check probes for each path x viewport
(dev.viewports, default 375,1440) in the widest locale (ux.widestLocale), so the verifier and ux-critic only
judge images. Relative paths need dev.url or --base. Paths default to the card's "## Surfaces" section. Signs in once with the
flow file in dev.loginFlow (default .workflow/login.flow.json) when it exists.
Writes <dev.screenshots>/ID/manifest.json and prints one line per failing shot.
Exit 1 when a check fails or the login flow fails, 2 on bad usage.`;

const argv = process.argv.slice(2);
// Help wins wherever it appears: nothing else runs.
if (argv.includes('-h') || argv.includes('--help')) {
    console.log(HELP);
    process.exit(0);
}
let id = '';
const paths: string[] = [];
let viewports = viewportsDefault();
let locale = expectedLang();
let base = devBase();
let baseGiven = false;
try {
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const val = () => {
            if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
            return argv[++i];
        };
        if (a === '-h' || a === '--help') {
            console.log(HELP);
            process.exit(0);
        } else if (a === '--viewports') viewports = val().split(',').map(Number);
        else if (a === '--locale') locale = val();
        else if (a === '--base') {
            base = val().replace(/\/$/, '');
            baseGiven = true;
        } else if (a.startsWith('-')) throw new Error(`unknown flag ${a}`);
        else if (!id) id = a;
        else paths.push(a);
    }
    if (!id) throw new Error('need a card ID');
} catch (e) {
    console.error(`wf shots: ${(e as Error).message}\n${HELP}`);
    process.exit(2);
}

// Paths and URLs listed under the card's "## Surfaces" heading.
function surfaces(body: string): string[] {
    const m = body.match(/^##\s+Surfaces\s*\n([\s\S]*?)(?=^##\s|(?![\s\S]))/m);
    if (!m) return [];
    return [...m[1].matchAll(/(?:^|[\s`(])((?:https?:\/\/[^\s`)]+)|\/[^\s`),]*)/gm)].map((x) => x[1]);
}

if (!paths.length) {
    const card = readCards().find((c) => c.id === id);
    if (!card) {
        console.error(`wf shots: no card ${id} and no paths given`);
        process.exit(2);
    }
    paths.push(...surfaces(card.body));
    if (!paths.length) {
        console.error(`wf shots: card ${id} has no "## Surfaces" paths; pass them: wf shots ${id} /path ...`);
        process.exit(2);
    }
}

if (!baseGiven && !devUrlSet() && paths.some((p) => !/^https?:\/\//.test(p))) {
    console.error(`wf shots: ${NO_DEV_URL}`);
    process.exit(2);
}

const dir = join(shotsDir(), id);
const browser = await launchOrExit('shots');

// Sign in once; every shot reuses the storage state.
const loginKey = cfg<string | undefined>('dev.loginFlow', undefined);
const loginFile = [here, main].map((d) => resolve(d, loginKey ?? '.workflow/login.flow.json')).find(existsSync);
let auth: string | undefined;
if (loginFile) {
    auth = join(dir, '.auth.json');
    let failure = '';
    const ok = await Promise.resolve()
        .then(() => runFlow(browser, loadFlow(loginFile), { base, shotDir: dir, saveState: auth, timeout: 15000 }, (r) => {
            if (!r.ok) failure = `step ${r.n} ${r.step}: ${r.error} (shot ${r.shot})`;
        }))
        .catch((e: Error) => {
            failure = e.message;
            return false;
        });
    if (!ok) {
        console.log(`login flow failed: ${failure}`);
        await browser.close();
        process.exit(1);
    }
} else {
    console.log(`login: none (${loginKey ? `no file ${loginKey}` : 'dev.loginFlow not set, no .workflow/login.flow.json'}); shooting signed out`);
}

const shots = [];
let bad = 0;
for (const path of paths) {
    for (const vp of viewports) {
        const r = await checkOne(browser, path, vp, { base, locale, expect: [], advisory: new Set(), shotDir: dir, timeout: 15000 });
        const { url, shot, ...rest } = r;
        shots.push({ path: url, viewport: vp, file: shot ? relative(dir, shot) : null, ...rest });
        if (!r.ok) {
            bad++;
            console.log(summary(r));
        }
    }
}
await browser.close();
const manifest = join(dir, 'manifest.json');
await Bun.write(manifest, `${JSON.stringify({ id, base, locale: locale ?? null, login: loginFile ?? null, generated: new Date().toISOString(), shots }, null, 2)}\n`);
console.log(`shots ${id}: ${shots.length} shots, ${bad} with failing checks -> ${manifest}`);
process.exit(bad ? 1 : 0);
