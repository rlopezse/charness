// A small, safe markdown renderer. It builds DOM nodes with textContent only — never innerHTML —
// so model output can't inject markup or scripts. Supports: headings, paragraphs, lists (nested),
// block quotes, fenced code, inline code/bold/italic/links, simple tables, horizontal rules.

const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};

const INLINE = /(`[^`\n]+`|\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\s][^*\n]*\*|~~[^~\n]+~~|\[[^\]\n]+\]\([^)\s]+\))/g;

function inline(text, parent) {
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    if (m.index > last) parent.append(text.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith('`')) parent.append(el('code', 'ic', tok.slice(1, -1)));
    else if (tok.startsWith('**') || tok.startsWith('__')) { const b = el('strong'); inline(tok.slice(2, -2), b); parent.append(b); }
    else if (tok.startsWith('~~')) { const s = el('del'); inline(tok.slice(2, -2), s); parent.append(s); }
    else if (tok.startsWith('*')) { const i = el('em'); inline(tok.slice(1, -1), i); parent.append(i); }
    else {
      const lm = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(tok);
      if (lm && /^(https?:\/\/|mailto:)/i.test(lm[2])) {
        const a = el('a', null, lm[1]);
        a.href = lm[2]; a.target = '_blank'; a.rel = 'noopener noreferrer nofollow';
        parent.append(a);
      } else parent.append(tok);
    }
    last = m.index + tok.length;
  }
  if (last < text.length) parent.append(text.slice(last));
}

function codeBlock(lang, code) {
  const wrap = el('div', 'code');
  const head = el('div', 'codehead');
  head.append(el('span', null, lang || 'text'));
  const btn = el('button', 'copy', 'Copy');
  btn.type = 'button';
  btn.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(code); btn.textContent = 'Copied'; } catch { btn.textContent = 'Failed'; }
    setTimeout(() => { btn.textContent = 'Copy'; }, 1200);
  });
  head.append(btn);
  const pre = el('pre');
  pre.append(el('code', null, code));
  wrap.append(head, pre);
  return wrap;
}

const LIST_RE = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const TABLE_SEP = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/;
const splitRow = (l) => l.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());

function buildList(items, root) {
  // items: [{indent, ordered, text}] -> nested ul/ol
  const stack = [];
  for (const it of items) {
    while (stack.length && it.indent < stack[stack.length - 1].indent) stack.pop();
    let top = stack[stack.length - 1];
    if (!top || it.indent > top.indent) {
      const list = el(it.ordered ? 'ol' : 'ul');
      if (top) (top.list.lastElementChild || top.list).append(list); else root.append(list);
      top = { indent: it.indent, list };
      stack.push(top);
    }
    const li = el('li');
    inline(it.text, li);
    top.list.append(li);
  }
}

export function renderMarkdown(src) {
  const root = el('div', 'md');
  const lines = String(src).replace(/\r\n/g, '\n').split('\n');
  let i = 0;
  const isBlockStart = (l) => /^(#{1,6}\s|```|>\s?|\s*([-*_])\2\2+\s*$)/.test(l) || LIST_RE.test(l);

  while (i < lines.length) {
    const line = lines[i];

    const fence = /^```\s*([\w+#.-]*)\s*$/.exec(line);
    if (fence) {
      const buf = [];
      i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) buf.push(lines[i++]);
      i++;                                   // closing fence (may be missing while streaming)
      root.append(codeBlock(fence[1], buf.join('\n')));
      continue;
    }
    if (/^\s*$/.test(line)) { i++; continue; }

    const hd = /^(#{1,6})\s+(.*)$/.exec(line);
    if (hd) { const h = el(`h${Math.min(hd[1].length + 2, 6)}`); inline(hd[2], h); root.append(h); i++; continue; }

    if (/^\s*([-*_])\1\1+\s*$/.test(line)) { root.append(el('hr')); i++; continue; }

    if (/^>\s?/.test(line)) {
      const buf = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) buf.push(lines[i++].replace(/^>\s?/, ''));
      const bq = el('blockquote');
      bq.append(renderMarkdown(buf.join('\n')));
      root.append(bq);
      continue;
    }

    if (line.includes('|') && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1])) {
      const head = splitRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].includes('|') && !/^\s*$/.test(lines[i])) rows.push(splitRow(lines[i++]));
      const table = el('table');
      const thead = el('thead'); const tr = el('tr');
      for (const c of head) { const th = el('th'); inline(c, th); tr.append(th); }
      thead.append(tr); table.append(thead);
      const tbody = el('tbody');
      for (const r of rows) { const trr = el('tr'); for (const c of r) { const td = el('td'); inline(c, td); trr.append(td); } tbody.append(trr); }
      table.append(tbody);
      const wrap = el('div', 'tablewrap'); wrap.append(table);
      root.append(wrap);
      continue;
    }

    if (LIST_RE.test(line)) {
      const items = [];
      while (i < lines.length) {
        const lm = LIST_RE.exec(lines[i]);
        if (lm) { items.push({ indent: lm[1].replace(/\t/g, '    ').length, ordered: /\d/.test(lm[2]), text: lm[3] }); i++; }
        else if (/^\s+\S/.test(lines[i]) && items.length && !isBlockStart(lines[i])) { items[items.length - 1].text += ` ${lines[i].trim()}`; i++; }
        else break;
      }
      buildList(items, root);
      continue;
    }

    const buf = [];
    while (i < lines.length && !/^\s*$/.test(lines[i]) && !isBlockStart(lines[i]) &&
           !(lines[i].includes('|') && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1]))) buf.push(lines[i++]);
    if (!buf.length) { buf.push(lines[i++]); }
    const p = el('p');
    buf.forEach((l, k) => { if (k) p.append(el('br')); inline(l, p); });
    root.append(p);
  }
  return root;
}
