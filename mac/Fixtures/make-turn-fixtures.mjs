// Regenerates mac/Fixtures/turns/*.json: what lib/agent.mjs's runTurn() (with the real Agent SDK) reports
// while it drives fake-claude.mjs through a few scenarios. The Swift port must report exactly the same.
//     node mac/Fixtures/make-turn-fixtures.mjs
// Each file is a list of { kind: 'event' | 'activity' | 'permission', ... } in the order they happened.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
process.env.HARNESS_CLAUDE_BIN = path.join(HERE, 'fake-claude.mjs');
const { runTurn } = await import(path.join(HERE, '..', '..', 'lib', 'agent.mjs'));
const DENY = 'The user denied this action. Do not retry it; ask what they would like instead.';

const scenarios = [
  { name: 'allow', prompt: 'list the files', allow: true, resume: null },
  { name: 'deny', prompt: 'edit the readme', allow: false, resume: 'prev-session-7' },
  { name: 'crash', prompt: 'crash please', allow: true, resume: null },
  { name: 'stop', prompt: 'a slow command', allow: true, resume: null, stopAfterMs: 300 },
  // the built-in mock backend (npm run mock): no claude process at all
  { name: 'mock-allow', prompt: 'hello there', allow: true, resume: null, mock: true, mode: 'default' },
  { name: 'mock-deny', prompt: 'edit something', allow: false, resume: 'prev-session-9', mock: true },
  { name: 'mock-plan', prompt: 'show me the plan', allow: true, resume: null, mock: true, mode: 'plan' },
];

// The mock makes up random ids (mock-…, toolu_…, msg_…): number them in order of appearance instead.
function normalizeIds(text) {
  const seen = new Map();
  return text.replace(/\b(mock-[0-9a-z]+|toolu_[0-9a-z]+|msg_[0-9a-z_]+)\b/g, (id) => {
    const kind = id.startsWith('mock-') ? 'SESSION' : id.startsWith('toolu_') ? 'TOOLU' : 'MSG';
    if (!seen.has(id)) seen.set(id, `$${kind}_${[...seen.keys()].filter((k) => k.slice(0, 4) === id.slice(0, 4)).length + 1}`);
    return seen.get(id);
  });
}

const OUT = path.join(HERE, 'turns');
fs.mkdirSync(OUT, { recursive: true });
const only = process.argv[2];                    // optional: one scenario by name
for (const sc of scenarios.filter((x) => !only || x.name === only)) {
  const cwd = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'charness-turn-')));   // macOS: /var -> /private/var
  const log = [];
  const abort = new AbortController();
  let stopTimer = null;
  await runTurn({
    thread: { model: 'claude-sonnet-5-5', sessionId: sc.resume },
    project: { path: cwd },
    text: sc.prompt,
    sdkMode: sc.mode || 'acceptEdits',
    abort,
    mock: !!sc.mock,
    env: { PATH: process.env.PATH, HOME: process.env.HOME },
    emit: (ev) => log.push({ kind: 'event', ev }),
    activity: (a) => {
      log.push({ kind: 'activity', now: a.now, steps: a.steps.map((st) => ({ ...st })) });   // snapshot: steps change later
      // "stop" scenario: press Stop a moment after the slow command starts (its progress adds no events)
      if (sc.stopAfterMs && !stopTimer && /^Bash: sleep/.test(a.now || '')) stopTimer = setTimeout(() => abort.abort(), sc.stopAfterMs);
    },
    canUseTool: async (name, input, o) => {
      log.push({ kind: 'permission', name, input, toolUseID: o.toolUseID, title: o.title, description: o.description });
      return sc.allow ? { behavior: 'allow', updatedInput: input } : { behavior: 'deny', message: DENY };
    },
  });
  // the temp folder differs on every run (and between Node and Swift): store it as $CWD / $FOLDER
  let text = JSON.stringify(log, null, 1).split(cwd).join('$CWD').split(path.basename(cwd)).join('$FOLDER');
  if (sc.mock) text = normalizeIds(text);
  fs.writeFileSync(path.join(OUT, `${sc.name}.json`), `${text}\n`);
  fs.rmSync(cwd, { recursive: true, force: true });
  console.log(`${sc.name}: ${log.length} entries`);
}
