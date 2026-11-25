// Regenerates mac/Fixtures/markdown.json: the element tree public/md.js builds for many Markdown samples, so the
// Swift port (CharnessCore/Markdown.swift) that the native screens draw from can be required to give the same tree.
//     node mac/Fixtures/make-markdown-fixtures.mjs
// md.js only needs document.createElement, so a tiny fake DOM is enough; each node is written as
// [tag, {attributes}, ...children] and text as a plain string (adjacent text merged, as the browser shows it).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

class Node {
  constructor(tag) { this.tag = tag; this.kids = []; this.attrs = {}; }
  set className(v) { this.attrs.class = v; }
  set textContent(v) { this.kids = [String(v)]; }
  set href(v) { this.attrs.href = v; }
  set target(v) { this.attrs.target = v; }
  set rel(v) { this.attrs.rel = v; }
  set type(v) { /* the copy button's type=button: not content */ }
  append(...xs) { for (const x of xs) this.kids.push(typeof x === 'string' ? x : x); }
  get lastElementChild() { for (let i = this.kids.length - 1; i >= 0; i--) if (typeof this.kids[i] !== 'string') return this.kids[i]; return null; }
  addEventListener() {}
}
globalThis.document = { createElement: (t) => new Node(t) };
const { renderMarkdown, linkify } = await import('../../public/md.js');

const tree = (n) => {
  const out = [n.tag, n.attrs];
  for (const k of n.kids) {
    const v = typeof k === 'string' ? k : tree(k);
    if (typeof v === 'string' && typeof out[out.length - 1] === 'string' && out.length > 2) out[out.length - 1] += v;
    else if (v !== '') out.push(v);
  }
  return out;
};

const samples = {
  'plain paragraph': 'Hello, world.',
  'two lines make one paragraph with a break': 'line one\nline two',
  'paragraphs split by a blank line': 'one\n\ntwo\n\n\nthree',
  'headings (shifted two levels, max h6)': '# One\n## Two\n### Three\n#### Four\n###### Six\n####### seven is not one\n#nospace',
  'inline styles': 'a **bold** and __bold__ and *em* and `code` and ~~gone~~ end',
  'nested inline': '**bold with *em* and `code` inside** and *em with **bold***',
  'star rules for em': 'a * b * c and 2*3*4 and *x*',
  'links: only http(s) and mailto': 'see [docs](https://example.com/a?b=1) or [mail](mailto:a@b.c) or [js](javascript:alert(1)) or [rel](/x)',
  'link text with styles is kept as text': '[**b**](http://x.y)',
  'code fence with language': '```swift\nlet x = 1\n  indented\n\n```\nafter',
  'code fence without language, never closed (streaming)': '```\nstill typing',
  'code fence keeps markdown as is': '```md\n# not a heading\n**not bold**\n```',
  'odd fence info': '```c++ \nint x;\n```\n``` objective-c.m\n@end\n```',
  'unordered list': '- one\n- two\n* three\n+ four',
  'ordered list': '1. one\n2) two\n10. ten',
  'nested lists': '- a\n  - a1\n  - a2\n    1. deep\n- b\n\tl- tab\n\t- tabbed child',
  'list then dedent to a shallower level than the first': '  - indented first\n- outer\n    - deeper',
  'list continuation lines': '- item one\n  continues here\n- item two\nnot a continuation',
  'list item that starts nested with no parent item': '  - lone',
  'ordered list nested in unordered': '- x\n   1. y\n   2. z\n- w',
  'block quote': '> quoted **text**\n> second line\n>\n> # heading in quote\nafter',
  'nested quote': '> > deep\n> shallow',
  'horizontal rules': 'a\n\n---\n\n***\n___\n- - -\nb',
  'table': '| a | **b** |\n|---|:--:|\n| 1 | `2` |\n| 3 | 4 |\n\nafter',
  'table without outer pipes': 'a | b\n--- | ---\n1 | 2',
  'table needs a separator line': '| a | b |\n| 1 | 2 |',
  'table rows end at a line without a pipe': '| h |\n| -- |\n| r |\nplain',
  'paragraph stops before a block': 'text\n# heading\nmore\n- list\nend\n```\ncode\n```',
  'paragraph stops before a table': 'intro\n| a | b |\n|---|---|\n| 1 | 2 |',
  'windows line endings': 'a\r\nb\r\n\r\n- c\r\n',
  'only spaces': '   \n\t\n',
  'empty': '',
  'unicode and emoji': 'Ñandú 😀 **café** `naïve`',
  'unclosed markers stay as text': '**open and *open and `open and ~~open and [x](',
  'a greater-than without space': '>tight',
  'heading text with inline': '## The `run()` **step**',
  'list item with inline': '- **bold** item with [link](https://a.b)',
  'bare addresses become links': 'Open http://localhost:5173/ or https://example.com/a?b=1&c=2#x now',
  'trailing punctuation is not part of the address': 'See https://example.com. Or (https://example.com/wiki/A_(b)) and https://x.io/path, then "https://q.org".',
  'a code span that is just an address': 'Server at `http://localhost:3000` and `curl http://x.io` and `https://` alone',
  'addresses inside styles and lists': '- **docs: https://docs.example.com/start**\n- *see http://a.b/c*\n- [named](https://n.example) vs https://n.example',
  'not addresses': 'ftp://x.y and http:// and https://?q and javascript:alert(1) and HTTP://UPPER.example',
  'claude style answer': "I'll check the files.\n\n## Summary\n\n- Updated `server.swift`:\n  - added a route\n- Ran the tests\n\n```bash\nnpm test\n```\n\n| File | Change |\n|------|--------|\n| a.swift | +3 |\n\n> Note: nothing else changed.",
};

// plain text (command output, the user's own message): only the addresses become links
const plain = {
  'command output with a dev server address': '  VITE v5.0.0  ready in 300 ms\n\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host to expose\n',
  'several addresses, punctuation around them': 'Deployed to https://app.example.com, docs at <https://docs.example.com>; (see http://x.y/z).',
  'every trailing character that is not part of an address': 'https://a.io/x; https://b.io/y! https://c.io/z? [https://d.io/w] {https://e.io/v} https://f.io/u: *https://g.io/t* _https://h.io/s_ https://i.io/r,',
  'no address': 'nothing to link here: http:// alone',
};

const out = [
  ...Object.entries(samples).map(([name, src]) => ({ name, src, tree: tree(renderMarkdown(src)) })),
  ...Object.entries(plain).map(([name, src]) => ({ name, src, plain: true, tree: tree(linkify(src, document.createElement('pre'))) })),
];
fs.writeFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'markdown.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(`wrote ${out.length} samples`);
