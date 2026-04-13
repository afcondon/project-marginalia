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

// Parse the subscription list response. Returns a plain JS object that
// PureScript can destructure via its SubscriptionResponse row type.
export const parseSubscriptionResponse_ = (str) => {
  try {
    const d = JSON.parse(str);
    return {
      subscriptions: (d.subscriptions || []).map(s => ({
        id: s.id || 0,
        name: s.name || '',
        category: s.category || '',
        amount: s.amount || 0,
        currency: s.currency || 'EUR',
        frequency: s.frequency || 'monthly',
        nextDue: s.nextDue || '',
        autoRenew: s.autoRenew !== false,
        notes: s.notes || '',
        projectId: s.projectId || 0,
        active: s.active !== false,
      })),
      count: d.count || 0,
      monthlyBurn: d.monthlyBurn || 0,
    };
  } catch {
    return { subscriptions: [], count: 0, monthlyBurn: 0 };
  }
};

// Parse the blog drafts response (Letters section).
export const parseBlogDraftsResponse_ = (str) => {
  try {
    const d = JSON.parse(str);
    return {
      drafts: (d.drafts || []).map(r => ({
        id: r.id || 0,
        slug: r.slug || '',
        name: r.name || '',
        domain: r.domain || '',
        blogStatus: r.blogStatus || '',
        filename: r.filename || '',
        wordCount: r.wordCount || 0,
        hasFile: r.hasFile === true,
      })),
      count: d.count || 0,
    };
  } catch {
    return { drafts: [], count: 0 };
  }
};

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
  // blogContent is no longer sent from the UI: drafts live on disk and
  // VS Code writes them directly. See BlogDrafts.purs on the server.
  return JSON.stringify(body);
};
