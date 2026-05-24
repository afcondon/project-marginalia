package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/afcondon/deepstar-v2/internal/identity"
	"github.com/afcondon/deepstar-v2/internal/lock"
	"github.com/afcondon/deepstar-v2/internal/registry"
	"github.com/afcondon/deepstar-v2/internal/spawn"
	"github.com/afcondon/deepstar-v2/internal/state"
)

// runUp implements SPEC §8.1 — idempotent verify-or-spawn each
// service in tier-≤N dependency order.
//
// Exit codes:
//
//	0  all services healthy (or no-op'd)
//	1  any service failed under tier_abort policy
//	3  config or state error
func runUp(ctx *cmdContext, args []string) int {
	upFlags := flag.NewFlagSet("up", flag.ContinueOnError)
	dryRun := upFlags.Bool("dry-run", false, "print decisions without spawning")
	upFlags.SetOutput(os.Stderr)
	if err := upFlags.Parse(args); err != nil {
		return exitUsage
	}

	held, err := lock.Acquire(ctx.LockPath())
	if err != nil {
		var inUse *lock.ErrInUse
		if errors.As(err, &inUse) {
			fmt.Fprintf(os.Stderr, "deepstar up: %v\n", err)
			return exitConcurrent
		}
		fmt.Fprintf(os.Stderr, "deepstar up: lock acquire: %v\n", err)
		return exitFailure
	}
	defer held.Release()

	r, err := registry.LoadFile(ctx.ConfigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar up: %v\n", err)
		return exitConfigAction
	}
	sf, err := state.Load(ctx.StatePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar up: %v\n", err)
		return exitConfigAction
	}
	services, err := r.Tier(ctx.Tier)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar up: %v\n", err)
		return exitConfigAction
	}

	failures := 0
	for _, svc := range services {
		if *dryRun {
			fmt.Printf("dry-run: would up %s\n", svc.Name)
			continue
		}
		if err := tryUp(ctx, sf, svc); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", svc.Name, err)
			failures++
			if onFailure(svc) == "tier_abort" {
				_ = sf.Save(ctx.StatePath)
				return exitFailure
			}
		}
	}

	if err := sf.Save(ctx.StatePath); err != nil {
		fmt.Fprintf(os.Stderr, "deepstar up: save state: %v\n", err)
		return exitFailure
	}
	if failures > 0 {
		return exitFailure
	}
	return exitOK
}

// upOne brings a single service to the desired state.  Implements
// SPEC §3.3 (idempotence) — re-running on a healthy service is a
// no-op; zombies are detected and respawned; foreign-occupants block
// adoption.
func upOne(ctx *cmdContext, sf *state.File, svc registry.Service) error {
	if e, ok := sf.Get(svc.Name); ok {
		// Existing record — is the identity still satisfied?
		if identity.GroupAlive(e.Pgid) {
			live, err := identity.Capture(e.Pgid, svc.Cmd)
			if err == nil && live.Equal(e.Triple()) {
				fmt.Printf("↻ %-18s already running (pgid=%d)\n", svc.Name, e.Pgid)
				return nil
			}
			// Identity mismatch (PID recycled, or process replaced).
			// SPEC §3.1: "not ours" — never signal.  Clear the stale
			// entry and let the foreign-occupant check downstream
			// decide whether to spawn or refuse.  The whole bug-class
			// motivating v2 is this exact branch: a recycled PID 417
			// belonging to loginwindow must NOT receive a SIGKILL.
			fmt.Printf("⚠ %-18s stale state record (identity mismatch at pgid=%d); clearing without signal\n",
				svc.Name, e.Pgid)
		}
		// Stored entry stale (or dead) — clear and re-spawn.
		sf.Delete(svc.Name)
	}

	// No record (or just cleared).  Refuse to adopt foreign occupants
	// — SPEC §3.3 / §11 (no adoption-by-port in v2).
	if foreignPid, occupied := portOccupied(svc); occupied {
		return fmt.Errorf("port %s bound by foreign pid %d; refusing to adopt",
			endpointLabel(svc), foreignPid)
	}

	res, err := spawn.Service(svc)
	if err != nil {
		return err
	}

	// Test hook: simulate a crash window between fork and
	// state-write per SPEC §7.4 / §10.8.  If
	// $DEEPSTAR_CRASH_AFTER_FORK matches this service name, exit now
	// with the spawned child orphaned.
	if crash := os.Getenv("DEEPSTAR_CRASH_AFTER_FORK"); crash == svc.Name {
		fmt.Fprintf(os.Stderr, "deepstar up: DEEPSTAR_CRASH_AFTER_FORK=%s — exiting before state save\n", crash)
		os.Exit(99)
	}

	sf.Set(svc.Name, state.Entry{
		Pgid:               res.Pgid,
		Lstart:             res.Identity.Lstart,
		CommandFingerprint: res.Identity.CommandFingerprint,
		SpawnedAt:          time.Now().UTC().Format(time.RFC3339Nano),
		SpawnArgv:          svc.Cmd,
		SpawnCwd:           svc.Cwd,
		SpawnEnvOverlay:    svc.Env,
	})
	// Save incrementally so a crash mid-tier doesn't lose the state
	// of services already up.
	_ = sf.Save(ctx.StatePath)

	fmt.Printf("✓ %-18s up (pgid=%d)\n", svc.Name, res.Pgid)
	return nil
}

// portOccupied detects whether the service's endpoint is already
// bound by some process — used to refuse adoption when state.json
// has no record.  Returns the listening PID if found, else 0.
//
// Implementation: shell out to `lsof -t` which returns the listening
// pid(s) for a port or socket.  UDP returns (0, false) — we can't
// reliably probe UDP occupancy without binding ourselves (which
// would race the service); spawn-time bind failure surfaces conflicts
// loudly enough.
func portOccupied(svc registry.Service) (int, bool) {
	var args []string
	switch svc.PortKind {
	case "tcp":
		args = []string{"-t", fmt.Sprintf("-iTCP:%d", svc.Port), "-sTCP:LISTEN"}
	case "unix":
		if _, err := os.Stat(svc.SocketPath); err != nil {
			return 0, false
		}
		// lsof -- <path> filters by path; -U + path returns every
		// process with any unix socket open.  Path-only is correct.
		args = []string{"-t", "--", svc.SocketPath}
	default:
		return 0, false
	}
	out, err := exec.Command("lsof", args...).Output()
	if err != nil || len(out) == 0 {
		return 0, false
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if pid, perr := strconv.Atoi(line); perr == nil {
			return pid, true
		}
	}
	return 0, false
}

func endpointLabel(svc registry.Service) string {
	switch svc.PortKind {
	case "unix":
		return "unix:" + svc.SocketPath
	default:
		return fmt.Sprintf("%s:%d", svc.PortKind, svc.Port)
	}
}

func onFailure(svc registry.Service) string {
	if svc.OnFailure == "" {
		return "warn"
	}
	return svc.OnFailure
}

// tryUp dispatches on on_failure policy.  retry wraps upOne with up
// to 3 attempts and 1s/2s exponential backoff between failures, per
// SPEC §3.5; final failure falls through to warn semantics (the
// caller decides tier-abort vs continue based on the policy).
func tryUp(ctx *cmdContext, sf *state.File, svc registry.Service) error {
	if onFailure(svc) != "retry" {
		return upOne(ctx, sf, svc)
	}
	const maxAttempts = 3
	backoff := []time.Duration{0, 1 * time.Second, 2 * time.Second}
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if attempt > 1 {
			fmt.Fprintf(os.Stderr, "%s: retry attempt %d/%d after %s backoff\n",
				svc.Name, attempt, maxAttempts, backoff[attempt-1])
			time.Sleep(backoff[attempt-1])
		} else {
			fmt.Fprintf(os.Stderr, "%s: attempt %d/%d\n",
				svc.Name, attempt, maxAttempts)
		}
		if err := upOne(ctx, sf, svc); err == nil {
			return nil
		} else {
			lastErr = err
		}
	}
	return lastErr
}
