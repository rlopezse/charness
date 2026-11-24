// Tiny JSON persistence. Everything lives under ~/.charness (override: HARNESS_HOME).
// Files are created 0600 / dirs 0700 because conversations can contain sensitive code.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

export const HOME = process.env.HARNESS_HOME || path.join(os.homedir(), '.charness');
const THREADS = path.join(HOME, 'threads');
fs.mkdirSync(THREADS, { recursive: true, mode: 0o700 });

function writeAtomic(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, data, { mode: 0o600 });
  fs.renameSync(tmp, file);
}
function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

const stateFile = path.join(HOME, 'state.json');
export const state = Object.assign(
  { projects: [], threads: [], allowHosts: [] },
  readJson(stateFile, {}),
);

export const newId = () => crypto.randomBytes(6).toString('hex');

// ---- debounced writers -------------------------------------------------
let stateTimer = null;
const dirty = new Set();       // thread ids whose messages need writing
let msgTimer = null;
const cache = new Map();       // threadId -> { messages: [] }

function flushState() {
  if (stateTimer) { clearTimeout(stateTimer); stateTimer = null; }
  writeAtomic(stateFile, JSON.stringify(state, null, 2));
}
function flushMessages() {
  if (msgTimer) { clearTimeout(msgTimer); msgTimer = null; }
  for (const id of dirty) {
    const t = cache.get(id);
    if (t) writeAtomic(path.join(THREADS, `${id}.json`), JSON.stringify(t));
  }
  dirty.clear();
}

export function saveState() {
  if (!stateTimer) stateTimer = setTimeout(flushState, 200);
}
export function saveMessages(id) {
  dirty.add(id);
  if (!msgTimer) msgTimer = setTimeout(flushMessages, 400);
}
export function flushAll() { flushState(); flushMessages(); }

// ids always come from state.threads (never straight from a URL) before touching disk
export function loadThread(id) {
  if (!cache.has(id)) cache.set(id, readJson(path.join(THREADS, `${id}.json`), { messages: [] }));
  return cache.get(id);
}
export function deleteThreadFiles(id) {
  cache.delete(id);
  dirty.delete(id);
  try { fs.unlinkSync(path.join(THREADS, `${id}.json`)); } catch { /* already gone */ }
}
