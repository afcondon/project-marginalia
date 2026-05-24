package registry

import "os"

// stat is a thin wrapper around os.Stat — extracted so tests in a
// constrained sandbox can override it if needed (currently they don't).
func stat(path string) (os.FileInfo, error) {
	return os.Stat(path)
}
