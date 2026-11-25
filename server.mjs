#!/usr/bin/env node
// Charness — a tiny local GUI for Claude (via the Claude Agent SDK).
// Zero runtime dependencies besides the SDK. Listens on 127.0.0.1 only. Makes no outbound
// requests itself; the Claude process it spawns is routed through the egress guard.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import * as store from './lib/store.mjs';
import * as uploads from './lib/uploads.mjs';
import { startGuard } from './lib/guard.mjs';
import { runTurn, buildEnv, baseEnv, clipInput } from './lib/agent.mjs';
import { apply } from './public/reduce.js';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };

const PORT = Number(opt('--port', process.env.PORT || 4317));
const MOCK = flag('--mock') || process.env.HARNESS_MOCK === '1';
const USE_GUARD = !flag('--no-guard') && process.env.HARNESS_NET_GUARD !== 'off';
const ALLOW_FULL = process.env.HARNESS_ALLOW_FULL_ACCESS === '1';

const MODELS = [
  { id: '', label: 'Default' },
  { id: 'claude-opus-5-5', label: 'Opus 5.5' },
  { id: 'claude-sonnet-5-5', label: 'Sonnet 5.5' },
  { id: 'claude-haiku-5-5', label: 'Haiku 5.5' },
  { id: 'claude-fable-5-2', label: 'Fable 5.2' },
];
const MODES = [
  { id: 'ask', label: 'Ask before changes', sdk: 'default' },
  { id: 'edits', label: 'Auto-accept edits', sdk: 'acceptEdits' },
  { id: 'plan', label: 'Plan only', sdk: 'plan' },
  ...(ALLOW_FULL ? [{ id: 'full', label: 'Full access (no prompts)', sdk: 'bypassPermissions' }] : []),
];

// ---------------------------------------------------------------- static files
const STATIC = {};
for (const [url, file, type] of [
  ['/', 'index.html', 'text/html; charset=utf-8'],
  ['/app.js', 'app.js', 'text/javascript; charset=utf-8'],
  ['/md.js', 'md.js', 'text/javascript; charset=utf-8'],
  ['/reduce.js', 'reduce.js', 'text/javascript; charset=utf-8'],
  ['/style.css', 'style.css', 'text/css; charset=utf-8'],
]) STATIC[url] = { body: fs.readFileSync(path.join(ROOT, 'public', file)), type };

// ---------------------------------------------------------------- auth
function loadToken() {
  const f = path.join(store.HOME, 'token');
  if (!flag('--rotate-token')) {
    try { const t = fs.readFileSync(f, 'utf8').trim(); if (t.length >= 32) return t; } catch { /* make one */ }
  }
  const t = crypto.randomBytes(32).toString('base64url');
  fs.writeFileSync(f, `${t}\n`, { mode: 0o600 });
  return t;
}
const TOKEN = loadToken();
const digest = (s) => crypto.createHash('sha256').update(String(s)).digest();
const tokenOk = (s) => !!s && crypto.timingSafeEqual(digest(s), digest(TOKEN));
const cookieOf = (req, name) => {
  for (const part of (req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return null;
};

// ---------------------------------------------------------------- network guard
const netLog = [];
let guard = null;
const defaultAllow = ['api.anthropic.com'];
if (process.env.ANTHROPIC_BASE_URL) {
  try { const u = new URL(process.env.ANTHROPIC_BASE_URL); defaultAllow.push(u.port ? `${u.hostname}:${u.port}` : u.hostname); } catch { /* ignore */ }
}
const allowList = () => [...new Set([
  ...defaultAllow,
  ...(process.env.HARNESS_ALLOW_HOSTS || '').split(',').map((s) => s.trim()).filter(Boolean),
  ...store.state.allowHosts,
])];

// ---------------------------------------------------------------- live events (SSE)
const clients = new Set();
function broadcast(obj) {
  const line = `data: ${JSON.stringify(obj)}\n\n`;
  for (const res of clients) res.write(line);
}
setInterval(() => { for (const res of clients) res.write(': ping\n\n'); }, 20000).unref();

// ---------------------------------------------------------------- runs & permissions
const runs = new Map();      // threadId -> { abort, activity }
const pending = new Map();   // permId   -> { perm, resolve, input }

const threadById = (id) => store.state.threads.find((t) => t.id === id);
const projectById = (id) => store.state.projects.find((p) => p.id === id);
const pendingFor = (threadId) => [...pending.values()].filter((p) => p.perm.threadId === threadId).map((p) => p.perm);

function settle(permId, result) {
  const p = pending.get(permId);
  if (!p) return false;
  pending.delete(permId);
  p.resolve(result);
  broadcast({ type: 'perm_done', id: permId });
  return true;
}

async function sendMessage(thread, text, files = []) {
  const project = projectById(thread.projectId);
  // Attached files: Claude gets the paths in the message and read access to the thread's upload folder
  // (also on later turns, so it can go back to them).
  const prompt = files.length
    ? `${text}${text ? '\n\n' : ''}Attached files (read them with the Read tool):\n${files.map((f) => `- ${f.path}`).join('\n')}`
    : text;
  const uploadDir = uploads.folderIfAny(thread.id);
  const abort = new AbortController();
  runs.set(thread.id, { abort });
  const msgs = store.loadThread(thread.id).messages;
  const mode = MODES.find((m) => m.id === thread.mode) || MODES[0];

  const emit = (ev) => {
    ev.ts ??= Date.now();
    apply(msgs, ev);
    if (ev.t === 'session') thread.sessionId = ev.sessionId;
    if (ev.t === 'end') thread.cost = (thread.cost || 0) + (ev.cost || 0);
    thread.updatedAt = Date.now();
    store.saveMessages(thread.id);
    store.saveState();
    broadcast({ type: 'thread', threadId: thread.id, ev });
  };

  const canUseTool = (toolName, input, o) => new Promise((resolve) => {
    const perm = {
      id: store.newId(), threadId: thread.id, toolUseId: o.toolUseID, tool: toolName,
      input: clipInput(input), title: o.title, description: o.description, defaultToNo: !!o.defaultToNo,
    };
    pending.set(perm.id, { perm, resolve, input });
    broadcast({ type: 'perm', perm });
    o.signal?.addEventListener('abort', () => settle(perm.id, { behavior: 'deny', message: 'Stopped by the user.', interrupt: true }));
  });

  emit(files.length ? { t: 'user', text, files: files.map(({ name, size }) => ({ name, size })) } : { t: 'user', text });
  if (thread.title === 'New thread') {
    thread.title = (text || files[0]?.name || 'New thread').replace(/\s+/g, ' ').slice(0, 48);
    broadcast({ type: 'state' });
  }
  broadcast({ type: 'busy', threadId: thread.id, busy: true });

  try {
    await runTurn({
      thread, project, text: prompt, sdkMode: mode.sdk, abort, emit, canUseTool, mock: MOCK,
      addDirs: uploadDir ? [uploadDir] : [],
      env: buildEnv({ guardPort: guard?.port }),
      activity: (a) => {                       // live feed only: kept with the run, never written to disk
        const r = runs.get(thread.id);
        if (r) r.activity = a;
        broadcast({ type: 'activity', threadId: thread.id, activity: a });
      },
    });
  } catch (e) {
    emit({ t: 'error', text: String(e?.message || e) });
  } finally {
    for (const p of [...pending.values()]) if (p.perm.threadId === thread.id) settle(p.perm.id, { behavior: 'deny', message: 'Run ended.' });
    runs.delete(thread.id);
    broadcast({ type: 'busy', threadId: thread.id, busy: false });
    broadcast({ type: 'state' });
    store.saveState();
  }
}

// ---------------------------------------------------------------- git (read-only, hardened)
function git(cwd, gitArgs) {
  return new Promise((resolve) => {
    execFile('git', ['-c', 'core.fsmonitor=false', '-c', 'core.pager=cat', ...gitArgs], {
      cwd, timeout: 10000, maxBuffer: 4 * 1024 * 1024,
      env: { ...baseEnv(), GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' },
    }, (err, stdout) => resolve({ ok: !err, out: stdout || '' }));
  });
}
async function gitChanges(cwd) {
  const inside = await git(cwd, ['rev-parse', '--is-inside-work-tree']);
  if (!inside.ok) return { isRepo: false };
  const status = await git(cwd, ['status', '--porcelain=v1', '-unormal']);
  let diff = await git(cwd, ['diff', '--no-color', '--no-ext-diff', '--no-textconv', 'HEAD']);
  if (!diff.ok) diff = await git(cwd, ['diff', '--no-color', '--no-ext-diff', '--no-textconv']);
  const LIMIT = 300 * 1024;
  return { isRepo: true, status: status.out, diff: diff.out.slice(0, LIMIT), truncated: diff.out.length > LIMIT };
}

// ---------------------------------------------------------------- http helpers
const json = (res, code, obj) => {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(body);
};
const fail = (res, code, msg) => json(res, code, { error: msg });
/** The raw request body, or null if it is larger than `limit` (the rest is read and dropped). */
function readRaw(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0; let tooBig = false; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > limit) { tooBig = true; chunks.length = 0; } else if (!tooBig) chunks.push(c); });
    req.on('end', () => resolve(tooBig ? null : Buffer.concat(chunks)));
    req.on('error', reject);
  });
}
function readBody(req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > limit) { reject(new Error('body too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch { reject(new Error('bad json')); } });
    req.on('error', reject);
  });
}

const SECURITY_HEADERS = {
  'content-security-policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'cross-origin-resource-policy': 'same-origin',
  'x-frame-options': 'DENY',
};

const publicThread = (t) => ({ ...t, busy: runs.has(t.id) });

function expandPath(p) {
  p = String(p || '').trim();
  if (p === '~') p = os.homedir();
  else if (p.startsWith('~/')) p = path.join(os.homedir(), p.slice(2));
  return path.resolve(p);
}

// ---------------------------------------------------------------- routing
async function handle(req, res) {
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) res.setHeader(k, v);

  // 1) DNS-rebinding protection: only our own loopback names are accepted.
  const host = (req.headers.host || '').toLowerCase();
  if (host !== `127.0.0.1:${PORT}` && host !== `localhost:${PORT}`) return fail(res, 403, 'bad host');

  const url = new URL(req.url, `http://${host}`);
  const method = req.method;

  // 2) First visit with ?token=… → set a strict cookie and drop the token from the URL.
  if (method === 'GET' && url.pathname === '/' && url.searchParams.has('token')) {
    if (!tokenOk(url.searchParams.get('token'))) return fail(res, 401, 'bad token');
    res.writeHead(302, {
      'set-cookie': `hk=${TOKEN}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000`,
      location: '/',
    });
    return res.end();
  }

  // 3) Everything else needs the cookie.
  if (!tokenOk(cookieOf(req, 'hk'))) {
    res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' });
    return res.end('Not authorised. Open the full URL printed in the terminal (it contains ?token=…).\n');
  }

  // 4) State-changing requests must come from our own page.
  if (method !== 'GET' && method !== 'HEAD') {
    if (req.headers.origin !== `http://${host}`) return fail(res, 403, 'bad origin');
    if (req.headers['x-harness'] !== '1') return fail(res, 403, 'missing header');
  }

  if (method === 'GET' && STATIC[url.pathname]) {
    res.writeHead(200, { 'content-type': STATIC[url.pathname].type, 'cache-control': 'no-store' });
    return res.end(STATIC[url.pathname].body);
  }
  if (method === 'GET' && url.pathname === '/favicon.ico') { res.writeHead(204); return res.end(); }

  if (method === 'GET' && url.pathname === '/api/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
    res.write(': hello\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return undefined;
  }

  if (!url.pathname.startsWith('/api/')) return fail(res, 404, 'not found');
  let m;

  try {
    // ---- state
    if (method === 'GET' && url.pathname === '/api/state') {
      return json(res, 200, {
        projects: store.state.projects,
        threads: store.state.threads.map(publicThread),
        perms: [...pending.values()].map((p) => p.perm),
        models: MODELS,
        modes: MODES.map(({ id, label }) => ({ id, label })),
        mock: MOCK,
        guard: { on: !!guard, allow: allowList(), log: netLog.slice(-200) },
      });
    }

    // ---- projects
    if (method === 'POST' && url.pathname === '/api/projects') {
      const body = await readBody(req);
      const p = expandPath(body.path);
      let real;
      try { real = fs.realpathSync(p); if (!fs.statSync(real).isDirectory()) throw new Error(); } catch { return fail(res, 400, `Not a folder: ${p}`); }
      if (store.state.projects.some((x) => x.path === real)) return fail(res, 409, 'Already added');
      const project = { id: store.newId(), name: path.basename(real) || real, path: real };
      store.state.projects.push(project);
      store.saveState();
      broadcast({ type: 'state' });
      return json(res, 200, project);
    }
    if ((m = /^\/api\/projects\/([0-9a-f]+)$/.exec(url.pathname))) {
      const project = projectById(m[1]);
      if (!project) return fail(res, 404, 'no such project');
      if (method === 'DELETE') {
        const ids = store.state.threads.filter((t) => t.projectId === project.id).map((t) => t.id);
        if (ids.some((id) => runs.has(id))) return fail(res, 409, 'A thread is still running');
        for (const id of ids) { store.deleteThreadFiles(id); uploads.removeAll(id); }
        store.state.threads = store.state.threads.filter((t) => t.projectId !== project.id);
        store.state.projects = store.state.projects.filter((p) => p.id !== project.id);   // folder on disk is untouched
        store.saveState(); broadcast({ type: 'state' });
        return json(res, 200, { ok: true });
      }
    }

    // ---- threads
    if (method === 'POST' && url.pathname === '/api/threads') {
      const body = await readBody(req);
      if (!projectById(body.projectId)) return fail(res, 400, 'unknown project');
      const t = { id: store.newId(), projectId: body.projectId, title: 'New thread', model: 'claude-sonnet-5-5', mode: 'edits', sessionId: null, cost: 0, createdAt: Date.now(), updatedAt: Date.now() };
      store.state.threads.push(t);
      store.loadThread(t.id); store.saveMessages(t.id); store.saveState();
      broadcast({ type: 'state' });
      return json(res, 200, publicThread(t));
    }
    if ((m = /^\/api\/threads\/([0-9a-f]+)(\/[a-z]+)?$/.exec(url.pathname))) {
      const thread = threadById(m[1]);
      if (!thread) return fail(res, 404, 'no such thread');
      const sub = m[2];

      if (!sub && method === 'GET') {
        return json(res, 200, { thread: publicThread(thread), messages: store.loadThread(thread.id).messages, perms: pendingFor(thread.id), activity: runs.get(thread.id)?.activity || null });
      }
      if (!sub && method === 'PATCH') {
        const b = await readBody(req);
        if (typeof b.title === 'string') thread.title = b.title.trim().slice(0, 120) || thread.title;
        if (typeof b.model === 'string') { if (!MODELS.some((x) => x.id === b.model)) return fail(res, 400, 'unknown model'); thread.model = b.model; }
        if (typeof b.mode === 'string') { if (!MODES.some((x) => x.id === b.mode)) return fail(res, 400, 'unknown mode'); thread.mode = b.mode; }
        store.saveState(); broadcast({ type: 'state' });
        return json(res, 200, publicThread(thread));
      }
      if (!sub && method === 'DELETE') {
        if (runs.has(thread.id)) return fail(res, 409, 'Thread is running — stop it first');
        store.deleteThreadFiles(thread.id);
        uploads.removeAll(thread.id);
        store.state.threads = store.state.threads.filter((t) => t.id !== thread.id);
        store.saveState(); broadcast({ type: 'state' });
        return json(res, 200, { ok: true });
      }
      if (sub === '/files' && method === 'POST') {
        // one attached file per request, as raw bytes; its name comes URL-encoded in X-File-Name
        const bytes = await readRaw(req, uploads.MAX_FILE_BYTES);
        if (!bytes) return fail(res, 413, `File too large (limit ${uploads.MAX_FILE_BYTES / 1024 / 1024} MB)`);
        let raw = String(req.headers['x-file-name'] || 'file');
        try { raw = decodeURIComponent(raw); } catch { /* keep it as sent */ }
        return json(res, 200, uploads.save(thread.id, raw, bytes));
      }
      if (sub === '/send' && method === 'POST') {
        const b = await readBody(req);
        const text = typeof b.text === 'string' ? b.text.trim() : '';
        const names = Array.isArray(b.files) ? b.files : [];
        if (names.length > uploads.MAX_FILES_PER_MESSAGE) return fail(res, 400, `At most ${uploads.MAX_FILES_PER_MESSAGE} files per message`);
        const files = names.map((n) => uploads.find(thread.id, n));
        if (files.some((f) => !f)) return fail(res, 400, 'unknown attached file');
        if ((!text && !files.length) || text.length > 200000) return fail(res, 400, 'empty or too long');
        if (runs.has(thread.id)) return fail(res, 409, 'Already running');
        if (!projectById(thread.projectId)) return fail(res, 400, 'project missing');
        sendMessage(thread, text, files);        // runs in the background; progress arrives over SSE
        return json(res, 202, { ok: true });
      }
      if (sub === '/stop' && method === 'POST') {
        runs.get(thread.id)?.abort.abort();
        return json(res, 200, { ok: true });
      }
      if (sub === '/diff' && method === 'GET') {
        const project = projectById(thread.projectId);
        return json(res, 200, await gitChanges(project.path));
      }
    }

    // ---- permissions
    if (method === 'POST' && (m = /^\/api\/permissions\/([0-9a-f]+)$/.exec(url.pathname))) {
      const b = await readBody(req);
      const p = pending.get(m[1]);
      if (!p) return fail(res, 404, 'already answered');
      if (b.allow === true) {
        settle(m[1], { behavior: 'allow', updatedInput: p.input });
      } else {
        const th = threadById(p.perm.threadId);
        if (th) {
          const ev = { t: 'tool_denied', id: p.perm.toolUseId, ts: Date.now() };
          apply(store.loadThread(th.id).messages, ev); store.saveMessages(th.id);
          broadcast({ type: 'thread', threadId: th.id, ev });
        }
        settle(m[1], { behavior: 'deny', message: 'The user denied this action. Do not retry it; ask what they would like instead.' });
      }
      return json(res, 200, { ok: true });
    }

    // ---- network allow-list
    if (method === 'POST' && url.pathname === '/api/net/allow') {
      const b = await readBody(req);
      const h = String(b.host || '').trim().toLowerCase();
      if (!/^(\*\.)?[a-z0-9.-]+(:\d+)?$/.test(h)) return fail(res, 400, 'bad host');
      if (!store.state.allowHosts.includes(h)) { store.state.allowHosts.push(h); store.saveState(); }
      broadcast({ type: 'allow', allow: allowList() });
      return json(res, 200, { allow: allowList() });
    }
  } catch (e) {
    return fail(res, 400, String(e?.message || e));
  }
  return fail(res, 404, 'not found');
}

// ---------------------------------------------------------------- start
if (USE_GUARD) {
  const upstream = process.env.HARNESS_UPSTREAM_PROXY || process.env.HTTPS_PROXY || process.env.https_proxy || null;
  guard = await startGuard({
    getAllow: allowList,
    upstream,
    onLog: (entry) => { netLog.push(entry); if (netLog.length > 500) netLog.shift(); broadcast({ type: 'net', entry }); },
  });
}

const server = http.createServer((req, res) => { handle(req, res).catch((e) => { try { fail(res, 500, String(e?.message || e)); } catch { /* socket gone */ } }); });
server.on('error', (e) => {
  console.error(e.code === 'EADDRINUSE' ? `Port ${PORT} is busy. Try: node server.mjs --port 4400` : e);
  process.exit(1);
});
server.listen(PORT, '127.0.0.1', () => {
  const link = `http://127.0.0.1:${PORT}/?token=${TOKEN}`;
  console.log(`\nCharness${MOCK ? ' (MOCK mode — no real model)' : ''}`);
  console.log(`  open:   ${link}`);
  console.log(`  data:   ${store.HOME}`);
  console.log(`  egress: ${guard ? `guarded via 127.0.0.1:${guard.port}, allowed = ${allowList().join(', ')}` : 'NOT guarded (--no-guard)'}\n`);
  if (flag('--open')) {
    const cmd = process.platform === 'darwin' ? ['open'] : process.platform === 'win32' ? ['cmd', '/c', 'start', '""'] : ['xdg-open'];
    execFile(cmd[0], [...cmd.slice(1), link], () => {});
  }
});

function shutdown() {
  for (const r of runs.values()) r.abort.abort();
  store.flushAll();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
