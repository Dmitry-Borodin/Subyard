package statusruntime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

func TestRuntimeAcceptsOnlyStructuredProbeOutput(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "scripts", "status-probe.sh")
	if err := os.WriteFile(path, []byte(`#!/bin/sh
printf '%s\n' '{"shared":[{"profile":"android","name":"emulator","state":"up"}],"security":"live","space":"1G"}'
`), 0o700); err != nil {
		t.Fatal(err)
	}
	facts, err := (Runtime{RepositoryRoot: root, Environment: map[string]string{"PATH": "/usr/bin:/bin"}}).
		ReadStatusFacts(context.Background(), domain.Context{}, true)
	if err != nil || len(facts.Shared) != 1 || facts.Security != "live" || facts.Space != "1G" {
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
