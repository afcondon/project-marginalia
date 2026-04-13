// FFI for API.Sources
//
// Source browsing: reads infovore databases and JSON files to provide
// concert tickets, photos, and music as blog post source material.

import fs from 'fs';
import path from 'path';
import os from 'os';
import Database from 'better-sqlite3';

// =============================================================================
// Paths to infovore data
// =============================================================================

const INFOVORE_ROOT = process.env.INFOVORE_ROOT
  || path.join(os.homedir(), 'work', 'afc-work', 'infovore-larder-db');

const TICKETS_JSON = path.join(INFOVORE_ROOT, 'data', 'notes', 'ticket-reviewed.json');
const PHOTOS_DB = path.join(INFOVORE_ROOT, 'data', 'photos', 'catalog.db');
const MUSIC_DB = path.join(INFOVORE_ROOT, 'data', 'music', 'library.db');

const _defaultBlogRoot = path.join(os.homedir(), 'Documents', 'klapaucius');
const _rawBlogRoot = process.env.KLAPAUCIUS_ROOT || _defaultBlogRoot;
const BLOG_ROOT = _rawBlogRoot.endsWith('/') ? _rawBlogRoot.slice(0, -1) : _rawBlogRoot;

// =============================================================================
// Concert Tickets
// =============================================================================

// Read ticket-reviewed.json, sort by artist, return JSON string.
export const readTicketsJson = () => {
  try {
    const raw = fs.readFileSync(TICKETS_JSON, 'utf-8');
    const parsed = JSON.parse(raw);
    const tickets = parsed.images || parsed;
    // Sort by artist, then date
    const sorted = tickets
      .filter(t => t.status === 'keep')
      .sort((a, b) => {
        const cmp = (a.artist || '').localeCompare(b.artist || '');
        if (cmp !== 0) return cmp;
        return (a.date || '').localeCompare(b.date || '');
      })
      .map((t, i) => ({
        idx: i,
        artist: t.artist || 'Unknown',
        venue: t.venue || '',
        date: t.date || '',
        city: t.city || '',
        price: t.price || '',
        notes: t.notes || '',
        filename: t.filename || '',
      }));
    return JSON.stringify({ tickets: sorted, count: sorted.length });
  } catch (e) {
    return JSON.stringify({ tickets: [], count: 0, error: String(e.message || e) });
  }
};

// =============================================================================
// Photos by Date
// =============================================================================

// Query catalog.db for photos on a given date.
// dateStr can be:
//   "YYYY-MM-DD" — specific day
//   "MM-DD"      — that day across all years
export const queryPhotosJson = (dateStr) => () => {
  try {
    const db = new Database(PHOTOS_DB, { readonly: true });

    let sql, params;
    if (/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) {
      // Full date: match the date prefix of capture_time
      sql = `
        SELECT p.image_id, p.file_name, p.capture_time, p.rating,
               p.file_width, p.file_height, p.file_extension,
               pf.file_path, pf.volume_name
        FROM photos p
        LEFT JOIN photo_files pf ON p.image_id = pf.image_id AND pf.file_type = 'negative'
        WHERE p.capture_time LIKE ? || '%'
        ORDER BY p.capture_time, p.file_name
      `;
      params = [dateStr];
    } else if (/^\d{2}-\d{2}$/.test(dateStr)) {
      // Month-day only: match across all years
      sql = `
        SELECT p.image_id, p.file_name, p.capture_time, p.rating,
               p.file_width, p.file_height, p.file_extension,
               pf.file_path, pf.volume_name
        FROM photos p
        LEFT JOIN photo_files pf ON p.image_id = pf.image_id AND pf.file_type = 'negative'
        WHERE substr(p.capture_time, 6, 5) = ?
        ORDER BY p.capture_time, p.file_name
      `;
      params = [dateStr];
    } else {
      db.close();
      return JSON.stringify({ photos: [], count: 0, error: 'Invalid date format' });
    }

    const rows = db.prepare(sql).all(...params);
    db.close();

    const photos = rows.map(r => ({
      imageId: r.image_id,
      fileName: r.file_name || '',
      captureTime: r.capture_time || '',
      rating: r.rating || 0,
      width: r.file_width || 0,
      height: r.file_height || 0,
      extension: r.file_extension || '',
      filePath: r.file_path || '',
      // URL for serving through the frontend proxy
      thumbUrl: r.file_path ? '/source-media' + r.file_path : null,
    }));

    return JSON.stringify({ photos, count: photos.length });
  } catch (e) {
    return JSON.stringify({ photos: [], count: 0, error: String(e.message || e) });
  }
};

// =============================================================================
// Photo Import — copy a photo into a post's asset directory
// =============================================================================

const SLUG_RE = /^[a-z][a-z0-9-]*$/;
const isSafeSlug = (s) =>
  typeof s === 'string' && s.length > 0 && s.length <= 200 && SLUG_RE.test(s);

export const importPhotoAsset = (category) => (slug) => (photoPath) => () => {
  if (!isSafeSlug(slug)) {
    return JSON.stringify({ error: 'invalid slug' });
  }
  try {
    if (!fs.existsSync(photoPath)) {
      return JSON.stringify({ error: 'Photo file not found: ' + photoPath });
    }

    const dir = path.join(BLOG_ROOT, category, slug);
    fs.mkdirSync(dir, { recursive: true });

    const destName = path.basename(photoPath);
    const destPath = path.join(dir, destName);
    fs.copyFileSync(photoPath, destPath);

    // Also create a minimal index.md if it doesn't exist
    const indexPath = path.join(dir, 'index.md');
    if (!fs.existsSync(indexPath)) {
      fs.writeFileSync(indexPath, '![' + destName + '](' + destName + ')\n\n', { flag: 'wx' });
    }

    const markdown = '![' + destName + '](' + destName + ')';
    return JSON.stringify({ ok: true, filename: destName, markdown });
  } catch (e) {
    return JSON.stringify({ error: String(e.message || e) });
  }
};

// =============================================================================
// Music Lookup
// =============================================================================

// =============================================================================
// Directory Browsing
// =============================================================================

// List directory contents, sorted directories-first then alphabetically.
export const listDirectoryJson = (dirPath) => () => {
  try {
    const entries = fs.readdirSync(dirPath, { withFileTypes: true });
    const items = entries
      .filter(e => !e.name.startsWith('.'))
      .map(e => ({
        name: e.name,
        isDirectory: e.isDirectory(),
        path: path.join(dirPath, e.name),
      }))
      .sort((a, b) => {
        if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
    return JSON.stringify({ items, count: items.length, path: dirPath });
  } catch (e) {
    return JSON.stringify({ items: [], count: 0, path: dirPath, error: String(e.message || e) });
  }
};

// Look up track metadata by file path from library.db.
export const lookupMusicByPath = (filePath) => () => {
  try {
    const db = new Database(MUSIC_DB, { readonly: true });
    const row = db.prepare(`
      SELECT name, artist, album_artist, album, genre, year,
             rating, play_count, total_time, file_path
      FROM tracks
      WHERE file_path = ?
    `).get(filePath);
    db.close();

    if (!row) return JSON.stringify(null);
    return JSON.stringify({
      name: row.name || '',
      artist: row.artist || '',
      albumArtist: row.album_artist || '',
      album: row.album || '',
      genre: row.genre || '',
      year: row.year || 0,
      rating: row.rating || 0,
      playCount: row.play_count || 0,
      totalTime: row.total_time || 0,
      filePath: row.file_path || '',
    });
  } catch (e) {
    return JSON.stringify(null);
  }
};
