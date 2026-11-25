#!/usr/bin/env node
// A stand-in for the `claude` binary that speaks Claude Code's stream-json protocol, as captured from the
// official Agent SDK (0.3.331) driving it. Lets the Swift client be tested with no network, no API key and no
// real binary. It was checked against the real Agent SDK (which drove it to record mac/Fixtures/turns) before
// the Node version was retired.
//
// It is strict on purpose: a missing flag, a missing CLAUDE_CODE_ENTRYPOINT, a user message before
// `initialize`, or a host that never closes stdin after the result make it fail loudly (stderr + exit code).
// The scenario comes from the prompt: "crash", "slow" (runs until stopped), "edit" (Edit tool, usually denied),
// anything else: a Bash command, then a sub-agent.
import readline from 'node:readline';

const argv = process.argv.slice(2);
const die = (code, msg) => { process.stderr.write(`fake-claude: ${msg}\n`); process.exit(code); };
for (const f of ['--output-format', 'stream-json', '--verbose', '--input-format', '--permission-prompt-tool=stdio', '--include-partial-messages']) {
  if (!argv.includes(f)) die(2, `missing argument ${f} (got: ${argv.join(' ')})`);
}
if (!process.env.CLAUDE_CODE_ENTRYPOINT) die(2, 'CLAUDE_CODE_ENTRYPOINT is not set');
const flag = (name) => { const a = argv.find((x) => x.startsWith(`${name}=`)); return a ? a.slice(name.length + 1) : undefined; };
const model = flag('--model') || 'fake-model';
const mode = flag('--permission-mode') || 'default';
const session = flag('--resume') || 'fake-session-1';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
const ev = (event, parent = null) => out({ type: 'stream_event', parent_tool_use_id: parent, session_id: session, event });
const say = async (text) => { for (const w of text.match(/\S+\s*/g) || []) { ev({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: w } }); await sleep(2); } };
const tool = (id, name, input, parent = null, msgId = `msg_${id}`) => out({ type: 'assistant', parent_tool_use_id: parent, session_id: session, message: { id: msgId, role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } });
const result = (id, content, isError = false, parent = null) => out({ type: 'user', parent_tool_use_id: parent, session_id: session, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content, is_error: isError }] } });

let initialized = false;
let stdinClosed = false;
const answers = new Map();
const ask = (requestId, request) => new Promise((resolve) => { answers.set(requestId, resolve); out({ type: 'control_request', request_id: requestId, request }); });

async function turn(prompt) {
  out({ type: 'system', subtype: 'init', session_id: session, model, cwd: process.cwd(), permissionMode: mode, tools: ['Bash', 'Edit', 'Read', 'Glob', 'Task'] });
  out({ type: 'system', subtype: 'status', status: 'requesting', session_id: session });
  ev({ type: 'message_start', message: { id: 'msg_1' } });
  ev({ type: 'content_block_start', index: 0, content_block: { type: 'thinking' } });
  await sleep(20);
  ev({ type: 'content_block_start', index: 1, content_block: { type: 'text' } });
  const intro = `Fake Claude (${mode}, ${model}). You said: ${prompt}\n\n`;
  await say(intro);
  if (/crash/i.test(prompt)) { process.stderr.write('fatal: the fake model fell over\n'); process.exit(3); }

  const edit = /edit/i.test(prompt);
  const slow = /slow/i.test(prompt);
  const name = edit ? 'Edit' : 'Bash';
  const input = edit
    ? { file_path: `${process.cwd()}/README.md`, old_string: 'old', new_string: 'new' }
    : { command: slow ? 'sleep 100' : 'ls', description: 'List files' };
  ev({ type: 'content_block_start', index: 2, content_block: { type: 'tool_use', id: 'toolu_A', name } });
  // the full assistant message repeats the streamed text; the host must not show it twice
  out({ type: 'assistant', parent_tool_use_id: null, session_id: session, message: { id: 'msg_1', role: 'assistant', content: [{ type: 'text', text: intro }, { type: 'tool_use', id: 'toolu_A', name, input }] } });
  await sleep(40);
  const r = await ask('perm-A', { subtype: 'can_use_tool', tool_name: name, input, tool_use_id: 'toolu_A', title: `Claude wants to use ${name}`, description: edit ? 'Edit README.md' : 'Run a command' });
  const d = r.response || {};
  const allowed = r.subtype === 'success' && d.behavior === 'allow' && d.toolUseID === 'toolu_A';
  await sleep(40);
  if (allowed && slow) {
    for (let sec = 1; ; sec++) { out({ type: 'tool_progress', tool_use_id: 'toolu_A', tool_name: name, parent_tool_use_id: null, elapsed_time_seconds: sec, session_id: session }); await sleep(100); }
  }
  if (allowed) {
    for (let sec = 1; sec <= 2; sec++) { out({ type: 'tool_progress', tool_use_id: 'toolu_A', tool_name: name, parent_tool_use_id: null, elapsed_time_seconds: sec, session_id: session }); await sleep(20); }
    result('toolu_A', [{ type: 'text', text: 'file-a\nfile-b' }]);
  } else {
    result('toolu_A', d.message || 'denied', true);
  }
  await sleep(40);
  if (allowed && !edit) {
    tool('toolu_T', 'Task', { description: 'Look around', prompt: 'Read the files', subagent_type: 'Explore' }, null, 'msg_1');
    await sleep(20);
    ev({ type: 'content_block_start', index: 0, content_block: { type: 'text' } }, 'toolu_T');   // sub-agent chatter: ignored
    tool('toolu_S1', 'Glob', { pattern: '**/*' }, 'toolu_T'); await sleep(20);
    result('toolu_S1', 'file-a', false, 'toolu_T'); await sleep(20);
    tool('toolu_S2', 'Read', { file_path: `${process.cwd()}/file-a` }, 'toolu_T'); await sleep(20);
    result('toolu_S2', 'contents', false, 'toolu_T'); await sleep(20);
    result('toolu_T', 'Two files.'); await sleep(40);
  }
  out({ type: 'system', subtype: 'api_retry', attempt: 1, max_retries: 10, retry_delay_ms: 10, error_status: 529, error: 'overloaded', session_id: session });
  await sleep(20);
  ev({ type: 'message_start', message: { id: 'msg_2' } });
  ev({ type: 'content_block_start', index: 0, content_block: { type: 'text' } });
  const outro = allowed ? 'All done — "quotes", ñ, 🚀.' : 'Understood, I did not do it.';
  await say(outro);
  out({ type: 'assistant', parent_tool_use_id: null, session_id: session, message: { id: 'msg_2', role: 'assistant', content: [{ type: 'text', text: outro }] } });
  out({ type: 'result', subtype: 'success', is_error: false, result: outro, total_cost_usd: 0.0123, num_turns: 3, duration_ms: 4321, session_id: session });
  setTimeout(() => { if (!stdinClosed) die(5, 'the host never closed stdin after the result'); }, 4000).unref();
}

readline.createInterface({ input: process.stdin })
  .on('line', (line) => {
    let m;
    try { m = JSON.parse(line); } catch { die(4, `not JSON on stdin: ${line.slice(0, 80)}`); }
    if (m.type === 'control_request' && m.request?.subtype === 'initialize') {
      initialized = true;
      out({ type: 'control_response', response: { subtype: 'success', request_id: m.request_id, response: { commands: [], models: [] } } });
    } else if (m.type === 'control_request') {
      out({ type: 'control_response', response: { subtype: 'error', request_id: m.request_id, error: `fake-claude does not support ${m.request?.subtype}` } });
    } else if (m.type === 'control_response') {
      answers.get(m.response?.request_id)?.(m.response);
    } else if (m.type === 'user') {
      if (!initialized) die(4, 'user message arrived before initialize');
      const c = m.message?.content;
      turn(typeof c === 'string' ? c : (c || []).map((b) => b.text || '').join('')).catch((e) => die(6, String(e)));
    }
  })
  .on('close', () => { stdinClosed = true; setTimeout(() => process.exit(0), 50); });
