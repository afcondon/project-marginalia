// §10.1 — Process identity rejection (the loginwindow case).
//
// THIS IS THE REGRESSION TEST FOR THE BUG-CLASS THAT MOTIVATED V2.
// On 2026-05-18 and 2026-05-23, v1 was a hair from SIGTERMing
// loginwindow because it had reused PID 417.  v2 must never signal
// a process whose stored identity triple doesn't match the live one,
// even if the pgid is alive — SPEC §3.1.
//
// Fixture:
//   1. Test spawns sleep-and-bind directly (not via deepstar) holding
//      a TCP port.  Captures the real pgid + argv.
//   2. Test writes a synthetic state.json claiming that pgid for
//      service "lookalike", with the REAL fingerprint but a FABRICATED
//      lstart.  This is the loginwindow scenario: same pgid, but the
//      kernel re-issued it to a different process.
//   3. Test runs `deepstar down`.
//      Assertions:
//        - exit code 0 (graceful state cleanup, not failure)
//        - helper IS STILL ALIVE (down refused to signal due to
//          identity mismatch — this is the regression check)
//        - state.json entry for "lookalike" is cleared
//        - output mentions "mismatch" so the user can diagnose
//   4. Test runs `deepstar up`.
//      Assertions:
//        - exit code != 0 (port held by foreign process; no adoption)
//        - helper STILL ALIVE (up never signalled it)
//        - output mentions "foreign" or "bound"
package e2e

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSpec_10_1_IdentityRejectionLoginwindowCase(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "down")
	RequireSubcommand(t, "up")

	scratch := t.TempDir()
	port := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")
	argv := []string{sb, "--port", strconv.Itoa(port), "--kind", "tcp"}

	// (1) Spawn helper directly — the test owns this process, NOT
	// deepstar.  This is the "foreign" process from deepstar's
	// perspective once we forge state.json.
	cmd := SpawnHelper(t, "sleep-and-bind",
		"--port", strconv.Itoa(port), "--kind", "tcp")
	WaitForPortBound(t, port, 3*time.Second)
	realPgid := cmd.Process.Pid // Setpgid:true in SpawnHelper

	// (2) Write services.toml registering a service whose Cmd
	// matches the helper's argv (so fingerprint comparison passes).
	cfg := WriteServices(t, scratch, []Service{{
		Name:            "lookalike",
		Tier:            1,
		Cwd:             "/tmp",
		Cmd:             argv,
		Port:            port,
		PortKind:        "tcp",
		HealthTimeoutMs: 2000,
	}})

	// Write state.json with REAL pgid + REAL fingerprint but a
	// FABRICATED lstart.  Only the lstart field is wrong — exactly
	// the loginwindow recurrence pattern.
	stateFile := StateFile{
		Version: 1,
		Services: map[string]StateEntry{
			"lookalike": {
				Pgid:               realPgid,
				Lstart:             "Wed Dec 31 23:59:59 1969", // pre-epoch sentinel
				CommandFingerprint: fingerprintArgv(argv),
				SpawnedAt:          "2026-05-23T00:00:00Z",
				SpawnArgv:          argv,
				SpawnCwd:           "/tmp",
				SpawnEnvOverlay:    map[string]string{},
			},
		},
	}
	data, err := json.MarshalIndent(stateFile, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(scratch, "state.json")
	if err := os.WriteFile(statePath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	// Pre-flight: helper is alive before we let deepstar at it.
	if !PgidAlive(realPgid) {
		t.Fatal("helper died before test could run")
	}

	// (3) `deepstar down` — identity mismatch, must NOT signal.
	out, err := Run(t, scratch, cfg, "down")
	if got := ExitCode(err); got != 0 {
		t.Errorf("down exit code: want 0, got %d\noutput:\n%s", got, out)
	}
	if !strings.Contains(strings.ToLower(out), "mismatch") {
		t.Errorf("down output should mention identity mismatch:\n%s", out)
	}
	// Give the process a beat in case down was about to signal (it
	// shouldn't, but if it did, we want this test to catch it).
	time.Sleep(200 * time.Millisecond)
	if !PgidAlive(realPgid) {
		t.Fatal("LOGINWINDOW REGRESSION (down): deepstar signalled a process whose stored identity did not match the live identity — exactly the 2026-05-18 / 2026-05-23 near-miss")
	}
	sf := ReadState(t, scratch)
	if _, exists := sf.Services["lookalike"]; exists {
		t.Errorf("state.json should have cleared 'lookalike' entry, still present: %+v", sf.Services)
	}

	// (4) `deepstar up` — port held by foreign process, must refuse.
	out2, err2 := Run(t, scratch, cfg, "up")
	if got := ExitCode(err2); got == 0 {
		t.Errorf("up should fail (port occupied by foreign process), got exit 0\noutput:\n%s", out2)
	}
	lower := strings.ToLower(out2)
	if !strings.Contains(lower, "foreign") && !strings.Contains(lower, "bound") {
		t.Errorf("up output should mention foreign occupant or bound port:\n%s", out2)
	}
	if !PgidAlive(realPgid) {
		t.Fatal("LOGINWINDOW REGRESSION (up): deepstar signalled a foreign process while attempting to start a service")
	}
}

// fingerprintArgv mirrors internal/identity.Fingerprint — kept inline
// here so the e2e package doesn't take a dependency on internal/.
// Algorithm: SHA-256 of argv with NUL separators.
func fingerprintArgv(argv []string) string {
	h := sha256.New()
	for i, a := range argv {
		if i > 0 {
			h.Write([]byte{0})
		}
		h.Write([]byte(a))
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil))
}
