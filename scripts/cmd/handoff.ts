#!/usr/bin/env bun
// wf-help: write .workflow/HANDOFF.md (branch, in flight, owner, verifying, unpushed, worktrees, runner, outcomes)
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { ACTIVE, LANDED, baseBranch, git, outcomeProse, parseArgs, readCards, root, today } from '../lib.ts';

const HELP = `Usage: wf handoff

Writes a snapshot a fresh session can resume from to .workflow/HANDOFF.md in the
main checkout and prints 5 summary lines.`;

parseArgs(process.argv.slice(2), {}, HELP);
const cards = readCards({ archive: 'body' });
const base = baseBranch();
const branch = git(['branch', '--show-current']).out || `(detached ${git(['rev-parse', '--short', 'HEAD']).out})`;
const inFlight = cards.filter((t) => ACTIVE.includes(t.status));
const owner = cards.filter((t) => t.status !== 'done' && (t.status === 'owner-review' || /^owner/i.test(t.blocked)));
const verifying = cards.filter((t) => t.status === 'verifying');
const upstream = git(['rev-parse', '--abbrev-ref', `${base}@{upstream}`]);
const unpushed = upstream.ok ? git(['log', '--format=%h %s', `${upstream.out}..${base}`]).out.split('\n').filter(Boolean) : [];
const worktrees = git(['worktree', 'list']).out.split('\n').filter(Boolean).slice(1);

// Runner state: the newest files under .workflow/runner, first line of each.
const runnerDir = `${root}.workflow/runner`;
const runner = existsSync(runnerDir)
    ? readdirSync(runnerDir)
          .map((f) => ({ f, t: statSync(`${runnerDir}/${f}`).mtimeMs }))
          .sort((a, b) => b.t - a.t)
          .slice(0, 8)
          .map(({ f }) => {
              const p = `${runnerDir}/${f}`;
              const first = statSync(p).isFile() ? (readFileSync(p, 'utf8').split('\n')[0] ?? '').slice(0, 100) : '(dir)';
              return `${f}: ${first}`;
          })
    : [];

const outcomes = cards
    .filter((t) => LANDED.includes(t.status) && outcomeProse(t.body))
    .sort((a, b) => (b.done ?? b.landed ?? '').localeCompare(a.done ?? a.landed ?? ''))
    .slice(0, 5)
    .map((t) => `${t.id} (${t.status}): ${outcomeProse(t.body).split('\n').find((l) => l.trim())?.replace(/^[-*]\s*/, '')}`);

const items = (list: string[], empty = 'none') => (list.length ? list.map((l) => `- ${l}`).join('\n') : `- ${empty}`);
const doc = `# Handoff ${today()}

Main checkout: \`${root}\` on \`${branch}\` (base \`${base}\`).
Resume: \`wf status\`, then pick up the in-flight cards below (\`wf start ID\` reuses their worktree).

## In flight

${items(inFlight.map((t) => `${t.id} ${t.status} on ${t.branch ?? '?'} since ${t.started ?? '?'}: ${t.title}`))}

## Waiting on owner

${items(owner.map((t) => `${t.id}: ${t.blocked || 'review and decide'} (${t.title})`))}

## Verifying

${items(verifying.map((t) => `${t.id} landed ${t.landed ?? '?'}: ${t.title}`))}

## Unpushed commits on ${base}

${upstream.ok ? items(unpushed.slice(0, 20)) : `- no upstream for ${base}`}

## Live worktrees

${items(worktrees)}

## Runner

${items(runner, 'not running (no .workflow/runner)')}

## Last outcomes

${items(outcomes)}
`;
mkdirSync(`${root}.workflow`, { recursive: true });
const path = `${root}.workflow/HANDOFF.md`;
writeFileSync(path, doc);
console.log(`handoff: ${path}`);
console.log(`branch ${branch}; ${upstream.ok ? `${unpushed.length} unpushed on ${base}` : `no upstream for ${base}`}`);
console.log(`in flight ${inFlight.length}: ${inFlight.map((t) => t.id).slice(0, 8).join(' ') || '-'}`);
console.log(`owner ${owner.length}, verifying ${verifying.length}: ${verifying.map((t) => t.id).slice(0, 8).join(' ') || '-'}`);
console.log(`worktrees ${worktrees.length}, runner ${runner.length ? 'state present' : 'idle'}`);
