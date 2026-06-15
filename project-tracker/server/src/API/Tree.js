// FFI for API.Tree — builds the Minard "tree.json" contract from DuckDB rows.
//
// This is the server-side promotion of cloudflare-sites/andrewcondon/working/tree.mjs:
// the same selection/shape logic, but fed query rows instead of two HTTP fetches. The
// website still bakes a static tree.json offline (it can't reach the tailnet API); the
// in-house newspaper fetches GET /api/tree live. One contract, two producers.
//
//   value = subtree leaf-count (leaf -> 1, internal -> sum of children).
//   Semantic fields only (tags/domain/status/tagline/description/cover/repoUrl); the
//   viewer's theme + MM_CONFIG map these to colour and link policy.

// Canonical attachment store — cover screenshots resolve to /attachments/... served
// same-origin by the frontend. Duplicated from Projects.js (FFI files can't import each
// other; PureScript copies them to the output tree per module).
const _defaultStore = '/Volumes/Crucial4TB/Documents/Notes Attachments/';
const _rawStore = process.env.MARGINALIA_ATTACHMENT_STORE || _defaultStore;
const ATTACHMENT_STORE = _rawStore.endsWith('/') ? _rawStore : _rawStore + '/';
const filePathToAttachmentUrl = (filePath) => {
  if (!filePath) return null;
  return filePath.startsWith(ATTACHMENT_STORE)
    ? '/attachments/' + filePath.slice(ATTACHMENT_STORE.length)
    : null;
};

// GitHub owner for composing repo URLs from a bare `repo` name. Everything in the
// showcase categories is the owner's own work; override for a future ports umbrella.
const GH_OWNER = process.env.MARGINALIA_GH_OWNER || 'afcondon';
const repoUrlOf = (row) => {
  const s = row.source_url;
  if (s && /^https?:\/\//.test(s)) return s;
  const r = row.repo;
  if (!r) return null;
  if (/^https?:\/\//.test(r)) return r;
  if (r.includes('/')) return 'https://github.com/' + r;
  return 'https://github.com/' + GH_OWNER + '/' + r;
};

// Curried to match the PureScript FFI: buildTreeJson projectRows depRows tag group root publicOnly
export const buildTreeJson = (projectRows) => (depRows) => (tag) => (group) => (root) => (publicOnly) => {
  const TAG = tag || null;
  const GROUP = group || null;
  const ROOT_ID = root ? Number(root) : null;
  const PUBLIC_ONLY = publicOnly === '1' || publicOnly === 'true';

  let all = (projectRows || []).map((row) => ({
    id: Number(row.id),
    slug: row.slug || null,
    name: row.name,
    domain: row.domain || null,
    status: row.status || null,
    parentId: row.parent_id != null ? Number(row.parent_id) : null,
    tags: row.tags ? row.tags.split(', ').filter((t) => t.trim()) : [],
    tagline: row.tagline || null,
    description: row.description || null,
    cover: filePathToAttachmentUrl(row.cover_path),
    repoUrl: repoUrlOf(row),
    visibility: row.visibility || 'public',
  }));

  // Public showcase drops private projects; the in-house newspaper omits publicOnly.
  if (PUBLIC_ONLY) all = all.filter((p) => p.visibility !== 'private');

  const byId = new Map(all.map((p) => [p.id, p]));
  const isRoot = (p) => p.parentId == null || !byId.has(p.parentId);

  const childrenOf = new Map();
  for (const p of all) {
    if (isRoot(p)) continue;
    if (!childrenOf.has(p.parentId)) childrenOf.set(p.parentId, []);
    childrenOf.get(p.parentId).push(p);
  }

  // Children sorted largest-first (conventional squarify input). Semantic attrs only.
  function buildNode(p) {
    const kids = (childrenOf.get(p.id) || [])
      .map(buildNode)
      .sort((a, b) => b.value - a.value || a.name.localeCompare(b.name));
    const value = kids.length ? kids.reduce((s, k) => s + k.value, 0) : 1;
    const node = {
      id: p.id, slug: p.slug, name: p.name,
      domain: p.domain, status: p.status,
      tags: p.tags, value, children: kids,
    };
    if (p.tagline) node.tagline = p.tagline;
    if (p.description) node.description = p.description;
    if (p.cover) node.cover = p.cover;
    if (p.repoUrl) node.repoUrl = p.repoUrl;
    return node;
  }

  function collectIds(node, into) {
    into.add(node.id);
    for (const c of node.children) collectIds(c, into);
    return into;
  }

  let tree;
  if (TAG != null) {
    // Curated flat tree: synthetic root whose children carry the semantic tag.
    const kids = all
      .filter((p) => p.tags.includes(TAG))
      .map(buildNode)
      .sort((a, b) => b.value - a.value || a.name.localeCompare(b.name));
    tree = {
      id: 0, slug: 'marginalia', name: 'Marginalia',
      domain: null, status: null, tags: [],
      value: kids.reduce((s, k) => s + k.value, 0),
      children: kids,
    };
  } else if (ROOT_ID != null && byId.has(ROOT_ID)) {
    tree = buildNode(byId.get(ROOT_ID));
  } else {
    const roots = all.filter(isRoot)
      .map(buildNode)
      .sort((a, b) => b.value - a.value || a.name.localeCompare(b.name));
    let children = roots;
    if (GROUP === 'domain') {
      // Synthetic domain super-nodes (negative ids) between root and top-level projects.
      const order = ['programming', 'music', 'infrastructure', 'house', 'woodworking', 'garden'];
      const rank = (d) => { const i = order.indexOf(d); return i < 0 ? 99 : i; };
      const byDomain = new Map();
      for (const r of roots) {
        const d = r.domain || 'other';
        if (!byDomain.has(d)) byDomain.set(d, []);
        byDomain.get(d).push(r);
      }
      children = [...byDomain.entries()]
        .sort((a, b) => rank(a[0]) - rank(b[0]) || a[0].localeCompare(b[0]))
        .map(([d, kids], i) => ({
          id: -(i + 1), slug: `domain-${d}`, name: d, domain: d, status: null,
          tags: [], value: kids.reduce((s, k) => s + k.value, 0), children: kids,
        }));
    }
    tree = {
      id: 0, slug: 'marginalia', name: 'Marginalia',
      domain: null, status: null, tags: [],
      value: children.reduce((s, k) => s + k.value, 0),
      children,
    };
  }

  // Keep only edges whose endpoints are both present in the emitted subtree.
  const present = collectIds(tree, new Set());
  const edges = (depRows || [])
    .map((e) => ({ source: Number(e.blocker_id), target: Number(e.blocked_id), type: e.dependency_type }))
    .filter((e) => present.has(e.source) && present.has(e.target));

  // rectDepth: rectangle tiers before bubbles. Domain-grouped forest = 2 (domain +
  // umbrella); curated/flat/rooted views = 1.
  const rectDepth = (GROUP === 'domain' && ROOT_ID == null && TAG == null) ? 2 : 1;

  const stamp = new Date().toISOString().slice(0, 10);
  return JSON.stringify({ generatedAt: stamp, root: tree.id, rectDepth, nodes: tree, edges });
};
