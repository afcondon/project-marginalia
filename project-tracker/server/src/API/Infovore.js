// FFI for API.Infovore — the Infovore markdown ProjectSource.
//
// The "press" (this server) federates two sources for the project Register:
// the tracker DuckDB (engineering realm) and a folder of frontmatter-markdown
// files in the infovore-larder-db repo (the personal "life" realm). A
// folder-of-markdown IS the bare reference ProjectSource: no DB, no service,
// just files with YAML-ish frontmatter + a body.
//
// This module reads that folder and emits project cards in EXACTLY the shape
// Projects.js#buildProjectListJson produces, so the frontend Register renders
// them identically with no client change.
//
// Dedupe-by-id is the bridge that makes the weave→drop migration seamless:
// while a life-project row STILL exists in the tracker DB (before the drop),
// the DB copy wins and the markdown copy is suppressed — no doubles. Once the
// row is dropped, the markdown copy is the only source and the project keeps
// appearing in the paper. So "weave first, then drop" never flickers.

import fs from 'fs';
import path from 'path';
import os from 'os';

// The life-projects markdown root. One subdirectory per domain
// (woodworking/, house/, garden/), each holding <slug>.md files.
// Overridable via INFOVORE_PROJECTS_DIR so the MacMini deploy can point at
// its own checkout; default matches the MacBook Pro layout.
const _defaultDir = path.join(
  os.homedir(), 'work', 'afc-work', 'infovore-larder-db', 'life-projects'
);
const LIFE_DIR = process.env.INFOVORE_PROJECTS_DIR || _defaultDir;

// Attachment store + URL mapping — duplicated from Projects.js because
// PureScript FFI files are copied per-module to output/, so cross-file JS
// imports don't survive compilation. (The codebase prefers a few lines of
// duplication over a bundler pipeline; see Projects.js / Agent.js.)
const _defaultStore = '/Volumes/Crucial4TB/Documents/Notes Attachments/';
const _rawStore = process.env.MARGINALIA_ATTACHMENT_STORE || _defaultStore;
const ATTACHMENT_STORE =
  _rawStore.endsWith('/') ? _rawStore : _rawStore + '/';

const filePathToAttachmentUrl = (filePath) => {
  if (!filePath) return null;
  return filePath.startsWith(ATTACHMENT_STORE)
    ? '/attachments/' + filePath.slice(ATTACHMENT_STORE.length)
    : null;
};

// Stable synthetic id for a markdown file that carries no tracker_id. Negative
// and well clear of any DuckDB sequence value, so it can never collide with a
// real project id (and dedupe-by-id simply never matches it). Lets the source
// work for brand-new markdown-only projects too, not just the migrated 33.
const synthId = (slug) => {
  let h = 0;
  for (let i = 0; i < slug.length; i++) {
    h = (h * 31 + slug.charCodeAt(i)) | 0;
  }
  return -2000000 - (Math.abs(h) % 1000000);
};

// Minimal frontmatter parser. The files are machine-written with simple
// `key: value` lines between `---` fences, so a full YAML parser would be
// overkill (and a dependency). Returns { fm, body, description } or null.
const parseFile = (filePath) => {
  let raw;
  try { raw = fs.readFileSync(filePath, 'utf-8'); } catch { return null; }
  const m = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) return null;
  const fm = {};
  for (const line of m[1].split('\n')) {
    const idx = line.indexOf(':');
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    let val = line.slice(idx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    fm[key] = val;
  }
  const body = m[2];
  // Description = everything before the first structured section ("## Notes"
  // or "## Attachments"), or the whole body if there is none, trimmed.
  let desc = body;
  const sectionIdx = body.search(/^##\s+(Notes|Attachments)\b/m);
  if (sectionIdx !== -1) desc = body.slice(0, sectionIdx);
  desc = desc.trim();
  return { fm, body, description: desc };
};

// Extract the body of a "## <name>" section: everything after the heading up
// to the next "## " heading (or EOF). Null if the section is absent.
const section = (body, name) => {
  const re = new RegExp('^##\\s+' + name + '\\s*\\n([\\s\\S]*?)(?=^##\\s|$(?![\\s\\S]))', 'm');
  const m = body.match(re);
  return m ? m[1] : null;
};

// Minimal extension→MIME map for attachment entries (images dominate; the
// frontend uses mimeType to decide thumbnail vs link tile).
const MIME_BY_EXT = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.gif': 'image/gif', '.webp': 'image/webp', '.heic': 'image/heic',
  '.pdf': 'application/pdf', '.md': 'text/markdown', '.txt': 'text/plain',
};
const mimeFor = (p) =>
  MIME_BY_EXT[path.extname(p).toLowerCase()] || 'application/octet-stream';

// Map one parsed file to a project card in buildProjectListJson shape, plus an
// internal _filePath / _body for the detail builder (stripped before emit).
const fileToCard = (domainName, filePath) => {
  const parsed = parseFile(filePath);
  if (!parsed) return null;
  const fm = parsed.fm;
  const slug = path.basename(filePath, '.md');
  const hasTracker = fm.tracker_id != null && fm.tracker_id !== '';
  const id = hasTracker ? Number(fm.tracker_id) : synthId(slug);
  // A life-project may nest under another (loose folder grouping). tracker_id
  // == the project id, so parent_tracker_id maps straight to parentId; this
  // keeps the migration lossless even though the source is "just markdown".
  const parentId = (fm.parent_tracker_id != null && fm.parent_tracker_id !== '')
    ? Number(fm.parent_tracker_id) : null;
  return {
    id,
    slug,
    parentId,
    name: fm.title || slug,
    domain: fm.domain || domainName,
    subdomain: fm.subdomain || null,
    status: fm.status || 'idea',
    description: parsed.description || null,
    createdAt: fm.created || null,
    updatedAt: fm.updated || fm.created || null,
    tags: [],
    coverUrl: null,
    blogStatus: null,
    // Single-line frontmatter only (the minimal parser is line-based); life
    // projects are written in the owner's voice anyway, so this is optional.
    humanSummary: fm.human_summary || null,
    _filePath: filePath,
    _body: parsed.body,
  };
};

// Read every life-project markdown file under LIFE_DIR/<domain>/*.md.
const readAllCards = () => {
  const cards = [];
  let entries;
  try { entries = fs.readdirSync(LIFE_DIR, { withFileTypes: true }); }
  catch { return cards; }            // dir absent on this host → no life source
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const domainDir = path.join(LIFE_DIR, e.name);
    let files;
    try { files = fs.readdirSync(domainDir); } catch { continue; }
    for (const f of files) {
      if (!f.endsWith('.md')) continue;
      const card = fileToCard(e.name, path.join(domainDir, f));
      if (card) cards.push(card);
    }
  }
  return cards;
};

// Map DB rows to the same card shape buildProjectListJson uses.
const dbRowToCard = (row) => ({
  id: Number(row.id),
  slug: row.slug || null,
  parentId: row.parent_id != null ? Number(row.parent_id) : null,
  name: row.name,
  domain: row.domain,
  subdomain: row.subdomain || null,
  status: row.status,
  description: row.description || null,
  updatedAt: row.updated_at || null,
  tags: row.tags ? row.tags.split(', ').filter(t => t.trim()) : [],
  coverUrl: filePathToAttachmentUrl(row.cover_path),
  blogStatus: row.blog_status || null,
  humanSummary: row.human_summary || null,
});

// Editorial order for the Register: living projects above terminal ones
// (done / evolved / defunct), updatedAt DESC within each class, NULLS LAST.
// The first card renders as the front-page Lead, so without the class split
// a bulk curation pass (status transitions bump updated_at) puts tombstones
// above the fold. Status-filtered views are single-class, hence unaffected.
const isTerminal = (s) => s === 'done' || s === 'evolved' || s === 'defunct';

const byUpdatedDesc = (a, b) => {
  const ta = isTerminal(a.status) ? 1 : 0;
  const tb = isTerminal(b.status) ? 1 : 0;
  if (ta !== tb) return ta - tb;
  if (!a.updatedAt && !b.updatedAt) return 0;
  if (!a.updatedAt) return 1;
  if (!b.updatedAt) return -1;
  return a.updatedAt < b.updatedAt ? 1 : (a.updatedAt > b.updatedAt ? -1 : 0);
};

// GET /api/projects, federated. Takes the already-filtered DB rows and the
// same query filters, applies them to the markdown source, dedupes, merges.
// Curried + thunked: (rows)(domain)(status)(tag)(search)() : String  [Effect].
export const federatedListJson_ =
  (rows) => (domain) => (status) => (tag) => (search) => () => {
    const dbCards = (rows || []).map(dbRowToCard);
    const dbIds = new Set(dbCards.map(c => c.id));

    // A tag filter can never match a life-project (they carry no tags), so
    // suppress the whole source rather than read the disk for nothing.
    let life = (tag != null) ? [] : readAllCards();

    if (domain != null) life = life.filter(c => c.domain === domain);
    if (status != null) life = life.filter(c => c.status === status);
    if (search != null) {
      const q = String(search).toLowerCase();
      life = life.filter(c =>
        (c.name && c.name.toLowerCase().includes(q)) ||
        (c.description && c.description.toLowerCase().includes(q)));
    }

    // Dedupe: DB wins while the row still exists (pre-drop). Post-drop the
    // markdown copy is the only one and survives.
    life = life.filter(c => !dbIds.has(c.id));

    const clean = life.map(({ _filePath, _body, createdAt, ...rest }) => rest);
    const projects = dbCards.concat(clean);
    projects.sort(byUpdatedDesc);
    return JSON.stringify({ projects, count: projects.length });
  };

// GET /api/stats, federated. Takes the three DB result sets Stats.purs already
// queries, plus the full project-id list for dedupe, and folds the markdown
// life-projects into totals / domains / byDomain so the nav pills agree with
// the federated Register (masthead). Same dedupe-by-id bridge as the list:
// a card whose tracker_id still exists as a DB row is not double-counted.
// No Maybe args, so no PureScript-side wrapper — exported under the foreign
// import's own name, unlike the underscore-suffixed pairs above.
// Curried + thunked: (dsRows)(totalsRows)(domainRows)(idRows)() : String  [Effect].
export const federatedStatsJson =
  (domainStatusRows) => (totalsRows) => (domainRows) => (idRows) => () => {
    const totals = totalsRows && totalsRows.length > 0 ? totalsRows[0] : {};
    let totalProjects = Number(totals.total_projects) || 0;

    const byDomain = {};
    for (const row of (domainStatusRows || [])) {
      const domain = row.domain;
      if (!byDomain[domain]) {
        byDomain[domain] = { domain, statuses: {}, total: 0 };
      }
      const count = Number(row.project_count) || 0;
      byDomain[domain].statuses[row.status] = count;
      byDomain[domain].total += count;
    }

    const dbIds = new Set((idRows || []).map(r => Number(r.id)));
    const domainSet = new Set((domainRows || []).map(r => r.domain));
    for (const card of readAllCards()) {
      if (dbIds.has(card.id)) continue;
      domainSet.add(card.domain);
      if (!byDomain[card.domain]) {
        byDomain[card.domain] = { domain: card.domain, statuses: {}, total: 0 };
      }
      const d = byDomain[card.domain];
      d.statuses[card.status] = (d.statuses[card.status] || 0) + 1;
      d.total += 1;
      totalProjects += 1;
    }

    return JSON.stringify({
      totals: {
        projects: totalProjects,
        tags: Number(totals.total_tags) || 0,
        dependencies: Number(totals.total_dependencies) || 0,
        notes: Number(totals.total_notes) || 0
      },
      domains: Array.from(domainSet).sort(),
      byDomain: Object.values(byDomain)
    });
  };

// GET /api/projects/:id fallback. Returns a detail-shaped JSON string for the
// life-project carrying that id, or null if none. Notes come from the
// "## Notes" section (one note per "- " bullet); deps/attachments are empty —
// a life-project is a capability-light source (read-and-steer, not full CRUD).
// Curried + thunked: (id)() : Nullable String  [Effect].
export const detailJson_ = (pid) => () => {
  const card = readAllCards().find(c => c.id === pid);
  if (!card) return null;

  const notes = [];
  const notesBody = section(card._body, 'Notes');
  if (notesBody) {
    let nid = 1;
    for (const line of notesBody.split('\n')) {
      const t = line.trim();
      if (t.startsWith('- ')) {
        notes.push({
          id: nid++,
          content: t.slice(2).trim(),
          author: 'infovore',
          createdAt: card.updatedAt,
        });
      }
    }
  }

  // "## Attachments" — one per "- " bullet: `- <abs path> | <description>`
  // (description optional). Same URL mapping as DB attachments, so anything
  // under the attachment store renders via /attachments/*.
  const attachments = [];
  const attBody = section(card._body, 'Attachments');
  if (attBody) {
    let aid = 1;
    for (const line of attBody.split('\n')) {
      const t = line.trim();
      if (!t.startsWith('- ')) continue;
      const [rawPath, ...rest] = t.slice(2).split(' | ');
      const filePath = rawPath.trim();
      if (!filePath) continue;
      attachments.push({
        id: aid++,
        filename: path.basename(filePath),
        mimeType: mimeFor(filePath),
        url: filePathToAttachmentUrl(filePath),
        description: rest.length ? rest.join(' | ').trim() || null : null,
        createdAt: card.updatedAt,
      });
    }
  }

  return JSON.stringify({
    id: card.id,
    slug: card.slug,
    parentId: null,
    name: card.name,
    domain: card.domain,
    subdomain: card.subdomain,
    status: card.status,
    evolvedInto: null,
    description: card.description,
    sourceUrl: null,
    sourcePath: card._filePath,
    repo: null,
    preferredView: null,
    blogStatus: null,
    blogContent: null,
    humanSummary: card.humanSummary,
    tags: [],
    createdAt: card.createdAt,
    updatedAt: card.updatedAt,
    notes,
    dependencies: { blocking: [], blockedBy: [] },
    attachments,
  });
};
