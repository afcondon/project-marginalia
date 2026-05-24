# DeepStar v2 — Specification

**Status:** Phase 0 — draft for Phase 1 (test suite) consumption.
**Audience:** the agent (Claude or otherwise) who writes the v2
test suite and Go implementation. Self-contained — readers do not
need to consult v1 source or prior session memory.
**Owner:** Andrew Condon. Tracked as Marginalia project 191
("DeepStar" — `charlie-india-charlie-november`).

---

## 1. Why v2

DeepStar v1 is a stdlib-only Python script (~580 LOC + ~160 LOC of
service registry) that has done its job — running the live-coding
rig — well enough for several months. But across two recent sessions
(2026-05-18 and 2026-05-23) it has produced the same class of failure
twice:

- **2026-05-18.** `deepstar down --tier 4` was a hair's breadth from
  SIGTERMing `loginwindow`. The stored PID 417 belonged to an
  fh2-daemon process that had long since exited; macOS recycled the
  PID to loginwindow. The PID-identity check (added that day) caught
  it via the `lstart` cross-check; without it, SIP's `EPERM` would
  have been the only thing between DeepStar and the wrong process.
- **2026-05-23.** DeepStar reported `⊕ fh2-daemon adopted (pid 417,
  was running already)`. PID 417 is loginwindow again. The real
  fh2-daemon was a multi-day-old zombie holding `~/.fh2/control.sock`
  with pre-C.1 wire-format code; DeepStar didn't know. Same day:
  two purerl-tidal BEAMs running simultaneously (PIDs 68075 and
  91937) — the browser talked to yesterday's BEAM while DeepStar
  reported the new one healthy. And: `up` claimed `↻ already running`
  for six services that `ps` showed *none* of (stale state file, no
  identity verification).

These are not bugs to patch. They are categories of failure that the
v1 design admits — PID-only identity, hardcoded global timeouts,
eager tier-abort, no zombie detection, no source-vs-process
staleness check. They cost Andrew ~4 hours of music-feature work on
2026-05-23 alone, on top of recurring smaller incidents.

v2 replaces v1 with a Go binary that enforces process identity via
types and tests, owns the full child-process tree via process
groups, and offers an explicit `verify` subcommand for "is what I
think is running actually running, and is it running the code I
think it is?"

Go is the pick because: stdlib `os/exec`/`syscall`/`os/signal`
support process groups and signal handling natively; single-binary
distribution removes the Python-runtime variable; the type system is
strong enough for the identity-tuple invariants we need; and adding
a Go dependency to the otherwise PureScript/Erlang/Python/Rust rig
is no longer a cognitive tax (per Andrew, 2026-05-23: "in the age
of agents it also matters less to have so many technologies in one
system").

---

## 2. v1 baseline (the thing we're replacing)

The v2 binary preserves the v1 CLI shape so muscle memory carries
over, and the v1 behaviours below are the regression baseline. v2
extends them in specific places (§3, §4, §8); everything else is
preserved.

### 2.1 CLI surface

Six subcommands, all accepting `--tier N` (default `1`):

| Subcommand     | Meaning |
|----------------|---------|
| `up`           | Start all tier-≤N services in dependency order. |
| `down`         | Stop all tier-≤N services in reverse dependency order. |
| `status`       | Tabular state: name, tier, PID, port, state symbol. |
| `restart <s>`  | Cycle one service plus all transitive dependents. |
| `logs [<s>]`   | `tail -F` one service log, or multiplex all with `[name]` prefix. |
| `list`         | Print the registry. |

Exit codes (v1): `0` success, `1` startup failure, `2` unknown
service. State symbols (v1 `status`): `✓ up`, `⚠ proc-no-port`,
`? port-no-pid`, `·` stopped.

### 2.2 Service inventory

| Name              | Tier | Cmd                                                            | Port / kind       | Deps                       |
|-------------------|------|----------------------------------------------------------------|-------------------|----------------------------|
| `cv-router`       | 1    | `./target/release/cv-router`                                   | `57120/udp`       | —                          |
| `link-spike`      | 1    | `./target/release/link-spike`                                  | `57122/udp`       | —                          |
| `purerl-tidal`    | 1    | `erl -pa ebin -noshell -eval 'F = main@ps:main(), F()'`        | `3012/tcp`        | cv-router, link-spike      |
| `calypso-server`  | 1    | `node server/run.js` (`BACKEND_PORT=3060`)                     | `3060/tcp`        | purerl-tidal               |
| `calypso-frontend`| 1    | `npx http-server frontend/public -p 3061 -c-1 --cors`          | `3061/tcp`        | calypso-server             |
| `fh2-daemon`      | 4    | `spago run -- --daemon`                                        | `~/.fh2/control.sock` (unix) | —              |

`purerl-tidal` carries `ERL_LIBS=_build/default/lib` in its
environment overlay. All others inherit only the parent environment
plus their declared overrides. Each entry's `cwd` is its repo root
on disk.

### 2.3 Process tracking model and the v1 bug

v1 stores per-service state at `/tmp/deepstar/<name>.pid` as a
two-line format introduced 2026-05-18:

```
<pid>
<lstart>           # absolute process start time from `ps -o lstart=`
```

The identity check (`deepstar.py:104-139`) is:

```python
def pid_identity_matches(name, pid):
    recorded = read_recorded_lstart(name)
    current  = current_lstart(pid)
    if recorded is not None:
        return current is not None and recorded == current   # case 1/2
    # Case 3: legacy pidfile — no lstart recorded → loose cmdline match
    if current is None:
        return False
    try:
        r = subprocess.run(
            ["ps", "-o", "command=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2)
        ...
        cmd_basename = Path(svc["cmd"][0]).name
        return cmd_basename in cmd or name in cmd            # case 3
    ...
```

The bug is case 3. When a pidfile lacks `lstart` (a leftover from
pre-2026-05-18, a corrupted write, an externally-written file, or
an externally-adopted process), the function falls back to
substring matching on the recycled PID's command line. PID 417 →
loginwindow → cmdline contains `"loginwindow"`; this passes if the
service name is even loosely a substring of any system command name.

**v2 eliminates case 3.** Identity is verified via a triple
`(pgid, lstart, command-fingerprint)`. If any element is missing
or doesn't match, the process is treated as "not ours" — never
"probably ours". See §3 property 1 and §10 regression test 1.

### 2.4 Spawn mechanics (v1, `deepstar.py:282-290`)

```python
proc = subprocess.Popen(
    svc["cmd"],
    cwd=str(svc["cwd"]),
    env=env,                         # os.environ + service.env overlay
    stdout=logf,                     # append to /tmp/deepstar/<name>.log
    stderr=subprocess.STDOUT,        # merged with stdout
    start_new_session=True,          # detached process group
)
```

`start_new_session=True` already creates a new session/process group.
v2 preserves this and additionally tracks the group leader's PID as
the canonical identity (v1 tracks it but doesn't enforce identity
against the group).

After spawn, v1 polls the service's port for up to 5 seconds at
0.2s intervals. If the child exits early → failure. If the port
doesn't bind in 5s → warning + return `False`. **5 seconds is too
short for `spago run`-wrapped daemons** (10–30s real boot tax); v2
makes this per-service. See §3 property 4.

### 2.5 Down mechanics (v1, `deepstar.py:316-378`)

1. Read PID. If absent and `--force` not set → return.
2. Check PID alive with `os.kill(pid, 0)`.
3. `pid_identity_matches` — if stale, clear pidfile, return without
   signalling.
4. Signal strategy: `os.killpg(pid, sig)`, falling back to
   `os.kill(pid, sig)` if `ProcessLookupError`.
5. SIGTERM + 2s wait polling `pid_alive` at 0.1s; if still alive,
   SIGKILL and 0.2s sleep.
6. Clear pidfile.

v2 preserves the SIGTERM→wait→SIGKILL sequence and the
group-then-pid signal fallback. v2 additionally verifies the
process is gone (not merely "PID is unreachable") before reporting
`stopped` — see §3 property 2.

### 2.6 Restart mechanics (v1, `deepstar.py:460-475`)

1. Stop transitive dependents in reverse dep order.
2. Stop target.
3. Start target.
4. Start dependents in forward dep order.
5. Fail fast if any startup fails.

v2 preserves this orchestration. The per-service `on_failure`
policy (§3 property 5) only affects step 5 — `tier_abort` keeps
v1's fail-fast; `warn` continues; `retry` retries with backoff.

### 2.7 Logging (v1)

- Path: `/tmp/deepstar/<name>.log`, append mode.
- No rotation.
- `deepstar logs [<name>]` shells out to `tail -F`. Multiplexed
  view (no name argument) spins one tail thread per service with a
  thread-safe `[name]` line prefix.

v2 preserves the path, the append mode, the `tail -F` semantic.
Multiplexed `logs` uses a goroutine per service rather than a
thread per service.

### 2.8 Config (v1)

Hardcoded Python dict in `deepstar/services.py`. Adding a service
requires editing Python source. v2 reads its registry from TOML —
see §6.

---

## 3. Correctness properties

Six properties, each a falsifiable claim. Each property has a
corresponding test in §10.

### 3.1 Process identity is a triple, never just a PID

> The v2 binary refuses to treat a process as a managed service
> unless `(pgid, lstart, command_fingerprint)` of the running
> process equals the stored triple, with **no fallback path** that
> accepts a partial match.

- `pgid` is the process group leader's PID, set at spawn via
  `syscall.SysProcAttr{Setpgid: true}`.
- `lstart` is `ps -o lstart= -p <pgid>` exactly as captured at
  spawn time, byte-equal comparison.
- `command_fingerprint` is the SHA-256 of `argv[0] + "\x00" +
  argv[1] + "\x00" + ...` for the spawn arguments, compared
  against the live process's `/proc`-equivalent (`ps -o command=`
  on macOS, byte-equal after argv-joining the same way).

If any of the three doesn't match, the process is "not ours" and:
- `up` treats the service as not running and respawns.
- `down` does not signal it.
- `verify` reports `identity_mismatch` with the recorded vs live
  triple.

This property kills the loginwindow class. See test §10.1.

### 3.2 `down` must actually terminate

> After `down` returns success for a service, no process with the
> stored identity triple exists on the system, **and no process
> belonging to the stored pgid exists either** (group dead).

Sequence:

1. Read identity triple. If state says "stopped" and identity
   isn't satisfied by any live process, return success (nothing
   to do).
2. Send SIGTERM to `-pgid` (the negative-pgid kill-group form).
3. Poll for up to `health_timeout_ms` (default 5s) at 100ms
   intervals: identity triple unsatisfied AND `pgrep -g <pgid>`
   returns no rows.
4. If still alive after timeout: SIGKILL to `-pgid`.
5. Poll again for 500ms.
6. If still alive: return error `down_failed_to_terminate{pgid,
   surviving_pids}`. **Never** clear state.json optimistically.

Reporting "stopped" while a process is alive is a v1 defect (the
two-BEAM case on 2026-05-23). v2 ties the success of `down` to
observable post-state, not signal-sent.

See test §10.2.

### 3.3 `up` is idempotent

> Calling `up` twice in a row is observably the same as calling
> `up` once, modulo logging.

Per service, in dependency order:
- **Identity-satisfied:** the running process matches the stored
  triple → no-op, emit `↻ <name> already running (pgid=N)`.
- **Identity-unsatisfied with state.json record:** zombie, recycled,
  or replaced. SPEC §3.1 forbids signalling a process whose identity
  doesn't match — the v2-motivating bug-class is exactly the PID-
  recycled-to-loginwindow scenario. Clear the stale state record
  **without** signalling the recorded pgid, then fall through to the
  foreign-occupant check.
- **No state.json record AND port-bound by foreign process:**
  refuse to start. Emit `✗ <name> port <port> bound by foreign
  pid <pid> (cmd: <cmd>)`. Exit nonzero. (Adoption-by-port from v1
  is dropped: v2 never adopts processes it didn't spawn.) Reached
  both via no-record and via cleared-stale-record paths.
- **Otherwise:** spawn fresh.

See test §10.3.

### 3.4 Per-service health timeout

> Each service's `health_timeout_ms` is the budget for the
> port-bind/socket-bind check after spawn. The global default is
> 5000ms; services with embedded build steps (e.g. `spago run`)
> override it.

After `Popen`-equivalent, poll the port at 100ms intervals up to
the per-service `health_timeout_ms`. Behaviour at timeout depends
on `on_failure` (property 3.5).

See test §10.4.

### 3.5 Per-service failure policy

> Each service declares `on_failure` ∈ {`tier_abort`, `warn`,
> `retry`}. The tier-up loop honours this on a per-service basis.
> The default is `warn`.

- `tier_abort`: failure stops the tier-up loop; remaining services
  not started. (v1 behaviour for everyone.)
- `warn`: failure logged; tier-up continues. State.json marks the
  service `failed_to_start{reason}`.
- `retry`: up to 3 attempts with exponential backoff (1s, 2s, 4s)
  before falling through to `warn` semantics.

See test §10.5.

### 3.6 `verify` is the rig-health subcommand

> `deepstar verify --tier N` walks every registered service and
> reports, for each, all of:
> - Identity match: running process triple vs state.json triple.
> - Source staleness: each `source_path` glob's newest mtime
>   compared against the live process's start time. Process
>   predates source → stale.
> - Sibling search: any process anywhere on the system whose
>   command line matches the service's command-fingerprint prefix
>   but whose pgid differs from state.json's → reported as
>   `unknown_sibling`.
> - Socket file: for unix-socket services, `lsof` confirms a
>   listener bound to the socket file; a file present without a
>   listener is `stale_socket`.

Output is structured (table by default; `--json` flag for
machine-readable). Exit code: `0` if all clean, `1` if any
divergence found. Used in two modes:
- Ad-hoc by Andrew when the rig acts weird.
- Implicit pass at the start of every `up`/`status`/`down` so the
  same checks gate the actions (per note 241: conservative
  full-check, no thresholds).

See tests §10.6, §10.7.

---

## 4. Triage decisions locked

From Marginalia project 191 note 241 (2026-05-23), reproduced here
so the spec is self-contained.

### 4.1 Process-group spawning: YES

Spawn every service as a fresh process group leader (`setpgid` at
spawn). All signals (SIGTERM, SIGKILL) target the **group**, not
the leader PID directly. Killing the group cleans up the entire
descendant tree — including `spago` wrappers around the real
daemon, npm-shell-wrapper around `http-server`, etc.

Stored identity anchors on the group-leader PID (`pgid`), not on
any direct child PID further down the tree. The v1 spago-wrapper /
daemon-grandchild confusion (failure mode A6 in note 240) becomes
impossible.

Added cost: ~50 lines of Go (`SysProcAttr.Setpgid: true`,
`syscall.Kill(-pgid, sig)`, group existence checks via
`syscall.Kill(-pgid, 0)`). Trivial vs the recurring cost.

### 4.2 Staleness threshold: CONSERVATIVE (no thresholds at all)

Per Andrew: in dev you save more time by being certain than you
spend on the extra few seconds of checks. v2 does **the full check
unconditionally** every time:

- `up`: pre-flight verify all services before any spawn decisions.
- `verify`: walks the registry, full check.
- `status`: full check (v1's status is informational; v2's is
  authoritative).
- `down`: post-action verify.

No `--quick`, no `--cached`, no time-based thresholds.

The full check is approximately: 6 services × (ps lookup ~10ms +
mtime stat ~1ms + sibling pgrep ~20ms + socket check ~5ms) ≈
200ms. Acceptable.

### 4.3 Calypso buffer overwrite: out of scope

Filed as Marginalia project 192 note 242 — architectural fix in
Calypso. DeepStar v2 doesn't touch the editor.

---

## 5. Failure mode catalogue → coverage matrix

Every A-category failure from project 191 note 240 maps to a
property in §3 and a test in §10. Every B-category failure maps to
a `verify` check in §3.6 and a test in §10. C-category failures
are referenced to their owning project.

| ID | Failure | Property | Test |
|----|---------|----------|------|
| A1 | PID-only identity (loginwindow PID-417 recurrence) | 3.1 | §10.1 |
| A2 | Zombie tolerance on `down` (two BEAMs case) | 3.2 | §10.2 |
| A3 | "Already running" claim without verification | 3.1, 3.3 | §10.1, §10.3 |
| A4 | Hardcoded 5s timeout too short for spago-run | 3.4 | §10.4 |
| A5 | Tier-abort on first failure too eager | 3.5 | §10.5 |
| A6 | Process-tree confusion (spago wrapper hides daemon) | 3.1 (pgid) | §10.2 (group kill verifies) |
| A7 | Stale socket file persists across daemon death | 3.6 (`stale_socket`) | §10.7 |

| ID | Failure | `verify` check |
|----|---------|----------------|
| B1 | "What code is actually running?" — no way to ask | identity + source staleness |
| B2 | Stale BEAM modules in long-running purerl-tidal | source staleness on `ebin/*.beam` |
| B3 | Stale daemon binary running pre-rebuild code | source staleness on `output/*.js` |
| B4 | Compile-success / hot-load divergence | source staleness flags incoherence |
| B5 | Two BEAMs same code path (sibling) | sibling search |

| ID | Failure | Owner |
|----|---------|-------|
| C1 | Calypso browser-buffer-overwrites-disk | Marginalia 192 note 242 |
| C2 | `make erl` not run after `spago build` | purerl-tidal `feedback_purerl_tidal_make_not_spago` |
| C3 | PureScript module compatibility under hot-load | Calypso compile-error surfacing |

---

## 6. Config schema (TOML)

### 6.1 File location

`~/.deepstar/services.toml`. Created on first `deepstar init` or by
hand. Overridable with `DEEPSTAR_CONFIG=/path/to/services.toml` env
var (for tests).

### 6.2 Schema

```toml
# Top-level array-of-tables. One [[service]] per managed service.

[[service]]
name              = "purerl-tidal"             # required; unique key
tier              = 1                          # required; integer ≥ 1
cwd               = "/abs/path/to/repo"        # required; absolute path
cmd               = ["erl", "-pa", "ebin",     # required; argv as list of strings
                     "-noshell", "-eval",
                     "F = main@ps:main(), F()"]
port              = 3012                       # required for tcp/udp; absent for unix-socket
socket_path       = ""                         # required for unix; absent otherwise
port_kind         = "tcp"                      # required; one of "tcp" | "udp" | "unix"
health_timeout_ms = 5000                       # optional; default 5000
on_failure        = "warn"                     # optional; one of
                                               #   "tier_abort" | "warn" | "retry"
                                               # default: "warn"
deps              = ["cv-router", "link-spike"]# optional; default []
source_paths      = ["ebin/*.beam",            # optional; default []
                     "output-erl/*.erl"]       # relative to cwd; globbed for mtime
description       = "free-form description"    # optional

[service.env]
ERL_LIBS = "_build/default/lib"                # zero-or-more env overlays
```

### 6.3 Validation rules

The Go binary refuses to start (`deepstar list` exit code 2, all
other subcommands exit code 3) if any of:

- duplicate `name` across services
- `port_kind = "tcp"` or `"udp"` without `port`
- `port_kind = "unix"` without `socket_path`
- `port` and `socket_path` both set
- `cwd` not absolute or not a directory
- `cmd` empty
- `deps` references a name not present in the registry
- `deps` forms a cycle (DFS detection)
- `on_failure` not in the allowed set
- `tier` < 1
- `health_timeout_ms` < 0

Error messages include the line number of the offending entry where
possible (TOML parsers can usually report this).

### 6.4 Initial population

The v1 service inventory (§2.2) translates field-for-field. The
`source_paths` field is new; recommended values:

| Service          | `source_paths`                                              |
|------------------|-------------------------------------------------------------|
| `cv-router`      | `["target/release/cv-router"]`                              |
| `link-spike`     | `["target/release/link-spike"]`                             |
| `purerl-tidal`   | `["ebin/*.beam", "output-erl/*.erl"]`                       |
| `calypso-server` | `["server/run.js", "server/output/**/*.js"]`                |
| `calypso-frontend`| `["frontend/public/*.js"]`                                 |
| `fh2-daemon`     | `["output/Main/index.js", "output/**/*.js"]`                |

`source_paths` is glob-expanded against `cwd`; the newest mtime
across all matched files is compared to the process's start time
during the staleness check.

### 6.5 Per-service overrides for known-slow daemons

`fh2-daemon` runs as `spago run -- --daemon`, which executes a
build check first (10–30s in cold cache). Its registry entry
overrides `health_timeout_ms = 30000`. v1's 5s blanket timeout was
the source of failure mode A4.

---

## 7. State persistence

### 7.1 File location

`~/.deepstar/state.json`. Single file, JSON, keyed by service name.
Survives `/tmp` wipes (v1 used `/tmp/deepstar/<name>.pid`, lost on
reboot — silently masked stale state).

### 7.2 Schema

```json
{
  "services": {
    "purerl-tidal": {
      "pgid": 91937,
      "lstart": "Fri May 23 14:02:11 2026",
      "command_fingerprint": "sha256:abc123...",
      "spawned_at": "2026-05-23T14:02:11.234Z",
      "spawn_argv": ["erl", "-pa", "ebin", "..."],
      "spawn_cwd": "/Users/afc/.../purerl-tidal",
      "spawn_env_overlay": {"ERL_LIBS": "_build/default/lib"}
    },
    "cv-router": { ... },
    ...
  },
  "version": 1
}
```

### 7.3 Atomicity

State is written via temp-file + rename (`os.Rename`, atomic on
the same filesystem). A crash mid-spawn leaves a stale entry that
the next `up` reconciles via the identity check (3.1).

### 7.4 Crash recovery

If the binary dies between fork and state-write:

- Next `up`: identity check sees no matching pgid (state has no
  record for the new spawn); the spawned process is orphaned.
  Property 3.3 says: port-bound by foreign process → refuse to
  start, emit clear error naming the foreign pid. Andrew kills it
  by hand and re-runs.

This is loud-fail, not auto-recovery. Note 239: "fail-loudly is
better than hidden restart loops".

### 7.5 Versioning

`"version": 1` enables future migrations. On schema mismatch, v2
exits with `state_schema_unknown{found_version, expected_version}`
rather than guessing.

---

## 8. CLI surface (v2)

All subcommands share `--tier N` (default `1`), `--json` (machine
output), `--config <path>` (override config location), `--state
<path>` (override state location).

### 8.1 `up`

```
deepstar [--tier N] up [--dry-run]
```

For each service in tier ≤ N, in dependency order:
1. Run full verify (§3.6).
2. If identity satisfied → no-op, log.
3. If state.json record exists but identity unsatisfied → log
   "zombie or recycled", SIGKILL stored pgid best-effort, respawn.
4. If no record AND port bound by foreign process → exit nonzero
   per §3.3.
5. Otherwise: spawn (process group leader), wait for port bind up
   to `health_timeout_ms`, record state.json triple on success.
6. On failure: apply `on_failure` policy (§3.5).

`--dry-run`: print decisions without spawning.

Exit codes: `0` all services up, `1` any service failed under a
`tier_abort` policy or under unrecoverable error, `2` config
error, `3` state schema mismatch.

### 8.2 `down`

```
deepstar [--tier N] down [--force]
```

For each service in tier ≤ N, in **reverse** dependency order:
1. SIGTERM to `-pgid`. Poll up to `health_timeout_ms` for
   group-gone.
2. SIGKILL to `-pgid` if still alive. Poll 500ms.
3. If still alive → exit nonzero, do NOT clear state.json.
4. On success: clear state.json entry.

`--force` (v1 compatibility): if no state.json record, attempt to
`lsof` the configured port, SIGKILL whatever is bound. v2-specific
warning: `--force` bypasses identity, name the killed PID + cmd.

Exit codes: `0` all stopped, `1` any service failed to terminate.

### 8.3 `status`

```
deepstar [--tier N] status [--json]
```

Tabular output by default:

```
NAME              TIER  PGID    PORT       STATE           SOURCE
cv-router         1     54321   57120/udp  ✓ up            (fresh)
link-spike        1     54322   57122/udp  ✓ up            (fresh)
purerl-tidal      1     -       3012/tcp   · stopped       —
calypso-server    1     -       3060/tcp   ? port-no-pgid  pid 99888 unmanaged
fh2-daemon        4     54324   ~/.fh2/control.sock  ⚠ stale-source  process predates ebin/*.beam by 4h
```

State symbols:
- `✓ up` — identity matches, source fresh.
- `· stopped` — no state.json record, port unbound.
- `⚠ stale-source` — identity matches but process predates a
  `source_paths` mtime.
- `⚠ identity-mismatch` — state.json has a triple but live
  process doesn't match.
- `? port-no-pgid` — port bound by a process not in state.json.
- `! down-failed` — state.json shows last `down` failed mid-way.

`--json`: structured for tooling.

### 8.4 `verify`

```
deepstar [--tier N] verify [--json]
```

Walks every tier-≤N service and emits all findings per §3.6 (identity,
source staleness, sibling search, socket file).

Default output: one block per service with its findings. `--json`:
machine-readable.

Exit code: `0` if all checks clean across all services, `1` if any
finding is non-clean.

### 8.5 `restart`

```
deepstar [--tier N] restart <service>
```

1. Compute transitive dependents.
2. `down` dependents in reverse dep order.
3. `down` target.
4. `up` target.
5. `up` dependents in forward dep order.

Fails fast: any sub-step returning nonzero halts the chain.

### 8.6 `logs`

```
deepstar logs [<service>]
```

- Single service: `tail -F /tmp/deepstar/<service>.log` from line
  -50.
- No argument: multiplex all services; one goroutine per log file;
  each line prefixed `[<service>] ` to a thread-safe stdout writer.
  From line -10 per file.

(v1 used `/tmp/deepstar/<name>.log`; v2 preserves the path to keep
log-tailing terminals workable across the cutover.)

### 8.7 `list`

```
deepstar list
```

Print every registry entry: name, tier, port/kind, deps,
description, cwd, cmd, env overlay. Human-readable.

### 8.8 `init`

```
deepstar init [--from-python <path>]
```

Write a starter `~/.deepstar/services.toml`. With `--from-python
<path>` (pointing at v1's `services.py`), parse the v1 dict and
emit equivalent TOML. Used once during cutover.

---

## 9. Marginalia coupling: none at runtime

The v2 binary reads only `~/.deepstar/services.toml` and writes
only `~/.deepstar/state.json`. It makes no HTTP calls to
Marginalia (port 3100).

Rationale: DeepStar runs at rig cold-start, before Marginalia is
necessarily up; depends on neither Wi-Fi nor Tailscale; must work
identically on MacMini and MacBook Pro.

A future bridge tool (`deepstar sync-from-marginalia`) could
rewrite the TOML from `/api/ports`, but it is **out of scope for
v2**. The TOML schema is kept compatible enough — names, ports,
start commands — that such a sync is mechanical when wanted.

---

## 10. Test surface

Phase 1 implements these against v1 first (to establish a regression
baseline; many will fail). Phase 2 implements them against v2 (to
pass). The fixtures are direct process-spawn — no music rig needed.

### 10.1 Identity rejection (the loginwindow case)

**Fixture:** spawn a small `sleep 9999` Go test binary; capture its
pgid and lstart. Write a state.json entry claiming that pgid /
lstart / fingerprint. Then kill the sleep and spawn a different
sleep that happens to get the same PID (in practice: spawn many
sleeps in a loop until PID collision).

**Assertion:** `verify` reports `identity_mismatch` for that
service. `down` does NOT signal the new sleep. `up` treats the
service as not running.

**Failure mode covered:** A1, A3.

### 10.2 Group-kill terminates the tree

**Fixture:** a test binary that forks a grandchild via
`os/exec.Command(...).Start()` then `sleep 9999` itself. Register
this as a service.

**Assertion:** after `down`, the parent's pgid has no live
descendants — neither parent nor grandchild.

**Failure mode covered:** A2 (zombie tolerance), A6 (spago wrapper).

### 10.3 `up` idempotence

**Fixture:** any service from the test registry.

**Assertion:** consecutive `up; up` — the second `up` reports
"already running" with the same pgid as the first. State.json
unchanged between invocations.

**Failure mode covered:** A3.

### 10.4 Per-service timeout

**Fixture:** a Go test binary that sleeps 8 seconds before binding
its port. Configure with `health_timeout_ms = 3000` (should fail
cleanly) and re-test with `health_timeout_ms = 12000` (should
succeed).

**Assertion:** at 3000ms — service marked `failed_to_start{reason:
health_timeout, elapsed: 3001ms}`, error message names the
timeout. At 12000ms — service marked up.

**Failure mode covered:** A4.

### 10.5 Failure policy

**Fixture:** three test services. A is `on_failure = tier_abort`
and configured to fail-bind. B is `on_failure = warn` and
fails-bind. C is healthy. Each scenario isolates one variant.

**Assertions:**
- A fails → B, C not started; `up` exit code 1.
- B fails → C still started; `up` exit code 0 with warning.
- `on_failure = retry` (third service config): the service is
  attempted 3 times with 1s/2s/4s backoff; if all fail, falls
  through to warn semantics.

**Failure mode covered:** A5.

### 10.6 Source-staleness detection

**Fixture:** spawn a long-running test service. Wait 2 seconds.
`touch` a file matched by `source_paths`. Run `verify`.

**Assertion:** `verify` reports `stale_source` with file path,
file mtime, process start time, delta. Exit code 1.

**Failure mode covered:** B1, B2, B3, B4.

### 10.7 Sibling and stale-socket detection

**Fixture A (sibling):** spawn the test service. Outside DeepStar's
control, spawn another instance with the same argv. Run `verify`.

**Assertion A:** `verify` reports `unknown_sibling{pid, pgid}` for
the unmanaged copy.

**Fixture B (stale socket):** register a unix-socket service.
Spawn it. Kill the process externally with `kill -9` (so DeepStar
doesn't clean state). The socket file persists. Run `verify`.

**Assertion B:** `verify` reports `stale_socket{path,
mtime}` for that service.

**Failure mode covered:** A7, B5.

### 10.8 Crash recovery

**Fixture:** start `up`, kill the DeepStar process mid-spawn (after
fork but before state-write — simulated with a test hook).

**Assertion:** next `up` reports `port_bound_by_foreign_pid`,
names the orphaned pid, exits nonzero. State.json not corrupted.

### 10.9 Concurrent invocations

**Fixture:** two `up` processes started simultaneously.

**Assertion:** one acquires a file lock on
`~/.deepstar/.lock` and proceeds; the other reports
`another_instance_in_progress{pid}` and exits 4.

(File lock added in v2 — v1 raced without protection.)

### 10.10 Registry validation

**Fixture:** every kind of malformed TOML from §6.3.

**Assertion:** v2 binary exits 2 (for `list`) or 3 (for action
subcommands), error names the offending field and (where the TOML
parser can provide) line number.

---

## 11. What v2 deliberately doesn't do

These exclusions are choices, not omissions.

- **No automatic restart of crashed services.** A crash is signal,
  not noise; v2 surfaces it via `status`/`verify` exit codes.
  Auto-restart loops hide root causes.
- **No log rotation.** Services emit; DeepStar tails. Rotation is
  a service's concern, or `logrotate`'s.
- **No structured log format enforcement.** v1's path
  (`/tmp/deepstar/<name>.log`, append, mixed stdout/stderr) is
  preserved.
- **No Marginalia dependency at runtime.** §9.
- **No process-tree introspection beyond pgid leadership.** v2 does
  not walk arbitrary descendant trees; it relies on the pgid
  group-kill to handle the entire tree atomically.
- **No HTTP control surface.** A future "Calypso talks to DeepStar
  endpoint" idea (project 191 description) is post-v2.
- **No adoption-by-port.** v1 adopted whatever process was bound
  to a service's port if no state.json existed. v2 refuses
  adoption; it only manages processes it spawned.
- **No `--force` bypass of identity for `down`.** `--force` only
  affects the no-state-record path; it never overrides a present
  state record's identity mismatch.

---

## 12. Sequencing

| Phase | Scope | Estimated sessions |
|-------|-------|--------------------|
| 0 | This spec. | 1 (this session) |
| 1 | Test suite. Runs against v1 first (regression baseline; many tests fail). Then incrementally against v2 stubs as they exist. | 1–2 |
| 2 | Go implementation. | 2–3 |
| 3 | Rig validation. Side-by-side: v1 in one session, v2 in another, on Andrew's actual rig. | 1 |
| 4 | Cutover. `deepstar-py` symlink kept for rollback. `deepstar` becomes the Go binary. | <1 |
| 5 | Polish: distribution path (brew tap? `go install`?), observability, README. | <1 |

Total ~6–8 focused sessions. The existing v1 keeps running until
Phase 4, so music work is not blocked by spec or implementation
timing.

---

## 13. How to test changes to DeepStar itself

Per project 191 note 241's wscat-testing principle: end-to-end
through the music rig is integration testing; v2 has unit and
integration test surfaces that don't require the rig.

- **Unit tests:** TOML parser, dependency topo-sort, identity
  triple comparison, fingerprint computation, glob expansion for
  `source_paths`.
- **Process-fixture tests:** the §10 fixtures use small Go test
  binaries (`testdata/cmd/sleep-and-bind/`,
  `testdata/cmd/fork-grandchild/`, `testdata/cmd/slow-binder/`)
  that exercise DeepStar's process management without any music
  services. These run in CI.
- **Rig integration tests (Phase 3 only):** spin up the actual
  service set and manually exercise the CLI against Andrew's
  rig. These are not automated.

Test process binaries are versioned under
`agent-teams/deepstar-v2/testdata/cmd/<name>/`. Each is a
single-file Go program with `// +build ignore` so it doesn't
appear in production builds.

---

## 14. Open implementation details (Phase 2 decides)

These are intentionally left to Phase 2 — the spec doesn't
prescribe them:

- TOML library: `BurntSushi/toml` vs `pelletier/go-toml` vs stdlib
  proposal.
- CLI library: `urfave/cli` vs `spf13/cobra` vs hand-rolled
  `flag.FlagSet` (registry has 8 subcommands; hand-rolled is
  plausible).
- State.json marshaling: stdlib `encoding/json` is fine; no third-
  party schema validator needed.
- Test runner: stdlib `testing` plus `t.Cleanup` for process
  reaping is sufficient.
- Distribution: `go install github.com/afcondon/deepstar-v2` or a
  Homebrew tap is the path; not blocking on a choice.

---

## 15. Acceptance gate for this spec

Before Phase 1 begins, the spec passes if:

1. Every property in §3 reads as a falsifiable claim a test
   can fail or pass — not a slogan. ✓ (each property names
   exact observable state).
2. The TOML schema in §6 is implementable from §6 alone — no
   fields missing, accepted values listed, validation rules
   enumerated. ✓
3. Every A-category failure from project 191 note 240 maps to a
   §10 test. ✓ (§5 matrix).
4. Every B-category failure maps to a §3.6 `verify` check. ✓
5. C-category failures are listed with their owning project. ✓
6. v1's CLI surface, signal sequence, log path, and idempotence
   shape are preserved or explicitly diverged from with reason. ✓
7. Andrew can read it and say "yes, this is the binary I want"
   without asking for clarification on meanings. *(human gate)*

Open the gate → start Phase 1 (test suite).
