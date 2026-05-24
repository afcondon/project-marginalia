package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"syscall"
	"time"

	"github.com/afcondon/deepstar-v2/internal/identity"
	"github.com/afcondon/deepstar-v2/internal/lock"
	"github.com/afcondon/deepstar-v2/internal/registry"
	"github.com/afcondon/deepstar-v2/internal/state"
)

// runDown implements SPEC §8.2 — stop services in reverse dependency
// order.  SPEC §3.2: success requires observable post-state (group
// dead), never just "signal sent".  Identity verified before any
// signal — SPEC §3.1 (no signalling a process we didn't start).
//
// Exit codes:
//
//	0  all services in tier are down
//	1  any service failed to terminate
//	3  config or state error
func runDown(ctx *cmdContext, args []string) int {
	downFlags := flag.NewFlagSet("down", flag.ContinueOnError)
	force := downFlags.Bool("force", false, "kill by-port if no state record (logs the pid)")
	downFlags.SetOutput(os.Stderr)
	if err := downFlags.Parse(args); err != nil {
		return exitUsage
	}
	_ = force // §3.3 / §8.2 force semantics deferred — Phase 2 TODO

	held, err := lock.Acquire(ctx.LockPath())
	if err != nil {
		var inUse *lock.ErrInUse
		if errors.As(err, &inUse) {
			fmt.Fprintf(os.Stderr, "deepstar down: %v\n", err)
			return exitConcurrent
		}
		fmt.Fprintf(os.Stderr, "deepstar down: lock acquire: %v\n", err)
		return exitFailure
	}
	defer held.Release()

	r, err := registry.LoadFile(ctx.ConfigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar down: %v\n", err)
		return exitConfigAction
	}
	sf, err := state.Load(ctx.StatePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar down: %v\n", err)
		return exitConfigAction
	}
	services, err := r.Tier(ctx.Tier)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar down: %v\n", err)
		return exitConfigAction
	}

	failures := 0
	// Reverse dependency order.
	for i := len(services) - 1; i >= 0; i-- {
		svc := services[i]
		if err := downOne(ctx, sf, svc); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", svc.Name, err)
			failures++
		}
	}

	if err := sf.Save(ctx.StatePath); err != nil {
		fmt.Fprintf(os.Stderr, "deepstar down: save state: %v\n", err)
		return exitFailure
	}
	if failures > 0 {
		return exitFailure
	}
	return exitOK
}

// downOne stops a single service.  No-op if no state record exists
// or if the group is already gone.  SIGTERM → wait → SIGKILL → wait,
// per SPEC §3.2.  Identity verified before signalling.
func downOne(ctx *cmdContext, sf *state.File, svc registry.Service) error {
	e, ok := sf.Get(svc.Name)
	if !ok {
		// Nothing to stop.
		return nil
	}

	if !identity.GroupAlive(e.Pgid) {
		// Already gone — clear and move on.
		sf.Delete(svc.Name)
		fmt.Printf("· %-18s already stopped\n", svc.Name)
		return nil
	}

	// Identity check — SPEC §3.1: never signal a process whose
	// triple has shifted.
	live, err := identity.Capture(e.Pgid, svc.Cmd)
	if err != nil || !live.Equal(e.Triple()) {
		fmt.Printf("⚠ %-18s state-record identity mismatch (pgid=%d); clearing without signal\n",
			svc.Name, e.Pgid)
		sf.Delete(svc.Name)
		return nil
	}

	timeout := time.Duration(svc.HealthTimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	// SIGTERM the group.
	_ = syscall.Kill(-e.Pgid, syscall.SIGTERM)
	if waitGroupGone(e.Pgid, timeout) {
		sf.Delete(svc.Name)
		fmt.Printf("✓ %-18s stopped (SIGTERM, pgid=%d)\n", svc.Name, e.Pgid)
		return nil
	}

	// SIGKILL escalation.
	_ = syscall.Kill(-e.Pgid, syscall.SIGKILL)
	if waitGroupGone(e.Pgid, 500*time.Millisecond) {
		sf.Delete(svc.Name)
		fmt.Printf("✓ %-18s stopped (SIGKILL, pgid=%d)\n", svc.Name, e.Pgid)
		return nil
	}

	// Group survived both signals — leave state intact, surface error.
	return fmt.Errorf("group %d survived SIGTERM+SIGKILL — state.json not cleared", e.Pgid)
}

func waitGroupGone(pgid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !identity.GroupAlive(pgid) {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return !identity.GroupAlive(pgid)
}
