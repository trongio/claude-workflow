#!/usr/bin/env bun
// wf-help: JSON locale catalogs: get|set|rm|missing KEY, keeps each file's indent; install-driver
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { format } from '../lang-merge-driver.ts';
import { cfg, ensureDir, here } from '../pw/lib.ts';

const HELP = `wf lang get KEY...                         value per locale ("-" when missing)
wf lang set KEY VALUE [KEY VALUE...] [--locale X[,Y]] [--create]   default locale: --base (en)
wf lang rm KEY... [--locale X]             default: every locale
wf lang missing [--base en] [--all] [--json]   keys in the base locale missing elsewhere (exit 1)
wf lang install-driver                     3-way per-key git merge driver for the catalogs
Options: --dir DIR (else ux.localeDir, else the first of ${'lang/ locales/ src/locales/ resources/js/locales/ public/locales/ src/i18n/ resources/lang/'})
Layouts: DIR/<locale>.json, or DIR/<locale>/<namespace>.json with keys "ns:key.path" or "ns.key.path".
Keys resolve flat ("a.b" literal) first, then nested. Each write keeps the file's indent
(tabs or N spaces) and is read back to assert it landed. --locale names existing locales;
a locale with no catalog yet is refused unless --create.`;

const CANDIDATES = ['lang', 'locales', 'src/locales', 'resources/js/locales', 'public/locales', 'src/i18n', 'resources/lang'];
const LOCALE = /^[a-z]{2,3}([-_][A-Za-z0-9]{2,4})?$/;
type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);

const die = (msg: string, code = 2): never => {
    console.error(`wf lang: ${msg}`);
    process.exit(code);
};

// Argument parsing: flags with values, the rest positional.
const argv = process.argv.slice(2);
// Help wins wherever it appears: nothing else runs.
if (argv.includes('-h') || argv.includes('--help')) {
    console.log(HELP);
    process.exit(0);
}
const flags: Record<string, string | true> = {};
const pos: string[] = [];
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') {
        console.log(HELP);
        process.exit(0);
    }
    if (['--dir', '--locale', '--base'].includes(a)) {
        if (i + 1 >= argv.length) die(`${a} needs a value`);
        flags[a.slice(2)] = argv[++i];
    } else if (a === '--all' || a === '--json' || a === '--create') flags[a.slice(2)] = true;
    else if (a.startsWith('--')) die(`unknown flag ${a}`);
    else pos.push(a);
}
const [cmd, ...args] = pos;
if (!cmd) die(`need a command\n${HELP}`);

type Catalog = { dir: string; nested: boolean; locales: string[] };
function detect(): Catalog {
    const given = (flags.dir as string) || cfg<string>('ux.localeDir', '');
    for (const d of given ? [given] : CANDIDATES) {
        const dir = resolve(here, d);
        if (!existsSync(dir) || !statSync(dir).isDirectory()) continue;
        const entries = readdirSync(dir);
        const files = entries.filter((f) => f.endsWith('.json') && LOCALE.test(f.slice(0, -5))).map((f) => f.slice(0, -5));
        if (files.length) return { dir, nested: false, locales: files.sort() };
        const subs = entries.filter((f) => LOCALE.test(f) && statSync(join(dir, f)).isDirectory() && readdirSync(join(dir, f)).some((x) => x.endsWith('.json')));
        if (subs.length) return { dir, nested: true, locales: subs.sort() };
    }
    return die(given ? `no locale catalogs in ${given}` : 'no locale dir found; pass --dir or set ux.localeDir');
}
const cat = detect();
const base = (flags.base as string) || (cat.locales.includes('en') ? 'en' : cat.locales[0]);

// KEY -> file and the key inside it.
function place(locale: string, key: string): { file: string; key: string } {
    if (!cat.nested) return { file: join(cat.dir, `${locale}.json`), key };
    const cut = key.includes(':') ? key.indexOf(':') : key.indexOf('.');
    if (cut < 1) die(`key ${key} needs a namespace (ns:key) in ${relative(here, cat.dir)}/<locale>/<ns>.json`);
    return { file: join(cat.dir, locale, `${key.slice(0, cut)}.json`), key: key.slice(cut + 1) };
}

const read = (file: string): { text: string; data: Obj } => {
    if (!existsSync(file)) return { text: '', data: {} };
    const text = readFileSync(file, 'utf8');
    try {
        const data = text.trim() ? JSON.parse(text) : {};
        return { text, data: isObj(data) ? data : die(`${file} is not a JSON object`) };
    } catch (e) {
        return die(`${file}: ${(e as Error).message}`);
    }
};

// Path to KEY: a literal key first, then split on dots into nested objects.
function lookup(obj: Obj, key: string): string[] | null {
    if (key in obj) return [key];
    for (let i = key.indexOf('.'); i > 0; i = key.indexOf('.', i + 1)) {
        const head = key.slice(0, i);
        if (isObj(obj[head])) {
            const rest = lookup(obj[head] as Obj, key.slice(i + 1));
            if (rest) return [head, ...rest];
        }
    }
    return null;
}
const getAt = (obj: Obj, path: string[]): unknown => path.reduce<unknown>((o, k) => (isObj(o) ? o[k] : undefined), obj);
const getKey = (obj: Obj, key: string): unknown => {
    const p = lookup(obj, key);
    return p ? getAt(obj, p) : undefined;
};

// A new key goes nested when the file already nests, else flat.
function setKey(obj: Obj, key: string, value: string): void {
    const path = lookup(obj, key) ?? (Object.values(obj).some(isObj) ? key.split('.') : [key]);
    let o = obj;
    for (const k of path.slice(0, -1)) {
        if (o[k] === undefined) o[k] = {};
        if (!isObj(o[k])) die(`cannot nest ${key}: ${k} holds a value`);
        o = o[k] as Obj;
    }
    o[path[path.length - 1]] = value;
}
function rmKey(obj: Obj, key: string): boolean {
    const path = lookup(obj, key);
    if (!path) return false;
    const parents: Obj[] = [obj];
    for (const k of path.slice(0, -1)) parents.push(parents[parents.length - 1][k] as Obj);
    delete parents[path.length - 1][path[path.length - 1]];
    // drop parents the removal left empty
    for (let i = path.length - 1; i > 0 && !Object.keys(parents[i]).length; i--) delete parents[i - 1][path[i - 1]];
    return true;
}

// Every leaf key of a locale ("ns:key" in the namespaced layout).
function leaves(locale: string): Map<string, unknown> {
    const out = new Map<string, unknown>();
    const walk = (o: Obj, pre: string) => {
        for (const [k, v] of Object.entries(o)) isObj(v) ? walk(v, `${pre}${k}.`) : out.set(pre + k, v);
    };
    if (!cat.nested) walk(read(join(cat.dir, `${locale}.json`)).data, '');
    else {
        const d = join(cat.dir, locale);
        for (const f of existsSync(d) ? readdirSync(d).filter((x) => x.endsWith('.json')).sort() : []) walk(read(join(d, f)).data, `${f.slice(0, -5)}:`);
    }
    return out;
}

const targets = (): string[] => {
    const l = flags.locale as string | undefined;
    if (!l) return [];
    const list = l.split(',');
    for (const x of list) {
        if (!LOCALE.test(x)) die(`bad locale ${x}`);
        if (!flags.create && !cat.locales.includes(x))
            die(`no catalog for locale ${x} in ${relative(here, cat.dir) || '.'} (have ${cat.locales.join(', ')}); pass --create to start one`);
    }
    return list;
};

// Apply edits per file, write once, then read back and assert each key.
function edit(changes: { locale: string; key: string; value?: string }[]): number {
    const byFile = new Map<string, { text: string; data: Obj; items: { key: string; value?: string }[] }>();
    for (const c of changes) {
        const p = place(c.locale, c.key);
        if (!byFile.has(p.file)) byFile.set(p.file, { ...read(p.file), items: [] });
        byFile.get(p.file)?.items.push({ key: p.key, value: c.value });
    }
    let n = 0;
    for (const [file, f] of byFile) {
        let touched = 0;
        for (const it of f.items) {
            if (it.value === undefined) touched += +rmKey(f.data, it.key);
            else {
                setKey(f.data, it.key, it.value);
                touched++;
            }
        }
        if (!touched) continue;
        // A new file takes the indent of a sibling catalog.
        const near = existsSync(dirname(file)) ? readdirSync(dirname(file)).find((x) => x.endsWith('.json')) : undefined;
        const sibling = f.text || (near ? readFileSync(join(dirname(file), near), 'utf8') : '');
        writeFileSync(ensureDir(file), format(f.data, sibling));
        const back = read(file).data;
        for (const it of f.items) {
            const v = getKey(back, it.key);
            if (it.value === undefined ? v !== undefined : v !== it.value) die(`${relative(here, file)}: ${it.key} did not land`, 1);
        }
        n += touched;
    }
    return n;
}

if (cmd === 'get') {
    if (!args.length) die('get needs a KEY');
    const locales = targets().length ? targets() : cat.locales;
    for (const key of args) {
        for (const l of locales) {
            const p = place(l, key);
            const v = getKey(read(p.file).data, p.key);
            console.log(`${key}\t${l}\t${v === undefined ? '-' : typeof v === 'string' ? v : JSON.stringify(v)}`);
        }
    }
} else if (cmd === 'set') {
    if (!args.length || args.length % 2) die('set takes KEY VALUE pairs');
    const locales = targets().length ? targets() : [base];
    const changes = [];
    for (let i = 0; i < args.length; i += 2) for (const locale of locales) changes.push({ locale, key: args[i], value: args[i + 1] });
    console.log(`set ${edit(changes)} keys in ${locales.join(', ')}`);
} else if (cmd === 'rm') {
    if (!args.length) die('rm needs a KEY');
    const locales = targets().length ? targets() : cat.locales;
    console.log(`removed ${edit(args.flatMap((key) => locales.map((locale) => ({ locale, key }))))} keys`);
} else if (cmd === 'missing') {
    const want = leaves(base);
    const report: Record<string, string[]> = {};
    for (const l of cat.locales.filter((x) => x !== base)) {
        const have = leaves(l);
        report[l] = [...want.keys()].filter((k) => !have.has(k));
    }
    if (flags.json) console.log(JSON.stringify({ base, missing: report }));
    else {
        for (const [l, keys] of Object.entries(report)) {
            const shown = flags.all ? keys : keys.slice(0, 10);
            console.log(`${l}: ${keys.length} missing (base ${base})${shown.length ? `\n  ${shown.join('\n  ')}` : ''}${keys.length > shown.length ? `\n  ... ${keys.length - shown.length} more (--all)` : ''}`);
        }
    }
    process.exit(Object.values(report).some((k) => k.length) ? 1 : 0);
} else if (cmd === 'install-driver') {
    const driver = resolve(dirname(import.meta.path), '..', 'lang-merge-driver.ts');
    const rel = relative(here, cat.dir);
    const pattern = cat.nested ? `${rel}/**/*.json merge=wf-lang` : `${rel}/*.json merge=wf-lang`;
    const attrs = join(here, '.gitattributes');
    const current = existsSync(attrs) ? readFileSync(attrs, 'utf8') : '';
    if (!current.split('\n').includes(pattern)) writeFileSync(attrs, `${current}${current && !current.endsWith('\n') ? '\n' : ''}${pattern}\n`);
    const git = (...a: string[]) => Bun.spawnSync(['git', '-C', here, 'config', ...a]).success || die(`git config ${a[0]} failed`);
    git('merge.wf-lang.name', 'wf lang: 3-way merge per key of JSON locale catalogs');
    git('merge.wf-lang.driver', `bun '${driver}' %O %A %B %P`);
    console.log(`.gitattributes: ${pattern} (commit it)\ngit config merge.wf-lang.driver -> ${relative(here, driver) || driver}`);
} else die(`unknown command ${cmd}\n${HELP}`);
