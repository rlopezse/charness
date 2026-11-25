// End-to-end smoke test in MOCK mode: no network, no API key, temp data dir.
// Checks the security gates, the thread/permission flow, persistence, and the egress guard.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
// resolved like the server resolves project folders (on macOS the temp folder is a symlink into /private)
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'harness-test-')));
const proj = path.join(tmp, 'proj'); fs.mkdirSync(proj);
const PORT = 4300 + Math.floor(Math.random() * 500);

// a tiny local TCP server the guard may be told to allow
const echo = net.createServer((s) => s.end('hello-from-echo')).listen(0, '127.0.0.1');
await new Promise((r) => echo.once('listening', r));
const echoPort = echo.address().port;
let sse = null;            // live-event stream, opened once we have the cookie

// CHARNESS_SERVER=<binary> runs the same checks against another server, e.g. the Swift one
// (mac/.build/debug/charness-server); by default the Node server is tested.
const SERVER = process.env.CHARNESS_SERVER;
const [cmd, cmdArgs] = SERVER
  ? [SERVER, ['--root', ROOT, '--mock', '--port', String(PORT)]]
  : [process.execPath, [path.join(ROOT, 'server.mjs'), '--mock', '--port', String(PORT)]];
console.log(`server: ${SERVER || 'node server.mjs'}`);
const child = spawn(cmd, cmdArgs, {
  env: { ...process.env, HARNESS_HOME: path.join(tmp, 'home'), HARNESS_UPSTREAM_PROXY: '', HTTPS_PROXY: '', https_proxy: '', HARNESS_ALLOW_HOSTS: `127.0.0.1:${echoPort}` },
  stdio: ['ignore', 'pipe', 'inherit'],
});
let out = '';
const url = await new Promise((resolve, reject) => {
  child.stdout.on('data', (d) => { out += d; const m = /open:\s+(http\S+)/.exec(out); if (m) resolve(m[1]); });
  child.on('exit', (c) => reject(new Error(`server exited early (${c})`)));
  setTimeout(() => reject(new Error('server start timeout')), 8000);
});
const base = `http://127.0.0.1:${PORT}`;
const token = new URL(url).searchParams.get('token');

let pass = 0;
const ok = (name) => { pass++; console.log(`  ✓ ${name}`); };
const raw = (opts, body) => new Promise((resolve, reject) => {
  const req = http.request({ host: '127.0.0.1', port: PORT, ...opts }, (res) => {
    let d = ''; res.on('data', (c) => { d += c; }); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: d }));
  });
  req.on('error', reject); if (body) req.write(body); req.end();
});

try {
  console.log('security gates');
  assert.equal((await raw({ path: '/api/state' })).status, 401); ok('no cookie → 401');
  assert.equal((await raw({ path: '/api/state', headers: { host: `evil.com:${PORT}` } })).status, 403); ok('wrong Host header (DNS rebinding) → 403');
  assert.equal((await raw({ path: '/?token=nope' })).status, 401); ok('bad token → 401');
  const r0 = await raw({ path: `/?token=${token}` });
  assert.equal(r0.status, 302);
  assert.match(r0.headers['set-cookie'][0], /HttpOnly; SameSite=Strict/); ok('good token → strict HttpOnly cookie');
  const cookie = r0.headers['set-cookie'][0].split(';')[0];
  const H = { cookie, 'x-harness': '1', origin: base, 'content-type': 'application/json' };
  const call = async (method, p, body, headers = H) => {
    const r = await raw({ method, path: p, headers }, body ? JSON.stringify(body) : undefined);
    return { status: r.status, json: r.body ? JSON.parse(r.body) : null };
  };
  assert.equal((await call('POST', '/api/projects', { path: proj }, { ...H, origin: 'http://evil.com' })).status, 403); ok('POST with foreign Origin → 403');
  assert.equal((await call('POST', '/api/projects', { path: proj }, { cookie, origin: base })).status, 403); ok('POST without X-Harness header → 403');
  const page = await raw({ path: '/', headers: { cookie } });
  assert.match(page.headers['content-security-policy'], /connect-src 'self'/);
  assert.doesNotMatch(page.body, /https?:\/\//); ok('CSP set, page has no external URLs');

  // listen to the live-event stream like the browser does
  const frames = [];
  sse = http.get({ host: '127.0.0.1', port: PORT, path: '/api/events', headers: { cookie } }, (res) => {
    let buf = '';
    res.on('data', (c) => {
      buf += c;
      for (let i; (i = buf.indexOf('\n\n')) >= 0;) {
        const m = /^data: (.*)$/m.exec(buf.slice(0, i)); buf = buf.slice(i + 2);
        if (m) { try { frames.push(JSON.parse(m[1])); } catch { /* ignore */ } }
      }
    });
  });
  sse.on('error', () => {});

  console.log('threads & permissions');
  assert.equal((await call('POST', '/api/projects', { path: path.join(tmp, 'missing') })).status, 400); ok('rejects non-folder');
  const p = (await call('POST', '/api/projects', { path: proj })).json;
  const t = (await call('POST', '/api/threads', { projectId: p.id })).json;
  assert.equal((await call('POST', `/api/threads/${t.id}/send`, { text: 'hello there' })).status, 202);

  const wait = async (fn, ms = 6000) => { const end = Date.now() + ms; for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) throw new Error('timeout'); await new Promise((r) => setTimeout(r, 40)); } };
  const perm = await wait(async () => (await call('GET', '/api/state')).json.perms[0]);
  assert.equal(perm.tool, 'Bash'); ok('Bash permission request raised');
  const live = (await call('GET', `/api/threads/${t.id}`)).json.activity;
  assert.match(live.now, /^Waiting for your approval: Bash/);
  assert.ok(live.steps.some((x) => x.text === 'Bash: ls -la' && x.status === 'running')); ok('live activity: "waiting for approval" with the step running');
  assert.equal((await call('POST', `/api/permissions/${perm.id}`, { allow: true })).status, 200);
  const done = await wait(async () => { const r = (await call('GET', `/api/threads/${t.id}`)).json; return !r.thread.busy && r.messages.length >= 2 ? r : null; });
  const asst = done.messages.find((m) => m.role === 'assistant');
  assert.ok(asst.blocks.some((b) => b.type === 'text' && /Mock mode/.test(b.text)));
  const tool = asst.blocks.find((b) => b.type === 'tool');
  assert.equal(tool.status, 'ok'); assert.match(tool.output, /hello.txt/);
  assert.ok(asst.done.cost > 0); ok('streamed text + approved tool + result + cost recorded');
  assert.equal(done.thread.title, 'hello there'); ok('thread auto-titled');
  await wait(async () => frames.some((f) => f.type === 'busy' && f.threadId === t.id && f.busy === false));
  const acts = frames.filter((f) => f.type === 'activity' && f.threadId === t.id).map((f) => f.activity);
  assert.ok(acts.some((a) => a.now === 'Thinking…') && acts.some((a) => a.now === 'Writing…') && acts.some((a) => a.now === 'Bash: ls -la'));
  assert.ok(acts.some((a) => a.now === '↳ Glob: **/*')); ok('live activity: thinking, writing, the running command, sub-agent steps');
  const lastAct = acts.at(-1);
  assert.equal(lastAct.now, null);
  assert.deepEqual(lastAct.steps.map((x) => `${x.sub ? '↳ ' : ''}${x.text} ${x.status}`),
    ['Bash: ls -la ok', 'Task: Look around the project ok', '↳ Glob: **/* ok', '↳ Read: ' + path.join(proj, 'hello.txt') + ' ok']);
  assert.equal((await call('GET', `/api/threads/${t.id}`)).json.activity, null);
  assert.ok(!JSON.stringify(done.messages).includes('**/*')); ok('live activity: steps ticked off, cleared when done, sub-agent steps not saved');

  // deny path
  assert.equal((await call('POST', `/api/threads/${t.id}/send`, { text: 'edit something' })).status, 202);
  const perm2 = await wait(async () => (await call('GET', '/api/state')).json.perms[0]);
  assert.equal(perm2.tool, 'Edit');
  await call('POST', `/api/permissions/${perm2.id}`, { allow: false });
  const done2 = await wait(async () => { const r = (await call('GET', `/api/threads/${t.id}`)).json; return !r.thread.busy && r.messages.length >= 4 ? r : null; });
  const tool2 = done2.messages.at(-1).blocks.find((b) => b.type === 'tool');
  assert.equal(tool2.status, 'denied'); ok('denied tool is marked denied and Claude is told');

  // plan mode never executes
  await call('PATCH', `/api/threads/${t.id}`, { mode: 'plan' });
  assert.equal((await call('PATCH', `/api/threads/${t.id}`, { mode: 'full' })).status, 400); ok('"full access" mode is refused unless explicitly enabled');

  // stop
  await call('PATCH', `/api/threads/${t.id}`, { mode: 'ask' });
  await call('POST', `/api/threads/${t.id}/send`, { text: 'stop me' });
  await wait(async () => (await call('GET', '/api/state')).json.perms[0]);
  await call('POST', `/api/threads/${t.id}/stop`);
  await wait(async () => !(await call('GET', `/api/threads/${t.id}`)).json.thread.busy);
  assert.equal((await call('GET', '/api/state')).json.perms.length, 0); ok('stop cancels run and clears pending prompt');

  // persistence on disk
  await new Promise((r) => setTimeout(r, 700));
  const files = fs.readdirSync(path.join(tmp, 'home', 'threads'));
  assert.ok(files.includes(`${t.id}.json`));
  const mode = fs.statSync(path.join(tmp, 'home', 'state.json')).mode & 0o777;
  assert.equal(mode, 0o600); ok('thread saved to disk, files are chmod 600');

  console.log('attachments');
  const t2 = (await call('POST', '/api/threads', { projectId: p.id })).json;
  const upload = (name, body, headers = H) => raw({ method: 'POST', path: `/api/threads/${t2.id}/files`,
    headers: { ...headers, 'content-type': 'application/octet-stream', 'x-file-name': encodeURIComponent(name) } }, body);
  const j = (r) => JSON.parse(r.body);
  const up1 = j(await upload('notes.txt', 'hello from a file'));
  assert.deepEqual(up1, { name: 'notes.txt', size: 17 });
  assert.equal(j(await upload('notes.txt', 'again')).name, 'notes (2).txt');
  const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');
  assert.deepEqual(j(await upload('foto ñ.png', png)), { name: 'foto ñ.png', size: png.length }); ok('files upload (text and binary, duplicate names numbered)');
  const updir = path.join(tmp, 'home', 'uploads', t2.id);
  assert.equal(j(await upload('../../../evil.txt', 'x')).name, 'evil.txt');
  assert.equal(j(await upload('.env', 'x')).name, 'env');
  assert.deepEqual(fs.readdirSync(updir).sort(), ['env', 'evil.txt', 'foto ñ.png', 'notes (2).txt', 'notes.txt']);
  assert.equal(fs.statSync(updir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(updir, 'notes.txt')).mode & 0o777, 0o600); ok('names cleaned (no ../, no hidden files), folder 700, files 600');
  assert.equal((await upload('x.txt', 'x', { cookie, origin: 'http://evil.com', 'x-harness': '1' })).status, 403);
  assert.equal((await upload('big.bin', Buffer.alloc(25 * 1024 * 1024 + 1))).status, 413);
  assert.equal((await call('POST', `/api/threads/${t2.id}/send`, { text: 'hi', files: ['../state.json'] })).status, 400);
  assert.equal((await call('POST', `/api/threads/${t2.id}/send`, { text: 'hi', files: ['missing.txt'] })).status, 400); ok('foreign origin, files over 25 MB and unknown or ../ names refused');
  assert.equal((await call('POST', `/api/threads/${t2.id}/send`, { text: '', files: ['notes.txt', 'foto ñ.png'] })).status, 202);
  const perm3 = await wait(async () => (await call('GET', '/api/state')).json.perms.find((x) => x.threadId === t2.id));
  await call('POST', `/api/permissions/${perm3.id}`, { allow: true });
  const done3 = await wait(async () => { const r = (await call('GET', `/api/threads/${t2.id}`)).json; return !r.thread.busy && r.messages.length >= 2 ? r : null; });
  assert.deepEqual(done3.messages[0], { role: 'user', text: '', files: [{ name: 'notes.txt', size: 17 }, { name: 'foto ñ.png', size: png.length }], ts: done3.messages[0].ts });
  assert.equal(done3.thread.title, 'notes.txt');
  assert.match(done3.messages[1].blocks[0].text, /Attached files/); ok('a message with only files is sent; files saved with it; thread named after the file');
  assert.equal((await call('DELETE', `/api/threads/${t2.id}`)).status, 200);
  assert.ok(!fs.existsSync(updir)); ok("deleting the thread deletes its files");

  console.log('git (hardened)');
  const d = (await call('GET', `/api/threads/${t.id}/diff`)).json;
  assert.equal(d.isRepo, false); ok('non-repo handled');

  console.log('egress guard');
  const st = (await call('GET', '/api/state')).json;
  assert.equal(st.guard.on, true);
  const guardPort = Number(/guarded via 127\.0\.0\.1:(\d+)/.exec(out)[1]);
  const connect = (host, port) => new Promise((resolve) => {
    const s = net.connect(guardPort, '127.0.0.1', () => s.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`));
    let d = ''; s.on('data', (c) => { d += c; if (/\r\n\r\n/.test(d) && /^HTTP\/1.1 200/.test(d)) { s.write('x'); } });
    s.on('close', () => resolve(d)); s.on('error', () => resolve(d));
    setTimeout(() => { s.destroy(); }, 1500);
  });
  assert.match(await connect('telemetry.example.com', 443), /403/); ok('unlisted host refused');
  assert.match(await connect('api.anthropic.com', 8443), /403/); ok('allowed host on wrong port refused');
  assert.match(await connect('127.0.0.1', echoPort), /200 Connection Established[\s\S]*hello-from-echo/); ok('allow-listed host tunnels through');
  const st2 = (await call('GET', '/api/state')).json;
  assert.ok(st2.guard.log.some((e) => e.host === 'telemetry.example.com' && !e.allowed)); ok('blocked attempt is logged');
  assert.equal((await call('POST', '/api/net/allow', { host: 'telemetry.example.com' })).status, 200);
  assert.ok((await call('GET', '/api/state')).json.guard.allow.includes('telemetry.example.com')); ok('UI can add a host to the allow-list');

  console.log(`\nall ${pass} checks passed`);
} catch (e) {
  console.error('\nFAILED:', e.message, '\n', e.stack?.split('\n').slice(1, 4).join('\n'));
  process.exitCode = 1;
} finally {
  sse?.destroy(); echo.close();
  // the server saves its state as it shuts down: let it finish before deleting its folder
  if (child.exitCode === null) {
    child.kill('SIGTERM');
    await Promise.race([new Promise((r) => child.once('exit', r)), new Promise((r) => setTimeout(r, 5000))]);
  }
  fs.rmSync(tmp, { recursive: true, force: true });
}
