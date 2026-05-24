// Package lock provides a per-DeepStar-install file lock so two
// invocations of `up`/`down`/`verify` can't race against each other
// over state.json or the rig.  SPEC §10.9.
//
// Implementation: flock(LOCK_EX | LOCK_NB) on a lock file alongside
// state.json.  On contention, the second invocation gets ErrInUse —
// the caller surfaces "another instance in progress, pid=N" and exits
// non-zero (exit code 4 per SPEC).
package lock

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// ErrInUse is returned when another invocation holds the lock.  The
// embedded pid is best-effort: read from the lock file's contents.
type ErrInUse struct {
	Path string
	Pid  int
}

func (e *ErrInUse) Error() string {
	if e.Pid > 0 {
		return fmt.Sprintf("another instance in progress (pid=%d, lock=%s)", e.Pid, e.Path)
	}
	return fmt.Sprintf("another instance in progress (lock=%s)", e.Path)
}

// Held is a held lock; call Release to drop it.
type Held struct {
	path string
	f    *os.File
}

// Acquire attempts to flock the file at path with LOCK_EX|LOCK_NB.
// Returns ErrInUse if another process holds the lock.  The lock file
// is created on first acquire and written with the holding pid.
func Acquire(path string) (*Held, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir lock dir: %w", err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock file: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			pid, _ := readPidFromLockFile(path)
			return nil, &ErrInUse{Path: path, Pid: pid}
		}
		return nil, fmt.Errorf("flock: %w", err)
	}
	// Write our pid for diagnostic purposes.
	_ = f.Truncate(0)
	_, _ = f.WriteString(strconv.Itoa(os.Getpid()))
	_ = f.Sync()
	return &Held{path: path, f: f}, nil
}

// Release drops the flock and removes the lock file.  Idempotent.
func (h *Held) Release() error {
	if h == nil || h.f == nil {
		return nil
	}
	_ = syscall.Flock(int(h.f.Fd()), syscall.LOCK_UN)
	_ = h.f.Close()
	_ = os.Remove(h.path)
	h.f = nil
	return nil
}

func readPidFromLockFile(path string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(data)))
}
