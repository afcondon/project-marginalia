// FFI for API.Activity
//
// Builds the JSON response for GET /api/activity. The PureScript side runs
// the SQL; this side marshals Foreign rows into a stable JSON shape.

const toInt = (v) => v == null ? 0 : Number(v);
const toNum = (v) => v == null ? 0 : Number(v);
const toIso = (v) => {
  if (v == null) return null;
  // DuckDB may return Date, number (epoch ms), or ISO string depending on
  // how the node-duckdb driver unboxes the column. Normalize to ISO.
  if (v instanceof Date) return v.toISOString();
  if (typeof v === 'number') return new Date(v).toISOString();
  return String(v);
};

export const buildActivityJson = (rows) => (halflife) => (windowDays) => (limit) => {
  const projects = (rows || []).map(row => ({
    id: Number(row.id),
    slug: row.slug || null,
    name: row.name,
    domain: row.domain,
    subdomain: row.subdomain || null,
    status: row.status,
    description: row.description || null,
    updatedAt: toIso(row.updated_at),
    score: toNum(row.score),
    notes7d: toInt(row.notes_7d),
    notes30d: toInt(row.notes_30d),
    notes90d: toInt(row.notes_90d),
    notesHuman30d: toInt(row.notes_human_30d),
    notesAgent30d: toInt(row.notes_agent_30d),
    statusChanges30d: toInt(row.status_changes_30d),
    attachments30d: toInt(row.attachments_30d),
    lastNoteAt: toIso(row.last_note_at),
    lastStatusAt: toIso(row.last_status_at),
    lastAttachmentAt: toIso(row.last_attach_at),
    lastActivityAt: toIso(row.last_activity_at),
    pinned: Boolean(row.pinned),
  }));
  return JSON.stringify({
    projects,
    count: projects.length,
    scoring: {
      formula: "sum over events in window of weight * 2^(-age_days/halflife), times status multiplier, times pinned multiplier",
      weights: { note: 1.0, statusChange: 3.0, attachment: 0.5 },
      statusMultipliers: {
        active: 1.0, idea: 1.0, blocked: 1.0,
        someday: 0.5, dormant: 0.3,
        done: 0.2, defunct: 0.2, evolved: 0.2,
      },
      pinnedMultiplier: 3.0,
      rules: {
        creationRowsExcludedAfter: "7 days",
        attachmentsScoredPerProject: 3,
      },
      halflifeDays: halflife,
      windowDays,
      limit,
    },
  });
};
