package registry

import (
	"fmt"
	"path/filepath"
	"strings"
)

// ValidationError describes a SPEC §6.3 rule violation.  Carries the
// offending service name (or "" for registry-wide errors) and the
// field name where applicable.
type ValidationError struct {
	Service string
	Field   string
	Reason  string
}

func (e *ValidationError) Error() string {
	switch {
	case e.Service == "" && e.Field == "":
		return "registry: " + e.Reason
	case e.Service == "":
		return fmt.Sprintf("registry: field %q: %s", e.Field, e.Reason)
	case e.Field == "":
		return fmt.Sprintf("service %q: %s", e.Service, e.Reason)
	default:
		return fmt.Sprintf("service %q: field %q: %s", e.Service, e.Field, e.Reason)
	}
}

var validPortKinds = map[string]bool{"tcp": true, "udp": true, "unix": true}
var validOnFailures = map[string]bool{"tier_abort": true, "warn": true, "retry": true}

func (r *Registry) validate() error {
	// Pass 1: structural checks per service.  Build byName as we go.
	for i, s := range r.Services {
		if s.Name == "" {
			return &ValidationError{Field: "name", Reason: fmt.Sprintf("missing on entry #%d", i)}
		}
		if _, dup := r.byName[s.Name]; dup {
			return &ValidationError{Service: s.Name, Field: "name",
				Reason: "duplicate name"}
		}
		r.byName[s.Name] = i

		if s.Tier < 1 {
			return &ValidationError{Service: s.Name, Field: "tier",
				Reason: fmt.Sprintf("must be >= 1, got %d", s.Tier)}
		}
		if s.Cwd == "" {
			return &ValidationError{Service: s.Name, Field: "cwd",
				Reason: "missing"}
		}
		if !filepath.IsAbs(s.Cwd) {
			return &ValidationError{Service: s.Name, Field: "cwd",
				Reason: fmt.Sprintf("must be absolute, got %q", s.Cwd)}
		}
		if fi, err := stat(s.Cwd); err != nil || !fi.IsDir() {
			reason := "not a directory"
			if err != nil {
				reason = err.Error()
			}
			return &ValidationError{Service: s.Name, Field: "cwd",
				Reason: fmt.Sprintf("%s (%s)", reason, s.Cwd)}
		}
		if len(s.Cmd) == 0 {
			return &ValidationError{Service: s.Name, Field: "cmd",
				Reason: "must be non-empty"}
		}

		if !validPortKinds[s.PortKind] {
			return &ValidationError{Service: s.Name, Field: "port_kind",
				Reason: fmt.Sprintf("must be one of tcp|udp|unix, got %q", s.PortKind)}
		}
		switch s.PortKind {
		case "tcp", "udp":
			if s.Port == 0 {
				return &ValidationError{Service: s.Name, Field: "port",
					Reason: fmt.Sprintf("required for port_kind=%q", s.PortKind)}
			}
			if s.SocketPath != "" {
				return &ValidationError{Service: s.Name, Field: "socket_path",
					Reason: fmt.Sprintf("must be empty for port_kind=%q (port and socket_path are mutually exclusive)", s.PortKind)}
			}
		case "unix":
			if s.SocketPath == "" {
				return &ValidationError{Service: s.Name, Field: "socket_path",
					Reason: `required for port_kind="unix"`}
			}
			if s.Port != 0 {
				return &ValidationError{Service: s.Name, Field: "port",
					Reason: `must be 0 for port_kind="unix" (port and socket_path are mutually exclusive)`}
			}
		}

		if s.HealthTimeoutMs < 0 {
			return &ValidationError{Service: s.Name, Field: "health_timeout_ms",
				Reason: fmt.Sprintf("must be >= 0, got %d", s.HealthTimeoutMs)}
		}

		// Empty on_failure is permitted; defaults to "warn" downstream.
		if s.OnFailure != "" && !validOnFailures[s.OnFailure] {
			return &ValidationError{Service: s.Name, Field: "on_failure",
				Reason: fmt.Sprintf("must be one of tier_abort|warn|retry, got %q", s.OnFailure)}
		}
	}

	// Pass 2: deps reference + cycle.  Must run after byName is built.
	for _, s := range r.Services {
		for _, dep := range s.Deps {
			if _, ok := r.byName[dep]; !ok {
				return &ValidationError{Service: s.Name, Field: "deps",
					Reason: fmt.Sprintf("references unknown service %q", dep)}
			}
		}
	}
	if cycle := r.findCycle(); cycle != nil {
		return &ValidationError{Field: "deps",
			Reason: fmt.Sprintf("dependency cycle: %s", strings.Join(cycle, " → "))}
	}

	return nil
}

// findCycle returns a cycle's nodes if any, or nil if the dep graph
// is acyclic.  DFS with white/grey/black colouring; surface the path
// containing the back edge.
func (r *Registry) findCycle() []string {
	const (
		white = 0
		grey  = 1
		black = 2
	)
	colour := make(map[string]int, len(r.Services))
	var stack []string
	var found []string

	var visit func(name string) bool
	visit = func(name string) bool {
		if colour[name] == grey {
			// back edge — extract path from stack[i] to end + name.
			for i, n := range stack {
				if n == name {
					found = append([]string{}, stack[i:]...)
					found = append(found, name)
					return true
				}
			}
			return true
		}
		if colour[name] == black {
			return false
		}
		colour[name] = grey
		stack = append(stack, name)
		s := r.ByName(name)
		if s != nil {
			for _, dep := range s.Deps {
				if visit(dep) {
					return true
				}
			}
		}
		stack = stack[:len(stack)-1]
		colour[name] = black
		return false
	}

	for _, s := range r.Services {
		if colour[s.Name] == white {
			if visit(s.Name) {
				return found
			}
		}
	}
	return nil
}
