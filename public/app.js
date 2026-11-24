// Claude Harness UI — plain ES modules, no framework, no build step, no network except this origin.
import { apply } from './reduce.js';
import { renderMarkdown } from './md.js';

// ------------------------------------------------------------------ tiny helpers
const $ = (sel) => document.querySelector(sel);
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'checked' || k === 'disabled' || k === 'selected') el[k] = !!v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
const fill = (el, ...kids) => { el.replaceChildren(); for (const k of kids.flat(Infinity)) if (k != null && k !== false) el.append(k.nodeType ? k : document.createTextNode(String(k))); };
function select(options, value, onchange) {
  return h('select', { onchange: (e) => onchange(e.target.value) },
    options.map((o) => h('option', { value: o.id, selected: o.id === value }, o.label)));
}
async function api(method, url, body) {
  const r = await fetch(url, {
    method,
    headers: { 'X-Harness': '1', ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let data = null;
  try { data = await r.json(); } catch { /* empty */ }
  if (!r.ok) throw new Error(data?.error || r.statusText);
  return data;
}
let toastTimer;
function toast(msg) {
  $('#toast')?.remove();
  document.body.append(h('div', { id: 'toast' }, msg));
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $('#toast')?.remove(), 4500);
}
const guarded = (fn) => async (...a) => { try { await fn(...a); } catch (e) { toast(e.message); } };
const lsGet = (k) => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch { /* private mode */ } };

// ------------------------------------------------------------------ state
const S = {
  projects: [], threads: [], models: [], modes: [], mock: false,
  guard: { on: false, allow: [], log: [] },
  cur: null,                 // { thread, messages }
  busy: new Set(), perms: new Map(),
  drawer: null,              // null | 'changes' | 'network'
  open: new Set(),           // expanded tool cards
  collapsed: new Set(),      // collapsed projects
  armed: null,               // two-click delete
  dirty: new Set(), raf: 0, stick: true, connectedOnce: false,
};

const MODE_HINT = {
  ask: 'Claude asks before editing files or running commands.',
  edits: 'File edits are applied automatically; commands still ask.',
  plan: 'Read-only: Claude explores and proposes a plan, changes nothing.',
  full: 'No prompts at all. Only use in a throwaway folder or VM.',
};

// ------------------------------------------------------------------ shell
function buildShell() {
  $('#app').append(
    h('aside', { id: 'side' },
      h('div', { class: 'brand' }, h('span', { id: 'conn', class: 'dot' }), 'Claude Harness', h('span', { id: 'mockTag', class: 'mock hidden' }, 'MOCK')),
      h('div', { id: 'projects' }),
      h('div', { class: 'side-actions', id: 'addbox' }),
      h('div', { class: 'guard', id: 'guard', title: 'Show network log', onclick: () => toggleDrawer('network') }),
    ),
    h('main', { id: 'main' },
      h('header', { id: 'head' }),
      h('div', { id: 'scroller' }, h('div', { id: 'empty' }), h('div', { id: 'msgs' }), h('div', { id: 'perms' })),
      h('footer', { id: 'composer' },
        h('div', { class: 'box' },
          h('textarea', { id: 'input', rows: '1', placeholder: 'Message Claude…' }),
          h('button', { id: 'send', class: 'btn primary', onclick: guarded(onSendClick) }, 'Send')),
        h('div', { class: 'hint', id: 'hint' })),
    ),
    h('aside', { id: 'drawer' }),
  );
  const input = $('#input');
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); guarded(onSendClick)(); }
  });
  input.addEventListener('input', autosize);
  $('#scroller').addEventListener('scroll', () => {
    const s = $('#scroller');
    S.stick = s.scrollHeight - s.scrollTop - s.clientHeight < 80;
  });
  $('#head').addEventListener('focusout', () => setTimeout(renderHeader, 0));
}
function autosize() { const i = $('#input'); i.style.height = 'auto'; i.style.height = `${Math.min(i.scrollHeight, 220)}px`; }
function scrollToBottom(force) { const s = $('#scroller'); if (force || S.stick) s.scrollTop = s.scrollHeight; }

// ------------------------------------------------------------------ rendering: sidebar
function renderSidebar() {
  $('#conn').className = `dot ${document.body.dataset.conn === '1' ? 'on' : ''}`;
  $('#mockTag').classList.toggle('hidden', !S.mock);
  const box = $('#projects');
  box.replaceChildren();
  if (!S.projects.length) box.append(h('div', { class: 'empty-hint' }, 'No projects yet — add a folder below.'));

  for (const p of S.projects) {
    const threads = S.threads.filter((t) => t.projectId === p.id).sort((a, b) => b.updatedAt - a.updatedAt);
    const key = `p:${p.id}`;
    const toggle = () => { S.collapsed.has(p.id) ? S.collapsed.delete(p.id) : S.collapsed.add(p.id); renderSidebar(); };
    box.append(h('div', { class: 'proj' },
      h('div', { class: 'proj-head' },
        h('button', { class: 'iconbtn chev', title: S.collapsed.has(p.id) ? 'Show threads' : 'Hide threads', 'aria-expanded': String(!S.collapsed.has(p.id)), onclick: toggle }, S.collapsed.has(p.id) ? '▸' : '▾'),
        h('span', { class: 'name', title: p.path, onclick: toggle }, p.name),
        h('button', { class: 'iconbtn', title: 'New thread', onclick: guarded(() => newThread(p.id)) }, '+'),
        h('button', { class: `iconbtn danger ${S.armed === key ? 'armed' : ''}`, title: 'Remove project and its threads (folder on disk is untouched)', onclick: guarded(() => armedDelete(key, () => api('DELETE', `/api/projects/${p.id}`))) }, S.armed === key ? 'sure?' : '×')),
      h('div', { class: 'proj-path', title: p.path }, p.path),
      S.collapsed.has(p.id) ? null : threads.map((t) => threadRow(t)),
      !S.collapsed.has(p.id) && !threads.length ? h('div', { class: 'empty-hint' }, 'No threads yet') : null));
  }

  const blocked = S.guard.log.filter((e) => !e.allowed).length;
  $('#guard').replaceChildren(
    h('span', { class: `dot ${S.guard.on ? (blocked ? 'warn' : 'on') : ''}` }),
    S.guard.on ? `Egress guard on · ${S.guard.allow.length} allowed · ${blocked} blocked` : 'Egress guard OFF',
  );
}
function threadRow(t) {
  const key = `t:${t.id}`;
  const needs = [...S.perms.values()].some((p) => p.threadId === t.id);
  return h('div', { class: `thread ${S.cur?.thread.id === t.id ? 'active' : ''}`, onclick: guarded(() => openThread(t.id)) },
    h('span', { class: `dot ${needs ? 'warn' : S.busy.has(t.id) ? 'on' : ''}`, title: needs ? 'Waiting for your approval' : S.busy.has(t.id) ? 'Running' : '' }),
    h('span', { class: 't' }, t.title),
    h('button', { class: `iconbtn x danger ${S.armed === key ? 'armed' : ''}`, title: 'Delete thread', onclick: (e) => { e.stopPropagation(); guarded(() => armedDelete(key, async () => { await api('DELETE', `/api/threads/${t.id}`); if (S.cur?.thread.id === t.id) { S.cur = null; renderAll(); } }))(); } }, S.armed === key ? 'sure?' : '×'));
}
async function armedDelete(key, fn) {
  if (S.armed === key) { S.armed = null; await fn(); await refreshState(); return; }
  S.armed = key; renderSidebar();
  setTimeout(() => { if (S.armed === key) { S.armed = null; renderSidebar(); } }, 3000);
}

function renderAddBox() {
  const input = h('input', { placeholder: '/path/to/project  or  ~/code/app', spellcheck: 'false' });
  $('#addbox').replaceChildren(h('form', { onsubmit: guarded(async (e) => {
    e.preventDefault();
    const path = input.value.trim();
    if (!path) return;
    const p = await api('POST', '/api/projects', { path });
    input.value = '';
    await refreshState();
    await newThread(p.id);
  }) }, input, h('button', { class: 'btn', type: 'submit' }, 'Add')));
}

// ------------------------------------------------------------------ rendering: header / composer
function renderHeader() {
  const head = $('#head');
  if (head.contains(document.activeElement)) return;     // don't clobber a control while it's being used
  head.replaceChildren();
  if (!S.cur) return;
  const t = S.cur.thread;
  head.append(
    h('input', { class: 'title', value: t.title, onchange: guarded((e) => api('PATCH', `/api/threads/${t.id}`, { title: e.target.value })) }),
    select(S.models, t.model, guarded((v) => api('PATCH', `/api/threads/${t.id}`, { model: v }))),
    select(S.modes, t.mode, guarded((v) => api('PATCH', `/api/threads/${t.id}`, { mode: v }))),
    h('button', { class: 'btn small', onclick: () => toggleDrawer('changes') }, 'Changes'),
    h('button', { class: 'btn small', onclick: () => toggleDrawer('network') }, 'Network'),
  );
  head.querySelector('input.title').value = t.title;
}
function renderComposer() {
  const input = $('#input'); const send = $('#send');
  const t = S.cur?.thread;
  const busy = !!t && S.busy.has(t.id);
  input.disabled = !t;
  input.placeholder = t ? 'Message Claude…  (Enter to send, Shift+Enter for a new line)' : 'Add a project, then start a thread';
  send.textContent = busy ? 'Stop' : 'Send';
  send.className = busy ? 'btn' : 'btn primary';
  send.disabled = !t;
  $('#hint').textContent = t ? `${MODE_HINT[t.mode] || ''}${t.cost ? `  ·  thread cost so far $${t.cost.toFixed(4)}` : ''}` : '';
}
async function onSendClick() {
  const t = S.cur?.thread;
  if (!t) return;
  if (S.busy.has(t.id)) { await api('POST', `/api/threads/${t.id}/stop`); return; }
  const input = $('#input');
  const text = input.value.trim();
  if (!text) return;
  input.value = ''; autosize();
  S.stick = true;
  try { await api('POST', `/api/threads/${t.id}/send`, { text }); } catch (e) { input.value = text; autosize(); throw e; }
}

// ------------------------------------------------------------------ rendering: messages
function renderEmpty() {
  const box = $('#empty');
  box.replaceChildren();
  if (S.cur && S.cur.messages.length) return;
  if (!S.projects.length) box.append(h('div', { class: 'empty-state' }, h('h2', null, 'Welcome'), h('p', null, 'Add a project folder in the sidebar to begin. Claude will work inside that folder only.')));
  else if (!S.cur) box.append(h('div', { class: 'empty-state' }, h('h2', null, 'No thread open'), h('p', null, 'Pick a thread, or press + next to a project to start one.')));
  else box.append(h('div', { class: 'empty-state' }, h('h2', null, S.cur.thread.title === 'New thread' ? 'New thread' : S.cur.thread.title), h('p', null, 'Ask Claude anything about this project.')));
}
function renderMessages() {
  const box = $('#msgs');
  box.replaceChildren();
  if (S.cur) for (const m of S.cur.messages) box.append(msgNode(m));
  renderEmpty();
}
function flushDirty() {
  S.raf = 0;
  if (!S.cur) return;
  const box = $('#msgs');
  for (const i of [...S.dirty].sort((a, b) => a - b)) {
    if (i > box.children.length) { renderMessages(); break; }
    const node = msgNode(S.cur.messages[i]);
    if (box.children[i]) box.children[i].replaceWith(node); else box.append(node);
  }
  S.dirty.clear();
  renderEmpty();
  scrollToBottom();
}
function markDirty(i) { S.dirty.add(i); if (!S.raf) S.raf = requestAnimationFrame(flushDirty); }

function msgNode(m) {
  if (m.role === 'user') return h('div', { class: 'msg user' }, h('div', { class: 'bubble' }, m.text));
  if (m.role === 'system') return h('div', { class: 'msg sys' }, m.text);
  const wrap = h('div', { class: 'msg assistant' });
  for (const b of m.blocks) wrap.append(b.type === 'text' ? renderMarkdown(b.text) : toolCard(b));
  if (m.done) {
    const bits = [];
    if (m.done.cost) bits.push(`$${m.done.cost.toFixed(4)}`);
    if (m.done.turns) bits.push(`${m.done.turns} turn${m.done.turns > 1 ? 's' : ''}`);
    if (m.done.ms) bits.push(`${(m.done.ms / 1000).toFixed(1)}s`);
    if (bits.length) wrap.append(h('div', { class: 'msg-meta' }, bits.join(' · ')));
  }
  return wrap;
}

// ---- tool cards
function summarize(b) {
  const i = b.input || {};
  const first = (s) => String(s ?? '').split('\n')[0].slice(0, 140);
  switch (b.name) {
    case 'Bash': return first(i.command);
    case 'Read': case 'Write': case 'Edit': case 'MultiEdit': case 'NotebookEdit': return first(i.file_path || i.notebook_path);
    case 'Grep': return first(`${i.pattern ?? ''}${i.path ? `  in ${i.path}` : ''}`);
    case 'Glob': return first(i.pattern);
    case 'WebFetch': return first(i.url);
    case 'WebSearch': return first(i.query);
    case 'Task': case 'Agent': return first(i.description);
    case 'TodoWrite': return `${(i.todos || []).length} items`;
    default: { const v = Object.values(i).find((x) => typeof x === 'string'); return first(v); }
  }
}
const lines = (s, n) => { const a = String(s ?? '').split('\n'); return a.length > n ? `${a.slice(0, n).join('\n')}\n… (${a.length - n} more lines)` : a.join('\n'); };
function diffBlock(oldS, newS) {
  const pre = h('pre');
  for (const l of String(oldS ?? '').split('\n')) pre.append(h('span', { class: 'diffline del' }, `- ${l}`));
  for (const l of String(newS ?? '').split('\n')) pre.append(h('span', { class: 'diffline add' }, `+ ${l}`));
  return pre;
}
function inputView(name, i) {
  i = i || {};
  if (name === 'Bash') return [h('pre', null, `$ ${i.command ?? ''}`), i.description && h('div', { class: 'label plain' }, i.description)];
  if (name === 'Edit') return [h('div', { class: 'label plain path' }, i.file_path), diffBlock(i.old_string, i.new_string)];
  if (name === 'MultiEdit') return [h('div', { class: 'label plain path' }, i.file_path), (i.edits || []).map((e) => diffBlock(e.old_string, e.new_string))];
  if (name === 'Write') return [h('div', { class: 'label plain path' }, i.file_path), h('pre', null, lines(i.content, 60))];
  if (name === 'ExitPlanMode') return [renderMarkdown(i.plan || '')];
  return [h('pre', null, JSON.stringify(i, null, 2))];
}
function toolCard(b) {
  const d = h('details', { class: `tool ${b.status}`, open: S.open.has(b.id) },
    h('summary', null, h('span', { class: 'tname' }, b.name), h('span', { class: 'tsum' }, summarize(b)), h('span', { class: 'tstat' }, b.status === 'running' ? 'running' : b.status)),
    h('div', { class: 'tbody' },
      inputView(b.name, b.input),
      b.output ? [h('div', { class: 'label' }, 'Output'), h('pre', null, b.output.length > 4000 ? `${b.output.slice(0, 4000)}\n…` : b.output)] : null));
  d.addEventListener('toggle', () => { d.open ? S.open.add(b.id) : S.open.delete(b.id); });
  return d;
}

// ---- permission cards
function renderPerms() {
  const box = $('#perms');
  box.replaceChildren();
  if (!S.cur) return;
  for (const p of S.perms.values()) if (p.threadId === S.cur.thread.id) box.append(permCard(p));
}
function permCard(p) {
  const plan = p.tool === 'ExitPlanMode';
  const answer = guarded(async (allow) => { S.perms.delete(p.id); renderPerms(); renderSidebar(); await api('POST', `/api/permissions/${p.id}`, { allow }); });
  return h('div', { class: 'perm' },
    h('h4', null, plan ? 'Claude has a plan — approve it?' : (p.title || `Claude wants to use ${p.tool}`)),
    p.description && h('div', { class: 'desc' }, p.description),
    inputView(p.tool, p.input),
    h('div', { class: 'actions' },
      h('button', { class: p.defaultToNo ? 'btn' : 'btn primary', onclick: () => answer(true) }, plan ? 'Approve plan' : 'Allow'),
      h('button', { class: p.defaultToNo ? 'btn primary' : 'btn', onclick: () => answer(false) }, plan ? 'Keep planning' : 'Deny')));
}

// ------------------------------------------------------------------ drawer
function toggleDrawer(which) {
  S.drawer = S.drawer === which ? null : which;
  renderDrawer();
}
function renderDrawer() {
  $('#app').classList.toggle('drawer-open', !!S.drawer);
  const d = $('#drawer');
  d.replaceChildren();
  if (!S.drawer) return;
  const tab = (id, label) => h('button', { class: `tab ${S.drawer === id ? 'active' : ''}`, onclick: () => { S.drawer = id; renderDrawer(); } }, label);
  d.append(
    h('div', { class: 'tabs' }, tab('changes', 'Changes'), tab('network', 'Network'), h('span', { class: 'spacer' }), h('button', { class: 'iconbtn', title: 'Close', onclick: () => toggleDrawer(null) }, '✕')),
    h('div', { class: 'dbody', id: 'dbody' }));
  fillDrawer();
}
function fillDrawer() {
  const body = $('#dbody');
  if (!body) return;
  if (S.drawer === 'network') return fillNetwork(body);
  return fillChanges(body);
}
async function fillChanges(body) {
  if (!S.cur) { fill(body, h('p', { class: 'note' }, 'Open a thread to see its project changes.')); return; }
  fill(body, h('p', { class: 'note' }, 'Loading…'));
  const id = S.cur.thread.id;
  let r;
  try { r = await api('GET', `/api/threads/${id}/diff`); } catch (e) { fill(body, h('p', { class: 'note' }, e.message)); return; }
  if (S.drawer !== 'changes' || !$('#dbody')) return;
  if (!r.isRepo) { fill(body, h('p', { class: 'note' }, 'This project is not a git repository, so there is nothing to diff.')); return; }
  const pre = h('pre');
  for (const l of r.diff.split('\n')) {
    const cls = l.startsWith('+') && !l.startsWith('+++') ? 'add' : l.startsWith('-') && !l.startsWith('---') ? 'del' : '';
    pre.append(h('span', { class: `diffline ${cls}` }, l || ' '));
  }
  fill(body,
    h('button', { class: 'btn small', onclick: () => fillChanges($('#dbody')) }, 'Refresh'),
    h('div', { class: 'label' }, 'Status'), h('pre', null, r.status.trim() || '(clean)'),
    h('div', { class: 'label' }, 'Diff vs HEAD'), r.diff ? pre : h('p', { class: 'note' }, 'No tracked-file changes.'),
    r.truncated && h('p', { class: 'note' }, 'Diff truncated at 300 KB.'));
}
function fillNetwork(body) {
  const g = S.guard;
  const groups = new Map();
  for (const e of g.log) {
    const k = `${e.host}:${e.port}|${e.allowed}`;
    const x = groups.get(k) || { ...e, n: 0 };
    x.n++; x.ts = e.ts; groups.set(k, x);
  }
  const rows = [...groups.values()].sort((a, b) => b.ts - a.ts).slice(0, 100);
  fill(body,
    h('p', { class: 'note' }, g.on
      ? 'Everything Claude Code tries to reach goes through a local guard on 127.0.0.1. Only the allowed hosts below are connected; anything else is refused and listed here. (Traffic contents are never visible to the guard — only host and port.)'
      : 'The guard is OFF: Claude Code is talking to the network directly. Restart without --no-guard to turn it on.'),
    h('div', { class: 'label' }, 'Allowed'),
    h('div', { class: 'chips' }, g.allow.map((a) => h('span', { class: 'chip' }, a))),
    h('div', { class: 'label' }, 'Connection attempts'),
    rows.length ? rows.map((e) => h('div', { class: 'netrow' },
      h('span', { class: 'h', title: `${e.host}:${e.port}` }, `${e.host}:${e.port}${e.n > 1 ? ` ×${e.n}` : ''}`),
      h('span', { class: `pill ${e.allowed ? 'ok' : 'no'}` }, e.allowed ? 'allowed' : 'blocked'),
      !e.allowed && e.note !== 'plain http' ? h('button', { class: 'btn small', title: 'Add to the allow-list', onclick: guarded(async () => { const r = await api('POST', '/api/net/allow', { host: e.port === 443 ? e.host : `${e.host}:${e.port}` }); S.guard.allow = r.allow; renderSidebar(); fillDrawer(); }) }, 'Allow') : null))
      : h('p', { class: 'note' }, 'Nothing yet. Send a message and any connection Claude Code makes will show up here.'));
}

// ------------------------------------------------------------------ data flow
function renderAll() {
  renderSidebar(); renderHeader(); renderComposer(); renderMessages(); renderPerms();
  if (S.drawer) fillDrawer();
  scrollToBottom(true);
}
async function refreshState() {
  const st = await api('GET', '/api/state');
  Object.assign(S, { projects: st.projects, threads: st.threads, models: st.models, modes: st.modes, mock: st.mock, guard: st.guard });
  S.perms = new Map(st.perms.map((p) => [p.id, p]));
  S.busy = new Set(st.threads.filter((t) => t.busy).map((t) => t.id));
  if (S.cur) {
    const t = st.threads.find((x) => x.id === S.cur.thread.id);
    if (t) S.cur.thread = t; else S.cur = null;
  }
  renderSidebar(); renderHeader(); renderComposer(); renderPerms();
  if (!S.cur) { renderMessages(); }
  if (S.drawer === 'network') fillDrawer();
}
async function openThread(id) {
  const r = await api('GET', `/api/threads/${id}`);
  S.cur = { thread: r.thread, messages: r.messages };
  lsSet('ch.last', id);
  S.stick = true;
  renderAll();
  $('#input').focus();
}
async function newThread(projectId) {
  const t = await api('POST', '/api/threads', { projectId });
  await refreshState();
  await openThread(t.id);
}

function handleEvent(msg) {
  switch (msg.type) {
    case 'state': refreshState().catch(() => {}); break;
    case 'busy':
      msg.busy ? S.busy.add(msg.threadId) : S.busy.delete(msg.threadId);
      renderSidebar(); renderComposer();
      break;
    case 'perm':
      S.perms.set(msg.perm.id, msg.perm);
      renderSidebar(); renderPerms();
      if (S.cur?.thread.id === msg.perm.threadId) scrollToBottom(true);
      break;
    case 'perm_done':
      S.perms.delete(msg.id); renderSidebar(); renderPerms();
      break;
    case 'thread':
      if (S.cur && S.cur.thread.id === msg.threadId) {
        const i = apply(S.cur.messages, msg.ev);
        if (i >= 0) markDirty(i);
      }
      break;
    case 'net':
      S.guard.log.push(msg.entry);
      if (S.guard.log.length > 500) S.guard.log.shift();
      renderSidebar();
      if (S.drawer === 'network') fillDrawer();
      break;
    case 'allow': S.guard.allow = msg.allow; renderSidebar(); if (S.drawer === 'network') fillDrawer(); break;
    default: break;
  }
}
function connect() {
  const es = new EventSource('/api/events');
  es.onmessage = (e) => { try { handleEvent(JSON.parse(e.data)); } catch { /* ignore bad frame */ } };
  es.onopen = async () => {
    document.body.dataset.conn = '1';
    if (S.connectedOnce) {                 // we may have missed events: resync everything
      try { await refreshState(); if (S.cur) await openThread(S.cur.thread.id); } catch { /* retry on next event */ }
    }
    S.connectedOnce = true;
    renderSidebar();
  };
  es.onerror = () => { document.body.dataset.conn = '0'; renderSidebar(); };
}

(async function init() {
  buildShell();
  renderAddBox();
  try {
    await refreshState();
    const last = lsGet('ch.last');
    const pick = S.threads.find((t) => t.id === last) || [...S.threads].sort((a, b) => b.updatedAt - a.updatedAt)[0];
    if (pick) await openThread(pick.id); else renderAll();
  } catch (e) { toast(e.message); }
  connect();
})();
