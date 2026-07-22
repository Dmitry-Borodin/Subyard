package statusruntime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/resource"
)

func TestRuntimeAcceptsOnlyStructuredProbeOutput(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "scripts", "status-probe.sh")
	if err := os.WriteFile(path, []byte(`#!/bin/sh
printf '%s\n' '{"security":"live","space":"1G"}'
`), 0o700); err != nil {
		t.Fatal(err)
	}
	facts, err := (Runtime{RepositoryRoot: root, Environment: map[string]string{"PATH": "/usr/bin:/bin"}}).
		ReadStatusFacts(context.Background(), domain.Context{}, true)
	if err != nil || len(facts.Shared) != 0 || facts.Security != "live" || facts.Space != "1G" {
		t.Fatalf("structured status result changed: %#v err=%v", facts, err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf 'human status\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := (Runtime{RepositoryRoot: root, Environment: map[string]string{"PATH": "/usr/bin:/bin"}}).
		ReadStatusFacts(context.Background(), domain.Context{}, false); err == nil {
		t.Fatal("human shell output was accepted as status API")
	}
}

func TestRuntimeProbesPreparedResources(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "scripts", "status-probe.sh"),
		[]byte("#!/bin/sh\nprintf '%s\\n' '{\"security\":\"live\",\"space\":\"1G\"}'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	resources := filepath.Join(root, "config", "profiles", "demo", "resources")
	if err := os.MkdirAll(filepath.Join(resources, "service"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(resources, "service.res"), []byte(
		"COMMAND=svc\nHANDLER=resources/service/handler.sh\nTITLE=Service\nVERBS=up down\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := filepath.Join(resources, "service", "handler.sh")
	if err := os.WriteFile(handler, []byte("#!/bin/sh\n[ \"$1\" = is-up ]\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	registry, err := resource.Load(root)
	if err != nil {
		t.Fatal(err)
	}
	facts, err := (Runtime{
		RepositoryRoot: root, Environment: map[string]string{"PATH": "/usr/bin:/bin"},
		Resources: registry.Definitions(), Program: "yard",
	}).ReadStatusFacts(context.Background(), domain.Context{}, true)
	if err != nil || len(facts.Shared) != 1 {
		t.Fatalf("resource status failed: %#v err=%v", facts, err)
	}
	status := facts.Shared[0]
	if status.Profile != "demo" || status.Name != "service" || status.State != "up" || status.Hint != "yard svc down" {
		t.Fatalf("unexpected resource status: %#v", status)
	}
}
