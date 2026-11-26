#!/usr/bin/env bun
// wf-help: land a card: outcome check, owner hold, cards-commit, land per finish.mode, tracker hook, verifying, cleanup
import {
    SCRIPTS, appendToSection, baseBranch, cardsCommit, changedFiles, classifyRisk, config, fail, findCard, gatesGreen, git, outcomeProse,
    parseArgs, readCards, root, section, tail, taskBranch, teardown, today, update, withLock, worktreeOf,
} from '../lib.ts';

const HELP = `Usage: wf finish ID [--force] [--mode pr|merge|none] [--no-cleanup]

In order:
 1. refuse unless every acceptance item is ticked and ## Outcome has prose (--force skips this);
 2. high risk with review.ownerHoldHigh (default true) and no owner-approved field on the card:
    park in owner-review and stop (approve with wf move ID owner-review --approve, then re-run);
 3. wf cards-commit;
 4. land per finish.mode:
    pr     needs "push": true. Push the task branch, then open a PR unless one is open (a merged
           PR for an older head is earlier work: a new PR is opened). finish.autoMerge merges it
           when risk is not high and wf gates --release --json, run in the task worktree, is
           green for the pushed head. A PR still open parks the card in owner-review and removes
           the worktree when it is clean and pushed (the branch stays); run wf finish ID again
           after the merge.
    merge  wf merge into the base branch, only when the main checkout is already on it. Never pushes.
    none   leave the branch.
 5. tracker.onMerge with WF_ISSUE per #link;  6. move to verifying;
 7. cleanup (finish.cleanup): worktree, local branch and resources; pr mode also deletes the
    remote branch unless it is gone already.
A landing failure leaves the card where it was, with a note. Never moves the main checkout's HEAD.`;

const { flags, args } = parseArgs(process.argv.slice(2), { force: 'bool', mode: 'string', 'no-cleanup': 'bool' }, HELP);
const id = args[0] ?? fail(HELP, 2);
const mode = String(flags.mode ?? config.finish?.mode ?? 'pr');
if (!['pr', 'merge', 'none'].includes(mode)) fail('--mode must be pr, merge or none', 2);
if (mode === 'pr' && config.push !== true) fail('push is false: set "push": true to open PRs, or use finish.mode merge|none', 2);
const card = findCard(readCards(), id);
if (['verifying', 'done'].includes(card.status)) fail(`${card.id} is already ${card.status}`);
const branch = taskBranch(card);
const base = baseBranch();
const cleanup = config.finish?.cleanup !== false && !flags['no-cleanup'];
const say = (s: string) => console.log(s);
const run = (cmd: string[], cwd = root, env: Record<string, string> = {}) => {
    const r = Bun.spawnSync(cmd, { cwd, stdout: 'pipe', stderr: 'pipe', env: { ...process.env, ...env } });
    return { ok: r.success, out: r.stdout.toString().trim(), err: r.stderr.toString().trim() };
};
const why = (r: { out: string; err: string }) => tail(`${r.out}\n${r.err}`) || '(no output)';
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
const landFail = (msg: string): never => {
    setCard({}, `finish failed: ${msg.split('\n')[0]}`);
    cardsCommit(`docs(tasks): ${card.id} finish failed`);
    fail(`land: ${msg}\n${card.id} stays ${card.status}`);
};

// 1. Outcome check: everything missing in one message.
if (!flags.force) {
    const { done, total } = card.acceptance;
    const missing: string[] = [];
    if (!total) missing.push('no acceptance criteria on the card: add - [ ] items or pass --force');
    else if (done < total) missing.push(`${done}/${total} acceptance items ticked (wf outcome ${card.id} --tick 1,2)`);
    if (!outcomeProse(card.body)) missing.push(`## Outcome is missing or holds only the skeleton (wf outcome ${card.id}, then write the prose)`);
    if (missing.length) fail(`${card.id} is not ready to finish (or pass --force):\n${missing.map((m) => `  - ${m}`).join('\n')}`);
}
const hasBranch = git(['rev-parse', '--verify', '--quiet', `${branch}^{commit}`]).ok;
if (!hasBranch && mode !== 'none') fail(`${card.id}: branch ${branch} not found`);
const dir = worktreeOf(branch);

// 2. Risk first: it decides the owner hold, and auto-merge never runs gates for high risk.
const risk = hasBranch ? classifyRisk(changedFiles(base, branch, dir)) : { level: 'light' as const, file: '(no branch)' };
if (risk.level === 'high' && config.review?.ownerHoldHigh !== false && !card.ownerApproved) {
    setCard({ status: 'owner-review', blocked: `owner: high risk (${risk.file}); approve with wf move ${card.id} owner-review --approve, then wf finish ${card.id}` });
    commitCards(`docs(tasks): ${card.id} held for owner review (high risk)`);
    say(`${card.id} -> owner-review: high risk (${risk.file}) needs the owner's approval before it lands`);
    process.exit(0);
}

// 3. Commit the card changes so far (nothing new on a retry: no commit).
commitCards(`docs(tasks): ${card.id} outcome`);

// 4. Land.
let prMerged = false;
if (mode === 'none') {
    say(`land: none (${branch} left as is)`);
} else if (mode === 'merge') {
    const current = git(['branch', '--show-current']).out;
    if (current !== base) landFail(`the main checkout is on ${current || 'a detached HEAD'}, not ${base}; wf finish never switches it (use finish.mode pr)`);
    const r = run(['bash', `${SCRIPTS}wt-merge.sh`, branch, '--into', base, '-m', `merge: ${card.id} ${card.title}`]);
    if (!r.ok) landFail(`merge failed\n${why(r)}`);
    say(`land: ${r.out.split('\n').pop()}`);
} else {
    landPr();
    prMerged = true;
}

// 5. Tracker hook, once per linked issue.
const hook = config.tracker?.onMerge;
if (hook) {
    for (const issue of card.links.filter((l) => /^#?\d+$/.test(l)).map((l) => l.replace('#', ''))) {
        const h = run(['sh', '-c', hook], root, { WF_ISSUE: issue, WF_CARD: card.id });
        say(`tracker: #${issue} ${h.ok ? 'ok' : `failed: ${why(h)}`}`);
    }
}

// 6. Verifying: landed, not yet proven where it runs.
setCard({ status: 'verifying', landed: today(), blocked: '' });
say(`${card.id} -> verifying (wf move ${card.id} done --verified "how" once checked)`);
commitCards(`docs(tasks): ${card.id} verifying`);

// 7. Cleanup. Mode none never merged the branch, so it keeps it.
if (mode === 'none') say('cleaned: nothing (mode none keeps the branch)');
else if (cleanup) {
    const r = dir ? teardown(dir, branch) : { cleaned: [] as string[], error: undefined };
    const cleaned = r.cleaned;
    // A squash-merged branch is never an ancestor of the base: in pr mode the merged PR for this head
    // proves it landed (-D); merge mode deletes it only when git agrees it is merged (-d).
    if (!worktreeOf(branch) && git(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`]).ok && git(['branch', prMerged ? '-D' : '-d', branch]).ok) cleaned.push('branch');
    if (prMerged && run(['git', 'ls-remote', '--exit-code', '--heads', 'origin', branch]).ok && run(['git', 'push', '--quiet', 'origin', '--delete', branch]).ok) cleaned.push('remote branch');
    if (r.error) console.error(`cleanup: ${r.error}`);
    say(`cleaned: ${cleaned.join(', ') || 'nothing'}`);
}

// pr mode: returns once the PR for the local head is merged; parks the card and exits while it is open.
function landPr(): void {
    const head = git(['rev-parse', `${branch}^{commit}`]).out;
    type PR = { number?: number; state: string; url: string; headRefOid?: string };
    const view = (): PR | undefined => {
        const v = run(['gh', 'pr', 'view', branch, '--json', 'number,state,url,headRefOid'], dir ?? root);
        if (!v.ok) return undefined;
        try {
            return JSON.parse(v.out) as PR;
        } catch {
            return undefined;
        }
    };
    // A PR's state is about THIS work only when its head is the local head: a
    // merged PR for an older head (a reopened card) is history and proves nothing.
    const current = (p: PR | undefined) => !!p && p.headRefOid === head;
    let pr = view();
    if (!(pr?.state === 'MERGED' && current(pr))) {
        const push = run(['git', 'push', '--quiet', '-u', 'origin', `refs/heads/${branch}:refs/heads/${branch}`]);
        if (!push.ok) landFail(`push failed\n${why(push)}`);
        say(`land: pushed ${branch} (${head.slice(0, 7)})`);
        pr = view();
        if (pr?.state === 'OPEN') say(`land: updated ${pr.url}`);
        else {
            const refs = card.links.filter((l) => /^#\d+$/.test(l)).map((l) => `Refs ${l}`);
            const body = [section(card.body, 'Outcome') ?? '', ...refs].join('\n\n');
            const created = run(['gh', 'pr', 'create', '--base', base, '--head', branch, '--title', card.title, '--body', body], dir ?? root);
            if (!created.ok) landFail(`gh pr create failed\n${why(created)}`);
            pr = view() ?? { state: 'OPEN', url: created.out.split('\n').pop() ?? '', headRefOid: head };
            say(`land: opened ${pr.url}`);
        }
    }
    if (pr.state === 'OPEN' && config.finish?.autoMerge) pr = autoMerge(pr, head, current, view);
    if (pr.state === 'MERGED') {
        say(`land: merged ${pr.url}`);
        return;
    }
    setCard({ status: 'owner-review', blocked: `owner: review and merge ${pr.url}, then wf finish ${card.id}` });
    commitCards(`docs(tasks): ${card.id} awaiting merge`);
    say(`${pr.number ? `PR #${pr.number}` : `PR ${pr.url}`} open: card parked in owner-review; after it merges run \`wf finish ${card.id}\` again to move it to verifying and tear down`);
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

// Merges only what was gated: risk not high (decided before any gate runs), the
// release gates green in the task worktree at the local head, and the PR head
// still that commit (gh --match-head-commit makes the last check atomic).
function autoMerge<P extends { state: string; url: string; headRefOid?: string }>(pr: P, head: string, current: (p: P) => boolean, view: () => P | undefined): P {
    if (risk.level === 'high') return note(pr, `high risk (${risk.file})`);
    if (!dir) return note(pr, `the worktree of ${branch} is gone (release gates run only there; wf start ${card.id} restores it)`);
    if (git(['rev-parse', 'HEAD'], dir).out !== head) return note(pr, `the worktree is not at ${branch}'s head`);
    const gates = run([`${SCRIPTS}../bin/wf`, 'gates', '--release', '--json'], dir);
    if (!gatesGreen(gateJson(gates.out))) return note(pr, `wf gates --release is not green\n${why(gates)}`);
    if (!current(pr)) return note(pr, `the PR head is ${pr.headRefOid?.slice(0, 7) ?? '?'}, not the gated ${head.slice(0, 7)}`);
    const m = run(['gh', 'pr', 'merge', pr.url, config.finish?.squash === false ? '--merge' : '--squash', '--match-head-commit', head], dir);
    if (!m.ok) landFail(`gh pr merge failed\n${why(m)}`);
    return view() ?? { ...pr, state: 'MERGED' };
}

function note<P>(pr: P, reason: string): P {
    say(`land: no auto-merge, ${reason}`);
    return pr;
}

// The gate report: one JSON line with `results`, `gates` or `ok` (the last such
// line wins), else the whole output when it is one JSON document (older gates.sh).
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
