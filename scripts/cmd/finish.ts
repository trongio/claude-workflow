#!/usr/bin/env bun
// wf-help: land a card: outcome check, clean tree, owner hold, release gates, cards-commit, land per finish.mode, tracker hook, verifying, cleanup
import {
    SCRIPTS, appendToSection, approvedSha, baseBranch, cardsCommit, changedFiles, classifyRisk, config, fail, findCard, git, outcomeProse,
    parkFields, parseArgs, plural, readCards, readJson, refreshOutcome, releaseVerdict, root, section, tail, taskBranch, teardown, today, update,
    withLock, worktreeOf, worktreePath,
} from '../lib.ts';
import { realpathSync } from 'node:fs';

const HELP = `Usage: wf finish ID [--force] [--mode pr|merge|none] [--no-cleanup]

In order, refusing before anything lands:
 1. every acceptance item ticked and ## Outcome has prose;
 2. the task worktree has no uncommitted or untracked files (up to 10 are listed);
 3. high risk with review.ownerHoldHigh (default true): held in owner-review unless the
    owner approved the current branch tip (wf approve ID; a later commit needs a new approval);
 4. wf gates --release green for the branch tip: the recorded result is reused when it is for
    that commit, else it runs in the task worktree. A gate skipped as "not in release" is fine;
    any other skip, pending, timeout or failure is not green.
--force skips 1, commits the dirty files of 2 as a wip commit (only in the task worktree
.workflow/worktrees/ID; anywhere else dirty files are refused even with --force), and lands past
4 with a note on the card. It never skips 3, and WF_HEADLESS=1 refuses it.
The Outcome's wf:auto block is refreshed (as wf outcome does) before it is committed or used
as the PR body.
Then wf cards-commit, and land per finish.mode:
    pr     needs "push": true. Push the task branch, open a PR unless one is open for it.
           finish.autoMerge merges it (squash unless finish.squash is false) when risk is not
           high and the gates were green, pinned to the gated head. A PR still open parks
           the card in owner-review (the worktree goes when clean and pushed; the branch
           stays); run wf finish ID again after the merge. A merged PR counts only when its
           head is the branch tip.
    merge  wf merge of exactly the gated tip (--sha) into the base branch, only when the
           main checkout is already on it; squashed into one commit "<title> (<ID>)" unless
           finish.squash is false. A conflict leaves the base untouched and the card where
           it was. Never pushes.
    none   leave the branch.
Then tracker.onMerge with WF_ISSUE per #link, move to verifying, and cleanup (finish.cleanup):
worktree, resources, and the branch only while its tip is the landed commit (pr mode deletes
the remote branch under the same rule). A landing failure leaves the card where it was, with
a note. Never moves the main checkout's HEAD. git push and gh time out after 120 s,
tracker.onMerge after 300 s.

Exit codes (what to do next):
  0  landed (verifying), or the PR was opened or updated and the card waits in owner-review
     for the merge: nothing to do until the owner merges, then wf finish ID again.
  1  a landing step failed (push, gh, merge error, timeout): read the message, fix, rerun.
  2  refused before anything landed (usage, unticked card, dirty tree, red gates, the
     branch moved past the gated commit, gh missing): fix what it names, rerun.
  3  merge conflict: rebase the task branch onto the base in its worktree, resolve,
     commit, then wf finish ID.
  4  held for the owner (high risk): stop; the owner runs wf approve ID.
  5  nothing to land (no changes against the base): wf move ID done --verified or backlog.

Example: wf finish T-12 --mode merge`;

const { flags, args } = parseArgs(process.argv.slice(2), { force: 'bool', mode: 'string', 'no-cleanup': 'bool' }, HELP);
const id = args[0] ?? fail(HELP, 2);
const force = !!flags.force;
if (force && process.env.WF_HEADLESS === '1') fail('wf finish --force is refused headless (WF_HEADLESS=1): park the card for the owner instead', 2);
const mode = String(flags.mode ?? config.finish?.mode ?? 'pr');
if (!['pr', 'merge', 'none'].includes(mode)) fail('--mode must be pr, merge or none', 2);
if (mode === 'pr' && config.push !== true) fail('push is false: set "push": true to open PRs, or use finish.mode merge|none', 2);
if (mode === 'pr' && !Bun.which('gh')) fail('gh not found: install GitHub CLI or use finish.mode merge|none', 2);
const card = findCard(readCards(), id);
if (['verifying', 'done'].includes(card.status)) fail(`${card.id} is already ${card.status}`, 2);
const branch = taskBranch(card);
const base = baseBranch();
const cleanup = config.finish?.cleanup !== false && !flags['no-cleanup'];
const squash = config.finish?.squash !== false;
const say = (s: string) => console.log(s);
// `seconds` bounds a network or hook call; on expiry the result says so instead of hanging finish.
const run = (cmd: string[], cwd = root, env: Record<string, string> = {}, seconds?: number) => {
    const r = Bun.spawnSync(cmd, { cwd, stdout: 'pipe', stderr: 'pipe', env: { ...process.env, ...env }, timeout: seconds ? seconds * 1000 : undefined });
    const timedOut = !!r.exitedDueToTimeout;
    const err = r.stderr.toString().trim();
    return { ok: r.success, code: r.exitCode, out: r.stdout.toString().trim(), err: timedOut ? `${err}
timed out after ${seconds} s: ${cmd.slice(0, 3).join(' ')}`.trim() : err };
};
const NET = 120;
const why = (r: { out: string; err: string }) => tail(`${r.out}\n${r.err}`) || '(no output)';
const short = (sha: string) => sha.slice(0, 7);
const tipOf = () => git(['rev-parse', '--verify', '--quiet', `${branch}^{commit}`]).out;
const commitCards = (msg: string) => {
    const c = cardsCommit(msg);
    if (!c.ok) fail(`cards-commit failed:\n${c.out}`);
    say(c.out);
};
const setCard = (fields: Record<string, unknown>, note?: string) =>
    withLock(() => {
        const t = findCard(readCards(), card.id);
        // The same note twice in a row (a retried failure) is written once.
        const fresh = note && !(section(t.body, 'Notes') ?? '').trimEnd().endsWith(`${today()} ${note}`);
        update(t, fields, fresh ? (text) => appendToSection(text, 'Notes', `- ${today()} ${note}`) : undefined);
    });
// A landing failure leaves the card in its status, with a note saying why.
const landFail = (msg: string, hint = '', code = 1): never => {
    setCard({}, `finish failed: ${msg.split('\n')[0]}`);
    cardsCommit(`docs(tasks): ${card.id} finish failed`);
    fail(`land: ${msg}\n${hint ? `${hint}\n` : ''}${card.id} stays ${card.status}`, code);
};

// 1. Outcome check: everything missing in one message.
if (!force) {
    const { done, total } = card.acceptance;
    const missing: string[] = [];
    if (!total) missing.push('no acceptance criteria on the card: add - [ ] items or pass --force');
    else if (done < total) missing.push(`${done}/${total} acceptance items ticked (wf outcome ${card.id} --tick 1,2)`);
    if (!outcomeProse(card.body)) missing.push(`## Outcome is missing or holds only the skeleton (wf outcome ${card.id}, then write the prose)`);
    if (missing.length) fail(`${card.id} is not ready to finish (or pass --force):\n${missing.map((m) => `  - ${m}`).join('\n')}`, 2);
}
const hasBranch = !!tipOf();
if (!hasBranch && mode !== 'none') fail(`${card.id}: branch ${branch} not found`, 2);
const dir = worktreeOf(branch);
// --force commits work only in the card's own worktree, never in the main checkout or a foreign one.
const real = (p: string) => {
    try {
        return realpathSync(p);
    } catch {
        return p;
    }
};
const taskDir = !!dir && real(dir) === real(worktreePath(card.id));

// 2. Uncommitted work never lands half-way, and teardown never has to rescue it.
if (dir) {
    // .workflow/ is wf's own state (gate logs, previews), never work; same rule as wf_save_work.
    const own = git(['check-ignore', '-q', '.workflow'], dir).ok ? [] : ['--', '.', ':(exclude).workflow'];
    // git() trims the first line's leading status space, so the status is matched, not sliced.
    const dirty = git(['status', '--porcelain', '--untracked-files=all', ...own], dir).out.split('\n').filter(Boolean).map((l) => l.replace(/^[ MTADRCU?!]{1,2} /, ''));
    if (dirty.length && !(force && taskDir)) {
        const more = dirty.length > 10 ? `\n  +${dirty.length - 10} more` : '';
        const hint = taskDir ? ' (--force commits it as wip)' : `; ${dir} is not the task worktree, so --force never commits there`;
        fail(`${card.id}: ${dir} has uncommitted work:\n${dirty.slice(0, 10).map((f) => `  ${f}`).join('\n')}${more}\ncommit or remove it, then wf finish ${card.id} again${hint}`, 2);
    }
    if (dirty.length) {
        const ok = git(['add', '-A', ...own], dir).ok && git(['commit', '--quiet', '--no-verify', '-m', `wip: ${card.id} uncommitted work at wf finish --force`], dir).ok;
        if (!ok) fail(`${card.id}: could not commit the uncommitted work in ${dir}`);
        say(`--force: committed ${plural(dirty.length, 'uncommitted path')} as a wip commit on ${branch}`);
    }
}
const tip = tipOf();

// 3. Risk decides the owner hold; an approval binds to one commit.
const risk = hasBranch ? classifyRisk(changedFiles(base, branch, dir)) : { level: 'light' as const, file: '(no branch)', pattern: '' };
const approved = approvedSha(card);
if (risk.level === 'high' && config.review?.ownerHoldHigh !== false && approved !== tip) {
    const was = approved ? ` (approved ${short(approved)}, the branch is now at ${short(tip)})` : '';
    setCard(parkFields(card, `owner: high risk (${risk.file})${was}; approve with wf approve ${card.id}, then wf finish ${card.id}`));
    commitCards(`docs(tasks): ${card.id} held for owner review (high risk)`);
    say(`${card.id} -> owner-review: high risk (${risk.file}) needs the owner's approval of ${short(tip)}${was}; the owner runs wf approve ${card.id}`);
    process.exit(4);
}

// 4. Release gates green for this exact commit.
const gates = hasBranch ? releaseProof() : { green: true, why: '' };
if (!gates.green) {
    const first = gates.why.split('\n')[0];
    if (!force) fail(`${card.id}: release gates are not green for ${short(tip)}: ${gates.why}\nfix and commit in ${dir ?? 'the task worktree'}, then wf finish ${card.id} again (--force lands anyway, noted on the card)`, 2);
    setCard({}, `finish --force: landed WITHOUT green release gates at ${short(tip)} (${first})`);
    console.error(`WARNING: --force lands ${short(tip)} without green release gates (${first}); noted on the card`);
}

// The Outcome facts as of the landing commit and gate run (wf outcome's block). Without the
// worktree (a PR that waited) the facts cannot improve, so the recorded block stays.
if (dir) withLock(() => refreshOutcome(findCard(readCards(), card.id)));
// Commit the card changes so far (nothing new on a retry: no commit).
commitCards(`docs(tasks): ${card.id} outcome`);

// 5. Land. `landed` is the commit that reached the base: the branch goes only while it is still its tip.
let prMerged = false;
let landed = tip;
if (mode === 'none') {
    say(`land: none (${branch} left as is)`);
} else if (mode === 'merge') {
    const current = git(['branch', '--show-current']).out;
    if (current !== base) landFail(`the main checkout is on ${current || 'a detached HEAD'}, not ${base}; wf finish never switches it (use finish.mode pr)`);
    const msg = squash ? `${card.title} (${card.id})` : `merge: ${card.id} ${card.title}`;
    // --sha pins the merge to the gated commit; WF_FROM_FINISH tells wt-merge the gates were checked here.
    const r = run(['bash', `${SCRIPTS}wt-merge.sh`, branch, '--sha', tip, '--into', base, ...(squash ? ['--squash'] : []), '-m', msg], root, { WF_FROM_FINISH: '1' });
    if (r.code === 3) landFail(`merge conflict in: ${conflicts(r.out)}`, `next: rebase the task branch onto ${base} in its worktree, resolve, commit, then wf finish ${card.id}`, 3);
    if (r.code === 5) fail(`nothing to land: the branch has no changes against ${base}; wf move ${card.id} done --verified or backlog`, 5);
    if (r.code === 2) fail(`merge refused: ${why(r)}\n${card.id} stays ${card.status}`, 2);
    if (!r.ok) landFail(`merge failed\n${why(r)}`);
    say(`land: ${r.out.split('\n').pop()}`);
} else {
    landed = landPr();
    prMerged = true;
}

// 6. Tracker hook, once per linked issue.
const hook = config.tracker?.onMerge;
if (hook) {
    for (const issue of card.links.filter((l) => /^#?\d+$/.test(l)).map((l) => l.replace('#', ''))) {
        const h = run(['sh', '-c', hook], root, { WF_ISSUE: issue, WF_CARD: card.id }, 300);
        say(`tracker: #${issue} ${h.ok ? 'ok' : `failed: ${why(h)}`}`);
    }
}

// 7. Verifying: landed, not yet proven where it runs.
setCard({ status: 'verifying', landed: today(), blocked: '' });
say(`${card.id} -> verifying (wf move ${card.id} done --verified "how" once checked)`);
commitCards(`docs(tasks): ${card.id} verifying`);

// 8. Cleanup. Mode none never merged the branch, so it keeps it.
if (mode === 'none') say('cleaned: nothing (mode none keeps the branch)');
else if (cleanup) {
    const wt = worktreeOf(branch);
    const r = wt ? teardown(wt, branch, { keepBranch: true }) : { cleaned: [] as string[], error: undefined };
    const cleaned = r.cleaned;
    const now = tipOf();
    // Teardown may save a wip commit: work past the landed commit is never deleted.
    const kept = !!now && now !== landed;
    if (kept) say(`kept branch ${branch}: its tip ${short(now)} is not the landed ${short(landed)}`);
    else if (now && !worktreeOf(branch) && git(['branch', '-D', branch]).ok) cleaned.push('branch');
    if (prMerged && !kept) {
        const remote = run(['git', 'ls-remote', '--heads', 'origin', branch], root, {}, NET).out.split(/\s/)[0];
        if (remote === landed && run(['git', 'push', '--quiet', 'origin', '--delete', branch], root, {}, NET).ok) cleaned.push('remote branch');
        else if (remote && remote !== landed) say(`kept remote branch ${branch}: origin has ${short(remote)}, not the landed ${short(landed)}`);
    }
    if (r.error) console.error(`cleanup: ${r.error}`);
    say(`cleaned: ${cleaned.join(', ') || 'nothing'}`);
}
if (prMerged) pullHint();

// The release verdict for the branch tip: the proof recorded on the card, else the worktree's
// last gate run, else a fresh wf gates --release there. A green verdict is recorded on the card,
// so the second finish of a PR (its worktree removed while it waited) still has it.
function releaseProof(): { green: boolean; why: string } {
    if (card.releaseGreen === tip) return { green: true, why: '' };
    if (!dir) return { green: false, why: `the worktree of ${branch} is gone and no green release run is recorded for ${short(tip)} (wf start ${card.id} restores it)` };
    const last = `${dir}/.workflow/gates-last.json`;
    let v = releaseVerdict(readJson(last), tip);
    if (!v.green && !force) {
        const r = run([`${SCRIPTS}../bin/wf`, 'gates', '--release', '--json'], dir);
        v = releaseVerdict(gateJson(r.out) ?? readJson(last), tip);
        if (!v.green) v = { green: false, why: `${v.why}\n${why(r)}` };
    }
    if (!v.green) return v;
    setCard({ 'release-green': tip });
    say(`gates: release green at ${short(tip)}`);
    return v;
}

// wt-merge prints one "--- <file>" line per conflicting file, each followed by its hunks.
function conflicts(out: string): string {
    const files = out.split('\n').filter((l) => l.startsWith('--- ')).map((l) => l.slice(4).trim());
    return [...new Set(files)].slice(0, 10).join(', ') || '(files not listed)';
}

// After a forge merge the local base is behind origin: say how to catch up, never do it.
function pullHint(): void {
    const remote = run(['git', 'ls-remote', '--heads', 'origin', base], root, {}, NET).out.split(/\s/)[0];
    if (!remote || remote === git(['rev-parse', '--verify', '--quiet', base]).out || git(['merge-base', '--is-ancestor', remote, base]).ok) return;
    say(`pull ${base} to pick up the merge: git -C ${root.replace(/\/$/, '')} pull --rebase`);
}

// pr mode: returns the merged head once the PR for the branch tip is merged; parks the card and exits while it is open.
function landPr(): string {
    const head = tip;
    type PR = { number?: number; state: string; url: string; headRefOid?: string };
    const view = (): PR | undefined => {
        const v = run(['gh', 'pr', 'view', branch, '--json', 'number,state,url,headRefOid'], dir ?? root, {}, NET);
        if (v.err.includes('timed out after')) landFail(`gh pr view failed\n${why(v)}`);
        if (!v.ok) return undefined;
        try {
            return JSON.parse(v.out) as PR;
        } catch {
            return undefined;
        }
    };
    // A PR's state is about THIS work only when its head is the branch tip: a
    // merged PR for an older head (a reopened card) is history and proves nothing.
    const current = (p: PR | undefined) => !!p && p.headRefOid === head;
    const merged = (p: PR | undefined): p is PR => p?.state === 'MERGED' && current(p);
    let pr = view();
    if (!merged(pr)) {
        const push = run(['git', 'push', '--quiet', '-u', 'origin', `refs/heads/${branch}:refs/heads/${branch}`], root, {}, NET);
        if (!push.ok) landFail(`push failed\n${why(push)}`);
        say(`land: pushed ${branch} (${short(head)})`);
        pr = view();
        if (pr?.state === 'OPEN') say(`land: updated ${pr.url}`);
        else {
            const refs = card.links.filter((l) => /^#\d+$/.test(l)).map((l) => `Refs ${l}`);
            // The card as committed above, with the refreshed Outcome block.
            const body = [section(findCard(readCards(), card.id).body, 'Outcome') ?? '', ...refs].join('\n\n');
            const created = run(['gh', 'pr', 'create', '--base', base, '--head', branch, '--title', card.title, '--body', body], dir ?? root, {}, NET);
            if (!created.ok) landFail(`gh pr create failed\n${why(created)}`);
            pr = view() ?? { state: 'OPEN', url: created.out.split('\n').pop() ?? '', headRefOid: head };
            say(`land: opened ${pr.url}`);
        }
    }
    if (pr?.state === 'OPEN' && config.finish?.autoMerge) pr = autoMerge(pr, head, current, view);
    if (merged(pr)) {
        say(`land: merged ${pr.url}`);
        return head;
    }
    const url = pr?.url ?? '(no PR found)';
    setCard(parkFields(card, `owner: review and merge ${url}, then wf finish ${card.id}`));
    commitCards(`docs(tasks): ${card.id} awaiting merge`);
    const state = pr?.state === 'MERGED' ? `merged at ${short(pr.headRefOid ?? '?')}, not the branch tip ${short(head)}` : 'open';
    say(`${pr?.number ? `PR #${pr.number}` : `PR ${url}`} ${state}: card parked in owner-review; after it merges run \`wf finish ${card.id}\` again to move it to verifying and tear down`);
    // Nothing sits around while the PR waits: a clean, pushed worktree goes now; the branch stays.
    if (dir && cleanup) {
        const clean = !git(['status', '--porcelain'], dir).out;
        const pushed = git(['rev-parse', '--verify', '--quiet', `refs/remotes/origin/${branch}`]).out === head;
        if (!clean || !pushed) say(`kept worktree ${dir} (${clean ? 'not pushed' : 'uncommitted changes'})`);
        else {
            const r = teardown(dir, branch, { keepBranch: true });
            if (r.error) console.error(`cleanup: ${r.error}`);
            else say(`cleaned: worktree (branch ${branch} kept for the PR)`);
        }
    }
    process.exit(0);
}

// Merges only what was gated: risk not high, the release gates green at the branch tip (checked
// above; a --force landing never auto-merges), and the PR head still that commit (gh
// --match-head-commit makes the last check atomic).
function autoMerge<P extends { state: string; url: string; headRefOid?: string }>(pr: P, head: string, current: (p: P) => boolean, view: () => P | undefined): P {
    if (risk.level === 'high') return note(pr, `high risk (${risk.file})`);
    if (!gates.green) return note(pr, 'release gates not green (--force)');
    if (!current(pr)) return note(pr, `the PR head is ${short(pr.headRefOid ?? '?')}, not the gated ${short(head)}`);
    const m = run(['gh', 'pr', 'merge', pr.url, squash ? '--squash' : '--merge', '--match-head-commit', head], dir ?? root, {}, NET);
    if (!m.ok) landFail(`gh pr merge failed\n${why(m)}`);
    return view() ?? { ...pr, state: 'MERGED' };
}

function note<P>(pr: P, reason: string): P {
    say(`land: no auto-merge, ${reason}`);
    return pr;
}

// The gate report: the last JSON line with `results`, `gates` or `ok`, else the whole
// output when it is one JSON document.
function gateJson(out: string): unknown {
    const report = (s: string) => {
        try {
            const j = JSON.parse(s) as Record<string, unknown>;
            return j && typeof j === 'object' && (Array.isArray(j) || 'results' in j || 'gates' in j || 'ok' in j) ? j : undefined;
        } catch {
            return undefined;
        }
    };
    for (const l of out.split('\n').reverse()) {
        const s = l.trim();
        const j = (s.startsWith('{') || s.startsWith('[')) && report(s);
        if (j) return j;
    }
    return report(out.trim());
}
