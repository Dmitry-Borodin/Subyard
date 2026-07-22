package config

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

// YardNames returns the configured yard names without evaluating their files.
// The default context is always first; duplicate private/user entries collapse.
func YardNames(directories ...string) ([]string, error) {
	seen := map[string]struct{}{"default": {}}
	names := []string{"default"}
	var discovered []string
	for _, directory := range directories {
		entries, err := os.ReadDir(directory)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".env") {
				continue
			}
			name := strings.TrimSuffix(entry.Name(), ".env")
			if !domain.SafeName(name) {
				continue
			}
			if _, exists := seen[name]; exists {
				continue
			}
			seen[name] = struct{}{}
			discovered = append(discovered, name)
		}
	}
	sort.Strings(discovered)
	return append(names, discovered...), nil
}

func RegistryDirectories(configDir, configHome string) []string {
	return []string{
		filepath.Join(configDir, "..", "private", "yards"),
		filepath.Join(configHome, "yards"),
	}
}
