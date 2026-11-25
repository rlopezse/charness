// Runs the same session against the Node server and the Swift server (both in mock mode) and requires the
// same answers: every API reply, every live event (SSE), and the files they leave on disk. Ids, times, ports
// and temp paths differ between the two runs, so they are numbered in order of appearance before comparing.
//     CHARNESS_SERVER=mac/.build/debug/charness-server node test/compare-servers.mjs
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SWIFT = process.env.CHARNESS_SERVER;
if (!SWIFT) { console.error('Set CHARNESS_SERVER to the Swift charness-server binary.'); process.exit(2); }

async function session(label, cmd, args) {
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'charness-cmp-')));
  const proj = path.join(tmp, 'proj'); fs.mkdirSync(proj);
  const PORT = 5000 + Math.floor(Math.random() * 2000);
  const child = spawn(cmd, [...args, '--mock', '--no-guard', '--port', String(PORT)], {
    env: { ...process.env, HARNESS_HOME: path.join(tmp, 'home'), HARNESS_ALLOW_HOSTS: '' }, stdio: ['ignore', 'pipe', 'inherit'],
  });
  let out = '';
  const url = await new Promise((resolve, reject) => {
    child.stdout.on('data', (d) => { out += d; const m = /open:\s+(http\S+)/.exec(out); if (m) resolve(m[1]); });
    child.on('exit', (c) => reject(new Error(`${label} exited (${c})`)));
    setTimeout(() => reject(new Error(`${label}: start timeout`)), 10000);
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
  const log = [];
  const call = async (method, p, body, headers = H) => {
    const r = await raw({ method, path: p, headers }, body === undefined ? undefined : typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
    log.push({ call: `${method} ${p}`, status: r.status, body: r.body });
    return r.body ? JSON.parse(r.body) : null;
  };
  const frames = [];
  const sse = http.get({ host: '127.0.0.1', port: PORT, path: '/api/events', headers: { cookie } }, (res) => {
    let buf = '';
    res.on('data', (c) => {
      buf += c;
      for (let i; (i = buf.indexOf('\n\n')) >= 0;) { const f = buf.slice(0, i); buf = buf.slice(i + 2); if (f.startsWith('data: ')) frames.push(f.slice(6)); }
    });
  });
  sse.on('error', () => {});
  await new Promise((r) => setTimeout(r, 200));
  const wait = async (fn, ms = 10000) => { const end = Date.now() + ms; for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) throw new Error('timeout'); await new Promise((r) => setTimeout(r, 50)); } };
  const quiet = async (fn) => { const n = log.length; const v = await fn(); log.length = n; return v; };   // polling: not compared
  const answer = async (allow) => {
    const p = await wait(() => quiet(async () => (await call('GET', '/api/state')).perms[0]));
    await call('POST', `/api/permissions/${p.id}`, { allow });
  };
  const idle = (id) => wait(() => quiet(async () => !(await call('GET', `/api/threads/${id}`)).thread.busy));

  try {
    await call('GET', '/api/state');
    await call('POST', '/api/projects', { path: path.join(tmp, 'missing') });
    const p = await call('POST', '/api/projects', { path: `${proj}/` });
    await call('POST', '/api/projects', { path: proj });
    await call('POST', '/api/threads', { projectId: 'nope' });
    const t = await call('POST', '/api/threads', { projectId: p.id });
    await call('PATCH', `/api/threads/${t.id}`, { model: 'gpt-4' });
    await call('PATCH', `/api/threads/${t.id}`, { mode: 'full' });
    await call('PATCH', `/api/threads/${t.id}`, { mode: 'ask', model: 'claude-opus-5-5' });
    await call('POST', `/api/threads/${t.id}/send`, { text: '  hello there  ' });
    await call('POST', `/api/threads/${t.id}/send`, { text: 'again' });
    await answer(true); await idle(t.id);
    await call('GET', `/api/threads/${t.id}`);
    await call('POST', `/api/threads/${t.id}/send`, { text: 'edit something' });
    await answer(false); await idle(t.id);
    await call('PATCH', `/api/threads/${t.id}`, { title: '  Renamed   thread  ' });
    await call('POST', `/api/threads/${t.id}/files`, 'hello file', { ...H, 'content-type': 'application/octet-stream', 'x-file-name': encodeURIComponent('../notas ñ.txt') });
    await call('POST', `/api/threads/${t.id}/send`, { text: '', files: ['notas ñ.txt'] });
    await answer(true); await idle(t.id);
    await call('POST', `/api/threads/${t.id}/send`, { text: 'stop me' });
    await wait(() => quiet(async () => (await call('GET', '/api/state')).perms[0]));
    await call('POST', `/api/threads/${t.id}/stop`);
    await idle(t.id);
    await call('GET', `/api/threads/${t.id}`);
    await call('GET', `/api/threads/${t.id}/diff`);
    await call('POST', '/api/net/allow', { host: 'Example.COM:8443' });
    await call('POST', '/api/net/allow', { host: 'bad host' });
    await call('POST', '/api/permissions/abcdef', { allow: true });
    await call('GET', '/api/nope');
    await call('POST', '/api/threads', '{not json');
    const t2 = await call('POST', '/api/threads', { projectId: p.id });
    await call('DELETE', `/api/threads/${t2.id}`);
    await call('GET', '/api/state');
    await new Promise((r) => setTimeout(r, 300));
  } finally {
    sse.destroy();
    child.kill('SIGTERM');
    await new Promise((r) => child.once('exit', r));
  }
  const home = path.join(tmp, 'home');
  const disk = { 'state.json': fs.readFileSync(path.join(home, 'state.json'), 'utf8') };
  for (const f of fs.readdirSync(path.join(home, 'threads')).sort()) disk[`thread ${Object.keys(disk).length}`] = fs.readFileSync(path.join(home, 'threads', f), 'utf8');
  fs.rmSync(tmp, { recursive: true, force: true });
  return { tmp, log, frames, disk };
}

// ids, times, ports and paths differ between runs: number them in order of appearance
function normalize(text, tmp) {
  const seen = new Map();
  const name = (kind, v) => { const k = `${kind}:${v}`; if (!seen.has(k)) seen.set(k, `<${kind}${[...seen.keys()].filter((x) => x.startsWith(`${kind}:`)).length + 1}>`); return seen.get(k); };
  return text.split(tmp).join('<TMP>')
    .replace(/\b(mock-[0-9a-z]+|toolu_[0-9a-z]+)\b/g, (v) => name('id', v))
    .replace(/\b[0-9a-f]{12}\b/g, (v) => name('hex', v))
    .replace(/\b1\d{12}\b/g, '<TIME>');
}

const node = await session('node', process.execPath, [path.join(ROOT, 'server.mjs')]);
const swift = await session('swift', SWIFT, ['--root', ROOT]);
let failures = 0;
const compare = (what, a, b) => {
  const x = normalize(a, node.tmp), y = normalize(b, swift.tmp);
  if (x === y) return true;
  failures++;
  let i = 0; while (i < x.length && x[i] === y[i]) i++;
  console.log(`  ✗ ${what}\n      Node : …${x.slice(Math.max(0, i - 60), i + 100)}\n      Swift: …${y.slice(Math.max(0, i - 60), i + 100)}`);
  return false;
};
for (let i = 0; i < Math.max(node.log.length, swift.log.length); i++) {
  const a = node.log[i], b = swift.log[i];
  compare(`reply ${i + 1}: ${a?.call ?? b?.call}`, JSON.stringify(a ?? null), JSON.stringify(b ?? null));
}
const okReplies = failures === 0;
console.log(`${okReplies ? '✓' : '✗'} ${node.log.length} API replies (status and body)`);
compare('live events', node.frames.join('\n'), swift.frames.join('\n')) && console.log(`✓ ${node.frames.length} live events, in order`);
let diskOk = true;
for (const k of new Set([...Object.keys(node.disk), ...Object.keys(swift.disk)])) diskOk = compare(`file ${k}`, node.disk[k] ?? '-', swift.disk[k] ?? '-') && diskOk;
if (diskOk) console.log(`✓ ${Object.keys(node.disk).length} files on disk, byte for byte`);
console.log(failures ? `\n${failures} difference(s)` : '\nthe Swift server answers exactly like the Node server');
process.exitCode = failures ? 1 : 0;
