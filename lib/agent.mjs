// Bridge to the Claude Agent SDK (which runs the Claude Code binary as a child process).
// This file decides exactly what that child process is allowed to see:
//   * an allow-listed environment (your other secrets are NOT inherited),
//   * telemetry/error-reporting/update checks forced off,
//   * all network traffic routed through the local egress guard.
import path from 'node:path';
import { toolSummary } from '../public/reduce.js';

const PASS = new Set([
  // basics
  'PATH', 'HOME', 'USER', 'USERNAME', 'LOGNAME', 'SHELL', 'LANG', 'LANGUAGE', 'LC_ALL', 'LC_CTYPE',
  'LC_MESSAGES', 'TERM', 'TMPDIR', 'TMP', 'TEMP', 'TZ',
  'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR',
  // windows
  'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'PATHEXT', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
  'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMDATA', 'HOMEDRIVE', 'HOMEPATH', 'SYSTEMDRIVE',
  // how Claude authenticates
  'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_OAUTH_TOKEN',
  'CLAUDE_CONFIG_DIR',
  // custom CA bundles
  'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_EXTRA_CA_CERTS', 'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE',
]);

const FORCED = {
  DISABLE_TELEMETRY: '1',
  DISABLE_ERROR_REPORTING: '1',
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
  CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY: '1',
  CLAUDE_CODE_ENABLE_TELEMETRY: '0',
  DISABLE_AUTOUPDATER: '1',
  DISABLE_BUG_COMMAND: '1',
  DO_NOT_TRACK: '1',
};

/** Allow-listed slice of the current environment (+ anything in HARNESS_PASS_ENV). */
export function baseEnv() {
  const extra = (process.env.HARNESS_PASS_ENV || '').split(',').map((s) => s.trim().toUpperCase()).filter(Boolean);
  const out = {};
  for (const [k, v] of Object.entries(process.env)) {
    const K = k.toUpperCase();
    if (v != null && (PASS.has(K) || extra.includes(K))) out[k] = v;
  }
  return out;
}

export function buildEnv({ guardPort } = {}) {
  const env = { ...baseEnv(), ...FORCED };
  if (guardPort) {
    const url = `http://127.0.0.1:${guardPort}`;
    for (const k of ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy']) env[k] = url;
    // NO_PROXY from your shell is intentionally NOT passed through: it could bypass the guard.
  }
  return env;
}

function clipInput(input) {
  const out = {};
  for (const [k, v] of Object.entries(input || {})) {
    out[k] = typeof v === 'string' && v.length > 20000 ? `${v.slice(0, 20000)}\n…[truncated]` : v;
  }
  return out;
}
export { clipInput };

const stringify = (c) => {
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map((x) => (x?.type === 'text' ? x.text : `[${x?.type || 'data'}]`)).join('\n');
  try { return JSON.stringify(c, null, 2); } catch { return String(c); }
};

// Live "what is Claude doing right now" feed, like the Claude Code terminal shows. Not saved anywhere:
// `now` is the current step (with `since`, when it started), `steps` the latest tool calls of this turn,
// including the ones sub-agents make (sub: true), each running / ok / error.
const MAX_STEPS = 8;
function activityTracker(report) {
  const steps = [];
  const byId = new Map();
  let now = null;
  let since = Date.now();
  const send = () => report({ now, since, steps: steps.slice(-MAX_STEPS) });
  const label = (st) => (st.sub ? `↳ ${st.text}` : st.text);
  return {
    now(text) { if (text === now) return; now = text; since = Date.now(); send(); },
    tool(id, name, input, sub) {
      if (!id || byId.has(id)) return;
      const summary = toolSummary(name, input);
      const st = { id, text: summary ? `${name}: ${summary}` : name, sub: !!sub, status: 'running' };
      steps.push(st); byId.set(id, st);
      if (steps.length > 200) byId.delete(steps.shift().id);
      now = label(st); since = Date.now(); send();
    },
    running(id) { const st = byId.get(id); if (st) this.now(label(st)); },
    result(id, isError) {
      const st = byId.get(id);
      if (st && st.status === 'running') { st.status = isError ? 'error' : 'ok'; send(); }
    },
    end() { now = null; send(); },
  };
}

/**
 * One user turn. Resumes the previous Claude session (sessionId) so context carries over.
 * Emits UI events through emit(); permission prompts go through canUseTool(); the live activity feed
 * goes to activity() (optional). addDirs: extra folders Claude may read (the thread's attachments).
 */
export async function runTurn({ thread, project, text, sdkMode, abort, emit, canUseTool, env, mock, activity = () => {}, addDirs = [] }) {
  const act = activityTracker(activity);
  const options = {
    cwd: project.path,
    model: thread.model || undefined,
    permissionMode: sdkMode,
    resume: thread.sessionId || undefined,
    abortController: abort,
    includePartialMessages: true,
    settingSources: ['project'],
    systemPrompt: { type: 'preset', preset: 'claude_code' },
    disallowedTools: ['AskUserQuestion'],
    env,
    canUseTool: async (name, input, o) => {
      act.now(`Waiting for your approval: ${name}`);
      const r = await canUseTool(name, input, o);
      if (r.behavior === 'allow') act.running(o.toolUseID); else act.now('Thinking…');
      return r;
    },
    pathToClaudeCodeExecutable: process.env.HARNESS_CLAUDE_BIN || undefined,
  };
  if (sdkMode === 'bypassPermissions') options.allowDangerouslySkipPermissions = true;
  if (addDirs.length) options.additionalDirectories = addDirs;   // e.g. the thread's attached files

  let stderrTail = '';
  options.stderr = (d) => { stderrTail = (stderrTail + d).slice(-1500); };

  const streamed = new Set();
  let shown = '';            // assistant text already sent to the UI (to avoid repeating errors)
  let gotResult = false;
  const say = (text) => { shown += text; emit({ t: 'delta', text }); };
  act.now('Starting Claude Code…');
  try {
    const query = mock
      ? mockQuery
      : (await import('@anthropic-ai/claude-agent-sdk')).query;

    for await (const msg of query({ prompt: text, options })) {
      switch (msg.type) {
        case 'system':
          if (msg.subtype === 'init') { emit({ t: 'session', sessionId: msg.session_id, model: msg.model }); act.now('Thinking…'); }
          if (msg.subtype === 'status' && msg.status === 'compacting') act.now('Compacting the conversation…');
          if (msg.subtype === 'api_retry') {
            act.now(`Claude API error${msg.error_status ? ` ${msg.error_status}` : ''}, retrying (${msg.attempt}/${msg.max_retries})…`);
          }
          break;

        case 'tool_progress':                                // a tool is still running (sent about once a second)
          act.running(msg.tool_use_id);
          break;

        case 'stream_event': {
          if (msg.parent_tool_use_id) break;               // ignore sub-agent chatter
          const e = msg.event;
          if (e?.type === 'content_block_start') {
            const kind = e.content_block?.type;
            if (kind === 'thinking' || kind === 'redacted_thinking') act.now('Thinking…');
            else if (kind === 'text') act.now('Writing…');
            else if (kind === 'tool_use') act.now(`Preparing ${e.content_block.name}…`);
          }
          if (e?.type === 'message_start' && e.message?.id) streamed.add(e.message.id);
          if (e?.type === 'content_block_delta' && e.delta?.type === 'text_delta') say(e.delta.text);
          break;
        }

        case 'assistant': {
          if (msg.parent_tool_use_id) {                    // a sub-agent's step: shown live only, not saved
            for (const b of msg.message?.content || []) if (b.type === 'tool_use') act.tool(b.id, b.name, b.input, true);
            break;
          }
          const id = msg.message?.id;
          for (const b of msg.message?.content || []) {
            if (b.type === 'text' && b.text && !streamed.has(id)) say(b.text);
            if (b.type === 'tool_use') { emit({ t: 'tool_use', id: b.id, name: b.name, input: clipInput(b.input) }); act.tool(b.id, b.name, b.input, false); }
          }
          break;
        }

        case 'user': {
          const content = msg.message?.content;
          if (Array.isArray(content)) for (const b of content) if (b.type === 'tool_result') act.result(b.tool_use_id, !!b.is_error);
          if (msg.parent_tool_use_id) break;
          if (Array.isArray(content)) {
            for (const b of content) {
              if (b.type === 'tool_result') {
                emit({ t: 'tool_result', id: b.tool_use_id, output: stringify(b.content).slice(0, 8000), isError: !!b.is_error });
                act.now('Thinking…');
              }
            }
          }
          break;
        }

        case 'result': {
          gotResult = true;
          if (msg.is_error || msg.subtype !== 'success') {
            const why = msg.is_error && msg.result ? msg.result : `Run ended: ${msg.subtype}${msg.errors?.length ? ` — ${msg.errors.join('; ')}` : ''}`;
            if (!shown.includes(why)) emit({ t: 'error', text: why });
            if (/invalid api key|not logged in|please run \/login|authentication/i.test(why)) {
              emit({ t: 'error', text: 'Authentication failed. Start the harness from a terminal that has ANTHROPIC_API_KEY set, or log in first with `claude auth login` (Claude Code CLI).' });
            }
          }
          emit({ t: 'end', cost: msg.total_cost_usd, turns: msg.num_turns, ms: msg.duration_ms });
          act.end();
          break;
        }
        default: break;
      }
    }
  } catch (err) {
    if (abort.signal.aborted) {
      emit({ t: 'error', text: 'Stopped.' });
    } else if (gotResult) {
      // the SDK also throws after an error result; we already reported it above
    } else {
      // The SDK's message already ends in ". stderr: <tail>"; keep its first part and show the tail once.
      const what = String(err?.message || err).split('. stderr: ')[0];
      const tail = stderrTail.trim();
      emit({ t: 'error', text: `${what}${tail ? `\n\n${tail}` : ''}` });
    }
  }
}

// ---------------------------------------------------------------------------
// Mock backend (npm run mock): same message shapes as the real SDK, no network, no API key.
// Lets you try the UI and test the permission flow safely.
// ---------------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function* mockQuery({ prompt, options }) {
  const signal = options.abortController.signal;
  const sid = options.resume || `mock-${Date.now().toString(36)}`;
  yield { type: 'system', subtype: 'init', session_id: sid, model: options.model || 'mock-model' };

  const msgId = `msg_${Math.random().toString(36).slice(2)}`;
  const say = async function* (text) {
    for (const w of text.match(/\S+\s*/g) || []) {
      if (signal.aborted) throw new Error('aborted');
      await sleep(12);
      yield { type: 'stream_event', parent_tool_use_id: null, event: { type: 'content_block_delta', delta: { type: 'text_delta', text: w } } };
    }
  };
  const rid = () => `toolu_${Math.random().toString(36).slice(2)}`;
  const block = (kind) => ({ type: 'stream_event', parent_tool_use_id: null, event: { type: 'content_block_start', content_block: { type: kind } } });
  yield { type: 'stream_event', parent_tool_use_id: null, event: { type: 'message_start', message: { id: msgId } } };
  yield block('thinking');
  await sleep(250);
  yield block('text');

  const wantsEdit = /edit|write|change/i.test(prompt);
  const intro = wantsEdit
    ? `Mock mode (${options.permissionMode}). I'll make a small edit in \`${path.basename(options.cwd)}\`.\n\n`
    : `Mock mode (${options.permissionMode}) — no real model is called here.\n\nYou said: **${prompt.slice(0, 80)}**\n\nHere's some formatting to check the renderer:\n\n- a list item with \`inline code\`\n- another with a [link](https://example.com)\n\n| Tool | Needs approval |\n|------|----------------|\n| Read | no |\n| Bash | yes |\n\n\`\`\`js\nconsole.log("hello from a code block");\n\`\`\`\n\nNow I'll run a command.\n\n`;
  yield* say(intro);

  const toolId = `toolu_${Math.random().toString(36).slice(2)}`;
  const input = wantsEdit
    ? { file_path: `${options.cwd}/hello.txt`, old_string: 'hello world', new_string: 'hello, harness' }
    : { command: 'ls -la', description: 'List files' };
  const name = wantsEdit ? 'Edit' : 'Bash';
  yield { type: 'assistant', parent_tool_use_id: null, message: { id: msgId, content: [{ type: 'tool_use', id: toolId, name, input }] } };

  const perm = options.permissionMode === 'plan'
    ? { behavior: 'deny', message: 'plan mode: no execution' }
    : await options.canUseTool(name, input, { signal, title: `Claude wants to use ${name}`, toolUseID: toolId });
  const ok = perm.behavior === 'allow';
  if (ok && name === 'Bash') {                       // a command that takes a moment, so the activity timer shows
    for (let sec = 1; sec <= 2; sec++) {
      await sleep(400);
      yield { type: 'tool_progress', tool_use_id: toolId, tool_name: name, parent_tool_use_id: null, elapsed_time_seconds: sec };
    }
  }
  yield {
    type: 'user', parent_tool_use_id: null,
    message: { content: [{ type: 'tool_result', tool_use_id: toolId, is_error: !ok, content: ok ? 'total 8\ndrwxr-xr-x  2 you you 4096 .\n-rw-r--r--  1 you you   12 hello.txt' : perm.message }] },
  };

  if (ok && !wantsEdit) {                            // a sub-agent whose steps appear in the live activity feed
    const taskId = rid();
    yield { type: 'assistant', parent_tool_use_id: null, message: { id: msgId, content: [{ type: 'tool_use', id: taskId, name: 'Task', input: { description: 'Look around the project', prompt: 'List and read the files.', subagent_type: 'Explore' } }] } };
    for (const [tool, inp, out] of [['Glob', { pattern: '**/*' }, 'hello.txt'], ['Read', { file_path: `${options.cwd}/hello.txt` }, 'hello world']]) {
      const subId = rid();
      await sleep(200);
      yield { type: 'assistant', parent_tool_use_id: taskId, message: { id: `msg_sub_${subId}`, content: [{ type: 'tool_use', id: subId, name: tool, input: inp }] } };
      await sleep(200);
      yield { type: 'user', parent_tool_use_id: taskId, message: { content: [{ type: 'tool_result', tool_use_id: subId, content: out }] } };
    }
    yield { type: 'user', parent_tool_use_id: null, message: { content: [{ type: 'tool_result', tool_use_id: taskId, content: 'One file, hello.txt, containing "hello world".' }] } };
  }

  const msg2 = `msg_${Math.random().toString(36).slice(2)}`;
  yield { type: 'stream_event', parent_tool_use_id: null, event: { type: 'message_start', message: { id: msg2 } } };
  yield* say(ok ? '\nAll done — that ran fine.' : '\nUnderstood, I did not run it.');
  yield { type: 'result', subtype: 'success', is_error: false, result: 'ok', total_cost_usd: 0.0042, num_turns: 2, duration_ms: 1234, session_id: sid };
}
