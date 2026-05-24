// Smoke tests for the convenience subcommands (status / restart /
// logs / init) — not part of the SPEC §10 correctness surface, but
// proof-of-life that the muscle-memory CLI works end-to-end.
package e2e

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// status — register a service, up it, run status, expect the service
// listed with ✓ up.  Then down and re-run, expect "· stopped".
func TestConvenience_Status(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "status")
	RequireSubcommand(t, "down")

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
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up: %v\n%s", err, out)
	}

	out, err := Run(t, scratch, cfg, "status")
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	if !strings.Contains(out, "alpha") {
		t.Errorf("status output should mention alpha:\n%s", out)
	}
	if !strings.Contains(out, "✓ up") {
		t.Errorf("status output should show ✓ up:\n%s", out)
	}

	if _, err := Run(t, scratch, cfg, "down"); err != nil {
		t.Fatalf("down: %v", err)
	}
	out2, _ := Run(t, scratch, cfg, "status")
	if !strings.Contains(out2, "· stopped") {
		t.Errorf("after down, status should show · stopped:\n%s", out2)
	}
}

// restart — up two services A→B (B depends on A), restart A, expect
// new pgids for both, both still bound.
func TestConvenience_Restart(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "restart")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	portA := FreePort(t)
	portB := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")

	cfg := WriteServices(t, scratch, []Service{
		{
			Name: "alpha", Tier: 1, Cwd: "/tmp",
			Cmd:             []string{sb, "--port", strconv.Itoa(portA), "--kind", "tcp"},
			Port:            portA,
			PortKind:        "tcp",
			HealthTimeoutMs: 5000,
		},
		{
			Name: "bravo", Tier: 1, Cwd: "/tmp",
			Cmd:             []string{sb, "--port", strconv.Itoa(portB), "--kind", "tcp"},
			Port:            portB,
			PortKind:        "tcp",
			HealthTimeoutMs: 5000,
			Deps:            []string{"alpha"},
		},
	})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up: %v\n%s", err, out)
	}
	before := ReadState(t, scratch)
	beforeAlphaPgid := before.Services["alpha"].Pgid
	beforeBravoPgid := before.Services["bravo"].Pgid

	if out, err := Run(t, scratch, cfg, "restart", "alpha"); err != nil {
		t.Fatalf("restart alpha: %v\n%s", err, out)
	}

	after := ReadState(t, scratch)
	if after.Services["alpha"].Pgid == beforeAlphaPgid {
		t.Errorf("restart should produce new pgid for alpha; same: %d", beforeAlphaPgid)
	}
	// bravo depends on alpha, so it should also have been cycled.
	if after.Services["bravo"].Pgid == beforeBravoPgid {
		t.Errorf("restart alpha should cycle bravo too; same pgid: %d", beforeBravoPgid)
	}
	// Both must be alive and bound.
	WaitForPortBound(t, portA, 2*time.Second)
	WaitForPortBound(t, portB, 2*time.Second)
}

// init — write a starter services.toml, then list against it.
func TestConvenience_InitStarter(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "init")
	RequireSubcommand(t, "list")

	scratch := t.TempDir()
	cfg := filepath.Join(scratch, "services.toml")
	// init writes to whatever DEEPSTAR_CONFIG points at — but Run()
	// sets that based on the configPath we pass to it.  Pass cfg as
	// the desired output file (it doesn't exist yet).
	out, err := Run(t, scratch, cfg, "init")
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out)
	}
	if _, statErr := os.Stat(cfg); statErr != nil {
		t.Fatalf("init did not create %s: %v", cfg, statErr)
	}

	// The starter should be valid — `list` parses it and prints the
	// example entry.
	out, err = Run(t, scratch, cfg, "list")
	if err != nil {
		t.Errorf("starter is not valid TOML: %v\n%s", err, out)
	}
	if !strings.Contains(out, "example") {
		t.Errorf("starter should contain 'example' entry:\n%s", out)
	}
}

// init --from-python — translate the real v1 services.py if present;
// otherwise skip.  Validates the round-trip works against real input.
func TestConvenience_InitFromPython(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "init")
	RequireSubcommand(t, "list")

	v1 := "/Users/afc/work/afc-work/music/live-coding/deepstar/services.py"
	if _, err := os.Stat(v1); err != nil {
		t.Skipf("v1 services.py not at %s (rig host only); skipping migration smoke test", v1)
	}

	scratch := t.TempDir()
	cfg := filepath.Join(scratch, "services.toml")
	out, err := Run(t, scratch, cfg, "init", "--from-python", v1)
	if err != nil {
		t.Fatalf("init --from-python: %v\n%s", err, out)
	}
	out, err = Run(t, scratch, cfg, "list")
	if err != nil {
		t.Errorf("migrated TOML is not valid: %v\n%s", err, out)
	}
	// v1 has cv-router, link-spike, purerl-tidal at minimum.
	for _, want := range []string{"cv-router", "link-spike", "purerl-tidal"} {
		if !strings.Contains(out, want) {
			t.Errorf("migrated TOML should contain %q:\n%s", want, out)
		}
	}
}

// logs — register a service whose log we can predict, up it, run
// `logs <name>` with a context timeout, expect non-empty output.
func TestConvenience_LogsSingleService(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "logs")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	port := FreePort(t)
	sb := HelperPath(t, "sleep-and-bind")

	cfg := WriteServices(t, scratch, []Service{{
		Name:            "tellme",
		Tier:            1,
		Cwd:             "/tmp",
		Cmd:             []string{sb, "--port", strconv.Itoa(port), "--kind", "tcp"},
		Port:            port,
		PortKind:        "tcp",
		HealthTimeoutMs: 5000,
	}})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up: %v\n%s", err, out)
	}

	// `logs` runs `tail -F` which never exits, so we cap the call via
	// context.  CommandContext alone is not enough — when deepstar is
	// SIGKILL'd, its child `tail -F` orphans and keeps writing to the
	// inherited stdout pipe; the test's reader then never sees EOF.
	// Spawn deepstar as a process-group leader and kill the whole
	// group on cancel so tail dies with its parent.
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	bin := DeepstarBinary(t)
	cmd := exec.CommandContext(ctx, bin,
		"--config", cfg,
		"--state", filepath.Join(scratch, "state.json"),
		"logs", "tellme")
	cmd.Env = append(os.Environ(),
		"DEEPSTAR_LOG_DIR="+filepath.Join(scratch, "logs"))
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if pgid, err := syscall.Getpgid(cmd.Process.Pid); err == nil {
			return syscall.Kill(-pgid, syscall.SIGKILL)
		}
		return cmd.Process.Kill()
	}
	out, _ := cmd.CombinedOutput()
	if !strings.Contains(string(out), "bound") &&
		!strings.Contains(string(out), "sleep-and-bind") {
		t.Errorf("logs should tail the service's stderr; got:\n%s", string(out))
	}
}
