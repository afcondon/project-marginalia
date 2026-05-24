// §10.3 — `up` is idempotent.
//
// Fixture: register a single sleep-and-bind service; run `up` twice.
// Assertions:
//   - Second invocation does NOT spawn a new process — pgid in
//     state.json is unchanged across the two calls.
//   - Second invocation emits an "already running" message (per
//     SPEC §3.3 / §8.1 output contract).
//   - Combined output of two ups is observably indistinguishable
//     from one up modulo logging — same final state.json contents
//     for the service entry's pgid/lstart/fingerprint.
//
// Covers SPEC §3.3 and failure mode A3 ("already running" claim
// without verification).
package e2e

import (
	"strconv"
	"strings"
	"testing"
)

func TestSpec_10_3_UpIsIdempotent(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")

	scratch := t.TempDir()
	port := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")

	cfg := WriteServices(t, scratch, []Service{
		{
			Name:            "idempotent",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{sb, "--port", strconv.Itoa(port), "--kind", "tcp"},
			Port:            port,
			PortKind:        "tcp",
			HealthTimeoutMs: 5000,
			OnFailure:       "warn",
		},
	})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	// First up: must spawn fresh.
	out1, err := Run(t, scratch, cfg, "up")
	if err != nil {
		t.Fatalf("first up: %v\nout: %s", err, out1)
	}
	state1 := ReadState(t, scratch)
	entry1, ok := state1.Services["idempotent"]
	if !ok {
		t.Fatalf("state.json missing 'idempotent' after first up: %+v", state1)
	}
	if entry1.Pgid <= 1 {
		t.Fatalf("first up: invalid pgid %d", entry1.Pgid)
	}

	// Second up: must no-op.
	out2, err := Run(t, scratch, cfg, "up")
	if err != nil {
		t.Fatalf("second up: %v\nout: %s", err, out2)
	}
	if !strings.Contains(strings.ToLower(out2), "already running") {
		t.Errorf("second up should mention 'already running': %s", out2)
	}

	state2 := ReadState(t, scratch)
	entry2 := state2.Services["idempotent"]

	// Idempotence: same pgid, same lstart, same fingerprint.
	if entry2.Pgid != entry1.Pgid {
		t.Errorf("pgid changed across idempotent up: %d → %d", entry1.Pgid, entry2.Pgid)
	}
	if entry2.Lstart != entry1.Lstart {
		t.Errorf("lstart changed across idempotent up: %q → %q", entry1.Lstart, entry2.Lstart)
	}
	if entry2.CommandFingerprint != entry1.CommandFingerprint {
		t.Errorf("command_fingerprint changed across idempotent up: %q → %q",
			entry1.CommandFingerprint, entry2.CommandFingerprint)
	}
}
