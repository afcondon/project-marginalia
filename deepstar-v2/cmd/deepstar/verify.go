package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/afcondon/deepstar-v2/internal/registry"
	"github.com/afcondon/deepstar-v2/internal/state"
	"github.com/afcondon/deepstar-v2/internal/verify"
)

// runVerify implements SPEC §8.4 — full identity + staleness + sibling
// + stale-socket check across every tier-≤N service.
//
// Exit codes:
//
//	0  every service clean (no findings)
//	1  any service has at least one finding
//	3  config / state error
func runVerify(ctx *cmdContext, args []string) int {
	vFlags := flag.NewFlagSet("verify", flag.ContinueOnError)
	vFlags.SetOutput(os.Stderr)
	if err := vFlags.Parse(args); err != nil {
		return exitUsage
	}

	r, err := registry.LoadFile(ctx.ConfigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar verify: %v\n", err)
		return exitConfigAction
	}
	sf, err := state.Load(ctx.StatePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar verify: %v\n", err)
		return exitConfigAction
	}
	services, err := r.Tier(ctx.Tier)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar verify: %v\n", err)
		return exitConfigAction
	}

	type serviceReport struct {
		Service  string           `json:"service"`
		Findings []verify.Finding `json:"findings"`
	}
	reports := make([]serviceReport, 0, len(services))
	anyFindings := false

	for _, svc := range services {
		var entry *state.Entry
		if e, ok := sf.Get(svc.Name); ok {
			entry = &e
		}
		findings := verify.Service(svc, entry)
		if len(findings) > 0 {
			anyFindings = true
		}
		reports = append(reports, serviceReport{
			Service:  svc.Name,
			Findings: findings,
		})
	}

	if ctx.AsJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(reports)
	} else {
		for _, r := range reports {
			if len(r.Findings) == 0 {
				fmt.Printf("✓ %-18s (clean)\n", r.Service)
				continue
			}
			fmt.Printf("⚠ %-18s %d finding(s)\n", r.Service, len(r.Findings))
			for _, f := range r.Findings {
				fmt.Printf("    %s: %s\n", f.Kind, f.Detail)
			}
		}
	}

	if anyFindings {
		return exitFailure
	}
	return exitOK
}
