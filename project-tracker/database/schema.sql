-- =============================================================================
-- Project Tracker Schema
-- =============================================================================
--
-- A project management database for tracking programming, house, garden,
-- woodworking, music, and infrastructure projects.
--
-- Design principles:
--   - Projects are the core entity, broader than "plan"
--   - Status lifecycle: idea -> someday -> active -> done (with branches)
--   - Dependencies are proper many-to-many (not comma-separated text)
--   - Tags for cross-cutting concerns
--   - Full status change history for timeline visualization
--   - Timestamped notes for project logs
--
-- =============================================================================

-- =============================================================================
-- SEQUENCES (DuckDB does not auto-increment INTEGER PRIMARY KEY)
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS seq_projects START 1;
CREATE SEQUENCE IF NOT EXISTS seq_tags START 1;
CREATE SEQUENCE IF NOT EXISTS seq_notes START 1;
CREATE SEQUENCE IF NOT EXISTS seq_status_history START 1;
CREATE SEQUENCE IF NOT EXISTS seq_attachments START 1;
CREATE SEQUENCE IF NOT EXISTS seq_agent_sessions START 1;
CREATE SEQUENCE IF NOT EXISTS seq_issues START 1;
CREATE SEQUENCE IF NOT EXISTS seq_servers START 1;

-- =============================================================================
-- CORE TABLES
-- =============================================================================

-- The main entity. Covers aspirations, clippings, active work, finished things.
CREATE TABLE IF NOT EXISTS projects (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_projects'),
    slug          TEXT UNIQUE,            -- dictation-friendly identifier: adjective-animal-animal or NATO callsign
    parent_id     INTEGER,                -- another project that contains this one (rank-n grouping)
    name          TEXT NOT NULL,
    domain        TEXT NOT NULL,          -- programming, house, garden, woodworking, music, infrastructure
    subdomain     TEXT,                   -- hylograph, minard, shapedsteer, furniture, eurorack, etc.
    status        TEXT NOT NULL DEFAULT 'idea',
                                          -- idea | someday | active | dormant | blocked | done | defunct | evolved
    evolved_into  INTEGER /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,  -- for status='evolved', points to successor
    description   TEXT,                   -- what is this project?
    source_url    TEXT,                   -- link to repo, plan doc, or reference
    source_path   TEXT,                   -- filesystem path to plan/doc if local
    repo          TEXT,                   -- git repo name if applicable
    preferred_view TEXT,                  -- which detail renderer to use: 'dossier' | 'magazine' | NULL
    cover_attachment_id INTEGER,          -- id of the attachment to use as the project's hero image on the Register
    blog_status    TEXT,                  -- NULL = unclassified | 'not_needed' | 'wanted' | 'drafted' | 'published'
    blog_content   TEXT,                  -- markdown body, populated when blog_status in ('drafted', 'published')
    created_at    TIMESTAMP DEFAULT current_timestamp,
    updated_at    TIMESTAMP DEFAULT current_timestamp
);

-- Idempotent column adds for schemas created before a given column existed.
-- DuckDB accepts ADD COLUMN IF NOT EXISTS so this is safe to re-run.
ALTER TABLE projects ADD COLUMN IF NOT EXISTS cover_attachment_id INTEGER;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS blog_status TEXT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS blog_content TEXT;

CREATE INDEX IF NOT EXISTS idx_projects_domain ON projects(domain);
CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);
CREATE INDEX IF NOT EXISTS idx_projects_subdomain ON projects(subdomain);
CREATE INDEX IF NOT EXISTS idx_projects_repo ON projects(repo);

-- =============================================================================
-- DEPENDENCIES
-- =============================================================================

-- Proper many-to-many dependency relation (not comma-separated text)
CREATE TABLE IF NOT EXISTS dependencies (
    blocker_id      INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    blocked_id      INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    dependency_type TEXT DEFAULT 'blocks',  -- blocks | informs | feeds_into
    PRIMARY KEY (blocker_id, blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_dependencies_blocker ON dependencies(blocker_id);
CREATE INDEX IF NOT EXISTS idx_dependencies_blocked ON dependencies(blocked_id);

-- =============================================================================
-- TAGS
-- =============================================================================

-- Tags for cross-cutting concerns (e.g. "hylograph", "paul", "claude-authored", "ship-2026")
CREATE TABLE IF NOT EXISTS tags (
    id    INTEGER PRIMARY KEY DEFAULT nextval('seq_tags'),
    name  TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS project_tags (
    project_id  INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    tag_id      INTEGER NOT NULL /* REFERENCES tags(id) */,
    PRIMARY KEY (project_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_project_tags_project ON project_tags(project_id);
CREATE INDEX IF NOT EXISTS idx_project_tags_tag ON project_tags(tag_id);

-- =============================================================================
-- NOTES
-- =============================================================================

-- Timestamped notes/updates - the project's log
CREATE TABLE IF NOT EXISTS project_notes (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_notes'),
    project_id  INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    content     TEXT NOT NULL,
    author      TEXT NOT NULL DEFAULT 'human',  -- 'human', 'architect', 'implementer', 'reviewer', 'manager', or agent name
    session_id  TEXT,                           -- links to agent_sessions.id for traceability
    created_at  TIMESTAMP DEFAULT current_timestamp
);

CREATE INDEX IF NOT EXISTS idx_project_notes_project ON project_notes(project_id);

-- =============================================================================
-- STATUS HISTORY
-- =============================================================================

-- Status change history - enables timeline visualization
CREATE TABLE IF NOT EXISTS status_history (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_status_history'),
    project_id  INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    old_status  TEXT,
    new_status  TEXT NOT NULL,
    changed_at  TIMESTAMP DEFAULT current_timestamp,
    reason      TEXT,
    author      TEXT NOT NULL DEFAULT 'human',  -- who/what made this change
    session_id  TEXT                            -- links to agent_sessions.id
);

CREATE INDEX IF NOT EXISTS idx_status_history_project ON status_history(project_id);
CREATE INDEX IF NOT EXISTS idx_status_history_changed ON status_history(changed_at);

-- =============================================================================
-- AGENT SESSIONS
-- =============================================================================

-- Tracks agent work sessions for traceability and dispatch coordination.
-- The Manager reads this to know what's running and what completed.
CREATE TABLE IF NOT EXISTS agent_sessions (
    id            TEXT PRIMARY KEY,              -- unique session identifier
    project_id    INTEGER /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    role          TEXT NOT NULL,                 -- 'manager', 'architect', 'implementer', 'reviewer'
    agent_name    TEXT,                          -- name within the team (e.g. 'implementer-1')
    team_name     TEXT,                          -- Agent Teams team name
    status        TEXT NOT NULL DEFAULT 'running', -- running | completed | failed | cancelled
    started_at    TIMESTAMP DEFAULT current_timestamp,
    ended_at      TIMESTAMP,
    summary       TEXT,                          -- what was accomplished (written at session end)
    worktree_path TEXT,                          -- git worktree path if isolated
    parent_session TEXT /* REFERENCES agent_sessions(id) */  -- manager session that spawned this
);

CREATE INDEX IF NOT EXISTS idx_agent_sessions_project ON agent_sessions(project_id);
CREATE INDEX IF NOT EXISTS idx_agent_sessions_status ON agent_sessions(status);

-- =============================================================================
-- ATTACHMENTS
-- =============================================================================

-- Markdown plans and reference images associated with projects
CREATE TABLE IF NOT EXISTS attachments (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_attachments'),
    project_id  INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    filename    TEXT NOT NULL,
    mime_type   TEXT NOT NULL,              -- text/markdown, image/png, etc.
    content     BLOB,                       -- file content (for small files)
    file_path   TEXT,                       -- filesystem path (for large files or external refs)
    description TEXT,
    created_at  TIMESTAMP DEFAULT current_timestamp
);

CREATE INDEX IF NOT EXISTS idx_attachments_project ON attachments(project_id);

-- =============================================================================
-- GITHUB ISSUES & PRs
-- =============================================================================

-- Synced from GitHub for projects that have a repo field.
-- A sync script runs `gh` CLI and upserts periodically.
CREATE TABLE IF NOT EXISTS project_issues (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_issues'),
    project_id    INTEGER NOT NULL /* REFERENCES projects(id) -- disabled: DuckDB FK prevents UPDATE on referenced rows */,
    github_number INTEGER NOT NULL,        -- GitHub issue/PR number
    kind          TEXT NOT NULL,            -- 'issue' | 'pull_request'
    title         TEXT NOT NULL,
    state         TEXT NOT NULL,            -- 'open' | 'closed' | 'merged'
    url           TEXT,
    author        TEXT,
    labels        TEXT,                     -- comma-separated
    created_at    TIMESTAMP,
    updated_at    TIMESTAMP,
    synced_at     TIMESTAMP DEFAULT current_timestamp,
    UNIQUE (project_id, github_number, kind)
);

CREATE INDEX IF NOT EXISTS idx_issues_project ON project_issues(project_id);
CREATE INDEX IF NOT EXISTS idx_issues_state ON project_issues(state);

-- =============================================================================
-- SERVERS
-- =============================================================================

-- Each running server (or to-be-running) is a row here. A project can have
-- zero or many. This is the port registry that lets Claude and humans avoid
-- collisions without grepping through config files.
CREATE TABLE IF NOT EXISTS project_servers (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_servers'),
    project_id    INTEGER NOT NULL,        -- owning project
    role          TEXT NOT NULL,           -- 'api', 'frontend', 'websocket', 'worker', 'whisper', etc.
    port          INTEGER,                 -- nullable for workers without a port
    url           TEXT,                    -- optional canonical URL, e.g. 'http://localhost:3100'
    start_command TEXT,                    -- how to launch it
    description   TEXT,
    created_at    TIMESTAMP DEFAULT current_timestamp
);

CREATE INDEX IF NOT EXISTS idx_servers_project ON project_servers(project_id);
CREATE INDEX IF NOT EXISTS idx_servers_port ON project_servers(port);

-- =============================================================================
-- CONVENIENCE VIEWS
-- =============================================================================

-- Project summary with tag and note counts
CREATE VIEW IF NOT EXISTS project_summary AS
SELECT
    p.id,
    p.name,
    p.domain,
    p.subdomain,
    p.status,
    p.description,
    p.repo,
    p.source_url,
    p.source_path,
    p.created_at,
    p.updated_at,
    COUNT(DISTINCT pt.tag_id) AS tag_count,
    COUNT(DISTINCT pn.id) AS note_count,
    COUNT(DISTINCT a.id) AS attachment_count
FROM projects p
LEFT JOIN project_tags pt ON pt.project_id = p.id
LEFT JOIN project_notes pn ON pn.project_id = p.id
LEFT JOIN attachments a ON a.project_id = p.id
GROUP BY p.id, p.name, p.domain, p.subdomain, p.status, p.description,
         p.repo, p.source_url, p.source_path, p.created_at, p.updated_at;

-- Projects with their tags as a comma-separated list
CREATE VIEW IF NOT EXISTS project_with_tags AS
SELECT
    p.id,
    p.name,
    p.domain,
    p.subdomain,
    p.status,
    p.description,
    STRING_AGG(t.name, ', ' ORDER BY t.name) AS tags
FROM projects p
LEFT JOIN project_tags pt ON pt.project_id = p.id
LEFT JOIN tags t ON t.id = pt.tag_id
GROUP BY p.id, p.name, p.domain, p.subdomain, p.status, p.description;

-- Dependency graph edges with project names
CREATE VIEW IF NOT EXISTS dependency_graph AS
SELECT
    d.blocker_id,
    b1.name AS blocker_name,
    b1.status AS blocker_status,
    d.blocked_id,
    b2.name AS blocked_name,
    b2.status AS blocked_status,
    d.dependency_type
FROM dependencies d
JOIN projects b1 ON d.blocker_id = b1.id
JOIN projects b2 ON d.blocked_id = b2.id;

-- Domain/status aggregate counts for stats endpoint
CREATE VIEW IF NOT EXISTS domain_status_counts AS
SELECT
    domain,
    status,
    COUNT(*) AS project_count
FROM projects
GROUP BY domain, status;

-- =============================================================================
-- SUBSCRIPTIONS (Finance section)
-- =============================================================================

-- Recurring subscriptions, bills, and memberships. Powers the Finance
-- section of the newspaper — "what's due this week" stories, monthly
-- burn totals, cancellation deadline alerts.
CREATE SEQUENCE IF NOT EXISTS seq_subscriptions START 1;

CREATE TABLE IF NOT EXISTS subscriptions (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_subscriptions'),
    name          TEXT NOT NULL,               -- "Netflix", "Tailscale", "Claude Pro"
    category      TEXT,                        -- "streaming", "tools", "insurance", "domain", "utility", "membership"
    amount        DECIMAL(10,2),               -- 14.99
    currency      TEXT NOT NULL DEFAULT 'EUR',
    frequency     TEXT NOT NULL DEFAULT 'monthly',  -- "monthly", "annual", "quarterly", "weekly"
    next_due      DATE,                        -- when the next charge hits
    auto_renew    BOOLEAN DEFAULT true,
    cancel_url    TEXT,                        -- direct link to cancellation page
    notes         TEXT,
    project_id    INTEGER,                    -- optional FK to a Marginalia project
    active        BOOLEAN DEFAULT true,       -- false = cancelled / lapsed
    created_at    TIMESTAMP DEFAULT current_timestamp,
    updated_at    TIMESTAMP DEFAULT current_timestamp
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_next_due ON subscriptions(next_due);
CREATE INDEX IF NOT EXISTS idx_subscriptions_category ON subscriptions(category);
CREATE INDEX IF NOT EXISTS idx_subscriptions_active ON subscriptions(active);

-- =============================================================================
-- EXERCISE LOG (Sports section)
-- =============================================================================

-- One row per workout session. The Sports section viz groups these by
-- month × activity and counts sessions, same dot-block pattern as Finance.
-- Later: import from Hevy CSV (weights) and Apple Health XML (cardio/other).
CREATE SEQUENCE IF NOT EXISTS seq_exercise START 1;

CREATE TABLE IF NOT EXISTS exercise_log (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_exercise'),
    activity    TEXT NOT NULL,           -- swimming, weights, walking, yoga, cycling, running
    date        DATE NOT NULL,
    duration    INTEGER,                 -- minutes
    distance    DECIMAL(10,2),           -- km, nullable
    calories    INTEGER,                 -- nullable
    notes       TEXT,
    source      TEXT DEFAULT 'manual',   -- manual, hevy, apple_health
    created_at  TIMESTAMP DEFAULT current_timestamp
);

CREATE INDEX IF NOT EXISTS idx_exercise_date ON exercise_log(date);
CREATE INDEX IF NOT EXISTS idx_exercise_activity ON exercise_log(activity);

-- =============================================================================
-- METADATA
-- =============================================================================

CREATE TABLE IF NOT EXISTS metadata (
    key   TEXT PRIMARY KEY,
    value TEXT
);

INSERT INTO metadata (key, value) VALUES ('schema_version', '1.0')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO metadata (key, value) VALUES ('created_at', CAST(current_timestamp AS TEXT))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
