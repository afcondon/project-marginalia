# deepstar-v2

Go rewrite of [DeepStar](../../music/live-coding/deepstar/) — the
live-coding rig supervisor.

## Status

- **Phase 0 (spec):** done. See [SPEC.md](SPEC.md).
- **Phase 1 (test suite):** done.
- **Phase 2 (Go impl):** done. All 8 subcommands implemented;
  every SPEC §10 test passes.
- **Phase 3 (rig validation):** pending.
- **Phase 4 (cutover):** pending.
- **Phase 5 (polish):** pending.

### Tests: 59 PASS / 1 SKIP

Every SPEC §10 test runs and passes against the v2 binary except
one: `TestSpec_10_2_DownReturnsErrorWhenGroupSurvives` — documented
as un-testable on macOS (cannot trap SIGKILL in user-space; would
require mocking the signal layer).

### Subcommands

| Subcommand              | Implements |
|-------------------------|------------|
| `list`                  | SPEC §8.7 — registry contents, human + `--json` |
| `up`                    | SPEC §8.1 — idempotent verify-or-spawn, file-locked |
| `down`                  | SPEC §8.2 — SIGTERM → SIGKILL → verify gone |
| `verify`                | SPEC §8.4 — identity + staleness + sibling + socket checks |
| `status`                | SPEC §8.3 — tabular state per service |
| `restart <service>`     | SPEC §8.5 — cycle one + transitive dependents |
| `logs [<service>]`      | SPEC §8.6 — tail one or multiplex all |
| `init [--from-python]`  | SPEC §8.8 — starter TOML, or migrate v1 services.py |

## Layout

```
deepstar-v2/
├── SPEC.md                 # canonical spec
├── README.md               # this file
├── Makefile                # `make all` builds deepstar + helpers
├── go.mod
├── cmd/deepstar/           # the binary entry + subcommand handlers
│   ├── main.go             #   global flags, subcommand dispatch
│   ├── list.go             #   `list` (Phase 2)
│   ├── up.go               #   `up` (Phase 2)
│   └── down.go             #   `down` (Phase 2)
├── internal/
│   ├── registry/           #   TOML parse + SPEC §6.3 validation + topo-sort
│   ├── identity/           #   (pgid, lstart, command_fingerprint) triple
│   ├── state/              #   state.json atomic read/write
│   └── spawn/              #   process-group spawn + port-bind probe
├── cmd/deepstar/
│   ├── main.go             #   subcommand dispatch + global flags
│   ├── list.go             #   §8.7
│   ├── up.go               #   §8.1 (lock, identity, spawn, retry)
│   ├── down.go             #   §8.2 (lock, identity, SIGTERM→KILL)
│   ├── verify.go           #   §8.4 (uses internal/verify)
│   ├── status.go           #   §8.3
│   ├── restart.go          #   §8.5 (orchestrates down+up)
│   ├── logs.go             #   §8.6 (tail -F per service)
│   └── init.go             #   §8.8 (starter + --from-python)
├── internal/
│   ├── registry/           #   TOML parse + SPEC §6.3 validation + topo
│   ├── identity/           #   (pgid, lstart, command_fingerprint)
│   ├── state/              #   state.json atomic read/write
│   ├── spawn/              #   process-group spawn + port-bind probe
│   ├── verify/             #   identity/staleness/sibling/socket checks
│   └── lock/               #   flock-based concurrent-invocation guard
├── e2e/                    # end-to-end test suite (the §10 surface)
│   ├── harness.go          #   shared helpers
│   ├── helper_sanity_test.go     7 tests, all PASS
│   ├── identity_test.go          §10.1 — LOGINWINDOW REGRESSION ✓
│   ├── group_kill_test.go        §10.2 — ✓ (one negative sub-test skipped)
│   ├── idempotence_test.go       §10.3 — ✓
│   ├── timeout_test.go           §10.4 — ✓
│   ├── failure_policy_test.go    §10.5 — ✓ ×3 (tier_abort/warn/retry)
│   ├── staleness_test.go         §10.6 — ✓ ×2 (single file + glob)
│   ├── sibling_test.go           §10.7 — ✓ ×2 (sibling + stale-socket)
│   ├── crash_recovery_test.go    §10.8 — ✓
│   ├── concurrent_test.go        §10.9 — ✓
│   ├── validation_test.go        §10.10 — ✓ ×13
│   └── convenience_test.go       status/restart/logs/init smoke tests ✓
└── testdata/
    ├── services-template.toml  # reference TOML for SPEC §6 schema
    └── cmd/                    # helper binaries
        ├── sleep-and-bind/     #   binds tcp/udp/unix, sleeps until signalled
        ├── fork-grandchild/    #   spawns 2-deep tree, optional --port
        └── slow-binder/        #   sleeps N seconds before binding
```

## Running tests

```bash
make helpers       # build the three test fixture binaries → ./bin
go test ./e2e/...  # run the suite

# Helper-sanity tests pass today; deepstar-driving tests SKIP
# because DEEPSTAR_BINARY is unset (no v2 binary yet).
```

Once Phase 2 has produced a v2 binary, set `DEEPSTAR_BINARY` to its
path and the §10 tests run end-to-end:

```bash
go build -o bin/deepstar ./cmd/deepstar          # Phase 2
DEEPSTAR_BINARY=$(pwd)/bin/deepstar go test ./e2e/...
```

## Phase 1 — what's done vs what's left

### Done

- **Helper binaries** — `sleep-and-bind`, `fork-grandchild`,
  `slow-binder`.  All three exit cleanly on SIGTERM/SIGINT, are
  signal-cooperative, and are exercised by the helper-sanity tests
  (which pass today).
- **Harness** — `e2e/harness.go`:
  - `DeepstarBinary(t)` — locate v2 binary; skip if unset.
  - `HelperPath(t, name)` — locate built fixture.
  - `Service`, `WriteServices()` — render SPEC §6 TOML.
  - `Run(t, scratchDir, configPath, args...)` — exec deepstar with
    `$DEEPSTAR_CONFIG` / `$DEEPSTAR_STATE` pointing at scratch.
  - `ReadState(t, scratchDir)` — parse SPEC §7.2 state.json.
  - `PgidAlive`, `WaitForGone`, `PgrepGroup` — process-state probes.
  - `FreePort`, `WaitForPortBound`, `WaitForSocketBound` — port probes.
  - `SpawnHelper(t, name, args…)` — start a helper in its own group
    with auto-cleanup.
- **Three §10 tests, fully written** (skip when v2 binary absent):
  - §10.2 group-kill terminates the tree (covers A2, A6).
  - §10.3 up is idempotent — same pgid/lstart/fingerprint across
    consecutive ups (covers A3).
  - §10.4 per-service health timeout — both fail-cleanly and
    success variants (covers A4).
- **Seven §10 stub clusters**, each documenting the fixture shape so
  the next session can fill in the bodies:
  - §10.1 identity rejection (the loginwindow regression — highest
    value test in the suite).
  - §10.5 failure policy (tier_abort / warn / retry variants).
  - §10.6 staleness detection.
  - §10.7 sibling and stale-socket detection.
  - §10.8 crash recovery.
  - §10.9 concurrent invocations.
  - §10.10 registry validation (12 sub-tests for SPEC §6.3 rules).

### Left for next Phase 1 session(s)

1. Fill in the §10.1 identity test once the v2 spawn helpers exist
   (needs ability to write a synthetic state.json before calling
   deepstar — Phase 2 territory).
2. Fill in the §10.5, §10.6, §10.7, §10.8, §10.9, §10.10 stubs —
   each can be done once Phase 2 emits a binary that honors
   `$DEEPSTAR_CONFIG` / `$DEEPSTAR_STATE`.
3. Optional: add a `cmd/sigterm-resistant/` helper for §3.2 negative
   testing (would need careful design to avoid making the test
   un-killable).

## Why no Phase 1 against v1?

The spec (§12) says tests run "against v1 first (regression baseline;
many will fail)".  v1 reads a hardcoded Python `SERVICES` dict in
`services.py`, not a TOML file — running these tests against v1
would require mutating v1's source per-test, which is out of scope.

Practical decision: Phase 1 builds a test surface targeting the v2
**spec**, not the v1 **implementation**.  v1's behaviours that v2
preserves verbatim (CLI shape, log paths, signal sequence) are
listed in SPEC §2.1–2.8 and are the regression baseline-by-
documentation; v1's behaviours v2 deliberately changes (PID-only
identity, port adoption, etc.) are listed as explicit divergences in
SPEC §11.

See SPEC §2 ("v1 baseline") and §11 ("What v2 deliberately doesn't
do") for the canonical list of preserved vs changed behaviours.

## Conventions

- Tests use `testing.TB` not `*testing.T` where they don't need
  Skip/Run — keeps them usable from benchmarks if we add them later.
- Each test is named `TestSpec_<section>_<descriptor>` so the spec
  section is grepable from test output.
- Per-test scratch dirs come from `t.TempDir()` — automatic cleanup.
- Each helper-spawn registers a SIGKILL-the-group cleanup so a
  failing test doesn't leak processes.

## See also

- [SPEC.md](SPEC.md) — the canonical spec.
- Marginalia project 191 (`charlie-india-charlie-november`).
- Marginalia notes 238–241 (project 191) for the v1 failure-mode
  catalogue and the spec-input narrative.
