// Regenerates mac/Fixtures/reducer.json: what public/reduce.js does with many event sequences, so the Swift
// port (CharnessCore/Reducer.swift) can be required to produce byte-identical thread files.
//     node mac/Fixtures/make-reducer-fixtures.mjs
// Sequences: every recorded turn in turns/*.json (real SDK runs and the mock), plus hand-made edge cases.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { apply, toolSummary } from '../../public/reduce.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const user = (text, ts, files) => (files ? { t: 'user', text, files, ts } : { t: 'user', text, ts });
const sequences = [];

// 1. the events of each recorded turn, after the user's message (as the server folds them)
for (const f of fs.readdirSync(path.join(HERE, 'turns')).sort()) {
  const log = JSON.parse(fs.readFileSync(path.join(HERE, 'turns', f), 'utf8'));
  const events = log.filter((e) => e.kind === 'event').map((e) => e.ev);
  sequences.push({ name: `turn ${f.replace('.json', '')}`, events: [user('the prompt', 1795549492136), ...events] });
}
// two turns in a row in one thread
sequences.push({ name: 'two turns', events: [...sequences[0].events, user('and again', 1795549499000), ...sequences[1].events.slice(1)] });

// 2. edge cases
const edge = {
  'user with files': [user('', 1, [{ name: 'a.txt', size: 3 }, { name: 'b ñ.png', size: 179 }])],
  'user with empty files list': [user('hi', 2, [])],
  'user without ts': [{ t: 'user', text: 'no ts' }],
  'delta starts an assistant message': [{ t: 'delta', text: 'Hello' }, { t: 'delta', text: ', world' }],
  'text after a tool is a new block': [{ t: 'delta', text: 'a' }, { t: 'tool_use', id: 'x', name: 'Bash', input: { command: 'ls' } }, { t: 'delta', text: 'b' }, { t: 'delta', text: 'c' }],
  'duplicate tool_use is ignored': [{ t: 'tool_use', id: 'x', name: 'Bash', input: {} }, { t: 'tool_use', id: 'x', name: 'Edit', input: {} }],
  'tool_use without input': [{ t: 'tool_use', id: 'x', name: 'Bash' }],
  'result for an unknown tool': [{ t: 'tool_result', id: 'nope', output: 'x', isError: false }],
  'denied stays denied after its result': [{ t: 'tool_use', id: 'x', name: 'Edit', input: {} }, { t: 'tool_denied', id: 'x' }, { t: 'tool_result', id: 'x', output: 'denied', isError: true }],
  'denied for an unknown tool': [{ t: 'tool_denied', id: 'nope' }],
  'error result': [{ t: 'tool_use', id: 'x', name: 'Bash', input: {} }, { t: 'tool_result', id: 'x', output: 'boom', isError: true }],
  'result without output': [{ t: 'tool_use', id: 'x', name: 'Bash', input: {} }, { t: 'tool_result', id: 'x', isError: false }],
  'result twice: second wins': [{ t: 'tool_use', id: 'x', name: 'Bash', input: {} }, { t: 'tool_result', id: 'x', output: 'one', isError: true }, { t: 'tool_result', id: 'x', output: 'two', isError: false }],
  'result finds the tool in an earlier message': [{ t: 'tool_use', id: 'x', name: 'Bash', input: {} }, user('meanwhile', 5), { t: 'error', text: 'oops' }, { t: 'tool_result', id: 'x', output: 'late', isError: false }],
  'end without an assistant message': [user('hi', 6), { t: 'end', cost: 0.1, turns: 1, ms: 5 }],
  'end with missing fields': [{ t: 'delta', text: 'a' }, { t: 'end' }],
  'end twice replaces done': [{ t: 'delta', text: 'a' }, { t: 'end', cost: 0.5, turns: 1, ms: 1 }, { t: 'end', cost: 0.25, turns: 2, ms: 2 }],
  'error becomes a system message': [{ t: 'error', text: 'Claude Code process exited with code 3\n\nfatal' }],
  'error then delta starts a new assistant message': [{ t: 'delta', text: 'a' }, { t: 'error', text: 'x' }, { t: 'delta', text: 'b' }],
  'unknown event types change nothing': [{ t: 'session', sessionId: 's', model: 'm' }, { t: 'nonsense' }, { t: 'delta', text: 'a' }],
  'numbers and unicode in events': [{ t: 'delta', text: 'ñ 🚀 "q" \\ \u0001' }, { t: 'tool_use', id: 'x', name: 'Bash', input: { n: 1.5e-7, big: 1e21, neg: -0, arr: [1, 'two', null, true] } }],
};
for (const [name, events] of Object.entries(edge)) sequences.push({ name, events, snapshots: true });

const out = { sequences: [], toolSummary: [] };
for (const sq of sequences) {
  const msgs = [];
  const indexes = [];
  const snapshots = [];
  for (const ev of sq.events) {
    indexes.push(apply(msgs, structuredClone(ev)));
    if (sq.snapshots) snapshots.push(JSON.stringify(msgs));
  }
  out.sequences.push({ name: sq.name, events: sq.events, indexes, ...(sq.snapshots ? { snapshots } : {}), final: JSON.stringify(msgs) });
}

// 3. toolSummary()
const long = 'x'.repeat(150);
const cases = [
  ['Bash', { command: 'npm test\nsecond line' }], ['Bash', { command: long }], ['Bash', { command: 42 }], ['Bash', {}], ['Bash', null],
  ['Read', { file_path: '/a/b.js' }], ['Write', { file_path: '' , notebook_path: '/n.ipynb' }], ['NotebookEdit', { notebook_path: '/n.ipynb' }],
  ['Edit', { file_path: '/ñ/🚀.txt' }], ['MultiEdit', {}],
  ['Grep', { pattern: 'TODO', path: 'src' }], ['Grep', { pattern: 'TODO' }], ['Grep', { path: 'src' }], ['Grep', { pattern: 'a', path: '' }],
  ['Glob', { pattern: '**/*.ts' }], ['WebFetch', { url: 'https://example.com/x' }], ['WebSearch', { query: 'swift json' }],
  ['Task', { description: 'Look around', prompt: 'p' }], ['Agent', { description: 'Explore' }],
  ['TodoWrite', { todos: [{}, {}, {}] }], ['TodoWrite', {}],
  ['mcp__x__y', { count: 3, label: 'first string', other: 'second' }], ['Mystery', { a: 1, b: true }], ['Mystery', {}],
  ['Bash', { command: `${'é'.repeat(139)}éñ` }],
];
for (const [name, input] of cases) out.toolSummary.push({ name, input, summary: toolSummary(name, input) });

fs.writeFileSync(path.join(HERE, 'reducer.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(`${out.sequences.length} sequences, ${out.toolSummary.length} toolSummary cases`);
