# 0001 — One DuckDB with a separable engineering spine (not two physical DBs)

- **Status:** Accepted
- **Date:** 2026-06-09
- **Deciders:** Andrew, Brunel

## Context

Marginalia is diverging into two practices: a private personal-life tracker
(`house` / `garden` / `woodworking` / `cooking` / `yoga` / `travel`) and a denser
software-engineering-with-LLMs practice (`programming` / `music` /
`infrastructure` — music counts as engineering here). The latter is a candidate
open-source app for other ultra-empowered single developers.

The SE practice needs first-class engineering substrate the life tracker doesn't:
per-project goals / non-goals, architecture decision records, and a test-coverage
time-series. The open question was: one database or two? An open-source SE app
must ship with an empty, self-standing schema and **zero** personal data, which
argues for a clean separation.

## Decision

One DuckDB. `projects` stays the shared spine. The engineering tables
(`project_goals`, `project_adrs`, `coverage_snapshots`) attach to any project but
are used by engineering-realm ones. A `domains` lookup classifies each domain
into a realm (`engineering` | `life`); the `engineering_projects` view
(`domains.realm = 'engineering'`) is the extraction boundary. "Open-source the SE
app" therefore becomes a **query, not a migration**.

The engineering tables foreign-key only *up* into the generic `projects` core,
never sideways into life-specific data — so the extraction stays clean.

## Consequences

- (+) No cross-DB join/sync tax before the life/SE seam is even proven.
- (+) The newspaper's two-view need is met by the existing `domain` field.
- (+) Clean OSS extraction path: dump engineering-realm projects + the spine
  tables, seed empty.
- (−) Requires discipline: no engineering construct may grow a life-ward foreign
  key, or the clean extraction rots. Watching that seam is itself a Brunel job.
- The split is **logical, not physical**; revisit if/when the SE app actually
  ships.

Implemented by `database/migrations/2026-06-09-engineering-spine.sql`.
