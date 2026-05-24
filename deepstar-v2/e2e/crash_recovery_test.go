// §10.8 — Crash recovery.
//
// Fixture: set DEEPSTAR_CRASH_AFTER_FORK=<svc>; run `up`.  The Go
// binary spawns the child, then exits before writing state.json.
// The child survives as an orphan, holding the registered port.
//
// Assertion: subsequent `up` (env var unset) reports a foreign
// occupant on the port, exits nonzero, leaves the orphan alive.
// state.json is parseable (the previous crash either left it absent
// or fresh).
//
// Covers SPEC §7.4 (crash recovery — loud-fail rather than silent
// auto-restart loops).
package e2e

import (
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestSpec_10_8_OrphanedProcessReportedOnNextUp(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")

	scratch := t.TempDir()
	port := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")

	cfg := WriteServices(t, scratch, []Service{{
		Name:            "alpha",
		Tier:            1,
		Cwd:             "/tmp",
		Cmd:             []string{sb, "--port", strconv.Itoa(port), "--kind", "tcp"},
		Port:            port,
		PortKind:        "tcp",
		HealthTimeoutMs: 5000,
	}})

	// (1) Crash-after-fork: helper spawns, deepstar exits with 99
	// before writing state.json.  The helper is now orphaned.
	t.Setenv("DEEPSTAR_CRASH_AFTER_FORK", "alpha")
	out1, err1 := Run(t, scratch, cfg, "up")
	if got := ExitCode(err1); got != 99 {
		t.Fatalf("first up: want exit 99 (crash hook), got %d\nout: %s", got, out1)
	}
	// Helper must be alive — orphan held by launchd (PID 1).
	WaitForPortBound(t, port, 2*time.Second)

	// Determine the orphan pid for cleanup.
	pidOut, _ := exec.Command("lsof", "-t",
		"-iTCP:"+strconv.Itoa(port), "-sTCP:LISTEN").Output()
	pid, _ := strconv.Atoi(strings.TrimSpace(string(pidOut)))
	if pid <= 1 {
		t.Fatalf("could not find orphan pid via lsof; lsof output: %q", string(pidOut))
	}
	t.Cleanup(func() {
		_ = syscall.Kill(pid, syscall.SIGTERM)
		time.Sleep(200 * time.Millisecond)
		_ = syscall.Kill(pid, syscall.SIGKILL)
	})

	// (2) Now clear the crash hook and run up again.  Must surface
	// the foreign occupant.
	t.Setenv("DEEPSTAR_CRASH_AFTER_FORK", "")
	out2, err2 := Run(t, scratch, cfg, "up")
	if got := ExitCode(err2); got == 0 {
		t.Errorf("second up: should fail (orphan holds port), got exit 0\nout: %s", out2)
	}
	lower := strings.ToLower(out2)
	if !strings.Contains(lower, "foreign") && !strings.Contains(lower, "bound") {
		t.Errorf("second up output should name the foreign occupant:\n%s", out2)
	}
	// State.json must be parseable (not corrupted by the crash).
	// ReadState fatals if it's malformed.
	_ = ReadState(t, scratch)
}
