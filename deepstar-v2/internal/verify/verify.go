// Package verify implements SPEC §3.6 — the rig-health checks that
// answer "is what I think is running actually running, and is it
// running the code I think it is?"
//
// Each check produces zero or more Findings; an empty result means
// clean.  Used by the `verify` subcommand and (in future) by `status`
// and the implicit pre-flight checks of `up`/`down` per SPEC §4.2.
package verify

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/afcondon/deepstar-v2/internal/identity"
	"github.com/afcondon/deepstar-v2/internal/registry"
	"github.com/afcondon/deepstar-v2/internal/state"
)

// Finding describes one divergence between expected and actual state.
// Kind enumerates the well-known divergence categories from SPEC §3.6.
type Finding struct {
	Kind    string         `json:"kind"`
	Service string         `json:"service"`
	Detail  string         `json:"detail"`
	Data    map[string]any `json:"data,omitempty"`
}

// Finding kinds.
const (
	IdentityMismatch = "identity_mismatch"
	ProcessGone      = "process_gone"
	StaleSource      = "stale_source"
	UnknownSibling   = "unknown_sibling"
	StaleSocket      = "stale_socket"
)

// Service runs every applicable check for one service and returns
// the findings.  Nil entry means "no state record" — only checks
// that don't require a baseline run (sibling, stale-socket).
func Service(svc registry.Service, entry *state.Entry) []Finding {
	var findings []Finding

	if entry == nil {
		// No state record: only sibling search makes sense.
		findings = append(findings, siblingFindings(svc, 0)...)
		if svc.PortKind == "unix" {
			if f := staleSocket(svc); f != nil {
				findings = append(findings, *f)
			}
		}
		return findings
	}

	// State record exists — identity + staleness.
	switch {
	case !identity.GroupAlive(entry.Pgid):
		findings = append(findings, Finding{
			Kind:    ProcessGone,
			Service: svc.Name,
			Detail:  fmt.Sprintf("state has pgid=%d but no process exists", entry.Pgid),
			Data:    map[string]any{"pgid": entry.Pgid},
		})

	default:
		live, err := identity.Capture(entry.Pgid, svc.Cmd)
		if err != nil || !live.Equal(entry.Triple()) {
			findings = append(findings, Finding{
				Kind:    IdentityMismatch,
				Service: svc.Name,
				Detail:  identityDetail(entry, live),
				Data: map[string]any{
					"recorded_pgid":        entry.Pgid,
					"recorded_lstart":      entry.Lstart,
					"recorded_fingerprint": entry.CommandFingerprint,
					"live_lstart":          live.Lstart,
					"live_fingerprint":     live.CommandFingerprint,
				},
			})
		} else {
			// Identity matches — check source staleness against
			// the recorded spawn time.
			findings = append(findings, staleSourceFindings(svc, entry)...)
		}
	}

	// Sibling search always runs — excludes the state-recorded pgid
	// (which is the legitimate one) but flags any other process
	// whose command line matches our service's argv.
	findings = append(findings, siblingFindings(svc, entry.Pgid)...)

	if svc.PortKind == "unix" {
		if f := staleSocket(svc); f != nil {
			findings = append(findings, *f)
		}
	}

	return findings
}

// staleSourceFindings checks each glob in svc.SourcePaths and reports
// any matched file whose mtime is newer than the recorded process
// start time.  Globs are expanded relative to svc.Cwd.
func staleSourceFindings(svc registry.Service, entry *state.Entry) []Finding {
	if len(svc.SourcePaths) == 0 {
		return nil
	}
	procStart, err := time.Parse(time.RFC3339Nano, entry.SpawnedAt)
	if err != nil {
		return nil // can't compare; skip silently — the SpawnedAt format is our own
	}

	// Pre-resolve exclude globs to absolute patterns for cwd-relative
	// match against each candidate file below.
	excludePatterns := make([]string, 0, len(svc.SourceExcludePaths))
	for _, p := range svc.SourceExcludePaths {
		if filepath.IsAbs(p) {
			excludePatterns = append(excludePatterns, p)
		} else {
			excludePatterns = append(excludePatterns, filepath.Join(svc.Cwd, p))
		}
	}

	var findings []Finding
	for _, pattern := range svc.SourcePaths {
		fullPattern := pattern
		if !filepath.IsAbs(pattern) {
			fullPattern = filepath.Join(svc.Cwd, pattern)
		}
		matches, _ := filepath.Glob(fullPattern)
		for _, m := range matches {
			info, statErr := os.Stat(m)
			if statErr != nil {
				continue
			}
			if info.IsDir() {
				continue
			}
			if matchesAnyGlob(m, excludePatterns) {
				continue
			}
			if info.ModTime().After(procStart) {
				findings = append(findings, Finding{
					Kind:    StaleSource,
					Service: svc.Name,
					Detail: fmt.Sprintf("%s mtime %s is newer than process start %s (delta %s)",
						m,
						info.ModTime().Format(time.RFC3339),
						procStart.Format(time.RFC3339),
						info.ModTime().Sub(procStart).Round(time.Second)),
					Data: map[string]any{
						"file":       m,
						"mtime":      info.ModTime().Format(time.RFC3339Nano),
						"proc_start": procStart.Format(time.RFC3339Nano),
						"delta_ms":   info.ModTime().Sub(procStart).Milliseconds(),
					},
				})
			}
		}
	}
	return findings
}

// matchesAnyGlob returns true if path matches any of the given glob
// patterns (filepath.Match semantics).
func matchesAnyGlob(path string, patterns []string) bool {
	for _, pat := range patterns {
		if ok, _ := filepath.Match(pat, path); ok {
			return true
		}
	}
	return false
}

// siblingFindings reports processes bound to the service's endpoint
// whose process group differs from excludePgid (the state-recorded
// one).  Port-bind is the operational identity of a service —
// strictly more accurate than argv-string matching, which the earlier
// implementation used and which broke against `erl→beam.smp`,
// `spago→node`, and `npx→npm exec` exec chains observed on the
// real rig (Phase 3 finding, note 248).
//
// Catches failure mode B5 (two BEAMs same code path): the older,
// no-longer-tracked process is binding the same port; we flag it
// regardless of how its cmdline mutated through exec.
func siblingFindings(svc registry.Service, excludePgid int) []Finding {
	pids := lsofPidsFor(svc)
	if len(pids) == 0 {
		return nil
	}
	var findings []Finding
	for _, pid := range pids {
		pgid, err := syscall.Getpgid(pid)
		if err != nil {
			continue
		}
		if pgid == excludePgid {
			continue
		}
		// Capture the cmdline for diagnostic detail.  Best-effort;
		// missing cmdline doesn't suppress the finding.
		cmd := ""
		if out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "command=").Output(); err == nil {
			cmd = strings.TrimSpace(string(out))
		}
		findings = append(findings, Finding{
			Kind:    UnknownSibling,
			Service: svc.Name,
			Detail: fmt.Sprintf("pid=%d pgid=%d bound to %s outside state.json (cmd: %s)",
				pid, pgid, endpointDesc(svc), cmd),
			Data: map[string]any{"pid": pid, "pgid": pgid, "cmd": cmd},
		})
	}
	return findings
}

// lsofPidsFor returns the PIDs of processes bound to the service's
// endpoint.  TCP: only LISTEN sockets; UDP: any bind; Unix: any
// process with the socket file open.
func lsofPidsFor(svc registry.Service) []int {
	var args []string
	switch svc.PortKind {
	case "tcp":
		args = []string{"-t", fmt.Sprintf("-iTCP:%d", svc.Port), "-sTCP:LISTEN"}
	case "udp":
		args = []string{"-t", fmt.Sprintf("-iUDP:%d", svc.Port)}
	case "unix":
		// lsof -- <path> filters by path; -U combined with a path
		// argument matches ALL unix-socket-holding processes (~100
		// system services on macOS), not what we want.
		args = []string{"-t", "--", svc.SocketPath}
	default:
		return nil
	}
	out, err := exec.Command("lsof", args...).Output()
	if err != nil || len(out) == 0 {
		return nil
	}
	var pids []int
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if pid, perr := strconv.Atoi(strings.TrimSpace(line)); perr == nil {
			pids = append(pids, pid)
		}
	}
	return pids
}

func endpointDesc(svc registry.Service) string {
	if svc.PortKind == "unix" {
		return "unix:" + svc.SocketPath
	}
	return fmt.Sprintf("%s:%d", svc.PortKind, svc.Port)
}

// staleSocket checks unix-socket services: file present + no listener
// is a stale socket from a crashed daemon (SPEC §3.6, failure A7).
func staleSocket(svc registry.Service) *Finding {
	info, err := os.Stat(svc.SocketPath)
	if err != nil {
		return nil
	}
	if c, derr := net.DialTimeout("unix", svc.SocketPath, 100*time.Millisecond); derr == nil {
		_ = c.Close()
		return nil
	} else if !errors.Is(derr, syscallECONNREFUSED) && !os.IsNotExist(derr) {
		// Connect failed for some other reason; treat as stale.
	}
	return &Finding{
		Kind:    StaleSocket,
		Service: svc.Name,
		Detail:  fmt.Sprintf("socket file %s exists but no listener", svc.SocketPath),
		Data: map[string]any{
			"path":  svc.SocketPath,
			"mtime": info.ModTime().Format(time.RFC3339),
		},
	}
}

// syscallECONNREFUSED is a sentinel for the errno comparison above.
// Imported indirectly via errors.Is.
var syscallECONNREFUSED = errors.New("connection refused")

func identityDetail(stored *state.Entry, live identity.Triple) string {
	var diffs []string
	if stored.Lstart != live.Lstart {
		diffs = append(diffs, fmt.Sprintf("lstart %q → %q", stored.Lstart, live.Lstart))
	}
	if stored.CommandFingerprint != live.CommandFingerprint {
		diffs = append(diffs, "command_fingerprint differs")
	}
	if len(diffs) == 0 {
		diffs = []string{"identity capture failed"}
	}
	return fmt.Sprintf("pgid=%d %s", stored.Pgid, strings.Join(diffs, "; "))
}
