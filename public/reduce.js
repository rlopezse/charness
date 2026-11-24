// Shared by the server (to persist threads) and the browser (to render them live).
// A thread is a list of messages; events from the agent are folded into it here.
//
//   {role:'user', text}
//   {role:'assistant', blocks:[{type:'text', text} | {type:'tool', id, name, input, status, output?}], done?}
//   {role:'system', text}

/** Applies one event. Returns the index of the message that changed (or -1). */
export function apply(msgs, ev) {
  const last = () => msgs[msgs.length - 1];
  const asst = () => {
    let m = last();
    if (!m || m.role !== 'assistant') { m = { role: 'assistant', blocks: [] }; msgs.push(m); }
    return m;
  };
  const findTool = (id) => {
    for (let i = msgs.length - 1; i >= 0; i--) {
      const m = msgs[i];
      if (m.role !== 'assistant') continue;
      const b = m.blocks.find((x) => x.type === 'tool' && x.id === id);
      if (b) return { b, i };
    }
    return null;
  };

  switch (ev.t) {
    case 'user':
      msgs.push({ role: 'user', text: ev.text, ts: ev.ts });
      return msgs.length - 1;

    case 'delta': {
      const m = asst();
      const b = m.blocks[m.blocks.length - 1];
      if (b && b.type === 'text') b.text += ev.text;
      else m.blocks.push({ type: 'text', text: ev.text });
      return msgs.length - 1;
    }

    case 'tool_use': {
      const m = asst();
      if (!m.blocks.some((b) => b.type === 'tool' && b.id === ev.id)) {
        m.blocks.push({ type: 'tool', id: ev.id, name: ev.name, input: ev.input, status: 'running' });
      }
      return msgs.length - 1;
    }

    case 'tool_result': {
      const f = findTool(ev.id);
      if (!f) return -1;
      f.b.output = ev.output;
      if (f.b.status !== 'denied') f.b.status = ev.isError ? 'error' : 'ok';
      return f.i;
    }

    case 'tool_denied': {
      const f = findTool(ev.id);
      if (!f) return -1;
      f.b.status = 'denied';
      return f.i;
    }

    case 'end': {
      const m = last();
      if (m && m.role === 'assistant') { m.done = { cost: ev.cost, turns: ev.turns, ms: ev.ms }; return msgs.length - 1; }
      return -1;
    }

    case 'error':
      msgs.push({ role: 'system', text: ev.text });
      return msgs.length - 1;

    default:
      return -1;
  }
}
