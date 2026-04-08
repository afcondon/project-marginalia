---
name: marginalia
description: Query the marginalia project tracker API to look up projects, ports, servers, and notes; start/stop services by reading their registered commands; add new server registrations when you have a known-good command.
---

# Marginalia — project tracker API skill

Marginalia is a personal project tracker that runs as a local HTTP API.
Instead of grepping through config files to answer "what port does X run on?"
or "what's the start command for this project?", **query the API**.
It's authoritative, fast, and structured.

## Where it runs

- **API base URL**: `http://localhost:3100`
- **Frontend**: `http://localhost:3101`
- **DB**: DuckDB at `~/work/afc-work/agent-teams/project-tracker/database/tracker.duckdb`

If the API isn't responding, the tracker isn't running. Start it with:

```
cd ~/work/afc-work/agent-teams/project-tracker && node server/run.js
```

## Core endpoints

### Discover projects

```
GET /api/projects
GET /api/projects?search=hylograph
GET /api/projects?domain=programming&status=active
GET /api/projects?tag=library
GET /api/projects?ancestor=125            # all descendants of project 125
```

Returns an envelope with `projects` (array) and `count`. Each project has
`id`, `slug`, `parentId`, `name`, `domain`, `subdomain`, `status`, `description`,
`tags`, `updatedAt`. The `slug` is a NATO-callsign four-word identifier
(`oscar-romeo-delta-uniform`) that's stable across renames.

### Full detail for one project

```
GET /api/projects/:id
```

Returns name, description, tags, notes, dependencies, attachments, slug,
parent, source_path, source_url, repo, evolved_into, full status history.

### Port registry — the key endpoint for this skill

```
GET /api/ports
```

Returns the full registry of all registered servers across all projects,
sorted by port. Each entry has:

- `id` — server entry id
- `projectId`, `projectName`, `projectSlug` — who owns it
- `role` — `api`, `frontend`, `websocket`, `worker`, `whisper`, etc.
- `port` — the TCP port (may be null for workers without a port)
- `url` — canonical URL (e.g. `http://localhost:3100`)
- `startCommand` — **polymorphic start instruction** (see below)
- `description` — human-readable note

The response also includes a `collisions` object mapping any port with more
than one claimant to a list of claimants — use this to detect conflicts.

```
GET /api/projects/:id/servers     # servers for one project
GET /api/ports/suggest            # the next free port starting at 3000
```

### Writing back

```
POST /api/projects/:id/servers
Body: { "role": "api", "port": 3100, "url": "http://localhost:3100",
        "startCommand": "cd /absolute/path && node server/run.js",
        "description": "..." }

DELETE /api/servers/:id

POST /api/agent/projects/:id/notes
Body: { "content": "...", "author": "claude" }

POST /api/agent/projects/:id/attachments
Body: { "filename":    "report.md",
        "filePath":    "/abs/path/to/file",
        "mimeType":    "text/markdown",      # optional, default application/octet-stream
        "description": "..." }               # optional
# Registers a filesystem reference on the project. No upload — the file stays
# where it is. If the path starts with the canonical store prefix
# (/Volumes/Crucial4TB/Documents/Notes Attachments/), the response url field
# points at /attachments/... so the frontend can link it. Otherwise url=null
# and the attachment shows as a plain pointer.

POST /api/projects/:id/tags
Body: { "tag": "library" }
```

## The polymorphic start_command

The `startCommand` field is **whatever-it-takes to start this server**.
Interpret the value by shape:

| Value shape | How to handle |
|---|---|
| Literal shell command (contains `&&`, pipes, or looks like a command) | `exec` it in a shell, background with `&`, capture logs |
| Path ending in `.sh` | `exec` the script |
| Path ending in `.py` | `python3 <path>` |
| Path ending in `.js` | `node <path>` |
| Path ending in `.md` | Read the file and follow the instructions inside — it's a runbook, not a command |
| Path to a Dockerfile directory | `docker compose up -d` or similar, if that's what the docs say |

Use the file extension as the primary signal. If a project hasn't been
"promoted" to a shell script yet, it may have a markdown runbook instead.
Read the runbook and do what it says. As the project matures, its start_command
evolves from markdown instructions → shell script → richer orchestration, but
the registered value is always "the thing that starts this".

## Common workflow: "get X running"

When the user asks you to get a project (or set of projects) running:

1. **Resolve**: find the project(s) by name, slug, or search
   ```
   curl -s http://localhost:3100/api/projects?search=<name> | jq
   ```
2. **Enumerate servers**: get the full detail or the servers endpoint
   ```
   curl -s http://localhost:3100/api/projects/<id>/servers | jq
   ```
3. **Check for collisions**: `curl -s http://localhost:3100/api/ports | jq .collisions`
4. **For each server**, read the `startCommand` and act on it according to
   the table above. Run in the background. Redirect stdout/stderr to a log
   file under `/tmp/marginalia-<slug>-<role>.log`.
5. **Verify**: after a brief pause, check the port is actually listening
   ```
   lsof -i :<port>
   ```
6. **Report** success/failure per server, including the log file path.

## Common workflow: "add a new server registration"

When a project doesn't have a start command registered yet, and the user
asks you to figure it out:

1. **Inspect the project**: read its README, spago.yaml, package.json,
   Cargo.toml, or whatever indicates how it's built and run
2. **Derive the command**: the form depends on the project kind
   - PureScript showcase: `cd <abs-source-path> && spago bundle -p <pkg> && npx http-server public -p <port> -c-1 --cors`
   - PureScript Node server: `cd <abs-source-path> && spago build && node server/run.js`
   - Rust binary: `cd <abs-source-path> && cargo run --release`
   - Python script: `cd <abs-source-path> && python3 <script>`
   - Docker: `cd <abs-source-path> && docker compose up -d`
3. **Test it**: run it in a subshell and verify the port becomes reachable
4. **If it works**, POST it to marginalia:
   ```
   curl -s -X POST http://localhost:3100/api/projects/<id>/servers \
     -H 'Content-Type: application/json' \
     -d '{"role":"api","port":3100,"url":"http://localhost:3100",
          "startCommand":"cd /abs/path && node server/run.js",
          "description":"HTTPurple API"}'
   ```
5. **If it doesn't work**, iterate. Don't register broken commands.
6. **When in doubt**, write a markdown runbook at
   `<project>/.marginalia/RUNNING.md` and register that path as the
   `startCommand`. Later sessions can promote it to a shell script.

## Guardrails

- **Absolute paths always** in registered start commands. `./foo` breaks
  when run from a different CWD.
- **Never register a command you haven't tested**. The registry's value
  is being trustworthy.
- **For umbrellas and deploy-configs, don't register servers**. Those
  projects orchestrate; their children have the actual runtime identity.
- **Check for port collisions** via `/api/ports` before suggesting a new
  port. The `/api/ports/suggest` endpoint does this for you automatically.
- **Don't silently overwrite** existing server entries. Fetch what's there,
  decide if you want to replace, DELETE the old one, POST the new one.

## Why this skill exists

The tracker has ground truth about what runs where. Without this skill,
Claude re-derives that information from `grep`, `ls`, and README-reading
on every session — slow, token-expensive, sometimes wrong. With this skill,
Claude issues `curl` queries and gets deterministic structured answers in
milliseconds. Inference is replaced by lookup wherever possible. Writes
happen via POST so the tracker stays the shared context layer across
sessions and across humans + agents.
