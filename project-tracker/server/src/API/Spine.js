// FFI for API.Spine — JSON serializers for the engineering-spine endpoints.
//
// DuckDB returns INTEGER columns as JavaScript BigInt, which JSON.stringify
// throws on ("Do not know how to serialize a BigInt"). Every serializer here
// runs through `bigintReplacer` so raw spine rows (with their varied integer
// columns) can be emitted generically without hand-mapping each column the way
// Projects.js does. Numbers stay exact for the id/count ranges in this DB.
const bigintReplacer = (_key, value) =>
  typeof value === "bigint" ? Number(value) : value;

// Generic: serialize a result set as a JSON array. Used by the per-project and
// cross-project list endpoints (goals, adrs, coverage, provenance, health,
// engineering_projects, goal_health, adr_orphans).
export const rowsToJson = (rows) =>
  JSON.stringify(rows ?? [], bigintReplacer);

// Composed per-project dossier: one round-trip the press renders from. Shape
// mirrors the §12.3 ProjectSource capabilities — absent rows just come back as
// empty arrays / null, so a thin project degrades gracefully.
export const buildDossierJson =
  (projectRows) => (goals) => (adrs) => (coverage) => (provenance) => (health) =>
    JSON.stringify(
      {
        project: (projectRows ?? [])[0] ?? null,
        goals: goals ?? [],
        adrs: adrs ?? [],
        // coverage is ordered DESC by taken_at, so [0] is the latest snapshot.
        coverage: { latest: (coverage ?? [])[0] ?? null, series: coverage ?? [] },
        provenance: provenance ?? [],
        health: health ?? [],
      },
      bigintReplacer
    );

// Realm extraction bundle (Tier A migration export). A self-describing payload
// the reference personal source re-imports. dependencies are filtered on the
// blocker side; cross-realm edges (rare — 2 deps total in the live DB) are a
// known follow-up.
export const buildExportJson =
  (realm) => (projects) => (notes) => (tags) => (deps) => (servers) =>
    JSON.stringify(
      {
        realm,
        exportedFrom: "marginalia",
        schemaVersion: 1,
        projects: projects ?? [],
        notes: notes ?? [],
        tags: tags ?? [],
        dependencies: deps ?? [],
        servers: servers ?? [],
      },
      bigintReplacer
    );
