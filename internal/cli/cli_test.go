package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestRepositoryQueriesUseGoManifest(t *testing.T) {
	var stdout bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: repositoryRoot(t), Program: "yard", Arguments: []string{"--command-effect", "status"},
		Environment: []string{"HOME=" + t.TempDir(), "SUBYARD_NO_AUDIT=1"}, Stdout: &stdout,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 || stdout.String() != "read\n" {
		t.Fatalf("manifest query failed: code=%d output=%q", code, stdout.String())
	}
}

func TestValidatedContextIsHandedToShellAdapterWithoutReload(t *testing.T) {
	root := t.TempDir()
	for _, directory := range []string{"config", "scripts"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	manifest := "show||show.sh||local|read|public|lifecycle|simple|show|show context||\n"
	writeCLIFile(t, filepath.Join(root, "config", "commands.registry"), manifest, 0o600)
	for _, name := range []string{"incus.project.env", "subyard.env", "host.env", "agents.env", "ports.env"} {
		writeCLIFile(t, filepath.Join(root, "config", name), "", 0o600)
	}
	writeCLIFile(t, filepath.Join(root, "scripts", "show.sh"), `#!/bin/sh
printf '%s|%s|%s\n' "$SUBYARD_CONFIG_LOADED" "$SSH_HOST" "$HOST_BASE"
`, 0o700)
	home := filepath.Join(root, "home")
	hostBase := filepath.Join(root, "host")
	environment := []string{
		"HOME=" + home, "SUBYARD_OPERATOR_HOME=" + home,
		"SUBYARD_CONFIG_HOME=" + filepath.Join(root, "state"),
		"SUBYARD_HOME=" + filepath.Join(root, "data"),
		"STORAGE_PATH=" + filepath.Join(root, "data", "storage"),
		"HOST_BASE=" + hostBase, "RESTRICTED_DISK_PATHS=" + hostBase,
		"SHIFT_MODE=shift", "FORWARD_SSH_AGENT=0", "DEV_SUDO=0", "DEV_UID=1000", "SSH_PORT=2222",
		"SUBYARD_NO_AUDIT=1",
	}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"show"}, Environment: environment,
		WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("adapter failed: code=%d stderr=%q", code, stderr.String())
	}
	if stdout.String() != "1|yard|"+hostBase+"\n" {
		t.Fatalf("validated context was not handed off: %q", stdout.String())
	}
}

func TestUnknownCommandIsDiagnosticOnly(t *testing.T) {
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: repositoryRoot(t), Program: "yard", Arguments: []string{"not-a-command"},
		Environment: []string{"HOME=" + t.TempDir(), "SUBYARD_NO_AUDIT=1"}, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 2 || !strings.Contains(stderr.String(), "unknown command") {
		t.Fatalf("unexpected diagnostic: code=%d stderr=%q", code, stderr.String())
	}
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve source path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(source), "..", ".."))
}

func writeCLIFile(t *testing.T, path, contents string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
}
