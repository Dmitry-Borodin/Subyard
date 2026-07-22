package releaseruntime

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

func TestPrepareValidatesOptionsAndKeepsChecksMutating(t *testing.T) {
	home := t.TempDir()
	var output bytes.Buffer
	release := New(Config{Environment: map[string]string{"HOME": home}, Stdout: &output})

	help, err := release.Prepare(context.Background(), []string{"--help"})
	if err != nil || help.Effect != domain.CommandRead || help.Execute(context.Background()) != nil ||
		!strings.Contains(output.String(), "Usage: yard update") {
		t.Fatalf("invalid help operation: %#v, %q, %v", help, output.String(), err)
	}
	check, err := release.Prepare(context.Background(), []string{"--version", "1.2.3", "--check"})
	if err != nil || check.Effect != domain.CommandMutate {
		t.Fatalf("update check can write its cache and must stay mutating: %#v, %v", check, err)
	}
	for _, arguments := range [][]string{
		{"--offline"},
		{"--runtime-root", "relative", "--version", "1"},
		{"--version", "bad/version"},
		{"--rollback", "--check"},
		{"--channel", "edge", "--version", "1"},
	} {
		if _, err := release.Prepare(context.Background(), arguments); err == nil {
			t.Fatalf("invalid arguments were accepted: %q", arguments)
		}
	}
	if err := (Prepared{}).Execute(context.Background()); err == nil {
		t.Fatal("empty prepared release operation was executable")
	}
}

func TestExecuteDownloadsAssetsAndPassesValidatedEnvironment(t *testing.T) {
	if runtime.GOOS != "linux" || runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		t.Skip("release runtime supports Linux amd64/arm64")
	}
	root := t.TempDir()
	assets := filepath.Join(root, "assets")
	cache := filepath.Join(root, "cache")
	runtimeRoot := filepath.Join(root, "runtime")
	if err := os.MkdirAll(assets, 0o700); err != nil {
		t.Fatal(err)
	}
	name := "subyard-1.2.3-linux-" + runtime.GOARCH + ".tar.gz"
	for _, suffix := range []string{"", ".sha256", ".manifest.json", ".provenance.json"} {
		if err := os.WriteFile(filepath.Join(assets, name+suffix), []byte("fixture"+suffix), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	capture := filepath.Join(root, "installer.args")
	installer := filepath.Join(root, "installer.sh")
	if err := os.WriteFile(installer, []byte("#!/bin/sh\nset -eu\n[ \"$RELEASE_SENTINEL\" = fixture ]\nprintf '%s\\n' \"$@\" > \"$RELEASE_CAPTURE\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELEASE_SENTINEL", "ambient-must-not-leak")
	var output bytes.Buffer
	release := New(Config{
		Environment: map[string]string{
			"HOME": root, "SUBYARD_HOME": root, "YARD_RELEASE_BASE_URL": "file://" + assets,
			"YARD_RELEASE_CACHE": cache, "RELEASE_SENTINEL": "fixture", "RELEASE_CAPTURE": capture,
		},
		Installer: installer, Stdout: &output, Stderr: &output,
	})
	prepared, err := release.Prepare(context.Background(), []string{
		"--runtime-root", runtimeRoot, "--version", "1.2.3", "--check",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := prepared.Execute(context.Background()); err != nil {
		t.Fatalf("execute release: %v (%s)", err, output.String())
	}
	arguments, err := os.ReadFile(capture)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Fields(string(arguments))
	for _, required := range []string{"--runtime-root", runtimeRoot, "--check"} {
		if !slices.Contains(lines, required) {
			t.Fatalf("installer arguments omit %q: %q", required, lines)
		}
	}
	for _, suffix := range []string{"", ".sha256", ".manifest.json", ".provenance.json"} {
		path := filepath.Join(cache, "1.2.3", name+suffix)
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("cached asset is missing or unsafe: %s (%v)", path, err)
		}
	}
	if !strings.Contains(output.String(), "available=1.2.3") {
		t.Fatalf("release status was not reported: %q", output.String())
	}
}
