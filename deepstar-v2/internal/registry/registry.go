// Package registry reads, parses, and validates the DeepStar
// services.toml file (SPEC §6).  A constructed *Registry is
// guaranteed to satisfy every rule in SPEC §6.3 — downstream
// callers don't need to re-validate.
package registry

import (
	"fmt"
	"os"

	"github.com/BurntSushi/toml"
)

// Service is the in-memory shape of one [[service]] block in
// services.toml.  Field tags mirror SPEC §6.2 verbatim.
type Service struct {
	Name            string            `toml:"name"`
	Tier            int               `toml:"tier"`
	Cwd             string            `toml:"cwd"`
	Cmd             []string          `toml:"cmd"`
	Port            int               `toml:"port"`
	SocketPath      string            `toml:"socket_path"`
	PortKind        string            `toml:"port_kind"`
	HealthTimeoutMs int               `toml:"health_timeout_ms"`
	OnFailure       string            `toml:"on_failure"`
	Deps            []string          `toml:"deps"`
	SourcePaths     []string          `toml:"source_paths"`
	// SourceExcludePaths suppresses staleness findings for files
	// matching any of these globs.  Use for modules whose mtime is
	// deliberately allowed to post-date the process start — i.e.
	// hot-loadable per-cell wrappers like purerl-tidal's
	// `calypso_generated_session@ps.beam`, which is rewritten on
	// every fire-typeful and reloaded into the running BEAM via the
	// `reload-baseline` WS verb.  Without this, every fire-typeful
	// would flip the service to `stale-source` in `status`.
	SourceExcludePaths []string       `toml:"source_exclude_paths"`
	Description     string            `toml:"description"`
	Env             map[string]string `toml:"env"`
}

// Registry is the validated, fully-loaded service registry.
// Construct via LoadFile or Load; both run the SPEC §6.3 validation
// suite before returning a non-nil registry.
type Registry struct {
	Services []Service
	byName   map[string]int // name → index into Services
}

// LoadFile reads the TOML registry at path and validates it.
// Returns a non-nil Registry only on success.
func LoadFile(path string) (*Registry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read registry %s: %w", path, err)
	}
	return Load(data)
}

// Load parses and validates a TOML registry from raw bytes.  Used
// by tests; LoadFile defers to it.
func Load(data []byte) (*Registry, error) {
	type wrapper struct {
		Service []Service `toml:"service"`
	}
	var w wrapper
	meta, err := toml.Decode(string(data), &w)
	if err != nil {
		// BurntSushi/toml returns errors with line/column info via
		// its ParseError type; %v preserves that.
		return nil, fmt.Errorf("parse error: %v", err)
	}

	// Strict mode: reject unknown keys so typos like
	// `on_faliure = "warn"` surface as errors instead of silent
	// no-ops.
	if undecoded := meta.Undecoded(); len(undecoded) > 0 {
		return nil, fmt.Errorf("unknown key(s): %v", undecoded)
	}

	r := &Registry{
		Services: w.Service,
		byName:   make(map[string]int, len(w.Service)),
	}

	if err := r.validate(); err != nil {
		return nil, err
	}
	return r, nil
}

// ByName returns a pointer into r.Services for the named entry, or
// nil if no such service exists.
func (r *Registry) ByName(name string) *Service {
	idx, ok := r.byName[name]
	if !ok {
		return nil
	}
	return &r.Services[idx]
}

// Names returns every registered service name in declaration order.
func (r *Registry) Names() []string {
	out := make([]string, len(r.Services))
	for i, s := range r.Services {
		out[i] = s.Name
	}
	return out
}
