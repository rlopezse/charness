// Test peer for the Swift egress guard (CharnessCore/Guard.swift). Starts the real Node guard (lib/guard.mjs)
// twice, directly and chained through a fake corporate proxy that requires a login, plus the local servers
// they tunnel to. Prints one JSON line with the ports, then a line per guard log entry and per request the
// fake proxy receives. `swift run core-checks` sends the same requests to these and to the Swift guards and
// requires the same answers and log entries. Exits when its stdin closes.
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const { startGuard } = await import(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'lib', 'guard.mjs'));
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
const listen = (srv) => new Promise((r) => srv.listen(0, '127.0.0.1', () => r(srv.address().port)));

const echo = await listen(net.createServer((s) => s.end('hello-from-echo')));
const pong = await listen(net.createServer((s) => s.once('data', (d) => s.end(`PONG:${d}`))));
const proxy = await listen(net.createServer((s) => {
  let buf = '';
  const onData = (d) => {
    buf += d;
    const i = buf.indexOf('\r\n\r\n');
    if (i < 0) return;
    s.off('data', onData);
    out({ proxyRequest: buf.slice(0, i + 4) });
    const m = /^CONNECT 127\.0\.0\.1:(\d+) /.exec(buf);
    if (m && Number(m[1]) === echo && /Proxy-Authorization: Basic dXNAZXI6cEBzcw==\r\n/.test(buf)) {
      const up = net.connect(echo, '127.0.0.1', () => { s.write('HTTP/1.1 200 Connection established\r\nVia: fake-proxy\r\n\r\n'); up.pipe(s); s.pipe(up); });
      up.on('error', () => s.destroy());
    } else {
      s.end('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n');
    }
  };
  s.on('data', onData);
  s.on('error', () => {});
}));

const allow = ['api.anthropic.com', `127.0.0.1:${echo}`, `127.0.0.1:${pong}`, '127.0.0.1:1', '*.example.org', `LocalHost:${echo}`];
const direct = await startGuard({ getAllow: () => allow, upstream: null, onLog: (entry) => out({ guard: 'direct', entry }) });
const chained = await startGuard({ getAllow: () => allow, upstream: `http://us%40er:p%40ss@127.0.0.1:${proxy}`, onLog: (entry) => out({ guard: 'chained', entry }) });
out({ ready: true, direct: direct.port, chained: chained.port, echo, pong, proxy, allow });
process.stdin.resume();
process.stdin.on('end', () => process.exit(0));
