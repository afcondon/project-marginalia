package registry

import "fmt"

// Tier returns every service with Tier <= maxTier in dependency
// order.  Stable: services at the same dep depth come out in
// declaration order — matches v1's `services_in_tier`.
//
// Returns an error if the registry contains a dep cycle (which
// validate() should have caught — defence in depth here).
func (r *Registry) Tier(maxTier int) ([]Service, error) {
	selected := make(map[string]bool)
	for _, s := range r.Services {
		if s.Tier <= maxTier {
			selected[s.Name] = true
		}
	}

	started := make(map[string]bool)
	out := make([]Service, 0, len(selected))

	// Kahn-style: repeatedly pick services whose deps are all started
	// (or out of selection).  Preserves declaration order at each
	// depth band.
	remaining := len(selected)
	for remaining > 0 {
		progress := false
		for _, s := range r.Services {
			if !selected[s.Name] || started[s.Name] {
				continue
			}
			ready := true
			for _, dep := range s.Deps {
				if selected[dep] && !started[dep] {
					ready = false
					break
				}
			}
			if ready {
				out = append(out, s)
				started[s.Name] = true
				remaining--
				progress = true
			}
		}
		if !progress {
			return nil, fmt.Errorf("dep cycle among remaining: %v",
				remainingNames(r, selected, started))
		}
	}
	return out, nil
}

func remainingNames(r *Registry, selected, started map[string]bool) []string {
	var out []string
	for _, s := range r.Services {
		if selected[s.Name] && !started[s.Name] {
			out = append(out, s.Name)
		}
	}
	return out
}

// DependentsOf returns transitive dependents of svcName in
// declaration order.  Used by `restart` to know what to cycle.
func (r *Registry) DependentsOf(svcName string) []string {
	seen := make(map[string]bool)
	var out []string
	var visit func(name string)
	visit = func(name string) {
		for _, s := range r.Services {
			for _, dep := range s.Deps {
				if dep == name && !seen[s.Name] {
					seen[s.Name] = true
					out = append(out, s.Name)
					visit(s.Name)
				}
			}
		}
	}
	visit(svcName)
	return out
}
