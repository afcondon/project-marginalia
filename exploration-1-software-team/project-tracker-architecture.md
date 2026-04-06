# Project Tracker: Architecture Plan

**A PureScript/Halogen/Hylograph project management app prototyping ShapedSteer visualization patterns.**

---

## Why This Project

Three birds, one stone:

1. **Useful tool**: manage all projects (programming, house, garden, woodworking, music) from anywhere via TailScale
2. **Multi-agent proof-of-concept**: first real task for the agent team workflow
3. **ShapedSteer prototype**: test DAG visualization, multi-view switching, and status workflows using Hylograph on a simpler domain before tackling ShapedSteer's full complexity

## Where It Lives

Start in `agent-teams/project-tracker/` for the experiment. If it proves useful, promote to its own repo or into the polyglot-deploy stack.

## Tech Stack (Matching Minard)

| Component | Technology | Notes |
|-----------|------------|-------|
| Frontend | PureScript + Halogen + Hylograph | HATS for viz, Halogen for UI chrome |
| Visualization | hylograph-layout (treemap, Sankey), hylograph-simulation (beeswarm), hylograph-graph (DAG ops) | All available as registry packages |
| Server | PureScript + HTTPurple | Route ADT + pattern match dispatch (Minard pattern) |
| Database | DuckDB | Matches Minard; migrated from existing SQLite catalog |
| Seed data | Import from infovore-larder-db (34 plans, 101 repos, house-projects.md) | One-time migration script |

## Data Model

### Core Tables

```sql
-- The main entity. Broader than "plan" — covers aspirations, clippings, active work, finished things.
CREATE TABLE projects (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL,
    domain        TEXT NOT NULL,       -- programming, house, garden, woodworking, music, infrastructure
    subdomain     TEXT,                -- hylograph, minard, shapedsteer, furniture, eurorack, etc.
    status        TEXT NOT NULL DEFAULT 'idea',
                                       -- idea | someday | active | blocked | done | defunct | evolved
    evolved_into  INTEGER REFERENCES projects(id),  -- for status='evolved', points to successor
    description   TEXT,                -- what is this project?
    source_url    TEXT,                -- link to repo, plan doc, or reference
    source_path   TEXT,                -- filesystem path to plan/doc if local
    repo          TEXT,                -- git repo name if applicable
    created_at    TIMESTAMP DEFAULT current_timestamp,
    updated_at    TIMESTAMP DEFAULT current_timestamp
);

-- Proper many-to-many dependency relation (not comma-separated text)
CREATE TABLE dependencies (
    blocker_id    INTEGER NOT NULL REFERENCES projects(id),
    blocked_id    INTEGER NOT NULL REFERENCES projects(id),
    dependency_type TEXT DEFAULT 'blocks',  -- blocks | informs | feeds_into
    PRIMARY KEY (blocker_id, blocked_id)
);

-- Tags for cross-cutting concerns (e.g. "hylograph", "paul", "claude-authored", "ship-2026")
CREATE TABLE tags (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE
);

CREATE TABLE project_tags (
    project_id    INTEGER NOT NULL REFERENCES projects(id),
    tag_id        INTEGER NOT NULL REFERENCES tags(id),
    PRIMARY KEY (project_id, tag_id)
);

-- Timestamped notes/updates — the project's log
CREATE TABLE project_notes (
    id            INTEGER PRIMARY KEY,
    project_id    INTEGER NOT NULL REFERENCES projects(id),
    content       TEXT NOT NULL,
    created_at    TIMESTAMP DEFAULT current_timestamp
);

-- Status change history — enables timeline visualization
CREATE TABLE status_history (
    id            INTEGER PRIMARY KEY,
    project_id    INTEGER NOT NULL REFERENCES projects(id),
    old_status    TEXT,
    new_status    TEXT NOT NULL,
    changed_at    TIMESTAMP DEFAULT current_timestamp,
    reason        TEXT
);
```

### Status Lifecycle

```
  idea ──► someday ──► active ──► done
              │           │
              │           ├──► blocked (+ unblocked back to active)
              │           │
              └───────────├──► defunct (abandoned)
                          │
                          └──► evolved (→ evolved_into points to successor)
```

The `evolved` status captures your pattern of projects that aren't "done" but have been absorbed into something else (e.g. early D3 tagless experiments → Hylograph).

### Domain Taxonomy

Initial domains and subdomains, derived from your existing data:

| Domain | Subdomains |
|--------|------------|
| programming | hylograph, minard, shapedsteer, ecosystem, polyglot, purerl-tidal, humboldt |
| music | pedalboard, eurorack, composition, samples, tarot-music |
| house | renovation, electrical, tiling, fixtures |
| woodworking | furniture, shelving, outdoor |
| garden | planting, landscaping, structures |
| infrastructure | deployment, backup, archive, self-hosting |

Not hardcoded — just seed data. New domains/subdomains created as projects are added.

## Visualizations

Hylograph visualizations will be added later, chosen to address specific needs as they emerge. The library offers treemap, Sankey, DAG, force-directed networks, circle packing, partition, and more — we'll pick what fits rather than pre-committing.

The initial phase is a forms-based CRUD app with a filterable list view. This is deliberately "todo app shaped" — the interesting visualization work comes once we have enough data and enough clarity about what questions matter.

### Available Hylograph options (for later)
- `hylograph-layout`: treemap (5 tiling algos), Sankey, pack, partition, tree, cluster, adjacency matrix
- `hylograph-simulation`: force-directed beeswarm, collision, many-body, link forces
- `hylograph-graph`: topological sort, cycle detection, layer computation, A*/Dijkstra/BFS/DFS
- No dedicated timeline layout yet — would need custom work or creative use of partition/Sankey

## Server API (HTTPurple, Minard Pattern)

Route ADT:

```purescript
data Route
  = ListProjects        -- GET  /api/projects
  | GetProject          -- GET  /api/projects/:id
  | CreateProject       -- POST /api/projects
  | UpdateProject       -- PUT  /api/projects/:id
  | DeleteProject       -- DELETE /api/projects/:id
  | ListDependencies    -- GET  /api/dependencies
  | CreateDependency    -- POST /api/dependencies
  | DeleteDependency    -- DELETE /api/dependencies/:blocker/:blocked
  | AddNote             -- POST /api/projects/:id/notes
  | ListTags            -- GET  /api/tags
  | TagProject          -- POST /api/projects/:id/tags
  | UntagProject        -- DELETE /api/projects/:id/tags/:tag
  | Stats               -- GET  /api/stats
  | StatusHistory       -- GET  /api/projects/:id/history
```

Query parameters for filtering: `?domain=...&status=...&tag=...`

## Directory Structure

```
agent-teams/project-tracker/
├── spago.yaml              # workspace root
├── database/
│   ├── schema.sql          # DDL
│   ├── seed.sql            # migrated data from infovore-larder-db
│   └── tracker.duckdb      # the database file (gitignored)
├── server/
│   ├── spago.yaml
│   └── src/
│       ├── Main.purs       # HTTPurple routes + server startup
│       ├── API/
│       │   ├── Projects.purs
│       │   ├── Dependencies.purs
│       │   ├── Tags.purs
│       │   └── Stats.purs
│       └── Database/
│           ├── DuckDB.purs   # FFI (can we share Minard's?)
│           └── DuckDB.js
├── frontend/
│   ├── spago.yaml
│   ├── public/
│   │   └── index.html
│   └── src/
│       ├── Main.purs
│       ├── Component/
│       │   ├── App.purs          # shell + view switching
│       │   ├── TreemapViz.purs   # domain treemap
│       │   ├── BeeswarmViz.purs  # status beeswarm
│       │   ├── DagViz.purs       # dependency DAG
│       │   └── ListView.purs     # table view
│       ├── API.purs              # fetch client
│       └── Types.purs            # shared domain types
└── tools/
    └── migrate.py            # one-time: SQLite → DuckDB migration
```

## Build Order (Phases)

### Phase 0: Skeleton + Data
1. DuckDB schema + seed data migration from infovore-larder-db
2. HTTPurple server with ListProjects + Stats endpoints
3. Frontend shell with List View only (no Hylograph yet)
4. Verify the pipeline works: data → API → browser

### Phase 1: First Visualization
5. Domain Treemap — the simplest Hylograph viz, reuses Minard's treemap patterns
6. Click-to-filter interaction between treemap and list

### Phase 2: Interactive Views
7. Status Beeswarm with drag-to-change-status
8. Dependency DAG (this is the ShapedSteer prototype payoff)
9. View switching UI

### Phase 3: Full CRUD + Polish
10. Create/edit/delete projects via UI
11. Tag management
12. Note-taking inline
13. Status history timeline (custom Hylograph work)

## What This Prototypes for ShapedSteer

| Project Tracker Feature | ShapedSteer Equivalent |
|------------------------|------------------------|
| Multi-view switching (treemap/beeswarm/DAG/list) | ShapedSteer's notebook/graph/grid/timeline views |
| Dependency DAG with status coloring | ShapedSteer's typed DAG with execution state |
| Drag-to-change-status on beeswarm | Direct manipulation of node state |
| Domain treemap drill-down | Hierarchical navigation of computation graphs |
| Status history timeline | Execution history / audit trail |

## Design Notes

- **Light theme, Swiss style** per personal preferences — clean grids, generous whitespace, sans-serif, restrained color
- **No framework beyond Halogen** — no routing library beyond what Halogen provides, no state management library beyond Halogen stores
- **DuckDB FFI**: ideally share Minard's `Database.DuckDB` module rather than rewriting. Check if `cartography-database` package can be depended on directly.

## Open Questions

1. **Share Minard's DuckDB FFI?** The `cartography-database` package in Minard's workspace — is it published or local-only? If local, we either copy or make it a proper shared package.
2. **Spago workspace structure**: single workspace with server + frontend packages (like Minard), or separate?
3. **Where do we get the missing projects from?** The existing 34 plans are a start, but you mentioned "a dozen more" plus marking old ones as defunct. Do we seed with what we have and add interactively?
4. **DuckDB or SQLite?** DuckDB matches Minard patterns and is more powerful for analytics queries, but SQLite is simpler and the existing data is already there. DuckDB is the recommendation but worth confirming.
