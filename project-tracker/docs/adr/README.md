# Architecture Decision Records

Nygard-format decision records for the project-tracker / Marginalia
software-engineering practice. Each file is one decision: **Context** (the forces
at play), **Decision** (what we chose), **Consequences** (what follows, good and
bad). Numbered sequentially.

These markdown files are the human-readable source of record. They mirror into
the `project_adrs` table (one row per ADR, `number` = the file number) once the
API exposes the goals/ADRs/coverage endpoints — at which point the table becomes
the queryable index and these files stay the prose.

Status lifecycle (enforced on the table): `proposed → accepted | rejected`;
`accepted → superseded | deprecated`.

| #    | Title                                              | Status   |
|------|----------------------------------------------------|----------|
| [0001](0001-one-db-separable-engineering-spine.md) | One DuckDB with a separable engineering spine | Accepted |
| [0002](0002-linkage-layer.md)                      | Link the spine strata into a graph            | Proposed |
