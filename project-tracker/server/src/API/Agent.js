// FFI for API.Agent
// JSON response builders for agent-optimized endpoints.
// All business logic (status lifecycle, validation) lives in PureScript.
// These functions only marshal Foreign (DuckDB rows) -> JSON strings.

// Build compact project list for agent consumption.
// statusOptionsMap: plain JS object keyed by status string -> array of strings.
// Passed from PureScript via allStatusOptions.
export const buildAgentProjectListJson = (rows) => (statusOptionsMap) => {
  const projects = (rows || []).map(row => {
    const status = row.status;
    const statusOptions = statusOptionsMap[status] || [];
    const desc = row.description || null;
    return {
      id: Number(row.id),
      name: row.name,
      domain: row.domain,
      subdomain: row.subdomain || null,
      status,
      description: desc && desc.length > 200 ? desc.slice(0, 200) + "..." : desc,
      repo: row.repo || null,
      statusOptions
    };
  });
  return JSON.stringify(projects);
};

// Build full agent project detail.
// All sub-arrays are raw Rows from DuckDB; this function extracts fields.
export const buildAgentProjectDetailJson = (project) => (tagRows) => (noteRows) => (depRows) => (histRows) => (statusOptions) => {
  const projectId = Number(project.id);

  const tags = (tagRows || []).map(r => r.name).filter(Boolean);

  const recentNotes = (noteRows || []).map(n => ({
    content: n.content,
    author: n.author,
    date: n.date || n.created_at
  }));

  const blocks = [];
  const blockedBy = [];
  for (const d of (depRows || [])) {
    if (Number(d.blocker_id) === projectId) {
      blocks.push({ id: Number(d.blocked_id), name: d.blocked_name });
    } else {
      blockedBy.push({ id: Number(d.blocker_id), name: d.blocker_name });
    }
  }

  const statusHistory = (histRows || []).map(h => ({
    from: h.old_status,
    to: h.new_status,
    date: h.date || h.changed_at,
    reason: h.reason || ""
  }));

  return JSON.stringify({
    id: projectId,
    name: project.name,
    domain: project.domain,
    subdomain: project.subdomain || null,
    status: project.status,
    description: project.description || null,
    repo: project.repo || null,
    sourceUrl: project.source_url || null,
    sourcePath: project.source_path || null,
    tags,
    noteCount: Number(project.note_count) || 0,
    recentNotes,
    dependencies: { blocks, blockedBy },
    statusOptions,
    statusHistory
  });
};

// Build compact project summary returned after a status change.
// No notes, deps, or history — just the updated core fields.
export const buildAgentProjectSummaryJson = (project) => (statusOptions) => {
  return JSON.stringify({
    id: Number(project.id),
    name: project.name,
    domain: project.domain,
    subdomain: project.subdomain || null,
    status: project.status,
    description: project.description || null,
    repo: project.repo || null,
    statusOptions
  });
};

// Build note creation response from the newly inserted note row.
export const buildAgentNoteJson = (row) => {
  return JSON.stringify({
    id: Number(row.id),
    projectId: Number(row.project_id),
    content: row.content,
    author: row.author,
    createdAt: row.created_at
  });
};

// Build attachment creation response from the newly inserted row.
// Mirrors the url-derivation logic in Projects.js: paths under the canonical
// attachment store get a /attachments/ URL; others return url=null.
export const buildAgentAttachmentJson = (row) => {
  const PREFIX = '/Volumes/Crucial4TB/Documents/Notes Attachments/';
  const filePath = row.file_path || '';
  const url = filePath.startsWith(PREFIX)
    ? '/attachments/' + filePath.slice(PREFIX.length)
    : null;
  return JSON.stringify({
    id: Number(row.id),
    projectId: Number(row.project_id),
    filename: row.filename,
    mimeType: row.mime_type,
    filePath: filePath || null,
    url: url,
    description: row.description || null,
    createdAt: row.created_at
  });
};

// Build search results.
// nameRows: projects matching on name; descRows: matching on description.
// Results are deduplicated: name matches take priority.
export const buildAgentSearchJson = (query) => (nameRows) => (descRows) => {
  const seen = new Set();
  const results = [];
  for (const row of (nameRows || [])) {
    const id = Number(row.id);
    if (!seen.has(id)) {
      seen.add(id);
      results.push({ id, name: row.name, domain: row.domain, status: row.status, match: "name" });
    }
  }
  for (const row of (descRows || [])) {
    const id = Number(row.id);
    if (!seen.has(id)) {
      seen.add(id);
      results.push({ id, name: row.name, domain: row.domain, status: row.status, match: "description" });
    }
  }
  return JSON.stringify({ query, results, count: results.length });
};

// Extract status string from a project row (used by PureScript via FFI).
export const extractRowStatus = (row) => row.status || "";
