#!/usr/bin/env bun
// wf-help: run a scripted browser journey (FILE.json); pass/fail per step, stops at the first failure
import { basename, join } from 'node:path';
import { type FlowOpts, loadFlow, runFlow } from '../pw/flow.ts';
import { devBase, launchOrExit, out, shotsDir } from '../pw/lib.ts';

const HELP = `wf flow FILE.json [--viewport 375] [--base URL] [--auth STATE_FILE] [--save-state FILE] [--timeout MS] [--json]

FILE: {"base"?, "viewport"?, "locale"?, "auth"?, "steps": [...]} or a bare steps array.
Steps (one action each; optional "timeout"):
  {"goto": "/path"}                     {"click": "Save" | {"role": "button", "name": "Save"} | {"text"|"label"|"testid"|"selector": ...}}
  {"fill": "Email" (label or placeholder) | {target}, "value": "x"}   {"select": target, "value": "x"}
  {"press": "Enter"}   {"wait": 500 | "css"}   {"expectText": "..."}   {"expectNoText": "..."}
  {"expectUrl": "/substring" | "/regex/"}   {"screenshot": "name"}   {"saveState": ".workflow/auth.json"}
  {"include": "other.flow.json"} (relative to this file)
Strings may use {{env.NAME}} so credentials stay out of the file.
On failure: the step's error, a screenshot and the last 20 console lines. Exit 1 on failure, 2 on bad usage.`;

const argv = process.argv.slice(2);
let file = '';
let json = false;
const o: FlowOpts = { base: devBase(), shotDir: '', timeout: 10000 };
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
        } else if (a === '--viewport') o.viewport = Number(val());
        else if (a === '--base') o.base = val().replace(/\/$/, '');
        else if (a === '--auth') o.auth = val();
        else if (a === '--save-state') o.saveState = val();
        else if (a === '--timeout') o.timeout = Number(val());
        else if (a === '--json') json = true;
        else if (a.startsWith('-') || file) throw new Error(`unexpected ${a}`);
        else file = a;
    }
    if (!file) throw new Error('need a FILE.json');
} catch (e) {
    console.error(`wf flow: ${(e as Error).message}\n${HELP}`);
    process.exit(2);
}

let flow: ReturnType<typeof loadFlow>;
try {
    flow = loadFlow(file);
} catch (e) {
    console.error(`wf flow: ${(e as Error).message}`);
    process.exit(2);
}
if (flow.base && !argv.includes('--base')) o.base = flow.base.replace(/\/$/, '');
o.shotDir = join(shotsDir(), 'flow', basename(file).replace(/(\.flow)?\.json$/, ''));

const browser = await launchOrExit('flow');
const ok = await runFlow(browser, flow, o, (r) => {
    if (json) return out(r);
    console.log(`${r.ok ? 'ok  ' : 'FAIL'} ${String(r.n).padStart(2)} ${r.step}${r.ok ? '' : `: ${r.error}`}`);
    if (r.ok && r.shot) console.log(`        shot ${r.shot}`);
    if (!r.ok) {
        if (r.shot) console.log(`shot ${r.shot}`);
        if (r.console?.length) console.log(`console (last ${r.console.length}):\n  ${r.console.join('\n  ')}`);
    }
});
await browser.close();
if (!json) console.log(ok ? `flow ok: ${flow.steps.length} steps` : 'flow failed');
process.exit(ok ? 0 : 1);
