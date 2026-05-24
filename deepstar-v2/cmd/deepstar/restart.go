package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/afcondon/deepstar-v2/internal/lock"
	"github.com/afcondon/deepstar-v2/internal/registry"
	"github.com/afcondon/deepstar-v2/internal/state"
)

// runRestart implements SPEC §8.5 — cycle one service plus its
// transitive dependents.
//
// Order:
//  1. Compute transitive dependents of <service>
//  2. down dependents in reverse dep order
//  3. down <service>
//  4. up <service>
//  5. up dependents in forward dep order
//
// Fail-fast: any failed step halts the chain.  Single lock acquisition
// covers the entire orchestration.
func runRestart(ctx *cmdContext, args []string) int {
	rFlags := flag.NewFlagSet("restart", flag.ContinueOnError)
	rFlags.SetOutput(os.Stderr)
	if err := rFlags.Parse(args); err != nil {
		return exitUsage
	}
	if rFlags.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "usage: deepstar restart <service>")
		return exitUsage
	}
	target := rFlags.Arg(0)

	held, err := lock.Acquire(ctx.LockPath())
	if err != nil {
		var inUse *lock.ErrInUse
		if errors.As(err, &inUse) {
			fmt.Fprintf(os.Stderr, "deepstar restart: %v\n", err)
			return exitConcurrent
		}
		fmt.Fprintf(os.Stderr, "deepstar restart: lock acquire: %v\n", err)
		return exitFailure
	}
	defer held.Release()

	r, err := registry.LoadFile(ctx.ConfigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar restart: %v\n", err)
		return exitConfigAction
	}
	sf, err := state.Load(ctx.StatePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar restart: %v\n", err)
		return exitConfigAction
	}

	targetSvc := r.ByName(target)
	if targetSvc == nil {
		fmt.Fprintf(os.Stderr, "deepstar restart: unknown service %q\n", target)
		return exitUsage
	}

	depNames := r.DependentsOf(target)
	deps := make([]registry.Service, 0, len(depNames))
	for _, name := range depNames {
		if s := r.ByName(name); s != nil {
			deps = append(deps, *s)
		}
	}

	// down dependents in reverse, then target.
	for i := len(deps) - 1; i >= 0; i-- {
		if err := downOne(ctx, sf, deps[i]); err != nil {
			fmt.Fprintf(os.Stderr, "restart: down %s: %v\n", deps[i].Name, err)
			_ = sf.Save(ctx.StatePath)
			return exitFailure
		}
	}
	if err := downOne(ctx, sf, *targetSvc); err != nil {
		fmt.Fprintf(os.Stderr, "restart: down %s: %v\n", target, err)
		_ = sf.Save(ctx.StatePath)
		return exitFailure
	}
	_ = sf.Save(ctx.StatePath)

	// up target, then dependents in forward order.
	if err := tryUp(ctx, sf, *targetSvc); err != nil {
		fmt.Fprintf(os.Stderr, "restart: up %s: %v\n", target, err)
		_ = sf.Save(ctx.StatePath)
		return exitFailure
	}
	for _, dep := range deps {
		if err := tryUp(ctx, sf, dep); err != nil {
			fmt.Fprintf(os.Stderr, "restart: up %s: %v\n", dep.Name, err)
			_ = sf.Save(ctx.StatePath)
			return exitFailure
		}
	}
	if err := sf.Save(ctx.StatePath); err != nil {
		fmt.Fprintf(os.Stderr, "restart: save state: %v\n", err)
		return exitFailure
	}
	return exitOK
}
