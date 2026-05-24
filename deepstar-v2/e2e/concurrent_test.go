// §10.9 — Concurrent invocations are serialised by a file lock.
//
// Fixture: kick off two `deepstar up` invocations simultaneously
// against a slow-binder service.  The first acquires the lock and
// processes through to completion; the second sees EWOULDBLOCK on
// `flock` and exits with code 4.
//
// Covers SPEC §10.9 (v1 raced without protection).
package e2e

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

type upResult struct {
	out string
	err error
}

func TestSpec_10_9_ConcurrentUpSerialised(t *testing.T) {
	DeepstarBinary(t)
	RequireSubcommand(t, "up")
	RequireSubcommand(t, "down")

	scratch := t.TempDir()
	port := FreePort(t)
	slow := HelperPath(t, "slow-binder")

	// A service that takes ~2s to bind keeps the first up holding
	// the lock long enough for the second up to race.
	cfg := WriteServices(t, scratch, []Service{{
		Name:            "slowpoke",
		Tier:            1,
		Cwd:             "/tmp",
		Cmd:             []string{slow, "--port", strconv.Itoa(port), "--delay", "2s"},
		Port:            port,
		PortKind:        "tcp",
		HealthTimeoutMs: 5000,
	}})
	t.Cleanup(func() { _, _ = Run(t, scratch, cfg, "down") })

	results := make(chan upResult, 2)
	for range 2 {
		go func() {
			out, err := Run(t, scratch, cfg, "up")
			results <- upResult{out, err}
		}()
		time.Sleep(50 * time.Millisecond) // brief stagger so they don't both ENOENT the same lock
	}
	r1 := <-results
	r2 := <-results

	exits := []int{ExitCode(r1.err), ExitCode(r2.err)}
	// Exactly one should be 0 (winner), one should be 4 (concurrent).
	winners := 0
	losers := 0
	for _, e := range exits {
		switch e {
		case 0:
			winners++
		case 4:
			losers++
		}
	}
	if winners != 1 || losers != 1 {
		t.Fatalf("expected one winner (exit 0) + one concurrent-loss (exit 4); got exits %v\noutputs:\n[1] %s\n[2] %s",
			exits, r1.out, r2.out)
	}

	// The losing invocation's output should explain itself.
	loser := r1
	if ExitCode(r1.err) == 0 {
		loser = r2
	}
	if !strings.Contains(strings.ToLower(loser.out), "another instance") {
		t.Errorf("loser output should explain the concurrent collision:\n%s", loser.out)
	}
}
