#!/usr/bin/env bun
// Git merge driver for JSON locale catalogs (flat or nested key-value files):
// a 3-way merge per key instead of line hunks. Installed by `wf lang install-driver`.
//
//   git config merge.wf-lang.driver "bun <this file> %O %A %B %P"
//
// Per key: a change on one side wins; the same change on both sides is kept; an
// addition on either side is kept (both sides adding different values conflicts);
// a deletion wins over an untouched key. A key deleted on one side but changed on
// the other is kept and warned about as resurrected. Order: ours, then theirs' new
// keys. Writes %A with ours' indent style. Exit 1 on a conflict (ours' value is
// kept for that key) or when a side is not JSON (then a plain git merge-file runs).
import { readFileSync, writeFileSync } from 'node:fs';

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

// The file's indent unit: a tab, or the width of the first indented line (default 2).
export function detectIndent(text: string): string | number {
    const m = text.match(/^([ \t]+)\S/m);
    if (!m) return 2;
    return m[1].startsWith('\t') ? '\t' : m[1].length;
}

// Serialize like the original: same indent, trailing newline when it had one.
export const format = (data: unknown, original: string): string =>
    JSON.stringify(data, null, detectIndent(original)) + (original === '' || original.endsWith('\n') ? '\n' : '');

export type MergeNote = { conflicts: string[]; resurrected: string[] };

export function merge3(base: Obj, ours: Obj, theirs: Obj, notes: MergeNote, prefix = ''): Obj {
    const out: Obj = {};
    const keys = [...Object.keys(ours), ...Object.keys(theirs).filter((k) => !(k in ours))];
    for (const k of keys) {
        const name = prefix + k;
        const [b, o, t] = [base[k], ours[k], theirs[k]];
        const [inB, inO, inT] = [k in base, k in ours, k in theirs];
        if (inO && inT) {
            if (same(o, t)) out[k] = o;
            else if (isObj(o) && isObj(t)) out[k] = merge3(isObj(b) ? b : {}, o, t, notes, `${name}.`);
            else if (inB && same(o, b)) out[k] = t;
            else if (inB && same(t, b)) out[k] = o;
            else {
                notes.conflicts.push(name);
                out[k] = o;
            }
        } else {
            const [side, val] = inO ? ['theirs', o] : ['ours', t];
            if (!inB) out[k] = val; // added on one side
            else if (!same(val, b)) {
                // deleted on one side, changed on the other: keep it, but say so
                notes.resurrected.push(`${name} (deleted in ${side})`);
                out[k] = val;
            }
        }
    }
    return out;
}

function main(args: string[]): number {
    const [basePath, oursPath, theirsPath, name = oursPath] = args;
    if (!theirsPath) {
        console.error('usage: lang-merge-driver.ts BASE OURS THEIRS [PATH]   (git merge driver: %O %A %B %P)');
        return 2;
    }
    const text = (p: string) => readFileSync(p, 'utf8');
    let parsed: Obj[];
    try {
        parsed = [basePath, oursPath, theirsPath].map((p) => {
            const t = text(p).trim();
            const v = t ? JSON.parse(t) : {};
            if (!isObj(v)) throw new Error('not an object');
            return v;
        });
    } catch (e) {
        console.error(`wf-lang: ${name}: not a JSON object (${(e as Error).message}); falling back to git merge-file`);
        const r = Bun.spawnSync(['git', 'merge-file', '-L', 'ours', '-L', 'base', '-L', 'theirs', oursPath, basePath, theirsPath]);
        return r.exitCode === 0 ? 0 : 1;
    }
    const notes: MergeNote = { conflicts: [], resurrected: [] };
    const merged = merge3(parsed[0], parsed[1], parsed[2], notes);
    writeFileSync(oursPath, format(merged, text(oursPath)));
    for (const k of notes.resurrected) console.error(`wf-lang: ${name}: resurrected ${k}: changed on the other side, kept`);
    for (const k of notes.conflicts) console.error(`wf-lang: ${name}: conflict on ${k} (both sides changed it); kept ours`);
    return notes.conflicts.length ? 1 : 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
