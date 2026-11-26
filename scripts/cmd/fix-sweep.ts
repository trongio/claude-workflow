#!/usr/bin/env bun
// wf-help: cluster recent fix commits by scope and keyword (recurring defect classes)
import { mkdirSync, writeFileSync } from 'node:fs';
import { git, parseArgs, plural, root } from '../lib.ts';

const HELP = `Usage: wf fix-sweep [--since DATE] [--top N] [--json]

Reads fix commits (fix:, fix(scope):, revert, or a subject naming a bug or
regression) since DATE (default 90 days ago) on all branches, and prints the top
scopes and keywords with counts. Commit lists per class go to .workflow/fix-sweep.md.`;

const { flags } = parseArgs(process.argv.slice(2), { since: 'string', top: 'string', json: 'bool' }, HELP);
const since = typeof flags.since === 'string' ? flags.since : '90 days ago';
const top = Number(flags.top ?? 8);
const STOP = new Set(
    'a an the and or of to in on for with from by at is it its be not no when after before into as that this than via only one two all any per out up use new add fix fixes fixed bug regression revert so'.split(' '),
);

const log = git(['log', '--all', '--no-merges', `--since=${since}`, '--format=%h%x09%s']).out.split('\n').filter(Boolean);
const fixes = log
    .map((l) => {
        const [hash, subject] = l.split('\t');
        return { hash, subject };
    })
    .filter(({ subject }) => /^(fix|revert|hotfix)(\(|!|:)/i.test(subject) || /^revert\b/i.test(subject) || /\b(bug|regression)\b/i.test(subject));

const scopes = new Map<string, string[]>();
const words = new Map<string, string[]>();
const add = (m: Map<string, string[]>, k: string, v: string) => m.set(k, [...(m.get(k) ?? []), v]);
for (const { hash, subject } of fixes) {
    const cc = subject.match(/^\w+(?:\(([^)]+)\))?!?:\s*(.*)$/);
    add(scopes, cc?.[1]?.toLowerCase() ?? '(none)', `${hash} ${subject}`);
    const text = (cc?.[2] ?? subject).toLowerCase();
    for (const w of new Set(text.match(/[a-z][a-z0-9_-]{2,}/g) ?? [])) if (!STOP.has(w)) add(words, w, `${hash} ${subject}`);
}
const rank = (m: Map<string, string[]>) => [...m.entries()].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]));
const topScopes = rank(scopes).slice(0, top);
const topWords = rank(words).filter(([, v]) => v.length > 1).slice(0, top);

mkdirSync(`${root}.workflow`, { recursive: true });
const detail = `${root}.workflow/fix-sweep.md`;
const sectionOf = (title: string, list: [string, string[]][]) =>
    `## ${title}\n\n${list.map(([k, v]) => `### ${k} (${v.length})\n\n${v.map((c) => `- ${c}`).join('\n')}`).join('\n\n')}\n`;
writeFileSync(detail, `# Fix sweep since ${since}\n\n${plural(fixes.length, 'fix commit')} of ${log.length}.\n\n${sectionOf('By scope', rank(scopes))}\n${sectionOf('By keyword', topWords)}`);

if (flags.json) {
    console.log(JSON.stringify({ since, fixes: fixes.length, commits: log.length, scopes: topScopes.map(([k, v]) => [k, v.length]), keywords: topWords.map(([k, v]) => [k, v.length]), detail }));
} else {
    console.log(`${plural(fixes.length, 'fix commit')} of ${log.length} since ${since}`);
    const pad = Math.max(8, ...topScopes.map(([k]) => k.length), ...topWords.map(([k]) => k.length));
    const rows = Math.max(topScopes.length, topWords.length);
    if (rows) console.log(`${'scope'.padEnd(pad)}    n  ${'keyword'.padEnd(pad)}    n`);
    for (let i = 0; i < rows; i++) {
        const s = topScopes[i];
        const w = topWords[i];
        console.log(`${(s?.[0] ?? '').padEnd(pad)} ${String(s?.[1].length ?? '').padStart(4)}  ${(w?.[0] ?? '').padEnd(pad)} ${String(w?.[1].length ?? '').padStart(4)}`);
    }
    console.log(`details: ${detail}`);
}
