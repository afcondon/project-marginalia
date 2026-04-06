# Agent Teams

Experimental workspace for multi-agent patterns using Claude Code Agent Teams.

## Two Explorations

### Exploration 1: Software Team Roles
Agents mimicking traditional software team roles (architect, implementer, reviewer) working together on real projects (ShapedSteer, Humboldt). The goal is to discover where role-based agent teams add value beyond a single Claude Code session, and where the metaphor of human team roles breaks down.

Target projects: Humboldt/DataExplorer (data cartography — schema + query visualization, counterpart to Minard's code cartography, currently brainstorm-stage in `/Users/afc/work/afc-work/CodeExplorer`), ShapedSteer (DAG workbench, has strict architectural layer rules).

### Exploration 2: Communication Buffer (Paul Harrington)
Agents that mediate between humans with different communication styles. Pipeline: intake stakeholder comms -> work with Paul to create concrete tasks -> package completed work for other stakeholders.

## Agent Teams Setup

Agent Teams is enabled via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `.claude/settings.local.json`.

To use: ask Claude to spawn a team in natural language. Teammates can reference pre-defined agent types from `.claude/agents/`.

### Reusable Agent Definitions

Agent role definitions live in `.claude/agents/`. These condition teammates with specific perspectives and constraints. See each file for details.

### Display Modes

- **in-process** (default): all teammates in one terminal
- **tmux/iTerm2**: split panes for visual monitoring

### Key Commands

- `Shift+Down`: cycle through teammates (in-process mode)
- `Ctrl+T`: toggle task list
- Direct messaging: address any teammate by name

## Learnings

Record what works and what doesn't in `shared/learnings.md` after each session.
