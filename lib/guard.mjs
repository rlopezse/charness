// Egress guard: a tiny local HTTPS CONNECT proxy that only tunnels to hosts you allow.
// The Claude Code process is started with HTTPS_PROXY pointing here, so every host it tries to
// reach is logged, and anything not on the allow-list is refused.
//
// It never sees request contents (TLS passes straight through), only "host:port".
// Honest limit: proxy variables are advisory. For hard enforcement, also run the whole thing
// in a container/VM or behind a firewall (see README).
import net from 'node:net';
import http from 'node:http';

const HOST_RE = /^[a-z0-9._-]+$/i;

export function startGuard({ getAllow, upstream, onLog }) {
  const allowed = (host, port) => {
    host = host.toLowerCase();
    return getAllow().some((entry) => {
      entry = entry.toLowerCase();
      const m = /^(.*?)(?::(\d+))?$/.exec(entry);
      const pat = m[1];
      const p = m[2] ? Number(m[2]) : 443;
      if (p !== port) return false;
      return pat === host || (pat.startsWith('*.') && host.endsWith(pat.slice(1)));
    });
  };

  const server = http.createServer((req, res) => {
    // Plain-HTTP proxying is deliberately unsupported; Claude only needs HTTPS.
    let host = '?';
    try { host = new URL(req.url).hostname; } catch { /* keep '?' */ }
    onLog({ ts: Date.now(), host, port: 80, allowed: false, note: 'plain http' });
    res.writeHead(403, { 'content-type': 'text/plain' });
    res.end('blocked by charness egress guard\n');
  });

  server.on('connect', (req, client, head) => {
    const m = /^([^:]+):(\d+)$/.exec(req.url || '');
    if (!m || !HOST_RE.test(m[1])) { client.destroy(); return; }
    const host = m[1];
    const port = Number(m[2]);
    const ok = allowed(host, port);
    onLog({ ts: Date.now(), host, port, allowed: ok });
    if (!ok) {
      client.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }

    const wire = (up, leftover) => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (leftover?.length) client.write(leftover);
      if (head?.length) up.write(head);
      up.pipe(client);
      client.pipe(up);
    };
    const cleanup = (up) => {
      up.on('error', () => client.destroy());
      up.on('close', () => client.destroy());
      client.on('error', () => up.destroy());
      client.on('close', () => up.destroy());
    };

    if (!upstream) {
      const up = net.connect(port, host, () => wire(up));
      cleanup(up);
      return;
    }

    // Chain through the user's own corporate proxy (HTTPS_PROXY at startup).
    const u = new URL(upstream);
    const up = net.connect(Number(u.port) || 80, u.hostname, () => {
      let req2 = `CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n`;
      if (u.username) {
        const cred = `${decodeURIComponent(u.username)}:${decodeURIComponent(u.password)}`;
        req2 += `Proxy-Authorization: Basic ${Buffer.from(cred).toString('base64')}\r\n`;
      }
      up.write(`${req2}\r\n`);
    });
    cleanup(up);
    let buf = Buffer.alloc(0);
    const onData = (d) => {
      buf = Buffer.concat([buf, d]);
      const end = buf.indexOf('\r\n\r\n');
      if (end < 0) return;
      up.off('data', onData);
      const status = buf.subarray(0, end).toString().split(' ')[1];
      if (status !== '200') { client.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n'); up.destroy(); return; }
      wire(up, buf.subarray(end + 4));
    };
    up.on('data', onData);
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, server }));
  });
}
