// FFI for API.Projects

// Read a string field from a row object. Returns "" if missing/null.
export const getRowString_ = (key) => (row) => {
  if (row == null) return "";
  const v = row[key];
  return v == null ? "" : String(v);
};
// JSON response builders only — marshalling Foreign (DuckDB rows) to JSON strings.
// All body parsing and SQL construction is in PureScript.

// Canonical attachment store. Paths under this prefix are served to the
// browser at /attachments/... via a symlink in the frontend's public dir.
// Overridable via MARGINALIA_ATTACHMENT_STORE so fresh clones on other
// machines (e.g. the MacMini demo instance) can point at a local directory
// instead of the Crucial4TB external drive. Default preserves the author's
// MacBook Pro behaviour exactly.
//
// Duplicated inline in Agent.js — PureScript FFI files get copied to the
// compiled output tree, so cross-file JS imports don't survive compilation.
// Ten lines of duplication is cheaper than a bundler pipeline.
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

// Build JSON array of projects (from project_with_tags view rows)
export const buildProjectListJson = (rows) => {
  const projects = (rows || []).map(row => ({
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
    blogStatus: row.blog_status || null
  }));
  return JSON.stringify({ projects, count: projects.length });
};

// Blog drafts directory — duplicated from BlogDrafts.js (FFI files can't import
// each other since PureScript copies them to output/foreign.js per module).
import fs from 'fs';
import path from 'path';
import os from 'os';
const _defaultDraftsDir = path.join(os.homedir(), 'Documents', 'marginalia-blog-drafts');
const _rawDraftsDir = process.env.MARGINALIA_BLOG_DRAFTS || _defaultDraftsDir;
const BLOG_DRAFTS_DIR = _rawDraftsDir.endsWith('/') ? _rawDraftsDir.slice(0, -1) : _rawDraftsDir;

// Build JSON for the Letters Page (GET /api/blog/drafts). Reads each
// project's <slug>.md from disk for word count and filename.
export const buildBlogDraftsJson_ = (rows) => () => {
  const drafts = (rows || []).map(row => {
    const slug = row.slug || '';
    const filename = slug ? slug + '.md' : null;
    let wordCount = 0;
    let hasFile = false;
    if (slug) {
      try {
        const content = fs.readFileSync(path.join(BLOG_DRAFTS_DIR, slug + '.md'), 'utf-8');
        hasFile = true;
        // Word count: split on whitespace, ignore empty tokens and markdown
        // frontmatter/headings (rough but good enough for a summary).
        wordCount = content.split(/\s+/).filter(w => w.length > 0).length;
      } catch { /* file doesn't exist yet */ }
    }
    return {
      id: Number(row.id),
      slug,
      name: row.name || '',
      domain: row.domain || '',
      blogStatus: row.blog_status || null,
      filename,
      wordCount,
      hasFile,
    };
  });
  return JSON.stringify({ drafts, count: drafts.length });
};

// Build JSON for a single project with notes, dependencies, and attachments
export const buildProjectDetailJson = (project) => (notes) => (deps) => (attachments) => {
  const projectId = Number(project.id);

  const blocking = [];
  const blockedBy = [];
  for (const d of (deps || [])) {
    if (Number(d.blocker_id) === projectId) {
      blocking.push({
        projectId: Number(d.blocked_id),
        projectName: d.blocked_name,
        projectStatus: d.blocked_status,
        dependencyType: d.dependency_type
      });
    } else {
      blockedBy.push({
        projectId: Number(d.blocker_id),
        projectName: d.blocker_name,
        projectStatus: d.blocker_status,
        dependencyType: d.dependency_type
      });
    }
  }

  return JSON.stringify({
    id: projectId,
    slug: project.slug || null,
    parentId: project.parent_id != null ? Number(project.parent_id) : null,
    name: project.name,
    domain: project.domain,
    subdomain: project.subdomain || null,
    status: project.status,
    evolvedInto: project.evolved_into != null ? Number(project.evolved_into) : null,
    description: project.description || null,
    sourceUrl: project.source_url || null,
    sourcePath: project.source_path || null,
    repo: project.repo || null,
    preferredView: project.preferred_view || null,
    blogStatus: project.blog_status || null,
    blogContent: project.blog_content || null,
    tags: project.tags ? project.tags.split(', ').filter(t => t.trim()) : [],
    createdAt: project.created_at,
    updatedAt: project.updated_at,
    notes: (notes || []).map(n => ({
      id: Number(n.id),
      content: n.content,
      author: n.author,
      createdAt: n.created_at
    })),
    dependencies: {
      blocking,
      blockedBy
    },
    attachments: (attachments || []).map(a => ({
      id: Number(a.id),
      filename: a.filename,
      mimeType: a.mime_type,
      url: filePathToAttachmentUrl(a.file_path),
      description: a.description || null,
      createdAt: a.created_at
    }))
  });
};
