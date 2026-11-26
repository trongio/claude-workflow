#!/usr/bin/env bun
// wf-help: start a card: branch wf/ID + worktree + wt-init + in-progress; prints the worktree path
import { existsSync } from 'node:fs';
import {
    ACTIVE, SCRIPTS, WIP, baseBranch, claimable, fail, findCard, git, parseArgs, readCards, root, section, today, update,
    withLock, worktreeOf, worktreePath,
} from '../lib.ts';

const HELP = `Usage: wf start ID [--json]

Claims the card under the WIP limit (as wf claim does), creates branch wf/ID from
the base branch and the worktree .workflow/worktrees/ID (both reused when they
exist), runs wt-init in it and records the branch on the card. Never touches the
main checkout's HEAD. Prints the worktree path and the card header.`;

const { flags, args } = parseArgs(process.argv.slice(2), { json: 'bool' }, HELP);
const id = args[0] ?? fail(HELP, 2);

// Claim (or confirm an existing claim) under the card lock.
const { card, prev } = withLock(() => {
    const cards = readCards();
    const t = findCard(cards, id);
    const branch = t.branch ?? `wf/${t.id}`;
    if (ACTIVE.includes(t.status)) {
        if (!t.branch) update(t, { branch });
        return { card: { ...t, branch }, prev: t.status };
    }
    const active = cards.filter((c) => ACTIVE.includes(c.status)).length;
    if (active >= WIP) fail(`WIP limit reached: ${active} active (limit ${WIP}). Finish or move one first.`);
    if (!claimable(cards, Infinity).some((c) => c.id === t.id)) fail(`${t.id} is not claimable (status ${t.status}; needs todo, unblocked, dependencies landed)`);
    update(t, { status: 'in-progress', started: t.started ?? today(), branch });
    return { card: { ...t, branch }, prev: t.status };
});

const branch = card.branch;
const claimed = !ACTIVE.includes(prev);
let dir = worktreeOf(branch);
const undo = (msg: string): never => {
    if (claimed) withLock(() => update(findCard(readCards(), card.id), { status: prev }));
    fail(`${msg}\n${card.id} moved back to ${prev}`);
};
if (!dir) {
    dir = worktreePath(card.id);
    if (existsSync(dir)) undo(`${dir} exists but is not a worktree of ${branch}; remove it or check it out there`);
    const hasBranch = git(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`]).ok;
    const base = baseBranch();
    const r = git(hasBranch ? ['worktree', 'add', '--quiet', dir, branch] : ['worktree', 'add', '--quiet', '-b', branch, dir, base]);
    if (!r.ok) undo(`git worktree add failed: ${r.err.split('\n').pop()}`);
}
const init = Bun.spawnSync(['bash', `${SCRIPTS}wt-init.sh`, dir], { cwd: dir, stdout: 'pipe', stderr: 'pipe' });
const initLine = (init.success ? init.stdout : init.stderr).toString().trim().split('\n').pop() ?? '';

const goal = (section(card.body, 'Goal') ?? '').split('\n').find((l) => l.trim()) ?? '(no goal written)';
if (flags.json) {
    console.log(JSON.stringify({ id: card.id, branch, worktree: dir, init: init.success, acceptance: card.acceptance }));
} else {
    console.log(`worktree: ${dir}`);
    console.log(`${card.id} ${claimed ? "in-progress" : `${card.status} (resumed)`} on ${branch}: ${card.title}`);
    console.log(`  size ${card.size}  area ${card.area || '-'}  acceptance ${card.acceptance.done}/${card.acceptance.total}`);
    console.log(`  goal: ${goal}`);
    console.log(`  card: ${root}${card.file}`);
    console.log(`  wt-init: ${initLine}`);
}
if (!init.success) process.exit(1);
