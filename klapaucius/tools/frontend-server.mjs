// Klapaucius frontend server — static files + reverse proxy to API.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, '..');
const STATIC_ROOT = path.join(PROJECT_ROOT, 'frontend', 'public');
const _defaultBlogRoot = path.join(os.homedir(), 'Documents', 'klapaucius');
const _rawBlogRoot = process.env.KLAPAUCIUS_ROOT || _defaultBlogRoot;
const BLOG_ROOT = _rawBlogRoot.endsWith('/') ? _rawBlogRoot.slice(0, -1) : _rawBlogRoot;
const PORT = parseInt(process.env.KLAPAUCIUS_FRONTEND_PORT || '3401', 10);
const API_TARGET = { host: '127.0.0.1', port: 3400 };

const THUMB_CACHE = path.join(BLOG_ROOT, '.thumb-cache');
const RAW_EXTS = new Set(['.dng', '.raf', '.cr2', '.nef', '.raw']);

function thumbPath(originalPath) {
  const hash = crypto.createHash('sha256').update(originalPath).digest('hex').slice(0, 16);
  return path.join(THUMB_CACHE, hash + '.jpg');
}

function ensureThumb(originalPath) {
  const dest = thumbPath(originalPath);
  if (!fs.existsSync(dest)) {
    fs.mkdirSync(THUMB_CACHE, { recursive: true });
    execSync(`sips -s format jpeg -Z 400 ${JSON.stringify(originalPath)} --out ${JSON.stringify(dest)}`, { stdio: 'ignore' });
  }
  return dest;
}

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.md': 'text/markdown; charset=utf-8',
};

function mimeType(filePath) {
  return MIME_TYPES[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

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
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`upstream error: ${err.message}\n`);
  });
  req.pipe(upstream);
}

function streamFile(filePath, res) {
  res.writeHead(200, {
    'content-type': mimeType(filePath),
    'cache-control': 'no-cache',
    'access-control-allow-origin': '*',
  });
  fs.createReadStream(filePath).pipe(res);
}

const server = http.createServer((req, res) => {
  const url = req.url || '/';

  // Proxy API calls
  if (url === '/api' || url.startsWith('/api/')) {
    proxy(req, res, API_TARGET);
    return;
  }

  // Source media: serve photo/music files from their original locations.
  // Path: /source-media/<absolute-path> — the API returns these URLs.
  // Only serves files, with basic extension allowlisting.
  if (url.startsWith('/source-media/')) {
    const absPath = decodeURIComponent(url.slice('/source-media'.length).split('?')[0]);
    const resolved = path.normalize(absPath);
    // Only serve image/audio files (no arbitrary filesystem reads)
    const ext = path.extname(resolved).toLowerCase();
    const allowed = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.tif', '.tiff',
                     '.raw', '.raf', '.cr2', '.nef', '.dng',
                     '.mp3', '.m4a', '.flac', '.wav', '.aac', '.ogg'];
    if (!allowed.includes(ext)) {
      res.writeHead(403, { 'content-type': 'text/plain' });
      res.end('forbidden file type\n');
      return;
    }
    fs.stat(resolved, (err, stat) => {
      if (err || !stat.isFile()) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('not found\n');
        return;
      }
      if (RAW_EXTS.has(ext)) {
        try {
          const cached = ensureThumb(resolved);
          streamFile(cached, res);
        } catch (thumbErr) {
          res.writeHead(500, { 'content-type': 'text/plain' });
          res.end(`thumbnail generation failed: ${thumbErr.message}\n`);
        }
      } else {
        streamFile(resolved, res);
      }
    });
    return;
  }

  // Blog assets: /blog-assets/<category>/<slug>/<file>
  if (url.startsWith('/blog-assets/')) {
    const subPath = url.slice('/blog-assets/'.length).split('?')[0];
    const resolved = path.normalize(path.join(BLOG_ROOT, subPath));
    if (resolved.startsWith(BLOG_ROOT)) {
      const blogExt = path.extname(resolved).toLowerCase();
      fs.stat(resolved, (err, stat) => {
        if (err || !stat.isFile()) {
          res.writeHead(404, { 'content-type': 'text/plain' });
          res.end('not found\n');
        } else if (RAW_EXTS.has(blogExt)) {
          try {
            const cached = ensureThumb(resolved);
            streamFile(cached, res);
          } catch (thumbErr) {
            res.writeHead(500, { 'content-type': 'text/plain' });
            res.end(`thumbnail generation failed: ${thumbErr.message}\n`);
          }
        } else {
          streamFile(resolved, res);
        }
      });
      return;
    }
    res.writeHead(400, { 'content-type': 'text/plain' });
    res.end('bad request\n');
    return;
  }

  // Static files
  if (url === '/' || url === '') {
    streamFile(path.join(STATIC_ROOT, 'index.html'), res);
    return;
  }

  const cleanPath = url.split('?')[0];
  let decoded;
  try { decoded = decodeURIComponent(cleanPath); } catch { res.writeHead(400); res.end(); return; }
  const fullPath = path.normalize(path.join(STATIC_ROOT, decoded));
  if (!fullPath.startsWith(STATIC_ROOT)) { res.writeHead(400); res.end(); return; }

  fs.stat(fullPath, (err, stat) => {
    if (err || !stat.isFile()) {
      // SPA fallback
      streamFile(path.join(STATIC_ROOT, 'index.html'), res);
    } else {
      streamFile(fullPath, res);
    }
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`klapaucius frontend-server listening on http://0.0.0.0:${PORT}`);
  console.log(`  static:      ${STATIC_ROOT}`);
  console.log(`  blog-assets: ${BLOG_ROOT}`);
  console.log(`  /api/*    -> http://${API_TARGET.host}:${API_TARGET.port}`);
});
