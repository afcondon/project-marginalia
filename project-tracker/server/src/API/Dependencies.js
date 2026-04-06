// FFI for API.Dependencies
// JSON response builders only — marshalling Foreign (DuckDB rows) to JSON strings.
// All body parsing and SQL construction is in PureScript.

// Build JSON array of dependency edges (from dependency_graph view rows)
export const buildDependencyListJson = (rows) => {
  const deps = (rows || []).map(row => ({
    blockerId: Number(row.blocker_id),
    blockerName: row.blocker_name,
    blockerStatus: row.blocker_status,
    blockedId: Number(row.blocked_id),
    blockedName: row.blocked_name,
    blockedStatus: row.blocked_status,
    type: row.dependency_type
  }));
  return JSON.stringify({ dependencies: deps, count: deps.length });
};

// Build JSON for a single dependency object (from dependency_graph row)
export const buildDependencyJson = (row) => {
  return JSON.stringify({
    blockerId: Number(row.blocker_id),
    blockerName: row.blocker_name,
    blockerStatus: row.blocker_status,
    blockedId: Number(row.blocked_id),
    blockedName: row.blocked_name,
    blockedStatus: row.blocked_status,
    type: row.dependency_type
  });
};
