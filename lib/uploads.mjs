// Files attached to a message. Kept per thread in ~/.charness/uploads/<threadId>/ (folders 0700, files 0600),
// outside the project so nothing lands in your repo. For each turn Claude gets read access to that folder
// (--add-dir) and the message lists the files' paths; Claude reads them with its Read tool (text, code,
// images, PDFs) or, for other formats, with commands you approve. Files are never served back to the browser,
// so an uploaded .html or .svg can't run inside the app.
import fs from 'node:fs';
import path from 'node:path';
import { HOME } from './store.mjs';

export const MAX_FILE_BYTES = 25 * 1024 * 1024;
export const MAX_FILES_PER_MESSAGE = 10;

const ROOT = path.join(HOME, 'uploads');
/** The thread's upload folder. Thread ids are lowercase hex (checked by the routes), so this stays in ROOT. */
export const dirFor = (threadId) => path.join(ROOT, threadId);

/** A file name that is safe to store: no folders, no control characters, no hidden files, not too long. */
export function safeName(raw) {
  let n = String(raw ?? '').split(/[\\/]/).pop();
  n = n.replace(/[\u0000-\u001f\u007f<>:"|?*]/g, '_').replace(/^[.\s]+/, '').trim();
  if (n.length > 120) {
    const ext = path.extname(n).slice(0, 16);
    n = n.slice(0, 120 - ext.length).trimEnd() + ext;
  }
  return n || 'file';
}

/** Stores the bytes under a free name ("notes.txt", then "notes (2).txt"...). Returns { name, size }. */
export function save(threadId, rawName, bytes) {
  const dir = dirFor(threadId);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const name = safeName(rawName);
  const ext = path.extname(name);
  const base = name.slice(0, name.length - ext.length) || name;
  for (let n = 1; n < 1000; n++) {
    const candidate = n === 1 ? name : `${base} (${n})${ext}`;
    let fd;
    try { fd = fs.openSync(path.join(dir, candidate), 'wx', 0o600); } catch (e) { if (e.code === 'EEXIST') continue; throw e; }
    try { fs.writeSync(fd, bytes); } finally { fs.closeSync(fd); }
    return { name: candidate, size: bytes.length };
  }
  throw new Error('too many files with that name');
}

/** { name, size, path } for a file stored for this thread, or null (unknown name, folder tricks, not a file). */
export function find(threadId, name) {
  if (typeof name !== 'string' || !name || name !== safeName(name)) return null;
  const p = path.join(dirFor(threadId), name);
  try {
    const st = fs.lstatSync(p);
    return st.isFile() ? { name, size: st.size, path: p } : null;
  } catch { return null; }
}

/** The folder to give Claude read access to, if this thread has any files. */
export const folderIfAny = (threadId) => (fs.existsSync(dirFor(threadId)) ? dirFor(threadId) : null);

/** Deletes the thread's files (when the thread or its project is deleted). */
export function removeAll(threadId) {
  fs.rmSync(dirFor(threadId), { recursive: true, force: true });
}
