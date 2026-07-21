package config

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestRegistryDirectoriesFollowSelectedConfigRoot(t *testing.T) {
	configDir := filepath.Join(string(filepath.Separator), "fixture", "checkout", "config")
	configHome := filepath.Join(string(filepath.Separator), "fixture", "operator", "config")
	want := []string{
		filepath.Join(configDir, "..", "private", "yards"),
		filepath.Join(configHome, "yards"),
	}
	if got := RegistryDirectories(configDir, configHome); !reflect.DeepEqual(got, want) {
		t.Fatalf("RegistryDirectories() = %v, want %v", got, want)
	}
}
