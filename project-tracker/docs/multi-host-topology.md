# Multi-host topology — schema, consumers, and migration

**Marginalia projects:** #202 (schema + tooling), #203 (Marginalia → MacMini migration; blocked by #202).
**Status:** schema landed 2026-05-07. Consumers (SDI, `/marginalia` skill) and the migration itself are pending.

---

## Why this doc exists

Andrew's services span multiple machines now — primarily MBP (development + several long-running showcases) and the MacMini (always-on infrastructure: Infovore, eventually Marginalia). Documentation, skills, and tooling have been quietly assuming "everything runs on one Mac". That breaks for any service the user actually relies on day-to-day. This doc is the canonical record of how multi-host is modelled and what consumers do with it.

---

## The schema (done)

`project_servers` now has two new columns:

| Column | Type | Values | Meaning |
|---|---|---|---|
| `host` | TEXT (nullable) | `'mbp'` \| `'macmini'` \| `'cloudflare'` \| `'andrew-only'` \| NULL | Logical machine identity. Stable across infrastructure swaps. |
| `tailscale_name` | TEXT (nullable) | e.g. `'andrews-mac-mini'` | Routable address. Can change when Tailscale nodes are renamed or replaced. |

Both fields are exposed in the API as `host` and `tailscaleName`. Indexes added: `idx_servers_host`.

The legacy `environment` column stays for now, repurposed semantically as **deployment style** (`'native'`, `'docker'`, `'cloudflare-pages'`). Old combined values (`'mbp-native'`, `'macmini-docker'`) are still in the DB but should be treated as legacy by new code; the host has been backfilled separately. Plan to deprecate `environment` once consumers are off it.

### Backfill applied 2026-05-07

| environment | host | tailscale_name | count |
|---|---|---|---|
| `mbp-native` | `mbp` | `andrews-macbook-pro` | 28 |
| `macmini-docker` | `macmini` | `andrews-mac-mini` | 1 |
| NULL | `mbp` | `andrews-macbook-pro` | 12 |

Plus Infovore re-registered as host=macmini.

**Andrew:** spot-check a few entries — particularly the "NULL → mbp default" rows. Music gear binaries (`link-discovery` port 20808, `osc` port 57120) might be `andrew-only` rather than `mbp` if they only run when you're physically using the rig.

---

## Consumers — what needs updating

### 1. SDI

**Today**: SDI binds *every* port in the registry on its host, regardless of which machine the service is supposed to run on. That's how we ended up with the failed Infovore-on-MBP spawn earlier this week.

**Target**:
- At boot: read all server entries. For each entry where `host == this-machine AND startCommand IS NOT NULL`, bind the port and spawn-on-demand. For entries where `host != this-machine`, **don't bind**; instead, register a redirect handler that responds with a clear "this service runs on {host}; try {tailscale_name}:{port}" message. Entries with NULL startCommand are passive registry rows (documentation only) — SDI ignores them entirely.
- The "NULL startCommand" rule is what implicitly keeps SDI out of DeepStar's domain. DeepStar (#191) is a separate per-machine launcher for the music rig (cv-router, link-spike, purerl-tidal, Calypso); its services exist in Marginalia for collision avoidance + documentation but with NULL startCommand so SDI doesn't try to spawn them. If we later fill in startCommands for those entries (e.g. for documentation), we add a `managed_by` column to disambiguate. Future work, not blocking.
- Each machine identifies itself via either an env var (`SDI_HOST=mbp`) or a config file. Default deduction from `hostname` is a reasonable fallback.
- Registry refresh: SDI fetches `/api/ports` from the canonical Marginalia at startup and on a periodic refresh. **Cache the response** to a JSON file alongside the SDI install. If Marginalia is unreachable, the cache is the fallback. If both empty, SDI logs and idles.
- Only show actively-relevant collisions: a port "collision" between mbp and macmini isn't a collision — they're different machines.

**Repo**: `agent-teams/sdi/`. Probably touches `registry.mjs` (registry shape) and `router.mjs` (binding logic).

**Plist install/sync**: `agent-teams/sdi/launchd/net.hylograph.sdi.plist` is the source-of-truth. macOS launchd loads from `~/Library/LaunchAgents/`. Edits to the source need to be propagated:

```
cp /path/to/agent-teams/sdi/launchd/net.hylograph.sdi.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/net.hylograph.sdi.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.hylograph.sdi.plist
```

`launchctl kickstart -k` alone is *not* enough — it restarts the process under the same plist; env-var or argument changes need bootout/bootstrap. (Symlinking from `~/Library/LaunchAgents/` to the source has been historically unreliable across macOS versions; copy is the durable approach.)

### 2. `/marginalia` slash command

**Today**: hardcodes `http://localhost:3100`.

**Target**:
- Read API URL from a config (e.g. `~/.claude/marginalia-config.json` or env var `MARGINALIA_API`). Default to `http://localhost:3100` only when no config is present.
- After Marginalia migrates to MacMini (project #203), config on every machine points at `http://andrews-mac-mini:3100`. Local Marginalia LaunchAgents on non-canonical machines get unloaded.
- Skill docs gain a section explaining: "Marginalia is canonical on the MacMini. The skill talks to it over Tailscale. To work offline, run a periodic snapshot: `…`"
- Cache: like SDI, a JSON snapshot of frequently-needed reads (`/api/projects`, `/api/ports`) refreshed every N minutes when reachable. Reads degrade gracefully to cache. Writes require online; queue or fail-loud when not reachable.

**Repo**: skill source lives at `~/work/afc-work/agent-teams/project-tracker/.claude/skills/marginalia.md` (per CLAUDE.md). Update the skill body, plus probably a small Python helper for the cache.

### 3. Per-project documentation

Audit each project's CLAUDE.md and README for hardcoded `localhost:NNNN`. Replace with either:
- The Tailscale URL when the service is meant to be reachable from any machine
- An explicit "this service runs on {host}; access via …" sentence when relevance is conditional

Targets at minimum: top-level `afc-work/CLAUDE.md`, any service repo with a README that says "open localhost:NNNN".

---

## The Marginalia migration (project #203)

In-place replacement of the demo Marginalia on the MacMini with the real one from MBP. Execute *after* the consumers above are done — we want the cache layer in place so the moment of cutover doesn't break MBP-side workflows.

### Pre-flight
- Confirm SDI on MBP knows about all services with their host fields populated.
- Confirm `/marginalia` skill points at MacMini Tailscale URL and the cache works for read paths.
- Confirm MacMini Marginalia demo DB has nothing worth saving (it was seed data for showing the system to someone).

### Cutover
1. Stop MBP Marginalia LaunchAgents.
2. rsync MBP's `tracker.duckdb` → MacMini's expected DB path. Capacity: trivial (DB is a few MB).
3. Stop MacMini's currently-running demo Marginalia LaunchAgents.
4. Replace the DB at the canonical MacMini path.
5. Start MacMini Marginalia LaunchAgents (api, frontend, whisper).
6. Confirm via Tailscale: `curl http://andrews-mac-mini:3100/api/projects | jq '.count'` shows the real count (currently 197, not the demo's tiny number).
7. Confirm `/marginalia` skill from MBP and any phone reaches it.
8. Update server registrations for Marginalia (entries 33, 34, 60, 35) to host=macmini, tailscale=andrews-mac-mini.
9. Unload MBP LaunchAgents permanently.

### Rollback
- Keep MBP DuckDB as `tracker.duckdb.pre-migration-2026-MM-DD.bak` for one week.
- If anything is wrong with MacMini's instance, re-load MBP LaunchAgents and revert skill config.

---

## Validation — how we know multi-host topology is working

- [ ] `curl http://localhost:3998/state` on MBP shows zero spawns for ports owned by macmini.
- [ ] `curl http://localhost:3998/8090` on MBP returns a redirect message naming `andrews-mac-mini:8090`.
- [ ] `/marginalia` skill on MBP successfully reads from `andrews-mac-mini:3100` (post-migration).
- [ ] Marginalia frontend at `http://andrews-mac-mini:3101` shows the real project list from any device on Tailscale.
- [ ] Each registered service has non-NULL `host` and `tailscale_name` (or explicitly-NULL with reasoned exception, e.g. cloudflare).
- [ ] No machine has two Marginalia instances running.

---

## Open questions resolved 2026-05-07

1. **Music-rig binaries.** Settled: they're `host=mbp` like everything else. SDI ignores them naturally because their `startCommand` is NULL — they're managed by DeepStar (#191), a separate per-machine launcher. No new field needed.
2. **Multi-host services.** Settled: distinct entries per machine. SDI itself, when registered, gets one row per machine.
3. **Cache freshness.** Settled: daily refresh by default, with explicit invalidation on writes (any POST/PUT/DELETE through the API pushes a "registry changed" signal). Hourly fallback if daily feels too stale during active multi-host work.
