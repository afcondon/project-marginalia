// §10.6 — Source staleness detection via `verify`.
//
// SPEC §3.6: verify reports `stale_source` for any file matched by a
// service's `source_paths` whose mtime is newer than the recorded
// process start time.  Covers failure modes B1–B4 (no way to ask
// "what code is actually running", stale BEAM / daemon binary / hot-
// load divergence).
package e2e

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSpec_10_6_StaleSourceDetectedByVerify(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "verify")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	port := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")

	// Seed a "source" file whose mtime is BEFORE the process spawn.
	watched := filepath.Join(scratch, "watched.txt")
	if err := os.WriteFile(watched, []byte("v1"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-1 * time.Hour)
	if err := os.Chtimes(watched, old, old); err != nil {
		t.Fatal(err)
	}

	cfg := WriteServices(t, scratch, []Service{{
		Name:            "watched-svc",
		Tier:            1,
		Cwd:             scratch,
		Cmd:             []string{sb, "--port", strconv.Itoa(port), "--kind", "tcp"},
		Port:            port,
		PortKind:        "tcp",
		HealthTimeoutMs: 5000,
		SourcePaths:     []string{"watched.txt"},
	}})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	// Bring service up — pre-existing file is older than spawn, so
	// verify is clean.
	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up: %v\nout: %s", err, out)
	}
	if out, err := Run(t, scratch, cfg, "verify"); err != nil {
		t.Fatalf("verify (pre-touch) should be clean, got error: %v\nout: %s", err, out)
	} else if strings.Contains(out, "stale_source") {
		t.Fatalf("pre-touch verify should not report stale_source:\n%s", out)
	}

	// Touch the file to advance its mtime past spawned_at.  Use a
	// concrete future timestamp to defeat coarse mtime quantization.
	future := time.Now().Add(1 * time.Second)
	if err := os.Chtimes(watched, future, future); err != nil {
		t.Fatal(err)
	}

	out, err := Run(t, scratch, cfg, "verify")
	if got := ExitCode(err); got != 1 {
		t.Errorf("verify (post-touch): want exit 1, got %d\nout: %s", got, out)
	}
	if !strings.Contains(out, "stale_source") {
		t.Errorf("verify should report stale_source after touch:\n%s", out)
	}
	if !strings.Contains(out, "watched.txt") {
		t.Errorf("verify output should name the stale file:\n%s", out)
	}
}

func TestSpec_10_6_GlobExpansion(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "verify")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	port := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")

	// Seed two old files matching the glob.
	for _, name := range []string{"alpha.beam", "bravo.beam"} {
		p := filepath.Join(scratch, name)
		if err := os.WriteFile(p, []byte{}, 0o600); err != nil {
			t.Fatal(err)
		}
		old := time.Now().Add(-1 * time.Hour)
		_ = os.Chtimes(p, old, old)
	}

	cfg := WriteServices(t, scratch, []Service{{
		Name:            "glob-svc",
		Tier:            1,
		Cwd:             scratch,
		Cmd:             []string{sb, "--port", strconv.Itoa(port), "--kind", "tcp"},
		Port:            port,
		PortKind:        "tcp",
		HealthTimeoutMs: 5000,
		SourcePaths:     []string{"*.beam"},
	}})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up: %v\nout: %s", err, out)
	}

	// Touch one of the two glob-matched files.
	future := time.Now().Add(1 * time.Second)
	_ = os.Chtimes(filepath.Join(scratch, "bravo.beam"), future, future)

	out, err := Run(t, scratch, cfg, "verify")
	if got := ExitCode(err); got != 1 {
		t.Errorf("verify: want exit 1, got %d\nout: %s", got, out)
	}
	if !strings.Contains(out, "bravo.beam") {
		t.Errorf("verify should name the touched file from the glob:\n%s", out)
	}
	if strings.Contains(out, "alpha.beam") {
		t.Errorf("verify should NOT flag the untouched file:\n%s", out)
	}
}
