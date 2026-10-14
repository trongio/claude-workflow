// Live board: serves index.html, the parsed cards at /api/state, and a server-sent
// event whenever a card file or git ref changes. Zero dependencies.
import { existsSync, watch } from 'node:fs';
import { basename } from 'node:path';
import { config, milestoneLabel, readCards, root } from '../lib.ts';

function git(args: string[]): string {
    const r = Bun.spawnSync(['git', ...args], { cwd: root, stderr: 'ignore' });
    return r.success ? r.stdout.toString().trim() : '';
}

function state() {
    const commits = git(['log', '--all', '--since=21.days', '-n', '40', '--pretty=%h%x09%ct%x09%an%x09%s'])
        .split('\n')
        .filter(Boolean)
        .map((l) => {
            const [hash, time, author, subject] = l.split('\t');
            return { hash, time: Number(time) * 1000, author, subject };
        });
    return {
        generatedAt: Date.now(),
        title: config.board?.title ?? `${basename(root.replace(/\/$/, ''))} board`,
        milestoneLabel: milestoneLabel(),
        branch: git(['branch', '--show-current']),
        tasks: readCards(),
        commits,
    };
}

export function serve(portArg?: number): void {
    const hostname = process.env.WF_BOARD_HOST ?? config.board?.host ?? '127.0.0.1';
    const port = portArg ?? Number(process.env.WF_BOARD_PORT ?? config.board?.port ?? 8090);
    const encoder = new TextEncoder();
    const clients = new Set<ReadableStreamDefaultController<Uint8Array>>();
    let pending: ReturnType<typeof setTimeout> | undefined;
    const notify = () => {
        clearTimeout(pending);
        pending = setTimeout(() => {
            for (const c of clients) {
                try {
                    c.enqueue(encoder.encode('data: change\n\n'));
                } catch {
                    clients.delete(c);
                }
            }
        }, 250);
    };
    for (const dir of ['tasks', '.git/refs/heads']) {
        if (existsSync(`${root}${dir}`)) watch(`${root}${dir}`, { recursive: true }, notify);
    }
    if (existsSync(`${root}.git/HEAD`)) watch(`${root}.git/HEAD`, notify);

    const page = Bun.file(new URL('index.html', import.meta.url));
    Bun.serve({
        hostname,
        port,
        idleTimeout: 0,
        fetch(req) {
            const { pathname } = new URL(req.url);
            if (pathname === '/api/state') return Response.json(state(), { headers: { 'cache-control': 'no-store' } });
            if (pathname === '/events') {
                let self: ReadableStreamDefaultController<Uint8Array>;
                const stream = new ReadableStream<Uint8Array>({
                    start(c) {
                        self = c;
                        clients.add(c);
                        c.enqueue(encoder.encode('retry: 2000\n\n'));
                    },
                    cancel() {
                        clients.delete(self);
                    },
                });
                return new Response(stream, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-store' } });
            }
            if (pathname === '/' || pathname === '/index.html') return new Response(page, { headers: { 'content-type': 'text/html; charset=utf-8' } });
            return new Response('not found', { status: 404 });
        },
    });
    console.log(`board: http://${hostname}:${port}  (cards in ${root}tasks)`);
}
