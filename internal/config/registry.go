package config

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
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
			if !domainSafeName(name) {
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

func RegistryDirectories(repositoryRoot, configHome string) []string {
	return []string{
		filepath.Join(repositoryRoot, "private", "yards"),
		filepath.Join(configHome, "yards"),
	}
}

func domainSafeName(value string) bool {
	if value == "" || !((value[0] >= 'a' && value[0] <= 'z') || (value[0] >= '0' && value[0] <= '9')) {
		return false
	}
	for _, char := range value {
		if !(char >= 'a' && char <= 'z') && !(char >= '0' && char <= '9') && char != '_' && char != '-' {
			return false
		}
	}
	return true
}
