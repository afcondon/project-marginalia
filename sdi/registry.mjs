import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const MARGINALIA_URL = process.env.MARGINALIA_URL || 'http://localhost:3100';
const CACHE_PATH = process.env.SDI_CACHE_PATH || path.join(os.homedir(), '.sdi', 'registry-cache.json');
const FETCH_TIMEOUT_MS = parseInt(process.env.SDI_FETCH_TIMEOUT_MS || '3000', 10);

// Ports that SDI should not try to spawn locally even if their startCommand
// looks runnable. Used today for DeepStar-managed music-rig services
// (#191): DeepStar has its own launcher, sequencing, and adopt-running
// semantics; SDI competing on those ports causes confusion. Stop-gap until
// a `managed_by` column on project_servers makes this declarative.
const EXCLUDE_PORTS = new Set(
  (process.env.SDI_EXCLUDE_PORTS || '')
    .split(',')
    .map(s => parseInt(s.trim(), 10))
    .filter(n => Number.isInteger(n))
);

// Resolve which machine SDI is running on. SDI_HOST env var is authoritative;
// fallback to hostname-based heuristic. Returns null if unknowable so the
// caller can refuse to start rather than silently misclassifying every server.
export function ourHost() {
  const explicit = process.env.SDI_HOST;
  if (explicit) return explicit.trim().toLowerCase();
  const hostname = os.hostname().toLowerCase();
  if (hostname.includes('macbook')) return 'mbp';
  if (hostname.includes('mac-mini') || hostname.includes('mac.fritz')) return 'macmini';
  return null;
}

// Fetch the registry from Marginalia. On network failure or non-2xx, fall back
// to the on-disk cache (a flat JSON file keyed by `servers`). Returns
// { servers: Array, source: 'live' | 'cache', cacheAge?: string }. Throws
// only if both live and cache are unavailable.
export async function fetchServers() {
  try {
    const resp = await fetch(`${MARGINALIA_URL}/api/ports`, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!resp.ok) throw new Error(`/api/ports returned ${resp.status}`);
    const json = await resp.json();
    const servers = json.servers || [];
    writeCache(servers);
    return { servers, source: 'live' };
  } catch (err) {
    const cached = readCache();
    if (cached) {
      console.warn(`[sdi] marginalia unreachable (${err.message}); using cache (${cached.length} entries, age ${cacheAge()})`);
      return { servers: cached, source: 'cache', cacheAge: cacheAge() };
    }
    throw new Error(`marginalia unreachable and no cache available: ${err.message}`);
  }
}

function writeCache(servers) {
  try {
    fs.mkdirSync(path.dirname(CACHE_PATH), { recursive: true });
    fs.writeFileSync(CACHE_PATH, JSON.stringify({ updatedAt: new Date().toISOString(), servers }, null, 2));
  } catch (err) {
    console.warn(`[sdi] cache write failed: ${err.message}`);
  }
}

function readCache() {
  try {
    const parsed = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'));
    return parsed.servers || null;
  } catch {
    return null;
  }
}

function cacheAge() {
  try {
    const ms = Date.now() - fs.statSync(CACHE_PATH).mtimeMs;
    if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
    if (ms < 3_600_000) return `${Math.round(ms / 60_000)}m`;
    if (ms < 86_400_000) return `${Math.round(ms / 3_600_000)}h`;
    return `${Math.round(ms / 86_400_000)}d`;
  } catch {
    return '?';
  }
}

// Spawnable on this host: host matches, startCommand non-null, port present.
// Excludes ports listed in SDI_EXCLUDE_PORTS — see comment on EXCLUDE_PORTS.
export function localServers(servers, host) {
  return servers.filter(s =>
    typeof s.port === 'number' &&
    typeof s.startCommand === 'string' &&
    s.startCommand.length > 0 &&
    s.host === host &&
    !EXCLUDE_PORTS.has(s.port)
  );
}

// Owned by another host: port present, host set and not us. SDI binds these
// with a redirect handler instead of trying to spawn locally.
export function remoteServers(servers, host) {
  return servers.filter(s =>
    typeof s.port === 'number' &&
    s.host &&
    s.host !== host
  );
}

// Legacy filter — kept for audit/plan code that still wants "anything spawnable
// regardless of host". Pre-host-awareness behaviour.
export function routableServers(servers) {
  return servers.filter(s =>
    typeof s.port === 'number' &&
    typeof s.startCommand === 'string' &&
    s.startCommand.length > 0
  );
}
