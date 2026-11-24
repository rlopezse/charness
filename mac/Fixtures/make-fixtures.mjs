// Regenerates mac/Fixtures/node-home/: real files written by the Node server (mock mode), used by
// `swift run core-checks` to prove the Swift store reads and rewrites them byte for byte.
//     node mac/Fixtures/make-fixtures.mjs
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..', '..');
const OUT = path.join(HERE, 'node-home');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'charness-fixtures-'));
const proj = path.join(tmp, 'proj'); fs.mkdirSync(proj);
const PORT = 4800 + Math.floor(Math.random() * 500);

const child = spawn(process.execPath, [path.join(ROOT, 'server.mjs'), '--mock', '--no-guard', '--port', String(PORT)], {
  env: { ...process.env, HARNESS_HOME: path.join(tmp, 'home') }, stdio: ['ignore', 'pipe', 'inherit'],
});
let out = '';
const url = await new Promise((resolve, reject) => {
  child.stdout.on('data', (d) => { out += d; const m = /open:\s+(http\S+)/.exec(out); if (m) resolve(m[1]); });
  child.on('exit', (c) => reject(new Error(`server exited early (${c})`)));
  setTimeout(() => reject(new Error('server start timeout')), 8000);
});
const base = `http://127.0.0.1:${PORT}`;
const raw = (opts, body) => new Promise((resolve, reject) => {
  const req = http.request({ host: '127.0.0.1', port: PORT, ...opts }, (res) => {
    let d = ''; res.on('data', (c) => { d += c; }); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: d }));
  });
  req.on('error', reject); if (body) req.write(body); req.end();
});
const cookie = (await raw({ path: `/?token=${new URL(url).searchParams.get('token')}` })).headers['set-cookie'][0].split(';')[0];
const H = { cookie, 'x-harness': '1', origin: base, 'content-type': 'application/json' };
const call = async (method, p, body) => {
  const r = await raw({ method, path: p, headers: H }, body ? JSON.stringify(body) : undefined);
  return r.body ? JSON.parse(r.body) : null;
};
const wait = async (fn, ms = 8000) => { const end = Date.now() + ms; for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) throw new Error('timeout'); await new Promise((r) => setTimeout(r, 40)); } };
const answerNext = async (allow) => { const p = await wait(async () => (await call('GET', '/api/state')).perms[0]); await call('POST', `/api/permissions/${p.id}`, { allow }); };
const idle = (id) => wait(async () => !(await call('GET', `/api/threads/${id}`)).thread.busy);

try {
  const p = await call('POST', '/api/projects', { path: proj });
  const t = await call('POST', '/api/threads', { projectId: p.id });
  // text that exercises JSON escaping: quotes, backslash, newline, tab, control char, accents, emoji, </script>
  await call('POST', `/api/threads/${t.id}/send`, { text: 'hola "mundo" \\ path\nline2\ttab \u0001 ñandú 🚀 </script>' });
  await answerNext(true); await idle(t.id);
  await call('POST', `/api/threads/${t.id}/send`, { text: 'edit something' });
  await answerNext(false); await idle(t.id);
  await call('PATCH', `/api/threads/${t.id}`, { title: 'Título con acentos y "comillas"' });
  await call('POST', '/api/threads', { projectId: p.id });            // an empty thread too
  await call('POST', '/api/net/allow', { host: 'example.com' });
} finally {
  child.kill('SIGTERM');                                               // server flushes its debounced writes on SIGTERM
  await new Promise((r) => child.once('exit', r));
}

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(path.join(OUT, 'threads'), { recursive: true });
const home = path.join(tmp, 'home');
fs.copyFileSync(path.join(home, 'state.json'), path.join(OUT, 'state.json'));
for (const f of fs.readdirSync(path.join(home, 'threads'))) fs.copyFileSync(path.join(home, 'threads', f), path.join(OUT, 'threads', f));
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`wrote ${OUT}`);
