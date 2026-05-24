// Package identity computes and compares the (pgid, lstart,
// command_fingerprint) triple that uniquely identifies a managed
// process per SPEC §3.1.  PID alone is never sufficient — recycled
// PIDs (the loginwindow case) require the triple to detect.
package identity

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

// Triple is the canonical identity for a managed process.
// Construct via Capture; compare with Equal.
type Triple struct {
	Pgid               int    `json:"pgid"`
	Lstart             string `json:"lstart"`
	CommandFingerprint string `json:"command_fingerprint"`
}

// Equal is byte-equal across all three fields.  No fuzzy matching:
// SPEC §3.1 forbids fallback paths that accept partial matches.
func (a Triple) Equal(b Triple) bool {
	return a.Pgid == b.Pgid && a.Lstart == b.Lstart && a.CommandFingerprint == b.CommandFingerprint
}

// Capture returns the identity of the running process group `pgid`,
// using `cmd` to compute the fingerprint.  Returns an error if the
// process can't be read (e.g. already exited).
func Capture(pgid int, cmd []string) (Triple, error) {
	lstart, err := ReadLstart(pgid)
	if err != nil {
		return Triple{}, err
	}
	return Triple{
		Pgid:               pgid,
		Lstart:             lstart,
		CommandFingerprint: Fingerprint(cmd),
	}, nil
}

// ReadLstart shells out to `ps -o lstart= -p <pid>` and returns the
// raw string (e.g. "Sat May 24 09:14:32 2026").  Byte-equal comparison
// is the only comparison v2 ever does — formatting and timezone come
// from ps consistently within a boot.
//
// Returns ESRCH-equivalent (via "process not found") if the PID is
// dead by the time we read.
func ReadLstart(pid int) (string, error) {
	out, err := exec.Command("ps", "-o", "lstart=", "-p", fmt.Sprintf("%d", pid)).Output()
	if err != nil {
		return "", fmt.Errorf("ps lstart pid=%d: %w", pid, err)
	}
	s := strings.TrimSpace(string(out))
	if s == "" {
		return "", fmt.Errorf("ps lstart pid=%d: empty (process gone)", pid)
	}
	return s, nil
}

// Fingerprint computes SHA-256 of the argv with NUL separators.
// Stable across runs given the same exact argv.
func Fingerprint(argv []string) string {
	h := sha256.New()
	for i, a := range argv {
		if i > 0 {
			h.Write([]byte{0})
		}
		h.Write([]byte(a))
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil))
}

// GroupAlive reports whether any process in process group `pgid` is
// alive on the system.  Implemented via kill(0) to -pgid.
func GroupAlive(pgid int) bool {
	if pgid <= 1 {
		return false
	}
	err := syscall.Kill(-pgid, 0)
	if err == nil {
		return true
	}
	return err == syscall.EPERM // exists but not ours — still "alive"
}
