import http from 'node:http';
import net from 'node:net';
import { fetchServers, routableServers, localServers, remoteServers, ourHost } from './registry.mjs';
import { ensureBackend, recordActivity, shutdownAll, stopBackend, currentState, rewriteCommand, internalPortFor } from './spawner.mjs';

const ONLY_PORT_FLAG = '--only';
const AUDIT_FLAG = '--audit';
const PLAN_FLAG = '--plan';
const STATUS_PORT = parseInt(process.env.SDI_STATUS_PORT || '3998', 10);
const REFRESH_INTERVAL_MS = parseInt(process.env.SDI_REFRESH_INTERVAL_MS || String(24 * 60 * 60 * 1000), 10);

function parseArgs(argv) {
  const args = { onlyPorts: null, mode: 'serve' };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === ONLY_PORT_FLAG) {
      const next = argv[i + 1];
      if (!next) throw new Error(`${ONLY_PORT_FLAG} requires a comma-separated port list`);
      args.onlyPorts = new Set(next.split(',').map(s => parseInt(s.trim(), 10)));
      i++;
    } else if (argv[i] === AUDIT_FLAG) {
      args.mode = 'audit';
    } else if (argv[i] === PLAN_FLAG) {
      args.mode = 'plan';
    }
  }
  return args;
}

function isPortBusy(port) {
  return new Promise((resolve) => {
    const sock = net.createConnection({ host: '127.0.0.1', port });
    const timer = setTimeout(() => { sock.destroy(); resolve(false); }, 500);
    sock.once('connect', () => { clearTimeout(timer); sock.destroy(); resolve(true); });
    sock.once('error', () => { clearTimeout(timer); sock.destroy(); resolve(false); });
  });
}

async function classifyTargets(targets, ownedByUs = new Set()) {
  const bind = [];
  const skip = [];
  for (const s of targets) {
    const rewritten = rewriteCommand(s.startCommand, s.port, internalPortFor(s.port));
    if (!rewritten) {
      skip.push({ server: s, reason: `startCommand has no literal :${s.port}` });
      continue;
    }
    if (!ownedByUs.has(s.port) && await isPortBusy(s.port)) {
      skip.push({ server: s, reason: `:${s.port} already bound by another process` });
      continue;
    }
    bind.push(s);
  }
  return { bind, skip };
}

function startListener(server) {
  const { port, projectName, projectId } = server;

  const proxy = http.createServer(async (req, res) => {
    try {
      const internalPort = await ensureBackend(server);
      recordActivity(server);

      const upstream = http.request({
        host: '127.0.0.1',
        port: internalPort,
        path: req.url,
        method: req.method,
        headers: { ...req.headers, host: `127.0.0.1:${internalPort}` },
      }, upstreamRes => {
        res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
        upstreamRes.pipe(res);
      });
      upstream.on('error', err => {
        console.error(`[sdi] :${port} upstream error: ${err.message}`);
        if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
        res.end(`SDI: upstream error from ${projectName}: ${err.message}\n`);
      });
      req.pipe(upstream);
    } catch (err) {
      console.error(`[sdi] :${port} spawn error: ${err.message}`);
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
      res.end(`SDI: could not start ${projectName} (:${port}): ${err.message}\nSee /tmp/sdi-${port}.log for details.\n`);
    }
  });

  proxy.on('upgrade', async (req, clientSocket, head) => {
    try {
      const internalPort = await ensureBackend(server);
      recordActivity(server);

      const upstream = http.request({
        host: '127.0.0.1',
        port: internalPort,
        path: req.url,
        method: req.method,
        headers: { ...req.headers, host: `127.0.0.1:${internalPort}` },
      });
      upstream.end();
      upstream.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
        const statusLine = `HTTP/${upstreamRes.httpVersion} ${upstreamRes.statusCode} ${upstreamRes.statusMessage || ''}`;
        const headerLines = [];
        for (const [k, v] of Object.entries(upstreamRes.headers)) {
          if (Array.isArray(v)) for (const vv of v) headerLines.push(`${k}: ${vv}`);
          else headerLines.push(`${k}: ${v}`);
        }
        clientSocket.write([statusLine, ...headerLines, '', ''].join('\r\n'));
        if (upstreamHead && upstreamHead.length) clientSocket.write(upstreamHead);
        upstreamSocket.pipe(clientSocket);
        clientSocket.pipe(upstreamSocket);
        const cleanup = () => { upstreamSocket.destroy(); clientSocket.destroy(); };
        upstreamSocket.on('error', cleanup);
        clientSocket.on('error', cleanup);
        upstreamSocket.on('close', () => clientSocket.destroy());
        clientSocket.on('close', () => upstreamSocket.destroy());
      });
      upstream.on('error', err => {
        console.error(`[sdi] :${port} upgrade upstream error: ${err.message}`);
        clientSocket.destroy();
      });
    } catch (err) {
      console.error(`[sdi] :${port} upgrade spawn error: ${err.message}`);
      clientSocket.destroy();
    }
  });

  proxy.on('error', err => {
    if (err.code === 'EADDRINUSE') {
      console.error(`[sdi] :${port} already in use — skipping (${projectName})`);
    } else {
      console.error(`[sdi] :${port} listener error: ${err.message}`);
    }
  });

  proxy.listen(port, '127.0.0.1', () => {
    console.log(`[sdi] :${port} → ${projectName} (project ${projectId}) — listening, idle`);
  });

  return proxy;
}

// For ports owned by a different host: bind locally and respond with a clear
// 421-style message naming where to actually go. Keeps "I tried to use this
// port" failures self-explanatory rather than silent (no listener) or
// confusingly-routed (proxied to an unintended target).
function startRedirectListener(server, ourHostName) {
  const { port, projectName, host, tailscaleName, url } = server;
  const target = url || (tailscaleName ? `http://${tailscaleName}:${port}` : `the ${host} machine`);
  const body =
    `SDI: this service runs on ${host}, not on ${ourHostName}.\n` +
    `Project: ${projectName} (port ${port})\n` +
    `Try: ${target}\n`;

  const handle = (req, res) => {
    res.writeHead(421, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(body);
  };

  const srv = http.createServer(handle);
  srv.on('upgrade', (req, clientSocket) => {
    clientSocket.write([
      'HTTP/1.1 421 Misdirected Request',
      'Content-Type: text/plain; charset=utf-8',
      `Content-Length: ${Buffer.byteLength(body)}`,
      'Connection: close',
      '',
      body,
    ].join('\r\n'));
    clientSocket.end();
  });
  srv.on('error', err => {
    if (err.code === 'EADDRINUSE') {
      console.error(`[sdi] :${port} (remote ${host}) — already in use locally; not redirecting`);
    } else {
      console.error(`[sdi] :${port} redirect listener error: ${err.message}`);
    }
  });
  srv.listen(port, '127.0.0.1', () => {
    console.log(`[sdi] :${port} → ${projectName} on ${host} — redirect to ${target}`);
  });

  return srv;
}

function startStatusServer(state) {
  const srv = http.createServer((req, res) => {
    if (req.url === '/state') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        ...state,
        spawned: currentState(),
      }, null, 2));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  srv.listen(STATUS_PORT, '127.0.0.1', () => {
    console.log(`[sdi] status :${STATUS_PORT}/state`);
  });
}

async function runAudit(targets) {
  console.log(`[sdi audit] ${targets.length} routable entries`);
  const results = { pass: [], fail: [] };
  for (const s of targets) {
    const label = `:${s.port} ${(s.projectName + '/' + s.role).padEnd(48)}`;
    const rewritten = rewriteCommand(s.startCommand, s.port, internalPortFor(s.port));
    if (!rewritten) {
      console.log(`  SKIP ${label} startCommand has no literal port ${s.port}`);
      results.fail.push({ server: s, reason: 'port-not-in-command' });
      continue;
    }
    const start = Date.now();
    try {
      await ensureBackend(s);
      const elapsed = Date.now() - start;
      console.log(`  PASS ${label} spawn=${elapsed}ms`);
      results.pass.push({ server: s, elapsedMs: elapsed });
    } catch (err) {
      console.log(`  FAIL ${label} ${err.message}`);
      results.fail.push({ server: s, reason: err.message });
    }
    await stopBackend(s.port);
  }
  const total = results.pass.length + results.fail.length;
  console.log(`\n[sdi audit] ${results.pass.length}/${total} pass, ${results.fail.length} fail`);
  if (results.fail.length) {
    console.log(`\nFailures (logs at /tmp/sdi-<port>.log):`);
    for (const f of results.fail) {
      console.log(`  :${f.server.port} ${f.server.projectName}/${f.server.role}  —  ${f.reason}`);
    }
  }
  return results;
}

async function main() {
  const args = parseArgs(process.argv);

  const host = ourHost();
  if (!host) {
    console.error(`[sdi] cannot determine host. Set SDI_HOST=mbp or SDI_HOST=macmini.`);
    process.exit(2);
  }
  console.log(`[sdi] host=${host}`);

  let fetchResult;
  try {
    fetchResult = await fetchServers();
  } catch (err) {
    console.error(`[sdi] could not reach marginalia or load cache: ${err.message}`);
    process.exit(1);
  }
  const { servers, source, cacheAge } = fetchResult;
  console.log(`[sdi] registry source=${source}${cacheAge ? ` age=${cacheAge}` : ''} entries=${servers.length}`);

  // Audit mode: spawn-and-test every routable entry regardless of host (legacy).
  // Useful when you actually want to exercise the whole registry.
  if (args.mode === 'audit') {
    const targets = args.onlyPorts
      ? routableServers(servers).filter(s => args.onlyPorts.has(s.port))
      : routableServers(servers);
    const results = await runAudit(targets);
    process.exit(results.fail.length > 0 ? 1 : 0);
  }

  const local = args.onlyPorts
    ? localServers(servers, host).filter(s => args.onlyPorts.has(s.port))
    : localServers(servers, host);
  const remote = args.onlyPorts
    ? remoteServers(servers, host).filter(s => args.onlyPorts.has(s.port))
    : remoteServers(servers, host);

  if (args.mode === 'plan') {
    console.log(`[sdi plan] host=${host}, would bind ${local.length} local + ${remote.length} remote-redirect\n`);
    console.log('LOCAL (spawn-on-demand):');
    for (const s of local) console.log(`  :${s.port}  ${s.projectName}/${s.role}`);
    console.log('\nREMOTE (redirect):');
    for (const s of remote) console.log(`  :${s.port}  ${s.projectName}/${s.role}  →  ${s.host} (${s.tailscaleName || '?'})`);
    process.exit(0);
  }

  const { bind: localBind, skip: localSkip } = await classifyTargets(local);

  if (localSkip.length) {
    console.log(`[sdi] skipping ${localSkip.length} local row(s):`);
    for (const { server: s, reason } of localSkip) console.log(`  :${s.port} ${s.projectName}/${s.role}  —  ${reason}`);
  }
  console.log(`[sdi] binding ${localBind.length} local + ${remote.length} remote-redirect (registry has ${servers.length})`);

  const listeners = new Map();
  for (const server of localBind) {
    const proxy = startListener(server);
    listeners.set(server.port, { server, proxy, kind: 'local' });
  }
  for (const server of remote) {
    if (await isPortBusy(server.port)) {
      console.log(`[sdi] :${server.port} (remote ${server.host}) skipped — port already bound locally`);
      continue;
    }
    const proxy = startRedirectListener(server, host);
    listeners.set(server.port, { server, proxy, kind: 'redirect' });
  }

  startStatusServer({ host, registrySource: source });

  if (REFRESH_INTERVAL_MS > 0) {
    setInterval(() => reloadRegistry(listeners, args, host).catch(err => {
      console.error(`[sdi] periodic refresh failed: ${err.message}`);
    }), REFRESH_INTERVAL_MS);
  }

  process.on('SIGTERM', handleShutdown);
  process.on('SIGINT', handleShutdown);
  process.on('SIGHUP', () => reloadRegistry(listeners, args, host).catch(err => {
    console.error(`[sdi] reload failed: ${err.message}`);
  }));
}

async function reloadRegistry(listeners, args, host) {
  console.log('[sdi] reloading registry');
  const { servers } = await fetchServers();

  const local = args.onlyPorts
    ? localServers(servers, host).filter(s => args.onlyPorts.has(s.port))
    : localServers(servers, host);
  const remote = args.onlyPorts
    ? remoteServers(servers, host).filter(s => args.onlyPorts.has(s.port))
    : remoteServers(servers, host);

  const { bind: localBind } = await classifyTargets(local, new Set([...listeners.keys()]));
  const newByPort = new Map();
  for (const s of localBind) newByPort.set(s.port, { server: s, kind: 'local' });
  for (const s of remote) if (!newByPort.has(s.port)) newByPort.set(s.port, { server: s, kind: 'redirect' });

  let added = 0, removed = 0, recreated = 0;

  for (const [port, existing] of Array.from(listeners.entries())) {
    const updated = newByPort.get(port);
    if (!updated) {
      console.log(`[sdi] :${port} removing — no longer in scope (was ${existing.server.projectName})`);
      if (existing.kind === 'local') await stopBackend(port);
      await new Promise(res => existing.proxy.close(res));
      listeners.delete(port);
      removed++;
    } else if (
      updated.kind !== existing.kind ||
      (updated.kind === 'local' && updated.server.startCommand !== existing.server.startCommand) ||
      (updated.kind === 'redirect' && (updated.server.host !== existing.server.host || updated.server.tailscaleName !== existing.server.tailscaleName))
    ) {
      console.log(`[sdi] :${port} ${existing.kind}→${updated.kind} or config changed — recreating listener`);
      if (existing.kind === 'local') await stopBackend(port);
      await new Promise(res => existing.proxy.close(res));
      listeners.delete(port);
      const proxy = updated.kind === 'local' ? startListener(updated.server) : startRedirectListener(updated.server, host);
      listeners.set(port, { server: updated.server, proxy, kind: updated.kind });
      recreated++;
    }
  }

  for (const [port, { server, kind }] of newByPort) {
    if (!listeners.has(port)) {
      if (kind === 'redirect' && await isPortBusy(port)) {
        console.log(`[sdi] :${port} (remote ${server.host}) skipped — port busy`);
        continue;
      }
      const proxy = kind === 'local' ? startListener(server) : startRedirectListener(server, host);
      listeners.set(port, { server, proxy, kind });
      added++;
    }
  }

  console.log(`[sdi] reload: +${added} -${removed} ~${recreated} — ${listeners.size} total`);
}

let shuttingDown = false;
function handleShutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log('[sdi] shutdown requested');
  shutdownAll();
  setTimeout(() => process.exit(0), 2000);
}

main();
