// Package state owns ~/.deepstar/state.json (SPEC §7).  All writes
// go through Save which is atomic via temp+rename so a crash mid-
// write leaves the previous good state on disk.
package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/afcondon/deepstar-v2/internal/identity"
)

// CurrentVersion is the state.json schema version v2 emits.  Reading
// a file with a different version is a hard error per SPEC §7.5 —
// never guess at migrations.
const CurrentVersion = 1

// Entry is the per-service shape recorded after a successful spawn.
// Mirrors SPEC §7.2.
type Entry struct {
	Pgid               int               `json:"pgid"`
	Lstart             string            `json:"lstart"`
	CommandFingerprint string            `json:"command_fingerprint"`
	SpawnedAt          string            `json:"spawned_at"`
	SpawnArgv          []string          `json:"spawn_argv"`
	SpawnCwd           string            `json:"spawn_cwd"`
	SpawnEnvOverlay    map[string]string `json:"spawn_env_overlay"`
}

// Triple extracts the identity triple from an Entry.  Convenience
// for callers that want to compare against a live process.
func (e Entry) Triple() identity.Triple {
	return identity.Triple{
		Pgid:               e.Pgid,
		Lstart:             e.Lstart,
		CommandFingerprint: e.CommandFingerprint,
	}
}

// File is the on-disk shape of state.json — single map keyed by
// service name plus a schema version.
type File struct {
	Services map[string]Entry `json:"services"`
	Version  int              `json:"version"`
}

// New returns a fresh, empty File at the current schema version.
func New() *File {
	return &File{
		Services: make(map[string]Entry),
		Version:  CurrentVersion,
	}
}

// Load reads and parses state.json at path.  Returns New() if the
// file doesn't exist (first-run case).  Returns an error if the file
// exists but is malformed or has an unexpected schema version.
func Load(path string) (*File, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return New(), nil
		}
		return nil, fmt.Errorf("read state %s: %w", path, err)
	}
	var f File
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("parse state %s: %w", path, err)
	}
	if f.Version != CurrentVersion {
		return nil, fmt.Errorf("state schema mismatch: file version %d, expected %d", f.Version, CurrentVersion)
	}
	if f.Services == nil {
		f.Services = make(map[string]Entry)
	}
	return &f, nil
}

// Save writes f to path atomically: temp file + rename, so a crash
// mid-write leaves the previous good state in place.
func (f *File) Save(path string) error {
	if f.Version == 0 {
		f.Version = CurrentVersion
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir state dir: %w", err)
	}
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal state: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write state tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("rename state tmp → path: %w", err)
	}
	return nil
}

// Set installs or replaces the entry for the named service.
func (f *File) Set(name string, e Entry) {
	if f.Services == nil {
		f.Services = make(map[string]Entry)
	}
	f.Services[name] = e
}

// Get returns the entry for the named service and whether one exists.
func (f *File) Get(name string) (Entry, bool) {
	e, ok := f.Services[name]
	return e, ok
}

// Delete removes the named service's entry, if present.
func (f *File) Delete(name string) {
	delete(f.Services, name)
}
