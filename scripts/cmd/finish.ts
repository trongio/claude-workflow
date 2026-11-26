#!/usr/bin/env bun
// wf-help: land a card: outcome check, cards-commit, land per finish.mode, tracker hook, verifying, cleanup
import {
    SCRIPTS, baseBranch, changedFiles, classifyRisk, config, fail, findCard, gatesGreen, git, outcomeProse, parseArgs, readCards,
    root, section, taskBranch, teardown, today, update, withLock, worktreeOf,
} from '../lib.ts';

const HELP = `Usage: wf finish ID [--force] [--mode pr|merge|none] [--no-cleanup]

In order: refuse unless every acceptance item is ticked and ## Outcome has prose
(--force skips this) -> wf cards-commit -> land per finish.mode (pr: push the task
branch and open a PR titled after the card with the Outcome as body, auto-merged
only when finish.autoMerge is set, risk is not high and wf gates --release --json
is green; merge: wf merge into the base branch, only when the main checkout is
already on it; none: leave the branch) -> tracker.onMerge with WF_ISSUE per #link
-> move to verifying -> remove the worktree, branch and resources (finish.cleanup).
An open, unmerged PR parks the card in owner-review instead. Never moves the main
checkout's HEAD. Re-run it after the PR merges to finish the remaining steps.`;

const { flags, args } = parseArgs(process.argv.slice(2), { force: 'bool', mode: 'string', 'no-cleanup': 'bool' }, HELP);
const id = args[0] ?? fail(HELP, 2);
const mode = String(flags.mode ?? config.finish?.mode ?? 'pr');
if (!['pr', 'merge', 'none'].includes(mode)) fail(`--mode must be pr, merge or none`, 2);
const card = findCard(readCards(), id);
if (['verifying', 'done'].includes(card.status)) fail(`${card.id} is already ${card.status}`);
const branch = taskBranch(card);
const base = baseBranch();
const say = (s: string) => console.log(s);

// 1. Outcome check.
if (!flags.force) {
    const { done, total } = card.acceptance;
    if (!total || done < total) fail(`${card.id}: ${done}/${total} acceptance items ticked (wf outcome ${card.id} --tick 1,2, or --force)`);
    if (!outcomeProse(card.body)) fail(`${card.id}: ## Outcome is missing or holds only the skeleton (wf outcome ${card.id}, then write the prose; or --force)`);
}
if (!git(['rev-parse', '--verify', '--quiet', `${branch}^{commit}`]).ok && mode !== 'none') fail(`${card.id}: branch ${branch} not found`);

// 2. Commit the card changes so far.
const cardsCommit = (msg: string) => {
    const r = Bun.spawnSync(['bash', `${SCRIPTS}cmd/cards-commit.sh`, '-m', msg], { cwd: root, stdout: 'pipe', stderr: 'pipe' });
    if (!r.success) fail(`cards-commit failed: ${r.stderr.toString().trim()}`);
    return r.stdout.toString().trim();
};
say(cardsCommit(`docs(tasks): ${card.id} outcome`));

// 3. Land.
const dir = worktreeOf(branch);
const run = (cmd: string[], cwd = dir ?? root) => {
    const r = Bun.spawnSync(cmd, { cwd, stdout: 'pipe', stderr: 'pipe', env: process.env });
    return { ok: r.success, out: r.stdout.toString().trim(), err: r.stderr.toString().trim() };
};
if (mode === 'none') {
    say(`land: none (${branch} left as is)`);
} else if (mode === 'merge') {
    const current = git(['branch', '--show-current']).out;
    if (current !== base) fail(`land: the main checkout is on ${current || 'a detached HEAD'}, not ${base}; wf finish never switches it (use finish.mode pr)`);
    const r = run(['bash', `${SCRIPTS}wt-merge.sh`, branch, '--into', base, '-m', `merge: ${card.id} ${card.title}`], root);
    if (!r.ok) fail(`land: merge failed\n${(r.out || r.err).split('\n').slice(0, 15).join('\n')}`);
    say(`land: ${r.out.split('\n').pop()}`);
} else {
    const view = () => {
        const v = run(['gh', 'pr', 'view', branch, '--json', 'state,url']);
        return v.ok ? (JSON.parse(v.out) as { state: string; url: string }) : undefined;
    };
    let pr = view();
    if (!pr || pr.state === 'CLOSED') {
        const push = run(['git', 'push', '--quiet', '-u', 'origin', branch]);
        if (!push.ok) fail(`land: push failed: ${push.err.split('\n').pop()}`);
        const refs = card.links.filter((l) => /^#\d+$/.test(l)).map((l) => `Refs ${l}`);
        const body = [section(card.body, 'Outcome') ?? '', ...refs].join('\n\n');
        const created = run(['gh', 'pr', 'create', '--base', base, '--head', branch, '--title', card.title, '--body', body]);
        if (!created.ok) fail(`land: gh pr create failed: ${created.err.split('\n').pop()}`);
        pr = { state: 'OPEN', url: created.out.split('\n').pop() ?? '' };
        say(`land: opened ${pr.url}`);
    }
    if (pr.state === 'OPEN' && config.finish?.autoMerge) {
        const risk = classifyRisk(changedFiles(base, branch, dir));
        const gates = run([`${SCRIPTS}../bin/wf`, 'gates', '--release', '--json']);
        let green = false;
        try {
            green = gatesGreen(JSON.parse(gates.out.split('\n').filter((l) => l.trim().startsWith('{') || l.trim().startsWith('[')).pop() ?? ''));
        } catch {}
        if (risk.level === 'high') say(`land: no auto-merge, high risk (${risk.file})`);
        else if (!green) say('land: no auto-merge, wf gates --release is not green');
        else {
            const m = run(['gh', 'pr', 'merge', pr.url, config.finish?.squash === false ? '--merge' : '--squash']);
            if (!m.ok) fail(`land: gh pr merge failed: ${m.err.split('\n').pop()}`);
            pr = view() ?? { ...pr, state: 'MERGED' };
        }
    }
    if (pr.state !== 'MERGED') {
        const blocked = `owner: review and merge ${pr.url}, then wf finish ${card.id}`;
        withLock(() => update(findCard(readCards(), card.id), { status: 'owner-review', blocked }));
        say(cardsCommit(`docs(tasks): ${card.id} awaiting merge`));
        say(`${card.id} -> owner-review (PR open: ${pr.url})`);
        process.exit(0);
    }
    say(`land: merged ${pr.url}`);
}

// 4. Tracker hook, once per linked issue.
const hook = config.tracker?.onMerge;
if (hook) {
    for (const issue of card.links.filter((l) => /^#?\d+$/.test(l)).map((l) => l.replace('#', ''))) {
        const r = Bun.spawnSync(['sh', '-c', hook], { cwd: root, env: { ...process.env, WF_ISSUE: issue, WF_CARD: card.id }, stdout: 'pipe', stderr: 'pipe' });
        say(`tracker: #${issue} ${r.success ? 'ok' : `failed: ${r.stderr.toString().trim().split('\n').pop()}`}`);
    }
}

// 5. Verifying: landed, not yet proven where it runs.
withLock(() => update(findCard(readCards(), card.id), { status: 'verifying', landed: today(), blocked: '' }));
say(`${card.id} -> verifying (wf move ${card.id} done --verified "how" once checked)`);
say(cardsCommit(`docs(tasks): ${card.id} verifying`));

// 6. Cleanup. Mode none never merged the branch, so it keeps it.
if (mode === 'none') say('cleaned: nothing (mode none keeps the branch)');
else if (config.finish?.cleanup !== false && !flags['no-cleanup']) {
    const r = teardown(dir, branch);
    if (r.error) console.error(`cleanup: ${r.error}`);
    say(`cleaned: ${r.cleaned.join(', ') || 'nothing'}`);
}
