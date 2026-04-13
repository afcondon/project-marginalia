// FFI for API.Posts
//
// Blog post storage: $KLAPAUCIUS_ROOT/<category>/<slug>/index.md + assets
// Default root: ~/Documents/klapaucius

import fs from 'fs';
import path from 'path';
import os from 'os';

const _defaultRoot = path.join(os.homedir(), 'Documents', 'klapaucius');
const _rawRoot = process.env.KLAPAUCIUS_ROOT || _defaultRoot;
const BLOG_ROOT = _rawRoot.endsWith('/') ? _rawRoot.slice(0, -1) : _rawRoot;

// Safety checks
const SLUG_RE = /^[a-z][a-z0-9-]*$/;
const isSafeSlug = (s) =>
  typeof s === 'string' && s.length > 0 && s.length <= 200 && SLUG_RE.test(s);
const SAFE_FN_RE = /^[a-z0-9_.-]+$/i;
const isSafeFilename = (s) =>
  typeof s === 'string' && s.length > 0 && s.length <= 200
  && SAFE_FN_RE.test(s) && !s.includes('..');

const postDir = (category, slug) => path.join(BLOG_ROOT, category, slug);
const postFile = (category, slug) => path.join(BLOG_ROOT, category, slug, 'index.md');

// Read a post's index.md and compute word count. Returns { wordCount, hasFile }.
const readPostInfo = (category, slug) => {
  if (!isSafeSlug(slug)) return { wordCount: 0, hasFile: false };
  const p = postFile(category, slug);
  try {
    const content = fs.readFileSync(p, 'utf-8');
    const wordCount = content.split(/\s+/).filter(w => w.length > 0).length;
    return { wordCount, hasFile: true };
  } catch {
    return { wordCount: 0, hasFile: false };
  }
};

// Row field helpers
export const getRowString_ = (key) => (row) => {
  if (row == null) return '';
  const v = row[key];
  return v == null ? '' : String(v);
};

export const getRowInt_ = (key) => (row) => {
  if (row == null) return 0;
  const v = row[key];
  return v == null ? 0 : Number(v);
};

// Build JSON list of posts, enriched with disk info
export const enrichPostRows = (rows) => () => {
  const posts = (rows || []).map(row => {
    const info = readPostInfo(row.category, row.slug);
    return {
      id: Number(row.id),
      category: row.category || '',
      slug: row.slug || '',
      title: row.title || '',
      status: row.status || 'wanted',
      sourceType: row.source_type || null,
      sourceId: row.source_id || null,
      wordCount: info.wordCount,
      hasFile: info.hasFile,
      createdAt: row.created_at || null,
      updatedAt: row.updated_at || null,
    };
  });
  return JSON.stringify({ posts, count: posts.length });
};

// Build JSON for a single post detail
export const buildPostDetailJson = (row) => {
  const info = readPostInfo(row.category, row.slug);
  return JSON.stringify({
    id: Number(row.id),
    category: row.category || '',
    slug: row.slug || '',
    title: row.title || '',
    status: row.status || 'wanted',
    sourceType: row.source_type || null,
    sourceId: row.source_id || null,
    sourceMeta: row.source_meta || null,
    wordCount: info.wordCount,
    hasFile: info.hasFile,
    createdAt: row.created_at || null,
    updatedAt: row.updated_at || null,
  });
};

// Build JSON for a list of posts (no enrichment — used by buildPostListJson)
export const buildPostListJson = (rows) => {
  const posts = (rows || []).map(row => ({
    id: Number(row.id),
    category: row.category || '',
    slug: row.slug || '',
    title: row.title || '',
    status: row.status || 'wanted',
    sourceType: row.source_type || null,
    wordCount: Number(row.word_count || 0),
    hasFile: Boolean(row.has_file),
    createdAt: row.created_at || null,
    updatedAt: row.updated_at || null,
  }));
  return JSON.stringify({ posts, count: posts.length });
};

// Build stats JSON
export const buildStatsJson = (statusRows) => (categoryRows) => {
  const byStatus = {};
  for (const r of (statusRows || [])) byStatus[r.status] = Number(r.cnt);
  const byCategory = {};
  for (const r of (categoryRows || [])) byCategory[r.category] = Number(r.cnt);
  const total = Object.values(byStatus).reduce((a, b) => a + b, 0);
  return JSON.stringify({ total, byStatus, byCategory });
};

// Build categories JSON
export const buildCategoriesJson = (rows) => {
  const categories = (rows || []).map(r => ({
    category: r.category,
    count: Number(r.cnt),
  }));
  return JSON.stringify({ categories });
};

// List asset files in <category>/<slug>/ (excluding index.md)
export const listAssetsJson = (category) => (slug) => () => {
  if (!isSafeSlug(slug)) return JSON.stringify({ assets: [], count: 0 });
  const dir = postDir(category, slug);
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    const assets = entries
      .filter(e => e.isFile() && e.name !== 'index.md')
      .map(e => {
        const stat = fs.statSync(path.join(dir, e.name));
        return {
          filename: e.name,
          size: stat.size,
          url: '/blog-assets/' + category + '/' + slug + '/' + e.name,
          markdown: '![' + e.name + '](' + e.name + ')',
        };
      });
    return JSON.stringify({ assets, count: assets.length });
  } catch {
    return JSON.stringify({ assets: [], count: 0 });
  }
};

// Save a base64-encoded file to <category>/<slug>/<filename>
export const saveAssetToDisk = (category) => (slug) => (filename) => (base64Data) => () => {
  if (!isSafeSlug(slug) || !isSafeFilename(filename)) {
    return JSON.stringify({ error: 'invalid slug or filename' });
  }
  const dir = postDir(category, slug);
  const absPath = path.join(dir, filename);
  const resolved = path.resolve(absPath);
  if (!resolved.startsWith(path.resolve(BLOG_ROOT))) {
    return JSON.stringify({ error: 'path escape' });
  }
  try {
    fs.mkdirSync(dir, { recursive: true });
    const buf = Buffer.from(base64Data, 'base64');
    fs.writeFileSync(absPath, buf);
    const markdown = '![' + filename + '](' + filename + ')';
    return JSON.stringify({ ok: true, filename, markdown });
  } catch (e) {
    return JSON.stringify({ error: String((e && e.message) || e) });
  }
};
