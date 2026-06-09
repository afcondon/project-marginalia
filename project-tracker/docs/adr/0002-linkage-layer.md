# 0002 — Link the engineering-spine strata into a graph

- **Status:** Proposed
- **Date:** 2026-06-09
- **Deciders:** Andrew, Brunel
- **Relates to:** [0001](0001-one-db-separable-engineering-spine.md)

## Context

The spine (ADR-0001) added the missing middle rungs of a **multi-resolution**
model of each project — intent (`project_goals`) and rationale (`project_adrs`)
between the one-line `description` (top) and the code (bottom), plus
`coverage_snapshots` as a projection of the build floor.

The goal behind that model is *consistency across resolutions*: a Claude should be
able to zoom to the right level for its task (managing / designing / specifying /
building) and trust the levels agree. That consistency **cannot be guaranteed by
derivation** — intent is authored *downward* and is not derivable from code — so
it is an irreducible coordination problem. What we *can* do is make inconsistency
cheap to detect.

As built, the strata are islands: `project_goals`, `project_adrs`, and
`coverage_snapshots` reference none of each other. With no edges, "is this goal
still being pursued?" and "does this decision serve any goal?" are unanswerable by
query — they live only in someone's head, which is exactly how drift hides (cf.
the 2026-06-09 incident: a deployment whose source had silently drifted eight
weeks from the running reality, undetected).

## Decision

Turn the strata into a linked graph with two additive tables and two views:

- **`adr_goals`** (many:many) — which goal(s) an ADR pursues. The
  intent↔rationale edge. Mirrors the shape of `dependencies`.
- **`provenance`** — evidence that real work (a `commit` / `note` / `worklog` /
  `pr` / `test` / `governs` code path) advances a goal or an ADR. The
  intent/rationale↔build edge, and also **Brunel's recording surface**: as the
  auditor reads the artifact trail, it writes `provenance` rows, so its findings
  become structured data rather than prose. Coverage-as-protection folds in here
  as `evidence_kind = 'test'`.
- **`goal_health`** view — per active goal: pursuing-ADR count, work-evidence
  count, and last-evidence timestamp. Zero ADRs = intent with no plan; a stale
  timestamp = direction drift, **as a number**.
- **`adr_orphans`** view — accepted/proposed ADRs pursuing no goal: rationale with
  no purpose.

Kept loose, matching the house style: foreign keys as comments not constraints;
the "exactly one of `goal_id` / `adr_id`" rule is a convention, not a `CHECK`.

## Consequences

- (+) Cross-level consistency becomes a **checkable graph-integrity property** —
  precisely what Brunel's direction/leverage audits need. Drift detection stops
  being vibes.
- (+) The level-graph is navigable (zoom by following edges) and is a natural
  dogfood target for the cartography tools (Minard / Humboldt).
- (+) `goal_health.last_evidence_at` is a first step toward per-level provenance
  stamping — "how stale is this rung."
- (+) Small and additive — two tables, two views, no changes to existing rows.
- (−) The graph is only as good as what gets recorded; empty `provenance` looks
  identical to "no work happened." Brunel must populate it diligently.
- (−) The "exactly one subject" invariant is unenforced; malformed writes are
  possible.
- (−) Does **not** solve the coordination problem. Authored intent still needs
  human reconciliation; this makes the gap cheap to *see*, not automatic to
  *close*. That is the intended, honest scope.

Implemented by `database/migrations/2026-06-09-linkage-layer.sql`.
