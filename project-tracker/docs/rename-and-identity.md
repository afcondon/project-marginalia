# Project rename, project identity, and the synchronisation problem

## The principle: identity is the slug

Every project in Marginalia has a **slug** — a four-word NATO-callsign identifier
like `november-echo-delta-yankee`. Slugs are generated when the project is
created, never change, and are unique. **The slug is the project's identity.**

Everything else is a label or a pointer:

- `name` is a human-readable label that can be edited freely.
- `source_path` is a pointer to a filesystem location.
- `repo` is a pointer to a git repository name.
- Tags, parent_id, status, description — all metadata, not identity.

This means: **internally, no relation in the database depends on the name**.
Foreign keys reference `id`. The hierarchy uses `parent_id`. Tags use
`tag_id`. Notes belong to `project_id`. So you can rename a project freely
without breaking any database invariants.

## Where divergence happens

A rename in Marginalia is *internally safe* but creates **external drift**
in three places that hold the same human-readable name:

### 1. The infovore-larder-db source data
The original imports came from `catalog.db` (plans) and `repos.db` (cloned
repos) inside the larder. Those databases still hold the old names. We
treat them as **frozen historical records** — we don't re-sync. The drift
is intentional and harmless.

### 2. The on-disk filename or directory name
For a plan-level project, `source_path` typically points at a markdown file
(e.g. `docs/kb/plans/purescript-ecosystem-site.md`). For a software project,
it points at a directory (e.g. `purescript-hylograph-libs/purescript-hylograph-canvas`).

After a rename in Marginalia, the file or directory still has the old name.
The slug-based identity still works, but the human-meaningful pairing
between tracker and disk becomes confusing.

### 3. External references (GitHub, build tools, IDE state)
For software projects only:

- **GitHub remote URL** matches the old directory name
- **Spago/Cargo/package config** in *other* projects may reference this one by
  the old path
- **IDE workspace state** (open tabs, recent files) holds old paths
- **Build artifacts** (`output/`, `target/`, `dist/`) sit under the old path
- **CI/deployment scripts** may pin paths

## The cases

### Case A — plan-level project (markdown file)
Low risk. Cosmetic only.

The source_path points at a markdown file. The file has its own internal
title (`# Heading`), filename, and possibly markdown links from other plans.
None of this is load-bearing — plans are reference material, not executed
artifacts.

**Recommended action**: leave the file alone. The tracker name diverging
from the filename is acceptable. If it bothers you for a specific case, do
it manually with `git mv` and a search-and-replace for inbound markdown links.

### Case B — code project (directory + git repo)
High risk. Cascading.

A rename here needs to update:

1. **The directory** on disk: `git mv old new` (preserves history) or `mv` if
   not in a git repo
2. **The marginalia DB**: `name`, `source_path`, possibly `repo`
3. **The GitHub remote**: `gh repo rename`
4. **The local git remote URL**: `git remote set-url origin <new>` (auto if
   you do the GH rename — GitHub redirects, but it's cleaner to update)
5. **Cross-references in sibling projects**: spago.yaml `path:` references in
   monorepos, package.json deps, dhall imports
6. **Build artifacts**: clear `output/`, `target/`, `.spago/`, etc. (they may
   bake in old paths)
7. **Worklog and KB cross-references**: any markdown plans/worklogs that link
   to the old path

This is enough work that doing it manually is error-prone. Marginalia should
do as much as possible atomically.

## Proposed mechanism

A `marginalia rename <slug> <new-name> [--also-files]` command (or a
detail-panel UI flow that produces the same effect) that handles the entire
chain for code projects.

### Algorithm

1. **Validate**:
   - `slug` resolves to a project
   - `new-name` is non-empty and not used by a sibling at the same level
   - If `--also-files`, the source_path must exist on disk
2. **Detect project type**: directory? markdown file? neither?
3. **For directory projects**:
   - Compute the new directory name (slugify the new name to a filesystem-safe
     form, or accept `--new-path` for an explicit override)
   - Check the directory is in a clean git state (no uncommitted changes)
   - Run `git mv old new` (relative to the repo root)
   - If the project is itself a git repo (not just a subdirectory), and has a
     GitHub remote whose URL matches the old name: prompt to also do
     `gh repo rename`
   - Update the marginalia DB: `name`, `source_path`, possibly `repo`
   - Run `marginalia scan` (see below) to detect any cross-references in
     sibling projects' configs and offer to update them
4. **For markdown-file projects**:
   - Default: don't touch the file. Just rename in DB.
   - With `--also-files`: do `git mv` and warn about possible inbound markdown links.
5. **For projects without source_path**: just rename in DB.

### `marginalia scan` (the drift detector)

A separate command — and arguably the more important one — that walks the
configured workspace roots and reports:

- Marginalia projects whose `source_path` no longer exists on disk
- Directories that look like projects (have `spago.yaml`, `Cargo.toml`,
  `package.json`, etc.) but have no marginalia entry
- Git remotes that don't match the directory name (likely renamed on GitHub
  but not locally, or vice versa)
- spago.yaml `path:` cross-references that point at non-existent siblings

For each issue, offer a **preview** of the fix and require confirmation
before applying.

This is the safety net for any rename or move that happens outside marginalia
(via `mv`, `git mv`, IDE rename, GitHub web UI, etc.).

## Why this matters for the workflow

The user does frequent exploratory programming and projects evolve names as
the user understands them better. So renames are not rare events — they are
part of the normal flow. The current state of the world (rename in tracker,
do filesystem rename manually if you remember, hope nothing breaks) isn't
sustainable at scale.

The right shape: **the tracker is the single command surface for project
identity changes**. You rename in Marginalia, it does the right thing across
disk + git + GitHub.

## Why slugs save us

The slug-as-identity decision pays off here. Even if the rename mechanism
fails partway through (e.g. `gh repo rename` succeeds but the local
`git remote set-url` fails), the slug-based linkage in the marginalia DB
still works. Drift detection can fix the local state later. Nothing
catastrophic happens from a partial rename.

This is also why we should never expose slugs as user-typed identifiers in
contexts where they might get truncated or transcribed. NATO callsigns are
exactly the right shape: voice-friendly, copy-friendly, unambiguous, but
not something you'd ever type by hand.

## Implementation phases

1. **Phase 1** (done): inline rename of project name in the detail panel.
   DB-only, no filesystem effects. Safe for plan-level projects today.
2. **Phase 2**: directory-aware rename for software projects with `source_path`
   pointing at a directory. Handles git mv, updates source_path. No
   GitHub or cross-reference handling yet.
3. **Phase 3**: GitHub integration. `gh repo rename` when applicable, update
   remote URL.
4. **Phase 4**: `marginalia scan` drift detector. Run periodically or before
   any rename to verify state.
5. **Phase 5**: cross-reference updater. Handle spago.yaml path: entries and
   similar.

## Adjacent: the move operation

Renaming and moving share most of their machinery. A move is "rename, but
the new name happens to be in a different parent directory". The same
algorithm above applies, just with a different `new-path`.

The marginalia parent_id hierarchy is **independent** of `source_path` — so
moving a project to a different parent in the tracker hierarchy does not
require any filesystem operation. They are separate concerns and shouldn't
be confused. (You might or might not also want to move the directory; that's
a per-case decision.)
