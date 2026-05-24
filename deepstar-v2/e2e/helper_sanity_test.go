// Helper-sanity tests verify that the testdata/cmd/ helper binaries
// behave as advertised.  These run today without any deepstar binary
// — they're the foundation everything else builds on; if these fail,
// every deepstar-driving test on top of them is suspect.
package e2e

import (
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func TestHelper_SleepAndBind_TCP(t *testing.T) {
	port := FreePort(t)
	SpawnHelper(t, "sleep-and-bind",
		"--port", strconv.Itoa(port),
		"--kind", "tcp",
	)
	WaitForPortBound(t, port, 3*time.Second)

	// Verify nothing else can bind the same port — proves the helper
	// is actually holding it, not just transiently accepting.
	if l, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port)); err == nil {
		_ = l.Close()
		t.Fatalf("port %d still bindable while helper supposedly holds it", port)
	}
}

func TestHelper_SleepAndBind_UDP(t *testing.T) {
	port := FreePort(t)
	SpawnHelper(t, "sleep-and-bind",
		"--port", strconv.Itoa(port),
		"--kind", "udp",
	)
	// Give the helper a moment to bind — UDP has no connect-based probe.
	time.Sleep(300 * time.Millisecond)

	addr, _ := net.ResolveUDPAddr("udp", "127.0.0.1:"+strconv.Itoa(port))
	c, err := net.ListenUDP("udp", addr)
	if err == nil {
		_ = c.Close()
		t.Fatalf("udp port %d still bindable while helper supposedly holds it", port)
	}
}

func TestHelper_SleepAndBind_Unix(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "sanity.sock")
	SpawnHelper(t, "sleep-and-bind",
		"--kind", "unix",
		"--path", sock,
	)
	WaitForSocketBound(t, sock, 3*time.Second)
}

func TestHelper_ForkGrandchild_GroupHasThreePids(t *testing.T) {
	cmd := SpawnHelper(t, "fork-grandchild")
	// The parent forks a child which forks a grandchild — give the
	// chain ~500ms to settle.
	time.Sleep(500 * time.Millisecond)

	pgid, err := syscall.Getpgid(cmd.Process.Pid)
	if err != nil {
		t.Fatalf("Getpgid: %v", err)
	}
	pids, err := PgrepGroup(pgid)
	if err != nil {
		t.Fatalf("PgrepGroup: %v", err)
	}
	sort.Ints(pids)
	if len(pids) != 3 {
		t.Fatalf("expected 3 pids in group %d (parent+child+grandchild), got %d: %v",
			pgid, len(pids), pids)
	}
}

func TestHelper_ForkGrandchild_GroupKillTerminatesAll(t *testing.T) {
	cmd := SpawnHelper(t, "fork-grandchild")
	time.Sleep(500 * time.Millisecond)

	pgid, err := syscall.Getpgid(cmd.Process.Pid)
	if err != nil {
		t.Fatalf("Getpgid: %v", err)
	}
	beforePids, _ := PgrepGroup(pgid)
	if len(beforePids) != 3 {
		t.Fatalf("setup: expected 3 pids before kill, got %v", beforePids)
	}

	if err := syscall.Kill(-pgid, syscall.SIGTERM); err != nil {
		t.Fatalf("kill group: %v", err)
	}
	// Reap the parent helper — until we Wait() it stays as a zombie
	// and `kill -0 -pgid` reports the group as alive even though all
	// three processes have exited.  The deepstar binary will do the
	// equivalent reaping for §10.2; here in helper-land we have to do
	// it ourselves.
	_, _ = cmd.Process.Wait()
	if err := WaitForGone(pgid, 2*time.Second); err != nil {
		t.Fatalf("group did not die in 2s: %v", err)
	}
	afterPids, _ := PgrepGroup(pgid)
	if len(afterPids) != 0 {
		t.Fatalf("after group SIGTERM expected no surviving pids, got %v", afterPids)
	}
}

func TestHelper_SlowBinder_DelaysThenBinds(t *testing.T) {
	port := FreePort(t)
	start := time.Now()
	SpawnHelper(t, "slow-binder",
		"--port", strconv.Itoa(port),
		"--delay", "1s",
	)
	// At 200ms the port should not yet be bound.
	time.Sleep(200 * time.Millisecond)
	if l, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port)); err == nil {
		_ = l.Close()
	} else {
		t.Fatalf("port %d already bound at t=200ms — slow-binder didn't delay", port)
	}
	// At delay+grace it should be bound.
	WaitForPortBound(t, port, 3*time.Second)
	if elapsed := time.Since(start); elapsed < 900*time.Millisecond {
		t.Fatalf("slow-binder bound too soon: elapsed %s", elapsed)
	}
}

// TestHelper_HelperBinariesExist is a meta-test ensuring `make helpers`
// has been run before the suite.  Avoids a confusing flood of failures
// when the bin/ directory is missing.
func TestHelper_HelperBinariesExist(t *testing.T) {
	for _, name := range []string{"sleep-and-bind", "fork-grandchild", "slow-binder"} {
		p := filepath.Join(RepoRoot(t), "bin", name)
		if _, err := os.Stat(p); err != nil {
			t.Errorf("helper %q missing at %s: %v", name, p, err)
		}
	}
}
