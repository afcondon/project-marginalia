package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/afcondon/deepstar-v2/internal/registry"
	"github.com/afcondon/deepstar-v2/internal/state"
	"github.com/afcondon/deepstar-v2/internal/verify"
)

// runStatus implements SPEC §8.3 — tabular state per service.
//
// State symbols (worst-finding wins):
//
//	✓ up              identity matches, no findings
//	· stopped         no state record, port unbound, no findings
//	⚠ stale-source    identity match, but source mtime > spawn time
//	⚠ identity-mism.  state has triple but live doesn't match
//	? port-no-pgid    port bound by foreign process (no state record)
//	! process-gone    state has record but group is dead
//
// Exit codes: 0 (always) — status is informational only.  Use
// `verify` (exit 1 on findings) for scripts that need an alarm.
func runStatus(ctx *cmdContext, args []string) int {
	sFlags := flag.NewFlagSet("status", flag.ContinueOnError)
	sFlags.SetOutput(os.Stderr)
	if err := sFlags.Parse(args); err != nil {
		return exitUsage
	}

	r, err := registry.LoadFile(ctx.ConfigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar status: %v\n", err)
		return exitConfigAction
	}
	sf, err := state.Load(ctx.StatePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar status: %v\n", err)
		return exitConfigAction
	}
	services, err := r.Tier(ctx.Tier)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar status: %v\n", err)
		return exitConfigAction
	}

	type row struct {
		Name     string           `json:"name"`
		Tier     int              `json:"tier"`
		Pgid     int              `json:"pgid"`
		Port     string           `json:"port"`
		State    string           `json:"state"`
		Note     string           `json:"note"`
		Findings []verify.Finding `json:"findings,omitempty"`
	}

	rows := make([]row, 0, len(services))
	for _, svc := range services {
		var entry *state.Entry
		if e, ok := sf.Get(svc.Name); ok {
			entry = &e
		}
		findings := verify.Service(svc, entry)
		st, note := classify(entry, findings)
		pgid := 0
		if entry != nil {
			pgid = entry.Pgid
		}
		rows = append(rows, row{
			Name:     svc.Name,
			Tier:     svc.Tier,
			Pgid:     pgid,
			Port:     endpointLabel(svc),
			State:    st,
			Note:     note,
			Findings: findings,
		})
	}

	if ctx.AsJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(rows)
		return exitOK
	}

	fmt.Printf("%-18s %-5s %-7s %-22s %-22s %s\n",
		"NAME", "TIER", "PGID", "ENDPOINT", "STATE", "NOTE")
	for _, r := range rows {
		pgidStr := "-"
		if r.Pgid > 0 {
			pgidStr = fmt.Sprintf("%d", r.Pgid)
		}
		fmt.Printf("%-18s %-5d %-7s %-22s %-22s %s\n",
			r.Name, r.Tier, pgidStr, r.Port, r.State, r.Note)
	}
	return exitOK
}

// classify derives the status row's symbol + note from the entry
// presence and the verify findings.  Worst-finding wins.
func classify(entry *state.Entry, findings []verify.Finding) (string, string) {
	for _, f := range findings {
		switch f.Kind {
		case verify.ProcessGone:
			return "! process-gone", fmt.Sprintf("state pgid=%d not alive", entry.Pgid)
		case verify.IdentityMismatch:
			return "⚠ identity-mism.", f.Detail
		case verify.UnknownSibling:
			return "? port-no-pgid", f.Detail
		case verify.StaleSource:
			return "⚠ stale-source", f.Detail
		case verify.StaleSocket:
			return "⚠ stale-socket", f.Detail
		}
	}
	if entry != nil {
		return "✓ up", fmt.Sprintf("(fresh)")
	}
	return "· stopped", "—"
}

// endpointLabel exists in up.go; defined again here would conflict,
// so we just reuse it from the package.

var _ = strings.Builder{} // keep imports tidy
