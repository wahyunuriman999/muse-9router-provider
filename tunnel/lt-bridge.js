// lt-bridge.js — localtunnel bridge with fixed-subdomain claim.
//
// Why a custom client: the stock `localtunnel` npm client can break on newer
// Node versions and behind egress proxies (Host header checks). This
// replicates the client's TunnelCluster behavior directly.
//
// Connection modes:
//   - If https_proxy/HTTPS_PROXY is set: opens each tunnel stream via an
//     HTTP CONNECT proxy (proxy auth taken from the URL).
//   - Otherwise: connects directly to localtunnel.me:<assigned-port>.
//
// Configuration via environment:
//   LT_SUBDOMAIN   fixed public name (becomes https://<name>.loca.lt).
//                  Empty = random name (not recommended for stable access).
//   LT_LOCAL_PORT  local port of 9router (default 20128).
//   LT_LOCAL_HOST  local bind host (default 127.0.0.1).
//   TUNNEL_STREAMS parallel tunnel streams (default 6).
const net = require('net');
const { execFileSync } = require('child_process');

const LOCAL_PORT = Number(process.env.LT_LOCAL_PORT || 20128);
const LOCAL_HOST = process.env.LT_LOCAL_HOST || '127.0.0.1';
const STREAMS = Number(process.env.TUNNEL_STREAMS || 6);

function proxyParts() {
  const raw = process.env.https_proxy || process.env.HTTPS_PROXY || '';
  if (!raw) return null;
  const u = new URL(raw);
  const auth = u.username
    ? Buffer.from(`${decodeURIComponent(u.username)}:${decodeURIComponent(u.password)}`).toString('base64')
    : null;
  return { host: u.hostname, port: Number(u.port) || 3128, auth };
}

function getAssignment() {
  const sub = (process.env.LT_SUBDOMAIN || '').trim().replace(/[^a-z0-9-]/gi, '').toLowerCase();
  const endpoint = sub ? `https://localtunnel.me/${sub}` : 'https://localtunnel.me/?new';
  // Retry the fixed subdomain: localtunnel assignments are racy and readable
  // names can get sniped between probe and claim.
  for (let attempt = 1; attempt <= 5; attempt++) {
    const out = execFileSync('curl', ['-s', '--max-time', '20', endpoint], { encoding: 'utf8' });
    const a = JSON.parse(out);
    if (!a.url || !a.port) throw new Error('bad assignment: ' + out.slice(0, 120));
    if (!sub || a.url.includes(`https://${sub}.`)) {
      if (sub) console.log(`claimed fixed subdomain: ${a.url} (attempt ${attempt}, id=${a.id}, port=${a.port})`);
      else console.log(`assigned random subdomain: ${a.url} (id=${a.id}, port=${a.port})`);
      return a;
    }
    console.error(`attempt ${attempt}: wanted ${sub} but got ${a.url}, retrying...`);
    execFileSync('sleep', ['3']);
  }
  throw new Error(`could not claim subdomain ${sub} after 5 attempts`);
}

// Open one tunnel stream to the tunnel server and pipe it to the local app.
function openStream(proxy, remoteHost, remotePort, tag) {
  const establishedRef = { value: false };
  let sock;

  const onEstablished = () => {
    establishedRef.value = true;
    console.log(`[${tag}] tunnel stream established`);
    const local = net.connect({ host: LOCAL_HOST, port: LOCAL_PORT });
    local.on('error', (e) => { console.error(`[${tag}] local error: ${e.message}`); sock.destroy(); });
    sock.on('error', (e) => { console.error(`[${tag}] remote error: ${e.message}`); local.destroy(); });
    sock.on('close', () => { local.destroy(); scheduleReconnect(); });
    // when the local side closes (e.g. keep-alive timeout), recycle the whole
    // pair — otherwise the remote stream stays open with no local peer and
    // the next request down it hangs (-> 408 from the relay)
    local.on('close', () => { sock.destroy(); });
    sock.pipe(local).pipe(sock);
  };

  let scheduled = false;
  function scheduleReconnect() {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => { scheduled = false; openStream(proxy, remoteHost, remotePort, tag); }, 3000);
  }

  if (proxy) {
    sock = net.connect({ host: proxy.host, port: proxy.port });
    let req = `CONNECT ${remoteHost}:${remotePort} HTTP/1.1\r\n` +
      `Host: ${remoteHost}:${remotePort}\r\n`;
    if (proxy.auth) req += `Proxy-Authorization: Basic ${proxy.auth}\r\n`;
    req += `Proxy-Connection: Keep-Alive\r\n\r\n`;
    let buf = Buffer.alloc(0);
    const onData = (chunk) => {
      if (establishedRef.value) return;
      buf = Buffer.concat([buf, chunk]);
      const idx = buf.indexOf('\r\n\r\n');
      if (idx === -1) return;
      const head = buf.slice(0, idx).toString();
      const rest = buf.slice(idx + 4);
      const status = head.split('\r\n')[0];
      if (!/^HTTP\/1\.[01] 200/.test(status)) {
        console.error(`[${tag}] CONNECT failed: ${status}`);
        sock.destroy();
        scheduleReconnect();
        return;
      }
      sock.removeListener('data', onData);
      if (rest.length) sock.unshift(rest);
      onEstablished();
    };
    sock.on('data', onData);
    sock.on('error', (e) => { if (!establishedRef.value) { console.error(`[${tag}] proxy conn error: ${e.message}`); scheduleReconnect(); } });
    // the egress proxy may close CONNECT with no response (e.g. stale port) —
    // without this the stream dies silently and never comes back
    sock.on('close', () => { if (!establishedRef.value) { console.error(`[${tag}] proxy closed before established`); scheduleReconnect(); } });
    sock.on('connect', () => sock.write(req));
  } else {
    sock = net.connect({ host: remoteHost, port: remotePort }, onEstablished);
    sock.on('error', (e) => { if (!establishedRef.value) { console.error(`[${tag}] direct conn error: ${e.message}`); scheduleReconnect(); } });
    sock.on('close', () => { if (!establishedRef.value) { console.error(`[${tag}] direct closed before established`); scheduleReconnect(); } });
  }
}

function main() {
  const proxy = proxyParts();
  console.log(proxy ? `proxy: ${proxy.host}:${proxy.port} (auth from env)` : 'direct connection (no proxy)');
  const a = getAssignment();
  console.log(`public URL: ${a.url}`);
  console.log(`tunnel endpoint: localtunnel.me:${a.port} (id: ${a.id})`);
  const remoteHost = 'localtunnel.me'; // server omits ip -> client uses host of localtunnel.me
  for (let i = 0; i < STREAMS; i++) openStream(proxy, remoteHost, a.port, `s${i}`);
  // keep process alive + heartbeat
  setInterval(() => {}, 60000);
}

main();
