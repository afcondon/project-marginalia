# Exploration 1: Software Team Roles

## Hypothesis

A team of role-conditioned agents (Architect, Implementer, Reviewer) can produce better results on complex tasks than a single Claude Code session — specifically by:

- Catching architectural violations that a single agent might introduce under time pressure
- Separating the "what to build" decision from the "how to build it" execution
- Providing genuine review friction (a second opinion that isn't just the same agent re-reading its own work)

## Counter-hypothesis (Organizational Skeuomorphism)

Human team roles exist partly because of human limitations (bounded attention, knowledge silos, social accountability). Agents don't have the same limitations. The role separation might:

- Add overhead without adding quality
- Create artificial communication bottlenecks
- Be worse than a single agent with a good system prompt that incorporates all three perspectives

## What to Measure

- **Quality**: Does the team catch errors/violations that a single agent misses?
- **Coherence**: Does the plan-implement-review cycle produce more architecturally coherent changes?
- **Cost**: Token usage and wall-clock time vs. single agent
- **Friction**: Where does the role separation help vs. hinder?

## How to Run

From any project directory with Agent Teams enabled:

```
Spawn a team for [task description].
Use the architect agent type for planning,
the implementer agent type for coding,
and the reviewer agent type for review.
The architect should plan first, I'll approve, then implementer builds, then reviewer checks.
```

## Target Projects

1. **Humboldt** (aka DataExplorer) — data cartography, the database/schema counterpart to Minard's code cartography. Lives in `/Users/afc/work/afc-work/CodeExplorer`. Currently brainstorm-stage: visualizing schemas, queries-as-operations-on-schemas, schema inference from web sources. Good test for agent teams in design/greenfield mode. See `CodeExplorer/docs/query-schema-visualization-brainstorm.md`.
2. **ShapedSteer** — DAG workbench, has ARCHITECTURE.md with strict layer rules. Good test case because architectural violations are well-defined and detectable. Better for testing agent teams on implementation tasks in an existing codebase.

## Session Log

Record each trial session here with date, project, task, outcome, and learnings.

| Date | Project | Task | Outcome | Notes |
|------|---------|------|---------|-------|
| | | | | |
