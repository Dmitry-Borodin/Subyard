package resource

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadRepositoryResources(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	registry, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	definitions := registry.Definitions()
	if len(definitions) == 0 {
		t.Fatal("repository resources were not found")
	}
	for _, definition := range definitions {
		if _, ok := registry.Lookup(definition.Command); !ok {
			t.Fatalf("resource command is not indexed: %s", definition.Command)
		}
	}
}

func TestLoadRejectsEscapingHandler(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "config", "profiles", "profile", "resources")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	content := "HANDLER=../../../../escape\nTITLE=x\nVERBS=up down\n"
	if err := os.WriteFile(filepath.Join(directory, "service.res"), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(root); err == nil {
		t.Fatal("escaping resource handler was accepted")
	}
}
