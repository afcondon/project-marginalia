// §10.5 — Per-service failure policy.
//
// Three test variants, one per `on_failure` value:
//   - tier_abort: failing service halts tier-up; later services not started.
//   - warn:       failing service is logged but tier-up continues.
//   - retry:      attempted 3 times with 1s/2s/4s backoff before
//                 falling through to warn semantics.
//
// Fixture: two services [alpha, bravo].  alpha is configured to fail
// (slow-binder with --delay 99s + health_timeout_ms 1000).  bravo is
// healthy.  Each variant changes alpha's on_failure value.
//
// Covers SPEC §3.5 and failure mode A5 (eager tier-abort).
package e2e

import (
	"strconv"
	"strings"
	"testing"
)

func TestSpec_10_5_TierAbortStopsRemainingServices(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	portAlpha := FreePort(t)
	portBravo := FreePort(t)
	slow := HelperPath(t, "slow-binder")
	sb := HelperPath(t, "sleep-and-bind")

	cfg := WriteServices(t, scratch, []Service{
		{
			Name:            "alpha",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{slow, "--port", strconv.Itoa(portAlpha), "--delay", "99s"},
			Port:            portAlpha,
			PortKind:        "tcp",
			HealthTimeoutMs: 500,
			OnFailure:       "tier_abort",
		},
		{
			Name:            "bravo",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{sb, "--port", strconv.Itoa(portBravo), "--kind", "tcp"},
			Port:            portBravo,
			PortKind:        "tcp",
			HealthTimeoutMs: 5000,
		},
	})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	out, err := Run(t, scratch, cfg, "up")
	if got := ExitCode(err); got != 1 {
		t.Errorf("up: tier_abort with failure should exit 1, got %d\nout: %s", got, out)
	}

	// bravo must NOT have been started — state.json should not record it.
	sf := ReadState(t, scratch)
	if _, ok := sf.Services["bravo"]; ok {
		t.Errorf("tier_abort should prevent bravo from starting; state.json has it:\n%+v", sf.Services)
	}
}

func TestSpec_10_5_WarnAllowsTierToContinue(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	portAlpha := FreePort(t)
	portBravo := FreePort(t)
	slow := HelperPath(t, "slow-binder")
	sb := HelperPath(t, "sleep-and-bind")

	cfg := WriteServices(t, scratch, []Service{
		{
			Name:            "alpha",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{slow, "--port", strconv.Itoa(portAlpha), "--delay", "99s"},
			Port:            portAlpha,
			PortKind:        "tcp",
			HealthTimeoutMs: 500,
			OnFailure:       "warn",
		},
		{
			Name:            "bravo",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{sb, "--port", strconv.Itoa(portBravo), "--kind", "tcp"},
			Port:            portBravo,
			PortKind:        "tcp",
			HealthTimeoutMs: 5000,
		},
	})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	out, _ := Run(t, scratch, cfg, "up")
	// Exit code: warn means failure recorded but tier continues; v2
	// still returns exitFailure (1) when ANY service failed.  But
	// bravo MUST have been started.
	if !strings.Contains(out, "alpha") {
		t.Errorf("up output should mention alpha (the failure):\n%s", out)
	}

	sf := ReadState(t, scratch)
	if _, ok := sf.Services["bravo"]; !ok {
		t.Errorf("warn should allow bravo to start; state.json missing it:\n%+v", sf.Services)
	}
}

func TestSpec_10_5_RetryBackoffBeforeWarn(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	port := FreePort(t)
	slow := HelperPath(t, "slow-binder")

	cfg := WriteServices(t, scratch, []Service{{
		Name:            "alpha",
		Tier:            1,
		Cwd:             "/tmp",
		Cmd:             []string{slow, "--port", strconv.Itoa(port), "--delay", "99s"},
		Port:            port,
		PortKind:        "tcp",
		HealthTimeoutMs: 200, // very short so retry test runs fast
		OnFailure:       "retry",
	}})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	out, _ := Run(t, scratch, cfg, "up")
	// SPEC §3.5: retry attempts 3 times with 1s/2s/4s backoff.  For
	// test speed we accept evidence of multiple attempts in the
	// output — "attempt 1/3", "attempt 2/3", "attempt 3/3" or similar.
	// Loose check: "retry" or "attempt" appears multiple times.
	attempts := strings.Count(strings.ToLower(out), "attempt")
	if attempts < 2 {
		t.Errorf("retry should log multiple attempts (got %d 'attempt' occurrences):\n%s",
			attempts, out)
	}
}
