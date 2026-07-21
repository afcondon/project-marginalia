---
name: marginalia
description: Query the marginalia project tracker API for project intent — look up projects, status, notes, tags, dependencies. NOTE (seam, 2026-07-21) ports/servers/startCommands now live in Bosun's chair-server (:3022 / fleet.json), NOT Marginalia; :3100 server rows were purged. For anything about ports, starting/stopping services, or registering a server, use Bosun :3022 (see the "Port registry — MOVED TO BOSUN" section and Bosun docs/REGISTER-A-SERVICE.md).
---

# Marginalia — project tracker API skill

Marginalia is a personal project tracker that runs as a local HTTP API.
Instead of grepping through config files to answer "what port does X run on?"
or "what's the start command for this project?", **query the API**.
It's authoritative, fast, and structured.

## Where it runs

The **MacMini is the canonical host** (since project #203 landed,
2026-05): launchd-managed, on all the time.

- **API base URL**: `http://andrews-mac-mini:3100` — use this from
  every machine on the tailnet, including the MBP. `localhost:3100`
  is correct only in a shell ON the mini itself. Override with the
  `MARGINALIA_API` env var for unusual setups.
- **Frontend**: `http://andrews-mac-mini:3101`.
- **DB**: DuckDB at `~/work/afc-work/agent-teams/project-tracker/database/tracker.duckdb` **on the mini** (login `andrew`).

If the API isn't responding: check Tailscale is up, then check the
launchd agents on the mini (`ssh andrew@andrews-mac-mini`, see
`tools/launchd/`; note launchd backoff can make a restarting service
look dead for ~40s). Do NOT start a local tracker on the MBP — a
second instance against a stale DB copy is worse than a brief outage.

### Multi-host topology (project #202)

The registry knows which machine each service runs on. Server entries
have two fields used by host-aware tooling:

- `host` — tagged value (`mbp` | `macmini` | `cloudflare` | `andrew-only`).
  Stable across infrastructure swaps; consumed by SDI to decide whether
  to spawn locally or redirect.
- `tailscaleName` — routable address (`andrews-mac-mini`, etc.). Can
  change when a Tailscale node is renamed or replaced.

Always fill both when registering a new server (see "Writing back"
below). The full plan and migration sequence lives at
`project-tracker/docs/multi-host-topology.md`.

### On a different machine

Fresh clones on a different Mac (e.g. a MacMini running fictional demo
data) follow the same API shape. Two things change:

- **Attachment store**: defaults to `/Volumes/Crucial4TB/Documents/Notes Attachments/`. Override per-clone via a `.env` file at the repo root: `MARGINALIA_ATTACHMENT_STORE=/path/with/trailing/slash/`. The server reads this at startup via `tools/launchd/start-api.sh`.
- **Frontend URL resolution**: the committed bundle detects `window.location.hostname` at load time. On `localhost` it hits `localhost:3100`; on any other hostname it uses same-origin (expected to be reverse-proxied via Tailscale Serve to the API on port 3100 and whisper on 3200).

See `docs/BOOTSTRAP.md` for the full fresh-install recipe including
`scripts/seed-demo-data.mjs` which POSTs ~25 fictional projects for
first-run demos and testing.

## Core endpoints

### Discover projects

```
GET /api/projects
GET /api/projects?search=hylograph
GET /api/projects?domain=programming&status=active
GET /api/projects?tag=library
GET /api/projects?ancestor=125            # all descendants of project 125
```

> **⚠️ The filter param is `search`, not `q`.** Unknown query params are
> **silently ignored** — `?q=quartermaster` returns ALL projects (count 229),
> not a filtered set. Piped through `head`/`jq '.[0:5]'` that looks exactly like
> "a few fuzzy matches, my term not among them" and produces a confident false
> "not tracked." This actually happened (Quartermaster #238 declared untracked
> twice). Always use `?search=<term>` and check `count`; a `count` equal to the
> unfiltered total means your filter did nothing.

Returns an envelope with `projects` (array) and `count`. Each project has
`id`, `slug`, `parentId`, `name`, `domain`, `subdomain`, `status`, `description`,
`tags`, `updatedAt`, `coverUrl`, `blogStatus`. The `slug` is a NATO-callsign
four-word identifier (`oscar-romeo-delta-uniform`) that's stable across renames.
`coverUrl` is the hero screenshot for this project (null if none set).
`blogStatus` is the project's blog-post classification (see "Blog posts"
section below for values); null means unclassified.

### Full detail for one project

```
GET /api/projects/:id
```

Returns name, description, tags, notes, dependencies, attachments, slug,
parent, source_path, source_url, repo, evolved_into, full status history,
plus `coverAttachmentId`, `blogStatus`, and `blogContent` (the markdown
body of the blog post, populated when blogStatus is `drafted` or `published`).

### Port registry — MOVED TO BOSUN (`:3022`)

> **⚠️ SEAM ENACTED (2026-07-21).** Marginalia no longer holds ANY server /
> port / `startCommand` data. On 2026-07-21 all 50 legacy `:3100` server rows
> were reconciled into Bosun's `registry/fleet.json` and **purged** — `GET
> :3100/api/ports` now returns **empty, by design**. **Bosun's chair-server
> (`:3022`) is the single operations registry.** Marginalia holds only *intent*
> (identity, status, notes, tags, dependencies-as-meaning). This is
> MARGINALIA-SEAM step 3, **done** — see Bosun `docs/MARGINALIA-SEAM.md`.
>
> **For anything about ports/servers/starting a service, go to Bosun `:3022`:**
>
> ```
> GET    :3022/api/ports                    every server row + live collisions
> GET    :3022/api/ports/suggest            next free port (over fleet.json)
> GET    :3022/api/projects/:id/servers     servers for one project
> POST   :3022/api/projects/:id/servers     register — assigns id, writes
>                                            fleet.json, reloads `bosun serve`
> DELETE :3022/api/servers/:id              remove a row
> ```
>
> The `:3022` rows are shape-compatible with the fields documented below (same
> `id`/`projectId`/`role`/`port`/`url`/`startCommand`/`host`/… shape); the full
> registration procedure is Bosun's `docs/REGISTER-A-SERVICE.md`. Marginalia
> must still hold the **project** so `:3022` can denormalise name/slug — but the
> `:3100` server endpoints in the rest of this section are **DEPRECATED**: they
> still exist and still respond, but they are empty and **must not be written
> to** (writing there is exactly the drift the seam removed).

The field shape below describes a Bosun `:3022` row (and the legacy, now-empty
`:3100` row). `GET :3022/api/ports` returns the full registry of all registered
servers across all projects, sorted by port. Each entry has:

- `id` — server entry id
- `projectId`, `projectName`, `projectSlug` — who owns it
- `role` — `api`, `frontend`, `websocket`, `worker`, `whisper`, etc.
- `port` — the TCP port (may be null for workers without a port)
- `url` — canonical URL (e.g. `http://localhost:3050` for an mbp-local dev service; `http://andrews-mac-mini:8090` for a service intended to be reached via Tailscale; port 3100 itself is the tracker API on the mini)
- `startCommand` — **polymorphic start instruction** (see below). NULL when the service is managed by another launcher (e.g. DeepStar #191) — registry rows with NULL startCommand are documentation/collision-avoidance only, not actionable by SDI.
- `description` — human-readable note
- `host` — `mbp` | `macmini` | `cloudflare` | `andrew-only` | NULL. **Set this on every new entry** — SDI uses it to decide spawn vs. redirect.
- `tailscaleName` — e.g. `andrews-mac-mini`. NULL for non-Tailscale-routable hosts (cloudflare, andrew-only).
- `environment` — *legacy* — deployment style (`native`, `docker`, `cloudflare-pages`). Older rows have combined values like `mbp-native` that bundled host + style; those have been unwound by setting `host` separately, but `environment` is still populated. Don't use `environment` as a host signal in new code; use `host`.

The response also includes a `collisions` object mapping any port with more
than one claimant to a list of claimants — use this to detect conflicts.

```
GET /api/projects/:id/servers     # servers for one project
GET /api/ports/suggest            # the next free port starting at 3000
```

### Writing back

```
POST /api/projects
Body: { "name":        "project name"         (required)
      , "domain":      "programming"          (required; one of:
                                              programming, music, house,
                                              woodworking, garden,
                                              infrastructure)
      , "status":      "idea"                 (optional, default "idea"; see
                                              the status lifecycle below)
      , "subdomain":   "halogen"              (optional)
      , "description": "..."                  (optional — 1-sentence what-is-it)
      , "parentId":    151                    (optional; parent project id)
      , "sourceUrl":   "https://..."          (optional)
      , "sourcePath":  "/absolute/path"       (optional; local filesystem)
      , "repo":        "github-repo-name"     (optional)
      }
# Returns { "projects": [ { "id": N, "slug": "...", ... } ] } — one-element
# array wrapping the created project. Slugs are auto-generated 4-word NATO
# callsigns (e.g. sierra-bravo-alpha-foxtrot) and are the project's stable
# identity; the numeric id is for convenience.
#
# Marginalia spans many domains — not just coding. If you're adding a house
# remodel, a woodworking piece, a garden plot, a music album, or a piece
# of infrastructure, pick the matching domain and skip repo/sourceUrl/etc.
# if they don't apply.

PUT /api/projects/:id
Body: same shape as POST, partial — only include fields you want to change.
# Empty-string fields are treated as "don't update", NOT "clear". To
# change status in particular you usually want the lifecycle-validated
# agent endpoint below instead.
#
# parentId is nullable-aware: JSON number reparents to that project id,
# JSON null moves the project to root (clears parent_id), missing key
# leaves parent_id untouched. This is how the frontend and gazetteer
# drag-to-reparent work is implemented.
#
# Additional updatable fields beyond the POST shape:
#   "coverAttachmentId": 43        (int; id of an existing attachment to
#                                    use as the hero screenshot on the
#                                    Register index view)
#   "blogStatus":        "wanted"  (one of: "not_needed" | "wanted" |
#                                    "drafted" | "published"; see
#                                    "Blog posts" section below)
#   "blogContent":       "# ..."   (markdown body; only meaningful when
#                                    blogStatus is "drafted" or "published")
#   "humanSummary":      "..."     (the owner's editorial summary, shown on
#                                    P1/P2 aggregate cards on the front page.
#                                    HUMAN-AUTHORED ONLY: Claude must never
#                                    write or update this field — it is the
#                                    owner's voice, strictly additional to
#                                    `description` (the Claude-maintained
#                                    agent-bootstrap summary + Raker flow))

# ── DEPRECATED (2026-07-21): server rows moved to Bosun. Do NOT write
# ── these against :3100 — register via chair-server :3022 instead (same
# ── body shape). See the "Port registry — MOVED TO BOSUN" banner above and
# ── Bosun docs/REGISTER-A-SERVICE.md. The :3100 endpoints below still exist
# ── but Marginalia's server table is now empty by design.
POST /api/projects/:id/servers     # DEPRECATED — use POST :3022/api/projects/:id/servers
Body: { "role":          "api",
        "port":          3050,
        "url":           "http://localhost:3050",
        "startCommand":  "cd /absolute/path && node server/run.js",
        "description":   "...",
        "host":          "mbp",                   # required-in-spirit
        "tailscaleName": "andrews-macbook-pro",   # NULL ok for cloudflare / andrew-only
        "environment":   "native"                 # optional; deployment style only
      }

DELETE /api/servers/:id            # DEPRECATED — use DELETE :3022/api/servers/:id

POST /api/agent/projects/:id/notes
Body: { "content": "...", "author": "claude" }

DELETE /api/notes/:id
# Idempotent — returns { "ok": true, "deleted": N } even if the row is gone.
# No PUT endpoint; to amend a note, DELETE + POST a fresh one.

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

DELETE /api/projects/:id/tags?name=<tag>
# Tag name in query param. Idempotent — ok whether or not the link existed.
# The tag itself stays in the tags table; only the project→tag link is removed.

POST /api/agent/projects/:id/status
Body: { "status": "active", "reason": "optional explanation" }
# Lifecycle-validated status change. Returns 400 with the valid
# next-statuses in the error message if the transition is illegal.

POST /api/dependencies
Body: { "blockerId": 134, "blockedId": 90, "type": "related" }
# type ∈ blocks (default) | informs | feeds_into | related.
# "related" is the SYMMETRIC cross-tree "see also" edge — use it when a
# curation-surface project (e.g. Polyglot) wants to exhibit/link a project
# that lives in another family, instead of multi-parenting. It appears in
# both projects' detail under dependencies.related and renders as a
# "see also" rail in the dossier. The parent tree stays single-parented.

DELETE /api/dependencies/:blockerId/:blockedId
```

### Status lifecycle

Marginalia projects move through a DAG of statuses, not a free-for-all.
Valid transitions (from → to):

- `idea`    → someday, active, dormant, defunct
- `someday` → active, idea, dormant, defunct
- `active`  → done, dormant, blocked, defunct, evolved
- `dormant` → active, someday, defunct
- `blocked` → active, dormant, defunct
- `done`    → active
- `defunct` → idea, someday
- `evolved` → (terminal — the project has become another project)

**Dormant** is the "parked indefinitely" state: you're not actively
moving the project forward, but you don't want to throw it away either.
Distinct from `someday` (which implies positive intent to do later) and
from `defunct` (which implies abandonment). Reachable from any non-
terminal, non-`done` state: an `idea` can be parked before it ever gets
started, an `active` project can be paused, a long-term `blocked` can
turn into a shelving decision. From dormant you can resume
(→ `active`), revive interest without commitment (→ `someday`), or
acknowledge it's dead (→ `defunct`).

Use `POST /api/agent/projects/:id/status` when you want the server to
enforce this DAG. Use `PUT /api/projects/:id` with a status field only
when you explicitly want to bypass the validation (rare).

## Blog posts

Every project carries a `blogStatus` field that classifies its
relationship with a future blog post. This is orthogonal to the
project's own status (idea/active/done/…) — a done project might still
want a blog post, an active project might not need one.

Values (stored as a string, deserialized into a four-constructor ADT
on the frontend):

| Value         | Meaning                                                        |
|---------------|----------------------------------------------------------------|
| `null`        | Unclassified — the initial state for every project             |
| `not_needed`  | Explicitly no blog post (e.g. infrastructure, throwaway stubs) |
| `wanted`      | A blog post is wanted but nothing's been written yet           |
| `drafted`     | Draft in progress — `blogContent` holds the current markdown   |
| `published`   | Finished post — `blogContent` holds the published markdown     |

The companion `blogContent` field (on the detail response only, not the
list) is a markdown body. It's only meaningful when `blogStatus` is
`drafted` or `published`; for other states it's null.

### Setting blog status

```
PUT /api/projects/42
Body: { "blogStatus": "wanted" }
```

Or with content:

```
PUT /api/projects/42
Body: { "blogStatus": "drafted",
        "blogContent": "# Title\n\nDraft body…" }
```

The PUT endpoint treats missing fields as "don't update" (see the
regular PUT notes), so you can update `blogStatus` and `blogContent`
independently or together. An empty-string `blogStatus` is treated as
"don't update" — the API does not currently offer a way to clear
`blogStatus` back to null once set, only to move it among the four
concrete values.

### Bulk classification

The dossier view (frontend detail page) has a four-button widget for
setting blog status interactively, plus an inline markdown editor that
appears when the status is `drafted` or `published`. For bulk
classification across many projects, drive the PUT endpoint directly —
e.g. mark all programming-domain projects as `wanted` in one pass:

```python
import json, urllib.request
for p in json.load(urllib.request.urlopen('http://andrews-mac-mini:3100/api/projects'))['projects']:
    if p['domain'] != 'programming': continue
    body = json.dumps({'blogStatus': 'wanted'}).encode()
    req = urllib.request.Request(
        f'http://andrews-mac-mini:3100/api/projects/{p["id"]}',
        data=body,
        headers={'Content-Type': 'application/json'},
        method='PUT',
    )
    urllib.request.urlopen(req).read()
```

## Living summaries — the `description` field as Claude-maintained context

The `description` field is a **project summary**, not a session log.
The test it has to pass: a Claude with no prior context, reading just
the descriptions of all active projects, gets a faithful overview of
the system without re-deriving it from notes, code, or git history.

That means the description answers **what is this project, where does
it stand, and where is it going next** — in timeless prose. Multi-
paragraph is fine. Dated activity, decisions made today, problems hit,
things deferred — those go in **notes**
(`POST /api/agent/projects/:id/notes`), which is the dated record. The
description is the timeless current view on top of that record.

### What to write

Aim for ~3–6 sentences (one paragraph) for small projects, up to three
short paragraphs for large ones, structured roughly as:

1. **What it is.** One or two sentences. Position it in the wider
   system if relevant (parent project, sibling projects, what it
   replaces, what it feeds into).
2. **Current state.** What exists now — the components, the shape, the
   key behaviours a fresh observer needs to navigate it. State, not
   history. Don't say "added X today"; say "has X".
3. **Near-term direction.** One sentence on what's next, if there's a
   clear pointing.

No leading dates. No "today". No "I" or "the session". No changelog
bullets. No "Deferred:" sections — deferred work is a note, not part
of the description.

### Description vs. note — the rule of thumb

If a sentence still reads naturally six months from now, it belongs in
the description. If it only makes sense in the context of a specific
session ("today's gap closes here", "the bug was…", "earlier we
tried…"), it belongs in a note.

#### Anti-pattern (do not write this)

```
**2026-05-04 (afternoon)** — Big Calypso UX session: 6→7 panes, sticky
toolbar, comment-toggle, persistence dir, Cmd-N keymap…

Promoted Hylograph's three sub-tabs to top-level panes; layout reflows
over `1fr` columns…

**Deferred**: pragma framework (`-- @bpm 120` declarations applied on
▶ fire) and config persistence to `current.tidal`.
```

This is a session log. A fresh Claude learns what was done on one
afternoon, not what Calypso *is*. If Andrew approves it as-is, the
durable summary is destroyed and replaced by a dated changelog that
ages out of usefulness within days.

#### Good shape (write this)

```
Live-coding webapp for purerl-tidal. The floating-atelier sibling of
Atelier (#158, PureScript Playground): cloned wholesale, then strips
the compile pipeline and swaps the BEAM adapter for a purerl-tidal
WebSocket adapter. Sonic output happens in the rig; the webapp
doesn't see it.

Seven side-by-side panes, each toggled by Cmd-1..Cmd-7… The topbar
BPM widget commits via `bpm <n>` through `/eval`, which routes to
link-spike's `/link/set-tempo` OSC handler.

Near-term: pragma framework and config persistence to `current.tidal`.
```

A fresh Claude reading this knows what the project is, what shape it's
in, and what to expect next. The session-specific stuff — *which* pane
was added today, which bug was fixed — lives in notes, where it
belongs.

### End-of-session update protocol

When a session has done substantive work on a tracked project — built
something, learned something non-obvious, made a decision, hit a
notable wall — refresh that project's `description` so it still
describes the project accurately. **"Refresh" means re-derive the
summary from the new state of the project; it does not mean append a
session report.** If the existing description still describes the
project accurately, leave it alone and write a note instead.

Use the **additive-with-divider** form:

```
[new summary — written to describe the project as it now stands]

---
[previous description, preserved verbatim]
```

Mechanics:

- New summary on top, then a `---` on its own line, then the old text
  unchanged.
- Write via `PUT /api/projects/:id` with the combined `description`.
- The `---` is the signal that this is a **pending update** awaiting
  human approval — it is the contract between Claude and Raker.

### Morning flush (Raker, project 193)

Once a day, Raker surfaces every project whose `description` contains
a `---` divider, presenting the new-vs-old diff for review. Andrew
approves, edits, or rewrites; on approval the below-divider text is
dropped and the field becomes just the new summary. **Andrew is
approving a candidate replacement summary** — your job above the
divider is to make that replacement worth approving on its own merits,
not merely "newer".

The shape of this protocol matches the shape of attention:
end-of-session has the highest **context** but lowest **attention**;
morning has the highest **attention** but decayed context. The divider
is the handoff. Claude proposes, Andrew disposes.

### When to update

- **Do** update when the project genuinely now reads differently — new
  components exist, the shape has changed, a constraint has resolved
  or been added, the near-term direction has shifted.
- **Skip** for trivial sessions: a one-line fix, a lookup-only query,
  re-running an existing command. Write a note instead if anything is
  worth recording at all.
- **Skip** if the existing description still describes the project
  accurately. A correct summary doesn't need to be touched just
  because work happened — write a note for the work.
- **Skip** for projects you only touched tangentially. Update the one
  whose summary is now most stale relative to reality.

### Stacking — handling a description that already has a `---`

If you go to update a description and find it already contains a
divider (a previous unflushed proposal Andrew hasn't reviewed yet), do
**not** stack dividers. Replace the above-divider text with your new
summary; leave the original old text below the divider untouched. Each
refinement during the day is still a complete project summary, not an
addition to a running session log.

```
[your newer summary — still a project summary, not a longer log]

---
[ORIGINAL old text — same as before, NOT yesterday's "new summary"]
```

This keeps the diff Raker shows Andrew always "current proposal vs.
last-approved baseline", regardless of how many times Claude refined
the proposal during the day.

### Mechanism

```
PUT /api/projects/:id
Body: { "description": "[new summary]\n\n---\n[old summary]" }
```

That's it — no schema changes, no new endpoints. The convention lives
entirely in the content of one existing field.

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

1. **Resolve**: find the project(s) by name, slug, or search — Marginalia
   holds project *identity*
   ```
   curl -s http://andrews-mac-mini:3100/api/projects?search=<name> | jq
   ```
2. **Enumerate servers**: from **Bosun** (`:3022`), not Marginalia — server
   rows moved there (seam, 2026-07-21)
   ```
   curl -s http://localhost:3022/api/projects/<id>/servers | jq
   ```
   (Better still: what `bosun serve` actually routes is `:3997/state`; a
   registered service lazy-spawns on its public port on first request.)
3. **Check for collisions**: `curl -s http://localhost:3022/api/ports | jq .collisions`
4. **For each server**, read the `startCommand` and act on it according to
   the table above. Run in the background. Redirect stdout/stderr to a log
   file under `/tmp/marginalia-<slug>-<role>.log`.
5. **Verify**: after a brief pause, check the port is actually listening
   ```
   lsof -i :<port>
   ```
6. **Report** success/failure per server, including the log file path.

## Common workflow: "add a new server registration"

> **Register via Bosun's chair-server (`:3022`), NOT Marginalia (seam,
> 2026-07-21).** Ports/servers/startCommands now live in Bosun's
> `fleet.json`; Marginalia's server table is empty by design. One `POST
> :3022/api/projects/:id/servers` assigns the port/id, writes `fleet.json`,
> and reloads the router. Ask Bosun for the port: `:3022/api/ports/suggest`.
> Full procedure: **Bosun `docs/REGISTER-A-SERVICE.md`**. The steps below
> (inspect → derive command → test → set host) still apply; only the final
> POST target is `:3022`. Do **not** POST to `:3100` — that reintroduces the
> drift the seam removed. (The project must already exist in Marginalia so
> `:3022` can denormalise its name/slug.)

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
4. **Decide the host**: which machine does this run on? `mbp` if it's
   a dev tool that lives on the laptop; `macmini` if always-on
   infrastructure that should be Tailscale-reachable; `cloudflare` for
   static hosting; `andrew-only` for things that exist only when
   physically using the rig (rare). Always set this — SDI's spawn-vs-
   redirect decision keys on it.
5. **If it works**, POST it to **Bosun `:3022`** (writes `fleet.json` +
   reloads the router). The `startCommand` MUST contain the literal port and
   an absolute `cd` anchor, or `bosun serve` typed-rejects it:
   ```
   curl -s -X POST http://localhost:3022/api/projects/<id>/servers \
     -H 'Content-Type: application/json' \
     -d '{"role":"api","port":3050,"url":"http://localhost:3050",
          "startCommand":"cd /abs/path && PORT=3050 node server/run.js",
          "description":"HTTPurple API",
          "host":"mbp",
          "tailscaleName":"andrews-macbook-pro"}'
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
- **Always set `host` on new server entries.** SDI defaults to "ignore
  unknown host" rather than "spawn anyway", so a missing host means SDI
  won't bind the port at all. Pair it with a `tailscaleName` when
  applicable (`andrews-macbook-pro`, `andrews-mac-mini`). See the
  multi-host runbook at `project-tracker/docs/multi-host-topology.md`.

## Why this skill exists

The tracker has ground truth about what runs where. Without this skill,
Claude re-derives that information from `grep`, `ls`, and README-reading
on every session — slow, token-expensive, sometimes wrong. With this skill,
Claude issues `curl` queries and gets deterministic structured answers in
milliseconds. Inference is replaced by lookup wherever possible. Writes
happen via POST so the tracker stays the shared context layer across
sessions and across humans + agents.
