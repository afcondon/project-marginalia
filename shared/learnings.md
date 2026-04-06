# Agent Teams Learnings

Record observations, surprises, and patterns from both explorations here.

## Format

### [Date] — [Exploration] — [Brief Title]

**What happened:**
**What worked:**
**What didn't:**
**Implications:**

---

### 2026-04-06 — Exploration 1 — First Parallelism Tests (Project Tracker)

**What happened:**
Ran three rounds of team experiments on the project tracker app:
1. Architect planned status traffic lights feature → discovered backend already supported it (frontend-only)
2. Architect planned filter pills with counts → same result, existing stats endpoint sufficient (frontend-only)
3. Gave up on finding a natural frontend+backend split for a single feature. Split into genuinely independent tasks: frontend (filter pills + traffic lights + quick edit) and backend (agent API endpoints). This worked — clean parallel execution, zero merge conflicts, both built successfully.
4. Second round with TeamCreate for tmux panes: frontend (traffic light redesign) + backend (dependency CRUD). Tmux display worked well. Both completed, combined build clean.

**What worked:**
- Tmux split panes gave good visibility into parallel work
- Completely independent file sets (frontend/ vs server/) eliminated merge risk
- Both agents produced working code that compiled together first try
- The Agent tool (subprocess) approach was faster for pure parallel execution
- TeamCreate approach gave better observability

**What didn't:**
- The Architect agent spent excessive time deliberating (2+ minutes per plan) on decisions that could have been made in seconds
- Two out of three features turned out to be frontend-only, making the "parallel frontend+backend" split artificial
- The overhead of defining API contracts, briefing agents, and reviewing output exceeded the time saved by parallelism
- For a codebase of this size (~120 projects, ~10 source files), a single agent can hold the full context and move faster
- The first frontend agent's traffic light implementation missed the core UX concept despite detailed spec — required a second round with screenshots

**Implications:**
- Agent teams may add more value on larger codebases where no single agent can hold full context
- The "completely independent file sets" pattern is the key enabler — features that touch the same files are risky
- For the user's current workloads, a single capable agent is likely more productive than a team
- The project tracker itself is more valuable to invest in than the team orchestration experiment
