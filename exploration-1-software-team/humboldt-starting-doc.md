# Humboldt: Starting Document

**Synthesized from all existing design documents, April 2026.**

This is the single source of truth for what Humboldt is, what's been decided, what's open, and where to start. It supersedes the earlier DATA_EXPLORER_PROPOSAL.md (March 2025) and query-schema-visualization-brainstorm.md (April 2026) by incorporating their ideas into a coherent whole.

---

## What Humboldt Is

Humboldt is a **data cartography** tool — the database/schema equivalent of Minard's code cartography. Where Minard makes codebase structure visible and navigable (packages → modules → declarations → type signatures), Humboldt does the same for data structure (portals → domains → datasets → columns).

Named after Alexander von Humboldt, whose *Naturgemälde* depicted the interconnected systems of nature as a single visual map. The parallel is exact: Humboldt maps the interconnected structure of data catalogs.

Part of a three-tool cartography suite:
- **Minard** — code cartography (working, pre-release)
- **Humboldt** — data cartography (this project)
- **Pausanias** — UX cartography (planned, separate)

## What Exists Today

### Code
- Landing page: `CodeExplorer/humboldt/src/Component/App.purs` — styled hero with Powers of Ten elevation metaphor, three feature cards
- Bootstrap: `CodeExplorer/humboldt/src/Main.purs` — minimal Halogen app
- Config: `CodeExplorer/humboldt/spago.yaml` — bare PureScript/Halogen deps only

### External Infrastructure (Paul's Rule4)
- TTST sync engine for transaction-time state tables
- Socrata adapter cataloging 10,000+ datasets from NYC, Chicago, Texas, Colorado, Utah
- DuckLake integration with 29-table metadata model and time-travel
- Universal type mapping (100+ types across 5 database engines)
- Provenance via OpenTelemetry trace injection
- Full-text search on resource/column names and descriptions
- No web UI, API, or visualization layer

### Documents (Now Consolidated Here)
- `CodeExplorer/docs/DATA_EXPLORER_PROPOSAL.md` — original proposal (March 2025)
- `CodeExplorer/docs/query-schema-visualization-brainstorm.md` — speculative extensions (April 2026)
- References in `CodeExplorer/docs/PAUSANIAS_PLAN.md` — suite context

---

## The Core Ideas (From Simple to Speculative)

### Tier 1: Direct Parallels to Minard (Proven Patterns)

These apply Minard's existing visualization vocabulary to data. Low risk, high clarity.

| Minard Concept | Humboldt Equivalent |
|---|---|
| Package treemap | Portal/domain treemap (sized by dataset count or total rows) |
| Module beeswarm | Dataset bubble-pack (sized by row count or column count) |
| Declaration detail | Column detail (type, nullability, description, usage) |
| Call graph arcs | Foreign key / join relationships |
| Reachability overlay | Query coverage heatmap (which tables/columns are actually used) |
| Purity overlay | Type consistency overlay (columns with mismatched types across datasets) |
| Git heat overlay | Freshness overlay (time since last update) |
| Coupling metrics | Cross-dataset column sharing |
| Namespace tree | Category/tag taxonomy tree |
| Type class grid | Type family grid (datasets sharing column schemas) |

### Tier 2: Temporal Dimension (Humboldt's Unique Advantage)

Minard has discrete snapshots. Humboldt has continuous schema history via TTST. This is genuinely new.

- **Schema timeline**: columns appearing, disappearing, changing type over years — git blame for database structure
- **Temporal treemap**: animate the universe growing/shrinking over time
- **Diff overlays**: added (green), removed (red), changed (amber) between any two points
- **Schema evolution sparklines**: inline mini-timelines showing each column's history

### Tier 3: Cross-Dataset Structure Discovery (Novel Territory)

No existing tool does this well. Highest risk, highest reward.

- **Latent foreign keys**: find relationships between datasets that nobody documented
- **Column fingerprinting**: statistical similarity (cardinality, distribution, histogram) to identify actually-related columns beyond name matching
- **Type families**: clusters of datasets that share column schemas
- **Schema mining from web sources**: infer schemas from API responses with confidence visualization

### Tier 4: Query-as-Visualization (Requires yoga-postgres-om or Similar)

Speculative. Depends on having type-level query information.

- **Query as highlighted subgraph**: a query lights up the schema elements it touches
- **Query as Sankey flow**: data flowing through filter/join/project stages
- **Schema coverage analysis**: aggregate all queries to find hot/cold schema regions
- **Visual query workbench**: ShapedSteer nodes as typed SQL queries

---

## Decided

These are settled based on the existing documents and the Minard precedent:

1. **Frontend**: PureScript + Halogen + Hylograph (HATS). Non-negotiable — shared vocabulary with Minard.
2. **Database**: DuckDB for the query/visualization layer.
3. **Navigation model**: Powers of Ten (Universe → Neighborhood → Entity → Atom) with click-to-navigate, no back buttons, URL-serialized state.
4. **Visualization vocabulary**: Hylograph's existing layouts (treemap, beeswarm, arc diagram, circle pack) as the starting point. Extend as needed.
5. **First data source**: Socrata (10K datasets already cataloged by Rule4).
6. **Relationship to Minard**: Sibling, not fork. Shared patterns via Hylograph libraries, no direct code dependency.
7. **Naming**: Humboldt (confirmed by landing page, brainstorm doc, suite references).

## Open (Needs Resolution)

### Architecture Questions

1. **Where does temporal state live?**
   - Option A: PG as temporal authority, DuckDB as query layer (preserves Rule4)
   - Option B: DuckDB-native via DuckLake snapshots (simpler, matches Minard)
   - Option C: PG for ingestion, DuckDB for exploration (clean separation)
   - *Likely answer*: Option C or A — don't fight Rule4's existing architecture. Paul's Python pipeline writes to PG; Humboldt reads from DuckDB. The sync mechanism is the key design decision.

2. **API server language?**
   - PureScript/HTTPurple (like Minard — code sharing, type safety)
   - Python/FastAPI (reuses Rule4Catalog directly)
   - Both (Python wraps Rule4, PS proxies for frontend)
   - *Likely answer*: PureScript API server talking to DuckDB, like Minard. Rule4's Python pipeline is a separate process that feeds the DuckDB.

3. **Loader/ingestion**: Rule4's Python pipeline is treated as external infrastructure. Humboldt doesn't rewrite it. The boundary is: Rule4 produces a DuckDB file (or keeps DuckLake in sync); Humboldt reads it.

### Scope Questions

4. **Second data source timing**: When to add Minard's own DuckDB as a data source (proving the mutual-reinforcement loop)?

5. **Cross-dataset discovery scope**: Start with column name matching (noisy but fast) or jump to statistical fingerprinting?

6. **Temporal visualization vocabulary**: What Hylograph primitives need building? Transitions exist but may need timeline-specific extensions.

---

## Where to Start

Given that this is exploratory and may pivot, the starting point should be:

### Phase 0: Prove the Data-to-Visualization Pipeline

**Goal**: Get Rule4's Socrata data rendering in a Hylograph visualization in the browser.

This is deliberately narrow. It answers one question: *can we take the data that Rule4 has already cataloged and make it visible using the same technology Minard uses?*

Concrete steps:
1. Get a DuckDB file with Rule4's Socrata catalog data (from Paul, or by running the Rule4 pipeline)
2. Stand up a PureScript/HTTPurple API server that queries it (clone Minard's server pattern)
3. Render a Universe-level treemap: all portals, domains sized by dataset count
4. Click into a domain → bubble-pack of datasets
5. Click into a dataset → column layout with types

This is the Tier 1 work from the table above. It reuses Minard's patterns wholesale. If this doesn't work smoothly, we learn where the data domain diverges from code before investing in temporal/discovery features.

### Phase 1: Add the Temporal Dimension

Once the spatial navigation works, add TTST-backed schema history. This is where Humboldt becomes more than "Minard with different nouns."

### Phase 2: Cross-Dataset Discovery

The novel stuff. Column fingerprinting, latent foreign keys, type families. This is where the multi-agent approach may become valuable — parallel exploration of different discovery algorithms.

---

## How This Relates to the Agent Teams Experiment

- **Phase 0** is mostly Andrew + Architect agent: reading Minard, planning the server/database/frontend structure, making architectural decisions.
- **Phase 1** may benefit from Architect + Implementer: the temporal visualization work has a clear plan-then-implement structure.
- **Phase 2** is where multi-agent really shines: competing approaches to discovery algorithms can be explored in parallel by different teammates.
- **Libraries extracted during any phase** should follow the Hylograph pattern — small, focused, published packages that compose.

---

## Appendix: Minard's Architecture (For Reference)

```
Source Files → Loader (Rust) → DuckDB → Server (PS/HTTPurple) → Frontend (PS/Halogen/Hylograph)
```

**Database**: 6-layer schema (Registry → Project → Module → Declaration → Call Graph → Metrics). ~1.17 GB for 437 packages.

**Server**: REST API on port 3000. Endpoints for packages, modules, declarations, imports, calls, annotations, git history. SQL queries against DuckDB.

**Frontend**: ~34K LOC PureScript. 15+ visualization components. Overlay system (hotkeys toggle reachability, purity, heat, coupling, co-change). Navigation by clicking visualization elements.

**Key pattern to replicate**: expensive analysis at load time; fast SQL queries at runtime; declarative HATS visualization; overlay system for multiple lenses on the same structure.
