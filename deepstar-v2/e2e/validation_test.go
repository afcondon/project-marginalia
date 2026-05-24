// §10.10 — Registry validation.
//
// For each kind of malformed TOML from SPEC §6.3, write the offending
// registry to a scratch services.toml and run `deepstar list`.  Assert:
//   - exit code is 2 (list-specific config error, per SPEC §10.10).
//   - stderr names the offending field, so the user can find it.
//
// Covers SPEC §6.3 (config validation rules) and the unit-test
// coverage in internal/registry/registry_test.go end-to-end through
// the binary.
package e2e

import (
	"strings"
	"testing"
)

// validationCase is one row of the §10.10 table — a malformed TOML
// and the substring that must appear in deepstar's error output.
type validationCase struct {
	name        string
	toml        string
	wantMessage string // substring expected in stderr
}

// runValidationCase: write toml to scratch, run `deepstar list`, expect
// exit 2 and the named substring in the combined output.
func runValidationCase(t *testing.T, c validationCase) {
	t.Helper()
	scratch := t.TempDir()
	cfg := WriteRawTOML(t, scratch, c.toml)
	out, err := Run(t, scratch, cfg, "list")
	if got := ExitCode(err); got != 2 {
		t.Errorf("expected exit code 2 (config error), got %d\noutput:\n%s", got, out)
	}
	if !strings.Contains(strings.ToLower(out), strings.ToLower(c.wantMessage)) {
		t.Errorf("output missing expected substring %q\noutput:\n%s", c.wantMessage, out)
	}
}

func TestList_ValidRegistry_ExitsZero(t *testing.T) {
	scratch := t.TempDir()
	cfg := WriteRawTOML(t, scratch, `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
`)
	out, err := Run(t, scratch, cfg, "list")
	if got := ExitCode(err); got != 0 {
		t.Fatalf("expected exit 0, got %d\noutput:\n%s", got, out)
	}
	if !strings.Contains(out, "alpha") {
		t.Errorf("output should mention 'alpha':\n%s", out)
	}
}

func TestSpec_10_10_DuplicateNamesRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"

[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31002
port_kind = "tcp"
`,
		wantMessage: "duplicate",
	})
}

func TestSpec_10_10_TcpWithoutPortRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port_kind = "tcp"
`,
		wantMessage: "port",
	})
}

func TestSpec_10_10_UnixWithoutSocketPathRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port_kind = "unix"
`,
		wantMessage: "socket_path",
	})
}

func TestSpec_10_10_PortAndSocketPathBothSetRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name        = "alpha"
tier        = 1
cwd         = "/tmp"
cmd         = ["true"]
port        = 31001
socket_path = "/tmp/x.sock"
port_kind   = "tcp"
`,
		wantMessage: "socket_path",
	})
}

func TestSpec_10_10_RelativeCwdRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "relative/path"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
`,
		wantMessage: "absolute",
	})
}

func TestSpec_10_10_NonexistentCwdRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/nonexistent-path-deepstar-v2-test"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
`,
		wantMessage: "cwd",
	})
}

func TestSpec_10_10_EmptyCmdRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = []
port = 31001
port_kind = "tcp"
`,
		wantMessage: "cmd",
	})
}

func TestSpec_10_10_MissingDepRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
deps = ["nonexistent"]
`,
		wantMessage: "unknown",
	})
}

func TestSpec_10_10_DepCycleRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
deps = ["bravo"]

[[service]]
name = "bravo"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31002
port_kind = "tcp"
deps = ["alpha"]
`,
		wantMessage: "cycle",
	})
}

func TestSpec_10_10_InvalidOnFailureRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
on_failure = "explode"
`,
		wantMessage: "on_failure",
	})
}

func TestSpec_10_10_InvalidTierRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 0
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
`,
		wantMessage: "tier",
	})
}

func TestSpec_10_10_NegativeTimeoutRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
health_timeout_ms = -1
`,
		wantMessage: "health_timeout_ms",
	})
}

func TestSpec_10_10_InvalidPortKindRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "carrier-pigeon"
`,
		wantMessage: "port_kind",
	})
}

func TestSpec_10_10_UnknownKeyRejected(t *testing.T) {
	runValidationCase(t, validationCase{
		toml: `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
on_faliure = "warn"
`,
		wantMessage: "unknown key",
	})
}
