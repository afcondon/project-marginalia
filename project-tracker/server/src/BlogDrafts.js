// FFI for BlogDrafts.purs
//
// Blog drafts live as <slug>.md files on disk in $MARGINALIA_BLOG_DRAFTS
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

// Defensive slug validation. Slug.purs generates NATO-callsign strings
// joined by hyphens — all [a-z][a-z0-9-]*. This regex is the last line
// of defence before a filesystem operation, belt-and-braces in case the
// slug generator changes or the DB gets hand-edited.
const SLUG_RE = /^[a-z][a-z0-9-]*$/;
const isSafeSlug = (s) =>
  typeof s === 'string' && s.length > 0 && s.length <= 200 && SLUG_RE.test(s);

const draftPath = (slug) => path.join(BLOG_DRAFTS_DIR, slug + '.md');

// Read the draft file for a given slug. Returns null if missing, invalid,
// or unreadable — never throws, so a missing file can't break GET requests.
export const readDraft_ = (slug) => () => {
  if (!isSafeSlug(slug)) return null;
  try {
    return fs.readFileSync(draftPath(slug), 'utf-8');
  } catch (e) {
    return null;
  }
};

// Ensure the drafts directory and the <slug>.md file exist. If the file
// is already there, leave it alone. Returns a tagged record consumed in
// PureScript — same shape as Filesystem.renameProjectDirectory_'s result.
export const ensureDraft_ = (slug) => (projectName) => () => {
  if (!isSafeSlug(slug)) {
    return { kind: 'error', absPath: '', error: 'invalid slug: ' + String(slug) };
  }
  const absPath = draftPath(slug);
  try {
    fs.mkdirSync(BLOG_DRAFTS_DIR, { recursive: true });
    if (!fs.existsSync(absPath)) {
      const safeName = projectName && projectName.length > 0 ? projectName : 'Untitled';
      const template = '# ' + safeName + '\n\n*Project: ' + slug + '*\n\n';
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
export const writeDraftIfMissing_ = (slug) => (body) => () => {
  if (!isSafeSlug(slug)) {
    return { kind: 'error', absPath: '', error: 'invalid slug: ' + String(slug) };
  }
  const absPath = draftPath(slug);
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
