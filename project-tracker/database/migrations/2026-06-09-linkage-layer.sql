-- =============================================================================
-- Migration: Engineering Spine — Linkage Layer  (2026-06-09)
-- =============================================================================
--
-- Implements ADR-0002 (docs/adr/0002-linkage-layer.md). Turns the spine's strata
-- (goals / ADRs / coverage) from islands into a linked graph, so cross-level
-- consistency — "is this intent actually being pursued and built?" — becomes a
-- checkable graph-integrity property instead of a vibe, and Brunel gets a
-- structured surface to record what it finds in the artifact trail.
--
-- Conventions: see 2026-06-09-engineering-spine.sql. DuckDB sequences, foreign
-- keys as comments (not enforced — DuckDB FKs block UPDATE on referenced rows),
-- idempotent, safe to re-run. Depends on the spine tables (project_goals,
-- project_adrs) existing first. Apply by folding into schema.sql (done — the
-- server re-applies it on boot) or by piping this file into the live DB.
-- =============================================================================

-- adr_goals: which goal(s) an ADR pursues. The intent <-> rationale edge
-- (many:many). Mirrors the shape of `dependencies`.
CREATE TABLE IF NOT EXISTS adr_goals (
    adr_id   INTEGER NOT NULL /* project_adrs.id  -- FK disabled per house convention */,
    goal_id  INTEGER NOT NULL /* project_goals.id */,
    PRIMARY KEY (adr_id, goal_id)
);
CREATE INDEX IF NOT EXISTS idx_adr_goals_adr  ON adr_goals(adr_id);
CREATE INDEX IF NOT EXISTS idx_adr_goals_goal ON adr_goals(goal_id);

-- provenance: evidence that real work advances a goal or an ADR. The
-- intent/rationale <-> build edge, and Brunel's recording surface — as the
-- auditor reads the artifact trail (git / worklogs / notes) it writes rows here
-- ("commit abc123 advances goal 5"). Exactly one of goal_id / adr_id is set;
-- that invariant is a convention, not a CHECK (matching the disabled-FK style).
-- Coverage-as-protection folds in here as evidence_kind = 'test'.
CREATE SEQUENCE IF NOT EXISTS seq_provenance START 1;

CREATE TABLE IF NOT EXISTS provenance (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_provenance'),
    project_id    INTEGER NOT NULL /* denormalized for filtering; project_goals/adrs.project_id */,
    goal_id       INTEGER,            -- set when the subject is a goal
    adr_id        INTEGER,            -- set when the subject is an ADR
    evidence_kind TEXT NOT NULL DEFAULT 'commit',  -- 'commit'|'note'|'worklog'|'pr'|'test'|'governs'
    evidence_ref  TEXT NOT NULL,      -- sha | note id | file path | url | test name | governed code path
    note          TEXT,               -- one line: how this advances the subject
    author        TEXT NOT NULL DEFAULT 'human',   -- usually 'brunel'
    created_at    TIMESTAMP DEFAULT current_timestamp
);
CREATE INDEX IF NOT EXISTS idx_provenance_project ON provenance(project_id);
CREATE INDEX IF NOT EXISTS idx_provenance_goal    ON provenance(goal_id);
CREATE INDEX IF NOT EXISTS idx_provenance_adr     ON provenance(adr_id);
CREATE INDEX IF NOT EXISTS idx_provenance_kind    ON provenance(evidence_kind);

-- ---------------------------------------------------------------------------
-- Drift signals as queryable views
-- ---------------------------------------------------------------------------

-- Per active goal: how many ADRs pursue it, how much work references it, and
-- when work last touched it. pursuing_adrs = 0 → intent with no plan; a stale
-- last_evidence_at → direction drift, as a number.
CREATE VIEW IF NOT EXISTS goal_health AS
    SELECT
        g.id          AS goal_id,
        g.project_id  AS project_id,
        g.text        AS goal_text,
        (SELECT count(*) FROM adr_goals  ag WHERE ag.goal_id = g.id) AS pursuing_adrs,
        (SELECT count(*) FROM provenance pv WHERE pv.goal_id = g.id) AS work_evidence,
        (SELECT max(pv.created_at) FROM provenance pv WHERE pv.goal_id = g.id) AS last_evidence_at
    FROM project_goals g
    WHERE g.kind = 'goal' AND g.status = 'active';

-- ADRs (proposed/accepted) that pursue no goal — orphan decisions: rationale
-- with no purpose. A coherence signal for Brunel.
CREATE VIEW IF NOT EXISTS adr_orphans AS
    SELECT a.id AS adr_id, a.project_id, a.number, a.title, a.status
    FROM project_adrs a
    WHERE a.status IN ('proposed', 'accepted')
      AND NOT EXISTS (SELECT 1 FROM adr_goals ag WHERE ag.adr_id = a.id);
