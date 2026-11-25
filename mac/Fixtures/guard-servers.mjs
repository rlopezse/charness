// Test servers for the egress-guard checks in `swift run core-checks`: a server that greets and closes, one that
// answers the first bytes it gets, and a fake corporate proxy that requires a login. Prints one JSON line with
// their ports, then a line for every request the fake proxy receives. Exits when its stdin closes.
// (The guard answers they are compared with are in guard.json, recorded from the retired Node guard.)
import net from 'node:net';

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
out({ ready: true, echo, pong, proxy });
process.stdin.resume();
process.stdin.on('end', () => process.exit(0));
