package config

import (
	"os"
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

func TestYardRegistryReadsNestedAndLegacyLayouts(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "nested"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{
		filepath.Join(root, "nested", "config.env"),
		filepath.Join(root, "legacy.env"),
	} {
		if err := os.WriteFile(path, []byte("SSH_PORT=1\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := YardNames(root)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"default", "legacy", "nested"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("YardNames() = %v, want %v", got, want)
	}
}

func TestYardFileCandidatesPreferInstalledNestedLayout(t *testing.T) {
	configDir := "/runtime/config"
	configHome := "/operator/config"
	want := []string{
		"/operator/config/yards/demo/config.env",
		"/runtime/private/yards/demo.env",
		"/operator/config/yards/demo.env",
	}
	if got := YardFileCandidates(configDir, configHome, "demo"); !reflect.DeepEqual(got, want) {
		t.Fatalf("YardFileCandidates() = %v, want %v", got, want)
	}
}
