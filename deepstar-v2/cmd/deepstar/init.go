package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"
	"github.com/afcondon/deepstar-v2/internal/registry"
)

// runInit implements SPEC §8.8 — bootstrap a starter services.toml,
// or with --from-python, translate v1's `services.py` SERVICES dict
// into v2 TOML format.
//
// Used once during Phase 4 cutover.
func runInit(ctx *cmdContext, args []string) int {
	iFlags := flag.NewFlagSet("init", flag.ContinueOnError)
	fromPython := iFlags.String("from-python", "", "path to v1 services.py to migrate")
	force := iFlags.Bool("force", false, "overwrite an existing services.toml")
	iFlags.SetOutput(os.Stderr)
	if err := iFlags.Parse(args); err != nil {
		return exitUsage
	}

	if _, err := os.Stat(ctx.ConfigPath); err == nil && !*force {
		fmt.Fprintf(os.Stderr, "deepstar init: %s already exists; use --force to overwrite\n",
			ctx.ConfigPath)
		return exitFailure
	}

	var data []byte
	if *fromPython != "" {
		out, err := loadV1AsTOML(*fromPython)
		if err != nil {
			fmt.Fprintf(os.Stderr, "deepstar init --from-python: %v\n", err)
			return exitFailure
		}
		data = out
	} else {
		data = []byte(starterToml)
	}

	if err := os.MkdirAll(filepath.Dir(ctx.ConfigPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "deepstar init: mkdir: %v\n", err)
		return exitFailure
	}
	if err := os.WriteFile(ctx.ConfigPath, data, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "deepstar init: write: %v\n", err)
		return exitFailure
	}
	fmt.Printf("✓ wrote %s\n", ctx.ConfigPath)
	return exitOK
}

const starterToml = `# DeepStar v2 services registry — SPEC §6.
#
# Adding a new service: copy a [[service]] block, customize fields,
# run ` + "`deepstar list`" + ` to validate.  Validation rules: SPEC §6.3.

[[service]]
name              = "example"
tier              = 1
cwd               = "/tmp"
cmd               = ["true"]
port              = 12345
port_kind         = "tcp"
health_timeout_ms = 5000
on_failure        = "warn"
deps              = []
description       = "placeholder — replace with a real service"
`

// loadV1AsTOML shells out to python3, imports v1's services module,
// dumps SERVICES as JSON, and re-encodes as TOML in the v2 schema.
// Python is used because v1's services.py uses pathlib.Path and HOME
// expansion — re-implementing a Python expression parser in Go is
// strictly worse than just running Python.
func loadV1AsTOML(pyPath string) ([]byte, error) {
	abs, err := filepath.Abs(pyPath)
	if err != nil {
		return nil, fmt.Errorf("abs path: %w", err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil, fmt.Errorf("stat %s: %w", abs, err)
	}
	if info.IsDir() {
		return nil, fmt.Errorf("%s is a directory; pass services.py path", abs)
	}
	dir := filepath.Dir(abs)
	module := strings.TrimSuffix(filepath.Base(abs), filepath.Ext(abs))

	script := fmt.Sprintf(`
import sys, json
sys.path.insert(0, %q)
import %s as m
result = []
for name, svc in m.SERVICES.items():
    entry = {
        'name': name,
        'tier': svc.get('tier'),
        'cwd': str(svc.get('cwd')),
        'cmd': list(svc.get('cmd', [])),
        'port_kind': svc.get('port_kind'),
        'deps': list(svc.get('deps', [])),
        'env': dict(svc.get('env', {})),
        'description': svc.get('description', ''),
    }
    port = svc.get('port')
    if svc.get('port_kind') == 'unix':
        entry['socket_path'] = str(port)
    else:
        entry['port'] = int(port)
    result.append(entry)
print(json.dumps(result))
`, dir, module)

	out, err := exec.Command("python3", "-c", script).Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return nil, fmt.Errorf("python3 failed: %s", string(ee.Stderr))
		}
		return nil, fmt.Errorf("python3: %w", err)
	}

	type entry struct {
		Name        string            `json:"name"`
		Tier        int               `json:"tier"`
		Cwd         string            `json:"cwd"`
		Cmd         []string          `json:"cmd"`
		Port        int               `json:"port,omitempty"`
		SocketPath  string            `json:"socket_path,omitempty"`
		PortKind    string            `json:"port_kind"`
		Deps        []string          `json:"deps"`
		Env         map[string]string `json:"env"`
		Description string            `json:"description"`
	}
	var entries []entry
	if err := json.Unmarshal(out, &entries); err != nil {
		return nil, fmt.Errorf("parse python json: %w\nraw: %s", err, string(out))
	}

	// Convert to registry.Service for stable TOML encoding.  Sort by
	// tier then declaration-name so the emitted TOML is deterministic
	// across runs.
	services := make([]registry.Service, 0, len(entries))
	for _, e := range entries {
		services = append(services, registry.Service{
			Name:        e.Name,
			Tier:        e.Tier,
			Cwd:         e.Cwd,
			Cmd:         e.Cmd,
			Port:        e.Port,
			SocketPath:  e.SocketPath,
			PortKind:    e.PortKind,
			Deps:        e.Deps,
			Env:         e.Env,
			Description: e.Description,
		})
	}
	sort.SliceStable(services, func(i, j int) bool {
		if services[i].Tier != services[j].Tier {
			return services[i].Tier < services[j].Tier
		}
		return services[i].Name < services[j].Name
	})

	var buf bytes.Buffer
	buf.WriteString("# DeepStar v2 registry — migrated from " + abs + "\n\n")
	enc := toml.NewEncoder(&buf)
	if err := enc.Encode(struct {
		Service []registry.Service `toml:"service"`
	}{Service: services}); err != nil {
		return nil, fmt.Errorf("toml encode: %w", err)
	}
	return buf.Bytes(), nil
}
