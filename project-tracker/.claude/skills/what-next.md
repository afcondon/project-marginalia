---
name: what-next
description: When the user asks "what should I work on?" or "what next?", query the marginalia project tracker API along several heuristic axes to generate a short curated list of candidates. Handles both programming and life-project domains (house, garden, woodworking, music). Expect noisy results until data hygiene improves; use dismissals as prompts to fix metadata.
---

# what-next — suggest something to work on from marginalia

This skill turns marginalia's project data into a short list of **things the
user might pick up next**. It's the start of a "coach" layer on top of the
registry: not commanding, not prioritizing, just surfacing candidates the
user can glance at and act on.

It assumes you've read the **marginalia** skill for the API query mechanics
(endpoints, base URL, interpretation of start_command, etc.). This skill
builds on that.

## When to invoke

Any of these user prompts should trigger this skill:
- "What should I work on?"
- "What next?"
- "Give me something to do"
- "What's in the inbox I haven't processed?"
- "What life projects have I been neglecting?"
- "Any quick wins?"
- "What should I blog about?"

If the user narrows the scope ("something quick", "code only", "nothing in
the garden today"), honour that in the heuristics below.

## The heuristic axes

For each axis, query marginalia, apply the filter, and collect candidates.
Then assemble a short, mixed list (see output format). **Don't dump
everything** — three to eight suggestions total across all categories is
the sweet spot.

### Axis 1 — Stale actives

Projects marked `active` but not updated in 30+ days. These are the most
likely data-hygiene targets: the status is probably stale and doesn't
reflect reality.

```
curl -s 'http://localhost:3100/api/projects?status=active' | jq '
  .projects | map(select(.updatedAt != null))
  | map(select((now - (.updatedAt | fromdate)) > (30 * 86400)))
  | sort_by(.updatedAt) | .[0:5]'
```

Action for each: **"Is this still active? Mark done / blocked / defunct if not."**

### Axis 2 — Claude Inbox unprocessed

The Claude Inbox (project id 123, slug `delta-charlie-echo-tango`) collects
freeform dictated thoughts. If the user has been dictating, there may be
notes waiting to be processed into per-project edits.

```
curl -s http://localhost:3100/api/projects/123 | jq '.notes | length'
curl -s http://localhost:3100/api/projects/123 | jq '.notes[0:5]'
```

Action: **"Process the inbox — read each note, identify the projects it
refers to, apply the implied changes, delete (or archive) the note."**

### Axis 3 — Todos embedded in project notes

Project notes often contain task-shaped text that never made it into a
formal tracking system. Look across recent notes for lines matching
patterns like `TODO`, `should`, `need to`, `- [ ]`, "remember to", etc.

```
# Fetch all projects with recent updates, pull notes from each
curl -s 'http://localhost:3100/api/projects' | jq -r '.projects[].id' | while read id; do
  curl -s "http://localhost:3100/api/projects/$id" | jq -r \
    '"\(.name): " + (.notes // [] | map(.content) | join(" | "))'
done | grep -iE 'TODO|should|need to|- \[ \]|remember' | head -20
```

Action for each: **"Do this specific thing from project X's notes."**

### Axis 4 — Projects missing descriptions

Any project with `description IS NULL` or a very short description.
These are usually imports that never got cleaned up.

```
curl -s 'http://localhost:3100/api/projects' | jq '
  .projects | map(select(.description == null or (.description | length) < 30))
  | .[0:5]'
```

Action: **"Add a real description in one sentence."** Cheap, high value.

### Axis 5 — Life projects drifting

Non-programming domains (house, garden, woodworking, music) with
`status=idea` or `status=someday`, not updated in 60+ days.

```
for domain in house garden woodworking music; do
  curl -s "http://localhost:3100/api/projects?domain=$domain&status=someday" \
    | jq ".projects[0:3] | .[] | \"$domain: \(.name) (updated: \(.updatedAt // \"never\"))\""
done
```

Action for each: **"Schedule this concretely, or accept it's never
happening and mark defunct."** Life projects fail differently from
software projects — usually it's not "too complex", it's "never prioritized".

### Axis 6 — Blog candidates

Projects that could become a blog post but haven't been. The tracker
currently has no direct "blogged" flag, so use a heuristic: any project
with `status=done` or `status=defunct` that isn't tagged `blogged` is a
candidate. Short posts about defunct projects are fine — often better.

```
curl -s 'http://localhost:3100/api/projects?status=done' | jq '.projects[0:5]'
curl -s 'http://localhost:3100/api/projects?status=defunct' | jq '.projects[0:5]'
```

Action: **"Write a blog post about this on blog.hylograph.net (#142).
Even 200 words is enough."** See the blog.hylograph.net project's
description for the underlying discipline (every project eventually
becomes a post).

### Axis 7 — Missing thumbnails

Projects in visually-oriented domains (house, woodworking, garden,
programming apps) that don't have any image attachments. Adding a
photo or screenshot makes the project legible at a glance.

```
# Get all projects, check attachment count (in the detail endpoint)
# Filter to those without image attachments in visual domains
```

Action: **"Take a photo / screenshot and attach it."** Especially
valuable for house and woodworking projects where visual state matters.

### Axis 8 — Running but unused

Check `/api/ports` for anything running. For each service, is there
recent activity on the owning project? If a service is running but the
project hasn't been touched in weeks, either use it or turn it off.

```
curl -s http://localhost:3100/api/ports | jq '.servers[] | {projectName, role, port}'
```

Action: **"Revisit project X or stop its launchd agent."**

## Output format

After collecting candidates across axes, produce a short mixed list.
Don't present it as a category dump — mix them up so the user sees
variety. Format:

```
Here are some candidates from marginalia:

1. **[alpha-bravo-charlie-delta]** — <project name>
   <why this was suggested: which axis, specific reason>
   Action: <one concrete sentence>

2. **[...]**
   ...
```

Keep it to 3–8 items. Bias toward concrete, quick, achievable tasks
unless the user explicitly asks for big projects ("something meaty",
"a weekend project").

After the list, offer:

> Tell me which one to pick up, or which ones to dismiss so I can
> improve the data.

## The dismissal loop — this is where the skill gets better

When the user dismisses a suggestion ("no, that's defunct", "no, that's
never happening", "I already did that"), **act on the data**:

- Status updates: use `PUT /api/projects/:id` or `POST /api/projects/:id/rename`
  for name changes, or `POST /api/agent/projects/:id/status` for status
- Tags: `POST /api/projects/:id/tags` to add flags like `not-doing`,
  `abandoned`, `done-offline`
- Notes: `POST /api/agent/projects/:id/notes` to record the dismissal
  reason ("dismissed as defunct on YYYY-MM-DD because X")

Every dismissal should leave a trace. That way the next query is more
accurate, and we have an audit trail of decisions.

## Honest limitations

Say these out loud to the user when appropriate:

- **The data is noisy**. Many projects have stale status. Many life
  projects are in "someday" that will never happen. This skill is only
  as good as the underlying metadata.
- **Heuristics are simple**. "Not updated in 30 days" isn't the same
  as "stale" — some long-running projects move slowly on purpose.
- **No prioritization**. The skill suggests candidates; the user picks.
  Don't imply "you should do #1".
- **Works better over time**. The dismissal loop improves the data,
  which improves the suggestions. Expect noise at first.

## Example session

User: "What should I work on?"

Claude (runs queries, applies heuristics, composes response):

> Here are some candidates from marginalia (as of YYYY-MM-DD):
>
> 1. **[oscar-uniform-sierra-bravo]** — Claude Code PureScript skills
>    Status: done. Has a clear evolution narrative — started as a
>    planned website, became a set of Claude Code skills instead.
>    No blog post yet.
>    Action: Write a post on blog.hylograph.net. 200 words is plenty.
>
> 2. **[delta-charlie-echo-tango]** — Claude Inbox
>    1 unprocessed dictated note from an earlier session.
>    Action: Process it — identify the projects it refers to, apply
>    the implied changes, delete the note.
>
> 3. **[kilo-uniform-zulu-echo]** — Kernel Separation Phase 2
>    86 days stale in `active` status. Either it's still active and
>    needs a progress note, or it moved on.
>    Action: Decide — mark blocked/done/defunct as appropriate.
>
> 4. **[<various>]** — Several woodworking "someday" projects stale
>    for 2+ years ("House idea", "Furniture clippings", etc.)
>    These are clippings, not plans. Probably `defunct` or at
>    least tagged as reference-only.
>    Action: Batch-mark the obviously-clippings as defunct.
>
> 5. **27 projects missing descriptions** is a data-hygiene target.
>    Most are external GitHub clones in `GitHub/`.
>    Action: Either add a description or tag them all with
>    `external-reference` to make them filter-away-able.
>
> Tell me which one to pick up, or which ones to dismiss so I can
> improve the data.

The above is a real first-run output against a real database.
Note the mix: a blog candidate, an inbox processing task, a stale-
active review, a life-project batch cleanup, and a meta data-hygiene
task. Good variety, concrete actions, slugs embedded so the user
can answer "do #2".
