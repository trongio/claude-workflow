#!/usr/bin/env bun
// wf-help: one-shot page check per url x viewport (overflow, clipped text, alt, console, screenshot)
import { join } from 'node:path';
import { CHECKS, type CheckOpts, checkOne, summary } from '../pw/check.ts';
import { devBase, devUrlSet, ensureDir, here, install, launchOrExit, NO_DEV_URL, out, shotsDir, viewportsDefault } from '../pw/lib.ts';

const HELP = `wf check URL... [--viewports 375,1440] [--locale X] [--expect TEXT]... [--auth STATE_FILE]
         [--advisory tap,nowrap] [--base URL] [--timeout MS] [--json]
wf check --install   cache playwright-core under ~/.cache/claude-workflow/pw

One result per url x viewport: status, final url, h1, console errors, failed requests,
horizontal overflow, clipped text, nowrap prose, mid-word breaks, images without alt or
width/height, tap targets under 44px (widths < 768), <html lang>, full-page screenshot.
--viewports defaults to dev.viewports (375,1440). URLs may be paths, joined to dev.url or
--base; a path with neither set is refused. With ux.widestLocale (or --locale) set, a page
whose <html lang> differs fails as wrong-locale and its other viewports are skipped.
--advisory lists checks that are reported but do not fail (${CHECKS.join(',')}).
Prints one line per result (--json: one JSON line); all results go to .workflow/check-last.jsonl.
Exit 1 when any check fails, 2 on bad usage or no Playwright.`;

const argv = process.argv.slice(2);
const urls: string[] = [];
const o: CheckOpts = { base: devBase(), expect: [], advisory: new Set(), shotDir: join(shotsDir(), 'check'), timeout: 15000 };
let viewports = viewportsDefault();
let json = false;
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
        } else if (a === '--install') process.exit(await install());
        else if (a === '--viewports') viewports = val().split(',').map(Number);
        else if (a === '--locale') o.locale = val();
        else if (a === '--expect') o.expect.push(val());
        else if (a === '--auth') o.auth = val();
        else if (a === '--advisory') for (const k of val().split(',')) o.advisory.add(k);
        else if (a === '--base') {
            o.base = val().replace(/\/$/, '');
            baseGiven = true;
        } else if (a === '--timeout') o.timeout = Number(val());
        else if (a === '--json') json = true;
        else if (a.startsWith('-')) throw new Error(`unknown flag ${a}`);
        else urls.push(a);
    }
    if (!urls.length) throw new Error('need at least one URL');
    if (!baseGiven && !devUrlSet() && urls.some((u) => !/^https?:\/\//.test(u))) throw new Error(NO_DEV_URL);
    if (viewports.some((v) => !Number.isInteger(v) || v < 200)) throw new Error('--viewports takes widths like 375,1440');
} catch (e) {
    console.error(`wf check: ${(e as Error).message}\n${HELP}`);
    process.exit(2);
}

const browser = await launchOrExit('check');

const log = ensureDir(join(here, '.workflow', 'check-last.jsonl'));
const lines: string[] = [];
let bad = 0;
for (const url of urls) {
    for (const vp of viewports) {
        const r = await checkOne(browser, url, vp, o);
        lines.push(JSON.stringify(r));
        if (!r.ok) bad++;
        if (json) out(r);
        else console.log(summary(r));
        if (r.fail.includes('wrong-locale')) break;
    }
}
await browser.close();
await Bun.write(log, `${lines.join('\n')}\n`);
if (!json) console.log(`${lines.length - bad}/${lines.length} ok; details ${log}`);
process.exit(bad ? 1 : 0);
