// FFI for API.Projects

// Read a string field from a row object. Returns "" if missing/null.
export const getRowString_ = (key) => (row) => {
  if (row == null) return "";
  const v = row[key];
  return v == null ? "" : String(v);
};
// JSON response builders only — marshalling Foreign (DuckDB rows) to JSON strings.
// All body parsing and SQL construction is in PureScript.

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
    tags: row.tags ? row.tags.split(', ').filter(t => t.trim()) : []
  }));
  return JSON.stringify({ projects, count: projects.length });
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
    attachments: (attachments || []).map(a => {
      // Convert filesystem path to a URL relative to the frontend's static root.
      // The frontend serves /attachments/* via a symlink to the canonical
      // attachment store on Crucial4TB.
      const PREFIX = '/Volumes/Crucial4TB/Documents/Notes Attachments/';
      const path = a.file_path || '';
      const url = path.startsWith(PREFIX) ? '/attachments/' + path.slice(PREFIX.length) : null;
      return {
        id: Number(a.id),
        filename: a.filename,
        mimeType: a.mime_type,
        url: url,
        description: a.description || null,
        createdAt: a.created_at
      };
    })
  });
};
