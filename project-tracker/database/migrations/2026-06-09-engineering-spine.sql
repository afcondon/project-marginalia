-- =============================================================================
-- Migration: Engineering Spine  (2026-06-09)
-- =============================================================================
--
-- Adds the first-class substrate the "head of engineering" auditor (Brunel)
-- reasons over: per-project GOALS / non-goals, architecture decision records
-- (ADRs), and a COVERAGE time-series. Plus a REALM classification over domains
-- so the engineering-realm projects can later be extracted as a standalone,
-- potentially open-source "software-engineering-with-LLMs" app while the
-- personal-life realm (house/garden/cooking/yoga/travel) stays private.
--
-- Conventions (matching database/schema.sql):
--   - DuckDB has no auto-increment: every table gets a sequence.
--   - Foreign keys are written as comments, NOT enforced — DuckDB FKs block
--     UPDATE on referenced rows, which the tracker relies on (see projects).
--   - Everything is idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING) so this
--     file is safe to re-run against the live MacMini DB.
--
-- Apply (on the canonical MacMini, against the live DB — NOT the stale MBP
-- cold-mirror):
--   duckdb /path/to/tracker.duckdb < 2026-06-09-engineering-spine.sql
-- The same object definitions should be folded into database/schema.sql so the
-- canonical schema stays complete.
-- =============================================================================

-- =============================================================================
-- REALM — classify domains as engineering vs. personal-life
-- =============================================================================
--
-- projects.domain stays a free TEXT column (unchanged). This lookup table
-- classifies each domain into a realm. The engineering realm is the extraction
-- boundary for the future open-source app; goals/ADRs/coverage are *available*
-- to any project but only meaningfully used by engineering-realm ones. No CHECK
-- constraint ties them to realm — kept loose, consistent with the disabled-FK
-- philosophy elsewhere in this schema.

CREATE TABLE IF NOT EXISTS domains (
    name        TEXT PRIMARY KEY,                 -- matches projects.domain values
    realm       TEXT NOT NULL DEFAULT 'life',     -- 'engineering' | 'life'
    label       TEXT,                             -- display name for the newspaper
    sort_order  INTEGER
);

-- Seed the known domains. ON CONFLICT DO NOTHING means re-running this never
-- clobbers a realm you've since re-classified by hand.
-- NOTE: woodworking is seeded 'life' (craft). Flip to 'engineering' with a
-- single UPDATE if a hand-cut dovetail deserves an ADR.
INSERT INTO domains (name, realm, label, sort_order) VALUES
    ('programming',    'engineering', 'Programming',    10),
    ('music',          'engineering', 'Music',          20),
    ('infrastructure', 'engineering', 'Infrastructure', 30),
    ('house',          'life',        'House',          40),
    ('garden',         'life',        'Garden',         50),
    ('woodworking',    'life',        'Woodworking',    60),
    ('cooking',        'life',        'Cooking',        70),
    ('yoga',           'life',        'Yoga',           80),
    ('travel',         'life',        'Travel',         90)
ON CONFLICT (name) DO NOTHING;

-- =============================================================================
-- GOALS / NON-GOALS — the project charter the "direction" audit checks against
-- =============================================================================
--
-- Each goal has its own lifecycle: active -> achieved | dropped. A dropped goal
-- MUST carry a reason (enforced in spirit by the auditor, not by a constraint):
-- the whole point of the direction axis is to force "we dropped X because Y"
-- instead of silent abandonment. Non-goals are explicit "we are deliberately
-- NOT doing X" guardrails.

CREATE SEQUENCE IF NOT EXISTS seq_goals START 1;

CREATE TABLE IF NOT EXISTS project_goals (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_goals'),
    project_id  INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    kind        TEXT NOT NULL DEFAULT 'goal',     -- 'goal' | 'non_goal'
    text        TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active',   -- 'active' | 'achieved' | 'dropped'
    reason      TEXT,                             -- why achieved/dropped (required in spirit when not 'active')
    sort_order  INTEGER,                          -- display order within the charter
    author      TEXT NOT NULL DEFAULT 'human',    -- 'human' | 'brunel' | agent name
    created_at  TIMESTAMP DEFAULT current_timestamp,
    resolved_at TIMESTAMP                         -- when it left 'active'
);

CREATE INDEX IF NOT EXISTS idx_goals_project ON project_goals(project_id);
CREATE INDEX IF NOT EXISTS idx_goals_status  ON project_goals(status);

-- =============================================================================
-- ADRs — architecture decision records (Nygard format)
-- =============================================================================
--
-- An ADR carries a status DAG AND a supersession chain — structurally the same
-- shape as the projects status lifecycle + evolved_into link:
--   proposed -> accepted | rejected
--   accepted -> superseded | deprecated
-- `number` is per-project (ADR-001, ADR-002, … within one project); assign it
-- app-side as MAX(number)+1 for the project. The UNIQUE index keeps it honest
-- without being a row-update-blocking foreign key.

CREATE SEQUENCE IF NOT EXISTS seq_adrs START 1;

CREATE TABLE IF NOT EXISTS project_adrs (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_adrs'),
    project_id    INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    number        INTEGER NOT NULL,              -- ADR-NNN within the project
    title         TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'proposed', -- 'proposed' | 'accepted' | 'rejected' | 'superseded' | 'deprecated'
    context       TEXT,                          -- the forces at play
    decision      TEXT,                          -- what we decided
    consequences  TEXT,                          -- what follows, good and bad
    supersedes_id INTEGER,                        -- another project_adrs.id this replaces
    author        TEXT NOT NULL DEFAULT 'human',  -- 'human' | 'brunel' | agent name
    created_at    TIMESTAMP DEFAULT current_timestamp,
    decided_at    TIMESTAMP                       -- when it left 'proposed'
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_adrs_project_number ON project_adrs(project_id, number);
CREATE INDEX IF NOT EXISTS idx_adrs_project ON project_adrs(project_id);
CREATE INDEX IF NOT EXISTS idx_adrs_status  ON project_adrs(status);

-- =============================================================================
-- COVERAGE SNAPSHOTS — the hygiene time-series (tests / CI / docs)
-- =============================================================================
--
-- A time-series, not a single value, so the newspaper can draw a per-project
-- coverage sparkline and the auditor can see trend (improving / rotting).
-- Uniform auto-collection across PureScript / Rust / Python is hard, so `source`
-- records HOW each number was obtained — and some will honestly be 'estimate'.

CREATE SEQUENCE IF NOT EXISTS seq_coverage START 1;

CREATE TABLE IF NOT EXISTS coverage_snapshots (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_coverage'),
    project_id  INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    taken_at    TIMESTAMP DEFAULT current_timestamp,
    line_pct    DOUBLE,                           -- 0..100, NULL if unmeasured
    branch_pct  DOUBLE,                           -- 0..100, NULL if unmeasured
    test_count  INTEGER,                          -- number of tests, NULL if unknown
    ci_status   TEXT,                             -- 'passing' | 'failing' | 'none' | 'unknown'
    has_docs    BOOLEAN,                          -- does the repo carry current docs?
    source      TEXT NOT NULL DEFAULT 'manual',   -- 'manual' | 'estimate' | 'tarpaulin' | 'c8' | 'spago-test' | 'jest' | …
    note        TEXT
);

CREATE INDEX IF NOT EXISTS idx_coverage_project ON coverage_snapshots(project_id);
CREATE INDEX IF NOT EXISTS idx_coverage_taken   ON coverage_snapshots(taken_at);

-- =============================================================================
-- CONVENIENCE VIEWS
-- =============================================================================

-- The extraction boundary for the future open-source app: every project in an
-- engineering-realm domain. "Open-source the SE app" becomes a query, not a
-- migration.
CREATE VIEW IF NOT EXISTS engineering_projects AS
    SELECT p.*
    FROM projects p
    JOIN domains d ON d.name = p.domain
    WHERE d.realm = 'engineering';

-- Most-recent coverage snapshot per project — feeds the scorecard / sparkline.
CREATE VIEW IF NOT EXISTS latest_coverage AS
    SELECT c.*
    FROM coverage_snapshots c
    JOIN (
        SELECT project_id, MAX(taken_at) AS max_taken
        FROM coverage_snapshots
        GROUP BY project_id
    ) latest
      ON latest.project_id = c.project_id
     AND latest.max_taken  = c.taken_at;
