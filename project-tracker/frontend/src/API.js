// FFI for API module
// JSON body builders and array helpers

export const arrayLength = (arr) => arr.length;

export const unsafeIndex = (arr) => (i) => arr[i];

// Build JSON body for POST /api/projects
export const buildCreateBody = (input) => {
  const body = {};
  if (input.name) body.name = input.name;
  if (input.domain) body.domain = input.domain;
  if (input.subdomain) body.subdomain = input.subdomain;
  if (input.status) body.status = input.status;
  if (input.description) body.description = input.description;
  if (input.repo) body.repo = input.repo;
  if (input.sourceUrl) body.sourceUrl = input.sourceUrl;
  if (input.sourcePath) body.sourcePath = input.sourcePath;
  return JSON.stringify(body);
};

// Build JSON body for POST /api/agent/projects/:id/notes
export const buildNoteBody = (content) =>
  JSON.stringify({ content, author: "human" });

// Build JSON body for creating a child project under a parent
export const buildChildBody = (parentId) => (name) => (domain) =>
  JSON.stringify({ parentId, name, domain, status: "idea" });

// Build JSON body for the rename endpoint
export const buildRenameBody = (name) => (renameDirectory) =>
  JSON.stringify({ name, renameDirectory: renameDirectory ? "true" : "false" });

// Build JSON body for PUT /api/projects/:id
// Only includes non-empty fields (partial update)
export const buildUpdateBody = (input) => {
  const body = {};
  if (input.name) body.name = input.name;
  if (input.domain) body.domain = input.domain;
  if (input.subdomain) body.subdomain = input.subdomain;
  if (input.status) body.status = input.status;
  if (input.description) body.description = input.description;
  if (input.repo) body.repo = input.repo;
  if (input.sourceUrl) body.sourceUrl = input.sourceUrl;
  if (input.sourcePath) body.sourcePath = input.sourcePath;
  if (input.statusReason) body.statusReason = input.statusReason;
  return JSON.stringify(body);
};
