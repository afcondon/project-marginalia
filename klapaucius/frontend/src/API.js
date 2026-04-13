// FFI for API module

export const computedBaseUrl = (() => {
  const loc = window.location;
  if (loc.hostname === 'localhost' || loc.hostname === '127.0.0.1') {
    return 'http://localhost:3400';
  }
  return loc.origin;
})();

export const arrayLength = (arr) => arr.length;
export const unsafeIndex = (arr) => (i) => arr[i];

export const parsePostListResponse_ = (str) => {
  try {
    const d = JSON.parse(str);
    return {
      posts: (d.posts || []).map(p => ({
        id: p.id || 0,
        category: p.category || '',
        slug: p.slug || '',
        title: p.title || '',
        status: p.status || 'wanted',
        sourceType: p.sourceType || '',
        wordCount: p.wordCount || 0,
        hasFile: p.hasFile === true,
        createdAt: p.createdAt || '',
        updatedAt: p.updatedAt || '',
      })),
      count: d.count || 0,
    };
  } catch {
    return { posts: [], count: 0 };
  }
};

export const parsePostDetailResponse_ = (str) => {
  try {
    return JSON.parse(str);
  } catch {
    return null;
  }
};

export const parseAssetsResponse_ = (str) => {
  try {
    const d = JSON.parse(str);
    return (d.assets || []).map(a => ({
      filename: a.filename || '',
      size: a.size || 0,
      url: a.url || '',
      markdown: a.markdown || '',
    }));
  } catch {
    return [];
  }
};

export const parseStatsResponse_ = (str) => {
  try { return JSON.parse(str); }
  catch { return { total: 0, byStatus: {}, byCategory: {} }; }
};

export const parseCategoriesResponse_ = (str) => {
  try {
    const d = JSON.parse(str);
    return (d.categories || []).map(c => ({
      category: c.category || '',
      count: c.count || 0,
    }));
  } catch {
    return [];
  }
};

export const buildCreateBody = (input) =>
  JSON.stringify(input);

export const buildUpdateBody = (input) => {
  const body = {};
  if (input.title) body.title = input.title;
  if (input.status) body.status = input.status;
  if (input.category) body.category = input.category;
  if (input.slug) body.slug = input.slug;
  return JSON.stringify(body);
};

export const buildAssetUploadBody = (filename) => (data) =>
  JSON.stringify({ filename, data });
