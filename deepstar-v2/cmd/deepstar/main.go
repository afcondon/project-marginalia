// Command deepstar is the v2 binary — a control bridge for Andrew's
// live-coding rig.  See SPEC.md for the canonical specification.
//
// CLI shape mirrors SPEC §8:
//
//	deepstar [--tier N] up [--dry-run]
//	deepstar [--tier N] down [--force]
//	deepstar [--tier N] status [--json]
//	deepstar [--tier N] verify [--json]
//	deepstar [--tier N] restart <service>
//	deepstar          logs [<service>]
//	deepstar          list
//	deepstar          init [--from-python <path>]
//
// Global env vars (overrideable per-test):
//
//	DEEPSTAR_CONFIG  — path to services.toml (default ~/.deepstar/services.toml)
//	DEEPSTAR_STATE   — path to state.json   (default ~/.deepstar/state.json)
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

// Exit codes, per SPEC §8.
const (
	exitOK            = 0
	exitFailure       = 1 // service failed under tier_abort, or other recoverable
	exitConfigList    = 2 // config error in `list`
	exitConfigAction  = 3 // config error in action subcommand
	exitConcurrent    = 4 // another instance in progress
	exitNotImpl       = 5 // Phase 2 stub
	exitUsage         = 64
)

func main() {
	os.Exit(realMain(os.Args[1:]))
}

func realMain(args []string) int {
	// Global flags appear before the subcommand: e.g.
	//   deepstar --tier 4 up
	// flag.FlagSet stops at the first non-flag token, leaving the
	// subcommand + its args in FlagSet.Args().
	global := flag.NewFlagSet("deepstar", flag.ContinueOnError)
	tier := global.Int("tier", 1, "service tier (1-4)")
	configPath := global.String("config", "", "path to services.toml (overrides DEEPSTAR_CONFIG)")
	statePath := global.String("state", "", "path to state.json (overrides DEEPSTAR_STATE)")
	asJSON := global.Bool("json", false, "machine-readable output (where supported)")
	global.SetOutput(os.Stderr)
	global.Usage = func() {
		fmt.Fprint(os.Stderr, usage)
	}
	if err := global.Parse(args); err != nil {
		return exitUsage
	}

	rest := global.Args()
	if len(rest) == 0 {
		fmt.Fprint(os.Stderr, usage)
		return exitUsage
	}

	subcmd, subargs := rest[0], rest[1:]

	ctx := &cmdContext{
		Tier:       *tier,
		ConfigPath: resolveConfigPath(*configPath),
		StatePath:  resolveStatePath(*statePath),
		AsJSON:     *asJSON,
	}

	switch subcmd {
	case "list":
		return runList(ctx, subargs)
	case "up":
		return runUp(ctx, subargs)
	case "down":
		return runDown(ctx, subargs)
	case "verify":
		return runVerify(ctx, subargs)
	case "status":
		return runStatus(ctx, subargs)
	case "restart":
		return runRestart(ctx, subargs)
	case "logs":
		return runLogs(ctx, subargs)
	case "init":
		return runInit(ctx, subargs)
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n\n%s", subcmd, usage)
		return exitUsage
	}
}

// cmdContext is the bundle of resolved global options passed to each
// subcommand handler.  Subcommands read from this rather than os.Args
// directly so test injection works.
type cmdContext struct {
	Tier       int
	ConfigPath string
	StatePath  string
	AsJSON     bool
}

// LockPath returns the file-lock path used to serialise mutating
// invocations (up/down/restart).  Sibling of state.json.
func (c *cmdContext) LockPath() string {
	dir := filepath.Dir(c.StatePath)
	return filepath.Join(dir, ".lock")
}

func resolveConfigPath(flagValue string) string {
	if flagValue != "" {
		return flagValue
	}
	if env := os.Getenv("DEEPSTAR_CONFIG"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".deepstar", "services.toml")
}

func resolveStatePath(flagValue string) string {
	if flagValue != "" {
		return flagValue
	}
	if env := os.Getenv("DEEPSTAR_STATE"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".deepstar", "state.json")
}

const usage = `Usage: deepstar [--tier N] [--config PATH] [--state PATH] [--json] <subcommand> [args]

Subcommands:
  up                       Start tier-<=N services in dependency order
  down                     Stop tier-<=N services in reverse dependency order
  status                   Tabular state of every tier-<=N service
  verify                   Run identity + staleness + sibling + socket checks
  restart <service>        Cycle one service plus its transitive dependents
  logs [<service>]         Tail one service log, or multiplex all
  list                     Print registry entries
  init [--from-python P]   Write a starter services.toml

Exit codes:
  0  success
  1  service failure under tier_abort
  2  config error (list)
  3  config error (action subcommands)
  4  another instance in progress
  5  not yet implemented (Phase 2 stub)
 64  usage error
`
