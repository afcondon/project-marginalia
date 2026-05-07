import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';

const LOG_DIR = process.env.SDI_LOG_DIR || '/tmp';
const IDLE_TIMEOUT_MS = parseInt(process.env.SDI_IDLE_TIMEOUT_MS || '600000', 10);
const BACKEND_STARTUP_TIMEOUT_MS = parseInt(process.env.SDI_STARTUP_TIMEOUT_MS || '60000', 10);
const PORT_POLL_INTERVAL_MS = 100;
const INTERNAL_PORT_OFFSET = 20000;

const state = new Map();

export function internalPortFor(publicPort) {
  return publicPort + INTERNAL_PORT_OFFSET;
}

export function rewriteCommand(cmd, publicPort, internalPort) {
  const re = new RegExp(`\\b${publicPort}\\b`, 'g');
  if (!re.test(cmd)) return null;
  return cmd.replace(re, String(internalPort));
}

function logPathFor(publicPort) {
  return path.join(LOG_DIR, `sdi-${publicPort}.log`);
}

function waitForPort(port, timeoutMs) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const attempt = () => {
      if (Date.now() > deadline) {
        return reject(new Error(`backend did not bind port ${port} within ${timeoutMs}ms`));
      }
      const sock = net.connect({ host: '127.0.0.1', port });
      sock.once('connect', () => { sock.end(); resolve(); });
      sock.once('error', () => { sock.destroy(); setTimeout(attempt, PORT_POLL_INTERVAL_MS); });
    };
    attempt();
  });
}

export async function ensureBackend(server) {
  const { port, startCommand, projectName } = server;
  const existing = state.get(port);
  if (existing) return existing.readyPromise.then(() => existing.internalPort);

  const internalPort = internalPortFor(port);
  const rewritten = rewriteCommand(startCommand, port, internalPort);
  if (!rewritten) {
    throw new Error(`startCommand for ${projectName} (:${port}) does not contain the literal port; cannot rewrite: ${startCommand}`);
  }

  const logStream = fs.createWriteStream(logPathFor(port), { flags: 'a' });
  logStream.write(`\n=== SDI spawn at ${new Date().toISOString()} — ${projectName} (:${port} -> :${internalPort}) ===\n`);
  logStream.write(`command: ${rewritten}\n\n`);

  const childProc = spawn('bash', ['-c', rewritten], {
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: false,
  });
  childProc.stdout.pipe(logStream, { end: false });
  childProc.stderr.pipe(logStream, { end: false });

  const readyPromise = waitForPort(internalPort, BACKEND_STARTUP_TIMEOUT_MS);
  const entry = { childProc, internalPort, idleTimer: null, startedAt: Date.now(), readyPromise, logStream };
  state.set(port, entry);

  childProc.on('exit', (code, signal) => {
    logStream.write(`\n=== exited code=${code} signal=${signal} at ${new Date().toISOString()} ===\n`);
    logStream.end();
    if (entry.idleTimer) clearTimeout(entry.idleTimer);
    state.delete(port);
    console.log(`[sdi] :${port} ${projectName} backend exited (code=${code}, signal=${signal})`);
  });

  try {
    await readyPromise;
    console.log(`[sdi] :${port} ${projectName} backend ready on internal :${internalPort} (${Date.now() - entry.startedAt}ms)`);
  } catch (err) {
    childProc.kill('SIGTERM');
    throw err;
  }

  recordActivity(server);
  return internalPort;
}

export function recordActivity(server) {
  const entry = state.get(server.port);
  if (!entry) return;
  if (entry.idleTimer) clearTimeout(entry.idleTimer);
  entry.idleTimer = setTimeout(() => {
    console.log(`[sdi] :${server.port} ${server.projectName} idle ${IDLE_TIMEOUT_MS}ms, SIGTERM`);
    entry.childProc.kill('SIGTERM');
  }, IDLE_TIMEOUT_MS);
}

export function shutdownAll() {
  for (const [port, entry] of state.entries()) {
    if (entry.childProc && !entry.childProc.killed) {
      console.log(`[sdi] :${port} killing on shutdown`);
      entry.childProc.kill('SIGTERM');
    }
  }
}

export function stopBackend(port) {
  const entry = state.get(port);
  if (!entry) return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => { clearTimeout(killTimer); resolve(); };
    entry.childProc.once('exit', done);
    entry.childProc.kill('SIGTERM');
    const killTimer = setTimeout(() => {
      if (!entry.childProc.killed) entry.childProc.kill('SIGKILL');
      setTimeout(resolve, 250);
    }, 5000);
  });
}

export function currentState() {
  return Array.from(state.entries()).map(([port, e]) => ({
    port,
    internalPort: e.internalPort,
    pid: e.childProc.pid,
    startedAt: new Date(e.startedAt).toISOString(),
    uptimeMs: Date.now() - e.startedAt,
  }));
}
