// Package e2e is the integration test harness for the DeepStar v2
// binary.  The tests here drive a deepstar executable end-to-end
// against synthetic helper services (testdata/cmd/) — no live music
// rig dependency.
//
// Tests are binary-agnostic: they shell out to whatever
// $DEEPSTAR_BINARY points at, with $DEEPSTAR_CONFIG / $DEEPSTAR_STATE
// pointing at per-test scratch dirs.  Without $DEEPSTAR_BINARY set,
// deepstar-driving tests skip — only the helper-sanity tests run.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// RepoRoot returns the absolute path to the deepstar-v2 module root.
// Resolved at test runtime from this file's location so tests can be
// invoked from any cwd.
func RepoRoot(t testing.TB) string {
	t.Helper()
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	// e2e/harness.go → e2e/ → deepstar-v2/
	return filepath.Dir(filepath.Dir(here))
}

// HelperPath returns the absolute path to a built helper binary.
// Fails (not skips) if the binary is missing — `make helpers` is a
// prerequisite of running the test suite.
func HelperPath(t testing.TB, name string) string {
	t.Helper()
	p := filepath.Join(RepoRoot(t), "bin", name)
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("helper %q not found at %s: %v (run `make helpers`)", name, p, err)
	}
	return p
}

// DeepstarBinary returns the path to the deepstar binary under test.
// Resolution order:
//  1. $DEEPSTAR_BINARY env var (explicit override).
//  2. ./bin/deepstar relative to repo root (built by `make`).
// Skips the test if neither is available.
func DeepstarBinary(t *testing.T) string {
	t.Helper()
	if p := os.Getenv("DEEPSTAR_BINARY"); p != "" {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("DEEPSTAR_BINARY=%q: %v", p, err)
		}
		return p
	}
	p := filepath.Join(RepoRoot(t), "bin", "deepstar")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	t.Skip("no deepstar binary: set DEEPSTAR_BINARY or run `make` to build ./bin/deepstar")
	return "" // unreachable
}

// implementedSubcommands records which deepstar subcommands have moved
// out of "not yet implemented (Phase 2 stub)" status.  Tests use
// RequireSubcommand to skip when their dependency hasn't landed yet —
// avoids per-test "if stub, skip" boilerplate, gives Phase 2 a single
// place to flip a bit as subcommands turn green.
var implementedSubcommands = map[string]bool{
	"list":    true,
	"up":      true,
	"down":    true,
	"verify":  true,
	"status":  true,
	"restart": true,
	"logs":    true,
	"init":    true,
}

// RequireSubcommand skips the test if the named deepstar subcommand
// has not yet been implemented (still returns exit 5 / "not yet
// implemented").  Call this near the top of any test whose fixture
// requires the subcommand to work.
func RequireSubcommand(t *testing.T, name string) {
	t.Helper()
	if !implementedSubcommands[name] {
		t.Skipf("subcommand %q not yet implemented (Phase 2 stub)", name)
	}
}

// WriteRawTOML writes the given content to dir/services.toml verbatim
// (no schema rendering — useful for tests that need exact malformed
// shapes) and returns the path.
func WriteRawTOML(t testing.TB, dir, content string) string {
	t.Helper()
	path := filepath.Join(dir, "services.toml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("WriteRawTOML: %v", err)
	}
	return path
}

// ExitCode extracts the exit code from an error returned by exec.
// Returns 0 if err is nil, -1 if err is not an *exec.ExitError
// (typically context timeout or spawn failure).
func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// FreePort returns a TCP port that was free at the moment of the
// call.  There is a race window between this returning and the
// caller binding the port; tests accept this.
func FreePort(t testing.TB) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("FreePort: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// Service mirrors the SPEC §6 TOML schema.  Used by WriteServices to
// render a per-test registry.
type Service struct {
	Name            string
	Tier            int
	Cwd             string
	Cmd             []string
	Port            int
	SocketPath      string
	PortKind        string // "tcp" | "udp" | "unix"
	HealthTimeoutMs int
	OnFailure       string // "tier_abort" | "warn" | "retry"
	Deps            []string
	SourcePaths     []string
	Env             map[string]string
}

// WriteServices renders a TOML registry into dir/services.toml and
// returns the path.  The schema is the one described in SPEC §6.
func WriteServices(t testing.TB, dir string, services []Service) string {
	t.Helper()
	var b strings.Builder
	for _, s := range services {
		b.WriteString("[[service]]\n")
		fmt.Fprintf(&b, "name = %q\n", s.Name)
		fmt.Fprintf(&b, "tier = %d\n", s.Tier)
		fmt.Fprintf(&b, "cwd  = %q\n", s.Cwd)
		b.WriteString("cmd  = [")
		for i, a := range s.Cmd {
			if i > 0 {
				b.WriteString(", ")
			}
			fmt.Fprintf(&b, "%q", a)
		}
		b.WriteString("]\n")
		switch s.PortKind {
		case "tcp", "udp":
			fmt.Fprintf(&b, "port = %d\n", s.Port)
		case "unix":
			fmt.Fprintf(&b, "socket_path = %q\n", s.SocketPath)
		}
		fmt.Fprintf(&b, "port_kind = %q\n", s.PortKind)
		if s.HealthTimeoutMs > 0 {
			fmt.Fprintf(&b, "health_timeout_ms = %d\n", s.HealthTimeoutMs)
		}
		if s.OnFailure != "" {
			fmt.Fprintf(&b, "on_failure = %q\n", s.OnFailure)
		}
		if len(s.Deps) > 0 {
			b.WriteString("deps = [")
			for i, d := range s.Deps {
				if i > 0 {
					b.WriteString(", ")
				}
				fmt.Fprintf(&b, "%q", d)
			}
			b.WriteString("]\n")
		}
		if len(s.SourcePaths) > 0 {
			b.WriteString("source_paths = [")
			for i, p := range s.SourcePaths {
				if i > 0 {
					b.WriteString(", ")
				}
				fmt.Fprintf(&b, "%q", p)
			}
			b.WriteString("]\n")
		}
		if len(s.Env) > 0 {
			b.WriteString("[service.env]\n")
			for k, v := range s.Env {
				fmt.Fprintf(&b, "%s = %q\n", k, v)
			}
		}
		b.WriteString("\n")
	}
	path := filepath.Join(dir, "services.toml")
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatalf("WriteServices: %v", err)
	}
	return path
}

// Run shells out to the deepstar binary with the given args.
// $DEEPSTAR_CONFIG and $DEEPSTAR_STATE point at the per-test scratch
// dir's services.toml and state.json respectively, so tests are
// isolated from any system-wide DeepStar state.
//
// A 30-second timeout caps the call — a misbehaving deepstar
// invocation must not hang the suite.  Returns combined output and
// the exit error (nil on exit code 0).
func Run(t *testing.T, scratchDir, configPath string, args ...string) (string, error) {
	t.Helper()
	bin := DeepstarBinary(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	logDir := filepath.Join(scratchDir, "logs")
	_ = os.MkdirAll(logDir, 0o755)
	cmd.Env = append(os.Environ(),
		"DEEPSTAR_CONFIG="+configPath,
		"DEEPSTAR_STATE="+filepath.Join(scratchDir, "state.json"),
		"DEEPSTAR_LOG_DIR="+logDir,
	)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// PgidAlive reports whether any process in process group pgid is
// alive on the system.  Implemented via `kill -0 -pgid`, which
// succeeds when the group exists and ESRCHes when it doesn't.
func PgidAlive(pgid int) bool {
	if pgid <= 1 {
		return false
	}
	err := syscall.Kill(-pgid, 0)
	if err == nil {
		return true
	}
	return errors.Is(err, syscall.EPERM)
}

// WaitForGone polls every 50ms until PgidAlive(pgid) is false, or
// the timeout fires.  Returns nil on gone, error on timeout.
func WaitForGone(pgid int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !PgidAlive(pgid) {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("pgid %d still alive after %s", pgid, timeout)
}

// PgrepGroup returns PIDs belonging to the given process group via
// `pgrep -g`.  Used by §10.2 to assert the whole tree was killed,
// not just the group leader.  pgrep exit code 1 (no matches) is not
// an error here.
func PgrepGroup(pgid int) ([]int, error) {
	out, err := exec.Command("pgrep", "-g", strconv.Itoa(pgid)).Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 1 {
			return nil, nil
		}
		return nil, err
	}
	var pids []int
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		pid, perr := strconv.Atoi(line)
		if perr != nil {
			return nil, perr
		}
		pids = append(pids, pid)
	}
	return pids, nil
}

// SpawnHelper starts a helper binary in a new process group and
// returns its *exec.Cmd.  The test gets automatic cleanup: SIGKILL
// to the group on test exit.  Stdout/stderr are discarded; tests
// that need them should wire their own pipes.
func SpawnHelper(t *testing.T, name string, args ...string) *exec.Cmd {
	t.Helper()
	bin := HelperPath(t, name)
	cmd := exec.Command(bin, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stderr = io.Discard
	cmd.Stdout = io.Discard
	if err := cmd.Start(); err != nil {
		t.Fatalf("spawn %s: %v", name, err)
	}
	t.Cleanup(func() {
		pgid, err := syscall.Getpgid(cmd.Process.Pid)
		if err == nil {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		}
		_, _ = cmd.Process.Wait()
	})
	return cmd
}

// WaitForPortBound polls until a TCP port accepts a connect or the
// timeout fires.  Used by helper-sanity tests to confirm a helper
// has bound its port.
func WaitForPortBound(t testing.TB, port int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("port %d not bound after %s", port, timeout)
}

// StateEntry mirrors SPEC §7.2's state.json per-service shape.
// Used by tests to inspect what deepstar recorded after up/down.
type StateEntry struct {
	Pgid               int               `json:"pgid"`
	Lstart             string            `json:"lstart"`
	CommandFingerprint string            `json:"command_fingerprint"`
	SpawnedAt          string            `json:"spawned_at"`
	SpawnArgv          []string          `json:"spawn_argv"`
	SpawnCwd           string            `json:"spawn_cwd"`
	SpawnEnvOverlay    map[string]string `json:"spawn_env_overlay"`
}

// StateFile mirrors SPEC §7.2's outer state.json shape.
type StateFile struct {
	Services map[string]StateEntry `json:"services"`
	Version  int                   `json:"version"`
}

// ReadState parses scratch/state.json, failing the test on missing
// file or malformed JSON.  Used by tests to assert the post-state
// of deepstar invocations.
func ReadState(t testing.TB, scratchDir string) StateFile {
	t.Helper()
	p := filepath.Join(scratchDir, "state.json")
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read state.json at %s: %v", p, err)
	}
	var s StateFile
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatalf("parse state.json: %v\nraw: %s", err, string(data))
	}
	return s
}

// WaitForSocketBound polls until a unix socket accepts a connect or
// the timeout fires.
func WaitForSocketBound(t testing.TB, path string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("unix", path, 100*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("socket %s not bound after %s", path, timeout)
}
