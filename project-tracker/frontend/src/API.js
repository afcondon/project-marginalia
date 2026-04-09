// FFI for API module
// JSON body builders and array helpers

// Resolved once at module load. Two deployment shapes we care about:
//
//   1. Dev on MBP: frontend served by http-server at http://localhost:3101/,
//      API running separately at http://localhost:3100/. Cross-origin but
//      CORS is enabled. Hostname is "localhost" or "127.0.0.1".
//
//   2. Deployed behind Tailscale Serve: a single origin on the tailnet's
//      HTTPS endpoint, with `/` → frontend and `/api/` → API via Tailscale
//      Serve path routing. The bundle uses relative-ish URLs (same-origin)
//      so it just works without CORS.
//
// The decision is made at module load based on window.location.hostname,
// so the same bundle file ships to both deployments without a build step.
export const computedBaseUrl = (() => {
  const loc = window.location;
  if (loc.hostname === 'localhost' || loc.hostname === '127.0.0.1') {
    return 'http://localhost:3100';
  }
  return loc.origin;
})();

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
  if (input.preferredView) body.preferredView = input.preferredView;
  return JSON.stringify(body);
};

// Build JSON body for POST /api/agent/projects/:id/notes
export const buildNoteBody = (content) =>
  JSON.stringify({ content, author: "human" });

// Build JSON body for POST /api/projects/:id/tags
export const buildTagBody = (tag) =>
  JSON.stringify({ tag });

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
  if (input.preferredView) body.preferredView = input.preferredView;
  if (input.blogStatus) body.blogStatus = input.blogStatus;
  if (input.blogContent) body.blogContent = input.blogContent;
  return JSON.stringify(body);
};
