// Marginalia frontend server — static files + path-based reverse proxy.
//
// Replaces `npx http-server` as the frontend LaunchAgent's entry point.
// Does two things:
//
//   1. Serves static files out of frontend/public on port 3101
//   2. Transparently proxies /api/* → localhost:3100 and /transcribe →
//      localhost:3200, preserving the full path in both directions
//
// Why: Tailscale Serve can only mount one backend at / per HTTPS port, so
// exposing the API + whisper as same-origin paths has to happen inside
// the frontend server itself rather than at the Tailscale edge. Keeping
// everything behind a single origin lets the frontend bundle use
// `window.location.origin` unconditionally for both dev and remote
// deployments (though the smart-URL detection still works for local-only
// use without this proxy).
//
// Zero dependencies — Node's built-in http + fs + path modules only.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, '..');
const STATIC_ROOT = path.join(PROJECT_ROOT, 'frontend', 'public');
const CAPTURE_ROOT = path.join(PROJECT_ROOT, 'capture', 'public');
const FINANCE_ROOT = path.join(PROJECT_ROOT, 'finance', 'public');
const _defaultBlogDrafts = path.join(os.homedir(), 'Documents', 'marginalia-blog-drafts');
const _rawBlogDrafts = process.env.MARGINALIA_BLOG_DRAFTS || _defaultBlogDrafts;
const BLOG_DRAFTS_ROOT = _rawBlogDrafts.endsWith('/') ? _rawBlogDrafts.slice(0, -1) : _rawBlogDrafts;
const PORT = parseInt(process.env.MARGINALIA_FRONTEND_PORT || '3101', 10);

const API_TARGET = { host: '127.0.0.1', port: 3100 };
const WHISPER_TARGET = { host: '127.0.0.1', port: 3200 };

// MIME type map — just the ones we actually serve
const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.wav': 'audio/wav',
  '.mp4': 'video/mp4',
  '.pdf': 'application/pdf',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
};

function mimeType(filePath) {
  return MIME_TYPES[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

// Proxy a request to a backend. Preserves method, headers, body, and path.
function proxy(req, res, target) {
  const options = {
    host: target.host,
    port: target.port,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: `${target.host}:${target.port}` },
  };
  const upstream = http.request(options, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });
  upstream.on('error', (err) => {
    console.error(`proxy error ${req.method} ${req.url} -> ${target.host}:${target.port}:`, err.message);
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    }
    res.end(`upstream error: ${err.message}\n`);
  });
  req.pipe(upstream);
}

// Resolve a URL path to a filesystem path inside STATIC_ROOT. Refuses any
// path that escapes the static root via .. segments or absolute paths.
function resolveStaticPath(urlPath) {
  // Strip query string
  const cleanPath = urlPath.split('?')[0];
  // Decode percent-encoding
  let decoded;
  try {
    decoded = decodeURIComponent(cleanPath);
  } catch {
    return null;
  }
  // Join and normalize
  const fullPath = path.join(STATIC_ROOT, decoded);
  const normalized = path.normalize(fullPath);
  if (!normalized.startsWith(STATIC_ROOT)) return null;
  return normalized;
}

function serveStatic(req, res) {
  const resolved = resolveStaticPath(req.url);
  if (!resolved) {
    res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('bad request\n');
    return;
  }

  fs.stat(resolved, (err, stat) => {
    if (err) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('not found\n');
      return;
    }

    // If it's a directory, try index.html inside it
    if (stat.isDirectory()) {
      const indexPath = path.join(resolved, 'index.html');
      fs.stat(indexPath, (indexErr) => {
        if (indexErr) {
          res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
          res.end('not found\n');
        } else {
          streamFile(indexPath, res);
        }
      });
      return;
    }

    streamFile(resolved, res);
  });
}

function streamFile(filePath, res) {
  // Disable caching so the bundle gets picked up immediately after rebuild.
  // The MBP dev loop rebuilds frequently; the Mini demo loop is fine with
  // fresh bytes on every request.
  res.writeHead(200, {
    'content-type': mimeType(filePath),
    'cache-control': 'no-cache',
    'access-control-allow-origin': '*',
  });
  const stream = fs.createReadStream(filePath);
  stream.on('error', (err) => {
    console.error(`read error ${filePath}:`, err.message);
    if (!res.headersSent) {
      res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('read error\n');
    }
  });
  stream.pipe(res);
}

const server = http.createServer((req, res) => {
  const url = req.url || '/';

  // Reverse-proxy API calls
  if (url === '/api' || url.startsWith('/api/')) {
    proxy(req, res, API_TARGET);
    return;
  }
  // Reverse-proxy whisper calls
  if (url === '/transcribe' || url.startsWith('/transcribe/')) {
    proxy(req, res, WHISPER_TARGET);
    return;
  }
  // Capture PWA — served under /capture/ from a separate static root.
  // The PWA's manifest.json sets start_url to /capture/ so iOS
  // Add-to-Home-Screen launches directly into the capture app.
  if (url === '/capture' || url === '/capture/') {
    streamFile(path.join(CAPTURE_ROOT, 'index.html'), res);
    return;
  }
  if (url.startsWith('/capture/')) {
    const captureFile = resolveStaticPath(url.replace('/capture/', '/'));
    if (captureFile) {
      const resolved = path.join(CAPTURE_ROOT, url.slice('/capture/'.length).split('?')[0]);
      const normalized = path.normalize(resolved);
      if (normalized.startsWith(CAPTURE_ROOT)) {
        fs.stat(normalized, (err, stat) => {
          if (err || !stat.isFile()) {
            // SPA fallback — serve index.html for unmatched routes
            streamFile(path.join(CAPTURE_ROOT, 'index.html'), res);
          } else {
            streamFile(normalized, res);
          }
        });
        return;
      }
    }
    streamFile(path.join(CAPTURE_ROOT, 'index.html'), res);
    return;
  }
  // Finance visualization app — served under /finance/
  if (url === '/finance' || url === '/finance/') {
    streamFile(path.join(FINANCE_ROOT, 'index.html'), res);
    return;
  }
  if (url.startsWith('/finance/')) {
    const subPath = url.slice('/finance/'.length).split('?')[0];
    const resolved = path.normalize(path.join(FINANCE_ROOT, subPath));
    if (resolved.startsWith(FINANCE_ROOT)) {
      fs.stat(resolved, (err, stat) => {
        if (err || !stat.isFile()) {
          streamFile(path.join(FINANCE_ROOT, 'index.html'), res);
        } else {
          streamFile(resolved, res);
        }
      });
      return;
    }
    streamFile(path.join(FINANCE_ROOT, 'index.html'), res);
    return;
  }
  // Blog assets — serve images from $MARGINALIA_BLOG_DRAFTS/<slug>/
  // Path: /blog-assets/<slug>/<filename>
  if (url.startsWith('/blog-assets/')) {
    const subPath = url.slice('/blog-assets/'.length).split('?')[0];
    const resolved = path.normalize(path.join(BLOG_DRAFTS_ROOT, subPath));
    if (resolved.startsWith(BLOG_DRAFTS_ROOT)) {
      fs.stat(resolved, (err, stat) => {
        if (err || !stat.isFile()) {
          res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
          res.end('not found\n');
        } else {
          streamFile(resolved, res);
        }
      });
      return;
    }
    res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('bad request\n');
    return;
  }
  // Serve index.html at the root
  if (url === '/' || url === '') {
    streamFile(path.join(STATIC_ROOT, 'index.html'), res);
    return;
  }
  // Everything else: static files from the desktop frontend
  serveStatic(req, res);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`marginalia frontend-server listening on http://0.0.0.0:${PORT}`);
  console.log(`  static:  ${STATIC_ROOT}`);
  console.log(`  capture: ${CAPTURE_ROOT} -> /capture/`);
  console.log(`  /api/*   -> http://${API_TARGET.host}:${API_TARGET.port}`);
  console.log(`  /transcribe -> http://${WHISPER_TARGET.host}:${WHISPER_TARGET.port}`);
});
