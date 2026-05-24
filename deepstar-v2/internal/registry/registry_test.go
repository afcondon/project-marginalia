package registry

import (
	"errors"
	"strings"
	"testing"
)

// minimalValid returns a TOML string with one valid service.  Used as
// a baseline by tests that mutate one field at a time.
func minimalValid(extra string) string {
	return `[[service]]
name      = "alpha"
tier      = 1
cwd       = "/tmp"
cmd       = ["true"]
port      = 31001
port_kind = "tcp"
` + extra
}

func TestLoad_MinimalValid(t *testing.T) {
	r, err := Load([]byte(minimalValid("")))
	if err != nil {
		t.Fatalf("expected valid registry, got error: %v", err)
	}
	if len(r.Services) != 1 || r.Services[0].Name != "alpha" {
		t.Fatalf("unexpected services: %+v", r.Services)
	}
	if r.ByName("alpha") == nil {
		t.Fatal("ByName(alpha) returned nil for the only service")
	}
}

func TestLoad_DuplicateNamesRejected(t *testing.T) {
	src := `
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
`
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "name" || !strings.Contains(ve.Reason, "duplicate") {
		t.Errorf("expected duplicate-name error, got %v", ve)
	}
}

func TestLoad_TcpWithoutPortRejected(t *testing.T) {
	src := `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port_kind = "tcp"
`
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "port" {
		t.Errorf("expected port field, got %q", ve.Field)
	}
}

func TestLoad_UnixWithoutSocketPathRejected(t *testing.T) {
	src := `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port_kind = "unix"
`
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "socket_path" {
		t.Errorf("expected socket_path field, got %q", ve.Field)
	}
}

func TestLoad_PortAndSocketPathBothSetRejected(t *testing.T) {
	src := `
[[service]]
name        = "alpha"
tier        = 1
cwd         = "/tmp"
cmd         = ["true"]
port        = 31001
socket_path = "/tmp/x.sock"
port_kind   = "tcp"
`
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "socket_path" {
		t.Errorf("expected socket_path field, got %q", ve.Field)
	}
}

func TestLoad_RelativeCwdRejected(t *testing.T) {
	src := minimalValid("")
	src = strings.Replace(src, `cwd       = "/tmp"`, `cwd       = "relative/path"`, 1)
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "cwd" || !strings.Contains(ve.Reason, "absolute") {
		t.Errorf("expected cwd-must-be-absolute error, got %v", ve)
	}
}

func TestLoad_NonexistentCwdRejected(t *testing.T) {
	src := minimalValid("")
	src = strings.Replace(src, `cwd       = "/tmp"`, `cwd       = "/nonexistent-path-deepstar-v2-test"`, 1)
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "cwd" {
		t.Errorf("expected cwd field, got %q", ve.Field)
	}
}

func TestLoad_EmptyCmdRejected(t *testing.T) {
	src := minimalValid("")
	src = strings.Replace(src, `cmd       = ["true"]`, `cmd       = []`, 1)
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "cmd" {
		t.Errorf("expected cmd field, got %q", ve.Field)
	}
}

func TestLoad_MissingDepRejected(t *testing.T) {
	src := `
[[service]]
name = "alpha"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 31001
port_kind = "tcp"
deps = ["nope"]
`
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "deps" || !strings.Contains(ve.Reason, "unknown") {
		t.Errorf("expected unknown-dep error, got %v", ve)
	}
}

func TestLoad_DepCycleRejected(t *testing.T) {
	src := `
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
`
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if !strings.Contains(ve.Reason, "cycle") {
		t.Errorf("expected cycle error, got %v", ve)
	}
}

func TestLoad_InvalidOnFailureRejected(t *testing.T) {
	src := minimalValid(`on_failure = "explode"
`)
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "on_failure" {
		t.Errorf("expected on_failure field, got %q", ve.Field)
	}
}

func TestLoad_InvalidTierRejected(t *testing.T) {
	src := strings.Replace(minimalValid(""), `tier      = 1`, `tier      = 0`, 1)
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "tier" {
		t.Errorf("expected tier field, got %q", ve.Field)
	}
}

func TestLoad_NegativeTimeoutRejected(t *testing.T) {
	src := minimalValid(`health_timeout_ms = -1
`)
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "health_timeout_ms" {
		t.Errorf("expected health_timeout_ms field, got %q", ve.Field)
	}
}

func TestLoad_InvalidPortKindRejected(t *testing.T) {
	src := minimalValid("")
	src = strings.Replace(src, `port_kind = "tcp"`, `port_kind = "carrier-pigeon"`, 1)
	_, err := Load([]byte(src))
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError, got %v", err)
	}
	if ve.Field != "port_kind" {
		t.Errorf("expected port_kind field, got %q", ve.Field)
	}
}

func TestLoad_UnknownKeyRejected(t *testing.T) {
	src := minimalValid(`on_faliure = "warn"
`) // misspelling
	_, err := Load([]byte(src))
	if err == nil {
		t.Fatal("expected error for unknown key, got nil")
	}
	if !strings.Contains(err.Error(), "unknown key") {
		t.Errorf("expected 'unknown key' in error, got %v", err)
	}
}

func TestTier_RespectsDependencyOrder(t *testing.T) {
	src := `
[[service]]
name = "calypso-frontend"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 3061
port_kind = "tcp"
deps = ["calypso-server"]

[[service]]
name = "calypso-server"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 3060
port_kind = "tcp"
deps = ["purerl-tidal"]

[[service]]
name = "purerl-tidal"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 3012
port_kind = "tcp"
deps = []
`
	r, err := Load([]byte(src))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	order, err := r.Tier(1)
	if err != nil {
		t.Fatalf("Tier: %v", err)
	}
	want := []string{"purerl-tidal", "calypso-server", "calypso-frontend"}
	if len(order) != len(want) {
		t.Fatalf("expected %d services, got %d: %+v", len(want), len(order), order)
	}
	for i, w := range want {
		if order[i].Name != w {
			t.Errorf("position %d: want %q got %q", i, w, order[i].Name)
		}
	}
}

func TestTier_FiltersByTier(t *testing.T) {
	src := `
[[service]]
name = "tier1-svc"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 30001
port_kind = "tcp"

[[service]]
name = "tier4-svc"
tier = 4
cwd  = "/tmp"
cmd  = ["true"]
port = 30004
port_kind = "tcp"
`
	r, _ := Load([]byte(src))
	t1, _ := r.Tier(1)
	if len(t1) != 1 || t1[0].Name != "tier1-svc" {
		t.Errorf("Tier(1) should yield only tier1-svc, got %+v", names(t1))
	}
	t4, _ := r.Tier(4)
	if len(t4) != 2 {
		t.Errorf("Tier(4) should yield both, got %+v", names(t4))
	}
}

func TestDependentsOf_Transitive(t *testing.T) {
	src := `
[[service]]
name = "a"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 30001
port_kind = "tcp"

[[service]]
name = "b"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 30002
port_kind = "tcp"
deps = ["a"]

[[service]]
name = "c"
tier = 1
cwd  = "/tmp"
cmd  = ["true"]
port = 30003
port_kind = "tcp"
deps = ["b"]
`
	r, _ := Load([]byte(src))
	deps := r.DependentsOf("a")
	want := []string{"b", "c"}
	if len(deps) != len(want) {
		t.Fatalf("expected %v, got %v", want, deps)
	}
	for i, w := range want {
		if deps[i] != w {
			t.Errorf("position %d: want %q got %q", i, w, deps[i])
		}
	}
}

func names(svcs []Service) []string {
	out := make([]string, len(svcs))
	for i, s := range svcs {
		out[i] = s.Name
	}
	return out
}
