package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/afcondon/deepstar-v2/internal/registry"
)

// runList implements SPEC §8.7 — print every registry entry,
// human-readable by default, JSON with --json.
//
// Exit codes:
//   0  registry loaded and printed
//   2  config error (per SPEC §10.10 — list-specific exit code)
func runList(ctx *cmdContext, _ []string) int {
	r, err := registry.LoadFile(ctx.ConfigPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deepstar list: %v\n", err)
		return exitConfigList
	}

	if ctx.AsJSON {
		// JSON output: emit the full registry so machine consumers
		// (e.g. a future Calypso process pane) can render it however.
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(r.Services)
		return exitOK
	}

	// Human-readable: per-service block.  Stable order = registry
	// declaration order; matches v1's `list` behaviour.
	for i, s := range r.Services {
		if i > 0 {
			fmt.Println()
		}
		printService(s)
	}
	return exitOK
}

func printService(s registry.Service) {
	endpoint := "(none)"
	switch s.PortKind {
	case "tcp", "udp":
		endpoint = fmt.Sprintf("%d/%s", s.Port, s.PortKind)
	case "unix":
		endpoint = "unix:" + s.SocketPath
	}

	deps := "(none)"
	if len(s.Deps) > 0 {
		deps = strings.Join(s.Deps, ", ")
	}

	onFailure := s.OnFailure
	if onFailure == "" {
		onFailure = "warn (default)"
	}

	timeout := s.HealthTimeoutMs
	if timeout == 0 {
		timeout = 5000
	}

	fmt.Printf("%s (tier %d)\n", s.Name, s.Tier)
	if s.Description != "" {
		fmt.Printf("  description       %s\n", s.Description)
	}
	fmt.Printf("  cwd               %s\n", s.Cwd)
	fmt.Printf("  cmd               %s\n", strings.Join(s.Cmd, " "))
	fmt.Printf("  endpoint          %s\n", endpoint)
	fmt.Printf("  deps              %s\n", deps)
	fmt.Printf("  health_timeout_ms %d\n", timeout)
	fmt.Printf("  on_failure        %s\n", onFailure)
	if len(s.SourcePaths) > 0 {
		fmt.Printf("  source_paths      %s\n", strings.Join(s.SourcePaths, ", "))
	}
	if len(s.Env) > 0 {
		keys := make([]string, 0, len(s.Env))
		for k := range s.Env {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		fmt.Printf("  env\n")
		for _, k := range keys {
			fmt.Printf("    %s=%s\n", k, s.Env[k])
		}
	}
}
