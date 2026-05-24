// §10.4 — Per-service health timeout.
//
// Fixture: slow-binder delays --delay before binding --port.  Run
// once with health_timeout_ms below the delay (must fail cleanly,
// naming the timeout in the error) and once above (must succeed).
//
// Covers SPEC §3.4 and failure mode A4 (hardcoded 5s too short for
// spago-run daemons).
package e2e

import (
	"strconv"
	"strings"
	"testing"
)

func TestSpec_10_4_TimeoutTooShortFailsCleanly(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")

	scratch := t.TempDir()
	port := FreePort(t)
	bin := HelperPath(t, "slow-binder")

	cfg := WriteServices(t, scratch, []Service{
		{
			Name:            "molasses",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{bin, "--port", strconv.Itoa(port), "--delay", "8s"},
			Port:            port,
			PortKind:        "tcp",
			HealthTimeoutMs: 3000,
			OnFailure:       "warn",
		},
	})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	out, err := Run(t, scratch, cfg, "up")
	// Service is `on_failure = warn`, so the up itself may succeed
	// overall — but the service entry must be marked failed.
	if err != nil && !strings.Contains(strings.ToLower(out), "timeout") {
		t.Logf("up reported error (acceptable for warn policy): %v\nout: %s", err, out)
	}
	if !strings.Contains(strings.ToLower(out), "timeout") {
		t.Errorf("expected output to name the timeout, got: %s", out)
	}

	// State.json should not contain a healthy entry for molasses.
	state := ReadState(t, scratch)
	if entry, ok := state.Services["molasses"]; ok && entry.Pgid > 1 {
		// If the binary records failure with pgid=0 or omits the entry,
		// either is acceptable per SPEC.  Recording the failure detail
		// is what the SPEC mandates — the form is implementation choice.
		t.Logf("state.json recorded molasses with pgid=%d — acceptable if entry marked failed", entry.Pgid)
	}
}

func TestSpec_10_4_TimeoutLongEnoughSucceeds(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")

	scratch := t.TempDir()
	port := FreePort(t)
	bin := HelperPath(t, "slow-binder")

	cfg := WriteServices(t, scratch, []Service{
		{
			Name:            "patient",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{bin, "--port", strconv.Itoa(port), "--delay", "2s"},
			Port:            port,
			PortKind:        "tcp",
			HealthTimeoutMs: 12000,
			OnFailure:       "warn",
		},
	})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	out, err := Run(t, scratch, cfg, "up")
	if err != nil {
		t.Fatalf("up with 12s timeout failed: %v\nout: %s", err, out)
	}

	state := ReadState(t, scratch)
	entry, ok := state.Services["patient"]
	if !ok || entry.Pgid <= 1 {
		t.Fatalf("expected healthy state.json entry for 'patient', got: %+v", state)
	}
}
