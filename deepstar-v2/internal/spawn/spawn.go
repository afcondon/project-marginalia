// Package spawn forks managed services as process group leaders and
// waits for their port/socket to become reachable.  SPEC §3.1
// (Setpgid identity) and §3.4 (per-service health timeout).
package spawn

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/afcondon/deepstar-v2/internal/identity"
	"github.com/afcondon/deepstar-v2/internal/registry"
)

// DefaultLogDir is where per-service logs are appended.  Honors
// $DEEPSTAR_LOG_DIR for test isolation, else /tmp/deepstar (matching
// v1's path per SPEC §2.7).
func DefaultLogDir() string {
	if d := os.Getenv("DEEPSTAR_LOG_DIR"); d != "" {
		return d
	}
	return "/tmp/deepstar"
}

// Result is what Service returns on a successful spawn.
type Result struct {
	Pgid     int
	Identity identity.Triple
	Cmd      *exec.Cmd // for the caller to optionally Wait or signal
}

// Service forks the given service in a fresh process group, waits up
// to its health_timeout for the port/socket to be bound, then returns
// the captured identity triple.
//
// On failure (process exits early, timeout fires) the function tries
// to kill anything it spawned and returns an error describing the
// failure mode.
func Service(svc registry.Service) (*Result, error) {
	if len(svc.Cmd) == 0 {
		return nil, fmt.Errorf("service %q: empty cmd", svc.Name)
	}

	cmd := exec.Command(svc.Cmd[0], svc.Cmd[1:]...)
	cmd.Dir = svc.Cwd
	cmd.Env = buildEnv(svc.Env)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	logf, err := openLog(svc.Name)
	if err != nil {
		return nil, fmt.Errorf("service %q: %w", svc.Name, err)
	}
	cmd.Stdout = logf
	cmd.Stderr = logf

	if err := cmd.Start(); err != nil {
		_ = logf.Close()
		return nil, fmt.Errorf("service %q: start: %w", svc.Name, err)
	}
	// We can close the log fd in the parent — the child has its own
	// duplicate via stdout/stderr.
	_ = logf.Close()

	pgid := cmd.Process.Pid // Setpgid:true → pgid == leader pid

	timeout := time.Duration(svc.HealthTimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	if err := waitForReady(cmd, svc, timeout); err != nil {
		// Best-effort kill the group; ignore error.
		_ = syscall.Kill(-pgid, syscall.SIGTERM)
		return nil, fmt.Errorf("service %q: %w", svc.Name, err)
	}

	triple, err := identity.Capture(pgid, svc.Cmd)
	if err != nil {
		_ = syscall.Kill(-pgid, syscall.SIGTERM)
		return nil, fmt.Errorf("service %q: capture identity: %w", svc.Name, err)
	}

	return &Result{Pgid: pgid, Identity: triple, Cmd: cmd}, nil
}

func buildEnv(overlay map[string]string) []string {
	env := os.Environ()
	for k, v := range overlay {
		env = append(env, k+"="+v)
	}
	return env
}

func openLog(name string) (*os.File, error) {
	dir := DefaultLogDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir log dir %s: %w", dir, err)
	}
	path := filepath.Join(dir, name+".log")
	return os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
}

// waitForReady polls until (a) the service has bound its port/socket
// or (b) the process has exited (failure) or (c) timeout fires.
func waitForReady(cmd *exec.Cmd, svc registry.Service, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()

	for time.Now().Before(deadline) {
		select {
		case err := <-exited:
			return fmt.Errorf("process exited before binding: %v", err)
		default:
		}
		if isBound(svc) {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}

	// One last check at the deadline.
	if isBound(svc) {
		return nil
	}
	return fmt.Errorf("timeout: %s did not bind after %s", endpointLabel(svc), timeout)
}

// isBound returns true if a probe of the service's endpoint succeeds.
// TCP and unix-socket probes connect to the endpoint; UDP tries to
// bind it ourselves — if the bind fails, someone (ideally the service)
// is holding the port.
func isBound(svc registry.Service) bool {
	switch svc.PortKind {
	case "tcp":
		c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", svc.Port), 200*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return true
		}
		return false
	case "udp":
		addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("127.0.0.1:%d", svc.Port))
		if err != nil {
			return false
		}
		l, err := net.ListenUDP("udp", addr)
		if err != nil {
			// Can't bind → someone holds it.  Assume it's our service.
			return errors.Is(err, syscall.EADDRINUSE)
		}
		_ = l.Close()
		return false
	case "unix":
		c, err := net.DialTimeout("unix", svc.SocketPath, 200*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return true
		}
		return false
	}
	return false
}

func endpointLabel(svc registry.Service) string {
	switch svc.PortKind {
	case "unix":
		return "unix:" + svc.SocketPath
	default:
		return fmt.Sprintf("%s:%d", svc.PortKind, svc.Port)
	}
}
