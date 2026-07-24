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
			name := ""
			if entry.IsDir() {
				if info, statErr := os.Lstat(filepath.Join(directory, entry.Name(), "config.env")); statErr == nil && info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 {
					name = entry.Name()
				}
			} else if strings.HasSuffix(entry.Name(), ".env") {
				name = strings.TrimSuffix(entry.Name(), ".env")
			}
			if name == "" || !domain.SafeName(name) {
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

func YardFileCandidates(configDir, configHome, name string) []string {
	return []string{
		filepath.Join(configHome, "yards", name, "config.env"),
		filepath.Join(configDir, "..", "private", "yards", name+".env"),
		filepath.Join(configHome, "yards", name+".env"),
	}
}

func RegistryDirectories(configDir, configHome string) []string {
	return []string{
		filepath.Join(configDir, "..", "private", "yards"),
		filepath.Join(configHome, "yards"),
	}
}
