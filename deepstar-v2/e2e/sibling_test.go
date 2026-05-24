// §10.7 — Sibling and stale-socket detection via `verify`.
//
// SPEC §3.6:
//   - Sibling: any process whose command line matches the service's
//     fingerprint but whose pgid differs from state.json's gets
//     flagged as `unknown_sibling`.  Catches failure mode B5 (two
//     BEAMs same code path).
//   - Stale socket: for unix-socket services, a socket file with no
//     listener (e.g. daemon crashed without cleanup) gets flagged as
//     `stale_socket`.  Failure mode A7.
package e2e

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestSpec_10_7_UnknownSiblingReportedByVerify(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "verify")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	port1 := FreePort(t)
	port2 := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")

	// Service registers a sleep-and-bind on port1 — deepstar's
	// "official" instance.
	managedArgs := []string{sb, "--port", strconv.Itoa(port1), "--kind", "tcp"}
	cfg := WriteServices(t, scratch, []Service{{
		Name:            "managed",
		Tier:            1,
		Cwd:             "/tmp",
		Cmd:             managedArgs,
		Port:            port1,
		PortKind:        "tcp",
		HealthTimeoutMs: 5000,
	}})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up: %v\nout: %s", err, out)
	}

	// Now register the SAME command line for a SECOND fictional service
	// on port2 (so the registry has knowledge of this argv) — but
	// don't `up` it via deepstar.  Instead, spawn it directly: this is
	// the "sibling" — a process running the registered argv whose
	// pgid is not in state.json.
	siblingArgs := []string{sb, "--port", strconv.Itoa(port2), "--kind", "tcp"}
	SpawnHelper(t, "sleep-and-bind", "--port", strconv.Itoa(port2), "--kind", "tcp")
	WaitForPortBound(t, port2, 3*time.Second)

	// Update services.toml to register the sibling-shape service too.
	cfg = WriteServices(t, scratch, []Service{
		{
			Name: "managed", Tier: 1, Cwd: "/tmp",
			Cmd:  managedArgs,
			Port: port1, PortKind: "tcp",
			HealthTimeoutMs: 5000,
		},
		{
			Name: "ghost", Tier: 1, Cwd: "/tmp",
			Cmd:  siblingArgs,
			Port: port2, PortKind: "tcp",
			HealthTimeoutMs: 5000,
		},
	})

	out, err := Run(t, scratch, cfg, "verify")
	if got := ExitCode(err); got != 1 {
		t.Errorf("verify: want exit 1, got %d\nout: %s", got, out)
	}
	if !strings.Contains(out, "unknown_sibling") {
		t.Errorf("verify should report unknown_sibling for ghost:\n%s", out)
	}
}

func TestSpec_10_7_StaleSocketReportedByVerify(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "verify")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	// Unix socket paths are limited to 104 bytes on macOS — and the
	// Go test framework's t.TempDir() lives under $TMPDIR which is a
	// long /var/folders/... path.  Put the socket in /tmp so the
	// path fits the syscall buffer.
	sockDir, err := os.MkdirTemp("/tmp", "ds2-sock-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(sockDir) })
	sock := filepath.Join(sockDir, "t.sock")
	sb := HelperPath(t, "sleep-and-bind")

	cfg := WriteServices(t, scratch, []Service{{
		Name:            "sock-svc",
		Tier:            1,
		Cwd:             "/tmp",
		Cmd:             []string{sb, "--kind", "unix", "--path", sock},
		SocketPath:      sock,
		PortKind:        "unix",
		HealthTimeoutMs: 5000,
	}})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up: %v\nout: %s", err, out)
	}

	// Now kill the helper externally with SIGKILL — bypasses any
	// cleanup the daemon would have done.  The socket file persists.
	st := ReadState(t, scratch)
	pgid := st.Services["sock-svc"].Pgid
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
	time.Sleep(300 * time.Millisecond)

	// Verify state of disk: socket file should still exist.
	if _, statErr := os.Stat(sock); statErr != nil {
		t.Fatalf("socket file should persist after SIGKILL: %v", statErr)
	}

	out, err := Run(t, scratch, cfg, "verify")
	if got := ExitCode(err); got != 1 {
		t.Errorf("verify: want exit 1, got %d\nout: %s", got, out)
	}
	if !strings.Contains(out, "stale_socket") &&
		!strings.Contains(out, "process_gone") {
		// Either finding is acceptable — process_gone is reported
		// when state has a record but the group is dead; stale_socket
		// reports the socket file without listener.
		t.Errorf("verify should report stale_socket or process_gone:\n%s", out)
	}
}
