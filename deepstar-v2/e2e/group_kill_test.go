// §10.2 — Group-kill terminates the whole tree.
//
// Fixture: register a service using fork-grandchild as cmd; the parent
// role binds the registered port (deepstar's health check is satisfied)
// and spawns child + grandchild in the same process group.
//
// Assertion: after `deepstar down`, the pgid recorded in state.json has
// no surviving members.  Verifies SPEC §3.1 (pgid identity) and §3.2
// (down ties success to observable post-state) — covers failure modes
// A2 (zombie tolerance), A6 (spago wrapper / daemon-grandchild).
package e2e

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSpec_10_2_GroupKillTerminatesWholeTree(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	port := FreePort(t)
	fg := HelperPath(t, "fork-grandchild")

	cfg := WriteServices(t, scratch, []Service{
		{
			Name:            "treeful",
			Tier:            1,
			Cwd:             "/tmp",
			Cmd:             []string{fg, "--role", "parent", "--port", strconv.Itoa(port)},
			Port:            port,
			PortKind:        "tcp",
			HealthTimeoutMs: 5000,
			OnFailure:       "warn",
		},
	})

	if out, err := Run(t, scratch, cfg, "up"); err != nil {
		t.Fatalf("up failed: %v\nout: %s", err, out)
	}

	state := ReadState(t, scratch)
	entry, ok := state.Services["treeful"]
	if !ok {
		t.Fatalf("state.json missing 'treeful' entry: %+v", state)
	}
	pgid := entry.Pgid
	if pgid <= 1 {
		t.Fatalf("invalid pgid recorded: %d", pgid)
	}

	// Settle: fork-grandchild's parent → child → grandchild chain
	// takes a moment to fully spawn.
	time.Sleep(500 * time.Millisecond)

	pids, err := PgrepGroup(pgid)
	if err != nil {
		t.Fatalf("PgrepGroup before down: %v", err)
	}
	if len(pids) != 3 {
		t.Fatalf("expected 3 pids in group %d (parent+child+grandchild), got %d: %v",
			pgid, len(pids), pids)
	}

	if out, err := Run(t, scratch, cfg, "down"); err != nil {
		t.Fatalf("down failed: %v\nout: %s", err, out)
	}

	// SPEC §3.2: after down returns success, no process in pgid survives.
	if err := WaitForGone(pgid, 3*time.Second); err != nil {
		survivors, _ := PgrepGroup(pgid)
		t.Fatalf("down reported success but pgid %d has survivors %v: %v",
			pgid, survivors, err)
	}
}

func TestSpec_10_2_DownReturnsErrorWhenGroupSurvives(t *testing.T) {
	// SPEC §3.2 negative: if SIGTERM + SIGKILL both fail to terminate
	// the group, down must exit nonzero and NOT clear state.json.
	//
	// Hard to fabricate in user-space (PID 1 / kernel processes are the
	// usual immortal subjects).  Documented here as a placeholder; a
	// real test would need to mock the signal layer or use a service
	// that ignores SIGTERM and rebinds a TRAP'd SIGKILL handler — which
	// macOS prohibits — making this category likely test-by-inspection
	// rather than test-by-execution.
	t.Skip("not runnable: macOS prohibits SIGKILL trapping; cover via code review of down impl")
	_ = strings.Builder{} // keep imports honest
}
