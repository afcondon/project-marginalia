// FFI for BlogDrafts.purs
//
// Blog drafts live as <projectId>.md files on disk in $MARGINALIA_BLOG_DRAFTS
// (default ~/Documents/marginalia-blog-drafts). The file is source of
// truth. The browser UI shows a read-only preview; writes happen in VS
// Code, which we shell out to via `open -a "Visual Studio Code" <path>`.
//
// The env var default mirrors the ATTACHMENT_STORE pattern in
// API/Projects.js and API/Agent.js — duplicated inline rather than
// imported because FFI JS files each get their own output/foreign.js and
// cross-file imports don't survive compilation.

import fs from 'fs';
import path from 'path';
import os from 'os';
import { spawn } from 'child_process';

const _defaultDrafts = path.join(os.homedir(), 'Documents', 'marginalia-blog-drafts');
const _rawDrafts = process.env.MARGINALIA_BLOG_DRAFTS || _defaultDrafts;
// Strip trailing slash so path.join composes cleanly.
const BLOG_DRAFTS_DIR = _rawDrafts.endsWith('/')
  ? _rawDrafts.slice(0, -1)
  : _rawDrafts;

// Defensive key validation, the last line of defence before a filesystem
// operation. It used to guard a slug against a NATO-callsign regex; the key
// is now the project id, so the guard is that it is a positive whole number
// and nothing else. `-1` and `0` are refused too, not because the filesystem
// would mind but because Tree.js hands those out to the synthetic root and
// domain nodes, which are not projects and have no drafts.
const isSafeKey = (n) => Number.isSafeInteger(n) && n > 0;
const keyOf = (n) => String(n);

const draftPath = (projectId) => path.join(BLOG_DRAFTS_DIR, keyOf(projectId) + '.md');

// Read the draft file for a given project. Returns null if missing, invalid,
// or unreadable — never throws, so a missing file can't break GET requests.
export const readDraft_ = (projectId) => () => {
  if (!isSafeKey(projectId)) return null;
  try {
    return fs.readFileSync(draftPath(projectId), 'utf-8');
  } catch (e) {
    return null;
  }
};

// Ensure the drafts directory and the <projectId>.md file exist. If the file
// is already there, leave it alone. Returns a tagged record consumed in
// PureScript — same shape as Filesystem.renameProjectDirectory_'s result.
export const ensureDraft_ = (projectId) => (projectName) => () => {
  if (!isSafeKey(projectId)) {
    return { kind: 'error', absPath: '', error: 'invalid project id: ' + String(projectId) };
  }
  const absPath = draftPath(projectId);
  try {
    fs.mkdirSync(BLOG_DRAFTS_DIR, { recursive: true });
    if (!fs.existsSync(absPath)) {
      const safeName = projectName && projectName.length > 0 ? projectName : 'Untitled';
      const template = '# ' + safeName + '\n\n*Project: #' + keyOf(projectId) + '*\n\n';
      // flag 'wx' fails if the file exists — atomic race safety.
      fs.writeFileSync(absPath, template, { flag: 'wx' });
    }
    return { kind: 'opened', absPath, error: '' };
  } catch (e) {
    // Race: another writer created the file between existsSync and writeFileSync.
    // Treat as success — the file is there, we just didn't write it.
    if (e && e.code === 'EEXIST') {
      return { kind: 'opened', absPath, error: '' };
    }
    return { kind: 'error', absPath: '', error: String((e && e.message) || e) };
  }
};

// Write a draft file with the given body only if it does not already
// exist. Used by the one-time startup migration that hoists pre-existing
// DB blog_content values onto disk.
export const writeDraftIfMissing_ = (projectId) => (body) => () => {
  if (!isSafeKey(projectId)) {
    return { kind: 'error', absPath: '', error: 'invalid project id: ' + String(projectId) };
  }
  const absPath = draftPath(projectId);
  try {
    fs.mkdirSync(BLOG_DRAFTS_DIR, { recursive: true });
    if (fs.existsSync(absPath)) {
      return { kind: 'skipped', absPath, error: '' };
    }
    fs.writeFileSync(absPath, body, { flag: 'wx' });
    return { kind: 'written', absPath, error: '' };
  } catch (e) {
    if (e && e.code === 'EEXIST') {
      return { kind: 'skipped', absPath, error: '' };
    }
    return { kind: 'error', absPath: '', error: String((e && e.message) || e) };
  }
};

// Spawn `open -a "Visual Studio Code" <absPath>` to bring VS Code to the
// foreground with the file open. macOS-only: guarded by process.platform.
// Returns immediately; the child is detached+unref'd so VS Code outlives
// the marginalia server if it restarts.
export const openInVSCode_ = (absPath) => () => {
  if (process.platform !== 'darwin') {
    return { kind: 'error', absPath: absPath, error: 'VS Code spawn only supported on macOS' };
  }
  try {
    const child = spawn('open', ['-a', 'Visual Studio Code', absPath], {
      detached: true,
      stdio: 'ignore',
    });
    // Async error surfacing: if `open` is missing or can't launch, we
    // won't know until after the handler has returned. Log it server-side.
    child.on('error', (err) => {
      console.error('openInVSCode spawn error:', (err && err.message) || err);
    });
    child.unref();
    return { kind: 'ok', absPath: absPath, error: '' };
  } catch (e) {
    return { kind: 'error', absPath: absPath, error: String((e && e.message) || e) };
  }
};

// =============================================================================
// Blog assets — images saved to $BLOG_DRAFTS/<projectId>/ for embedding in drafts
// =============================================================================

const assetDir = (projectId) => path.join(BLOG_DRAFTS_DIR, keyOf(projectId));

// Safe filename: timestamp + optional suffix. Only allow [a-z0-9_-.]
const SAFE_FN_RE = /^[a-z0-9_.-]+$/i;
const isSafeFilename = (s) =>
  typeof s === 'string' && s.length > 0 && s.length <= 200
  && SAFE_FN_RE.test(s) && !s.includes('..');

// Save base64-encoded image data to <projectId>/<filename>. Creates the
// directory if needed. Returns { kind, filename, absPath, error }.
export const saveBlogAsset_ = (projectId) => (filename) => (base64Data) => () => {
  if (!isSafeKey(projectId)) {
    return { kind: 'error', filename: '', absPath: '', error: 'invalid project id' };
  }
  if (!isSafeFilename(filename)) {
    return { kind: 'error', filename: '', absPath: '', error: 'invalid filename' };
  }
  const dir = assetDir(projectId);
  const absPath = path.join(dir, filename);
  // Belt-and-braces: ensure resolved path is inside the drafts dir.
  const resolved = path.resolve(absPath);
  if (!resolved.startsWith(path.resolve(BLOG_DRAFTS_DIR))) {
    return { kind: 'error', filename: '', absPath: '', error: 'path escape' };
  }
  try {
    fs.mkdirSync(dir, { recursive: true });
    const buf = Buffer.from(base64Data, 'base64');
    fs.writeFileSync(absPath, buf);
    return { kind: 'ok', filename, absPath, error: '' };
  } catch (e) {
    return { kind: 'error', filename: '', absPath: '', error: String((e && e.message) || e) };
  }
};

// List image files in <projectId>/ directory. Returns an array of
// { filename, size } objects, or an empty array if the dir is missing.
export const listBlogAssets_ = (projectId) => () => {
  if (!isSafeKey(projectId)) return [];
  const dir = assetDir(projectId);
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    return entries
      .filter(e => e.isFile())
      .map(e => {
        const stat = fs.statSync(path.join(dir, e.name));
        return { filename: e.name, size: stat.size };
      });
  } catch {
    return [];
  }
};

// Mutate a project row in place, overwriting blog_content with the given
// value (or null). Called between the DB read and the JSON builder in
// getProject so buildProjectDetailJson picks up the file contents without
// needing to know anything about disk storage.
export const overrideBlogContent_ = (row) => (contentNullable) => {
  if (row != null) {
    row.blog_content = contentNullable; // null = absent, string = replace
  }
  return row;
};

// Private helper: pull a string field from a Foreign row. Duplicated from
// API/Projects.js so BlogDrafts.purs doesn't need to import from
// API.Projects (which would create a module-level cycle).
export const getRowString_ = (key) => (row) => {
  if (row == null) return '';
  const v = row[key];
  return v == null ? '' : String(v);
};

// Same, for the numeric key the draft files are named by. Returns 0 for a
// missing or unparseable value, which `isSafeKey` then refuses — so a row
// with no usable id is skipped rather than writing to a file called "NaN.md".
export const getRowInt_ = (key) => (row) => {
  if (row == null) return 0;
  const n = Number(row[key]);
  return Number.isSafeInteger(n) ? n : 0;
};
