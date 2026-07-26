package testyardmigration

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestApplyRecreatesCanonicalTestYardAndRemovesLegacyController(t *testing.T) {
	root := t.TempDir()
	configHome := filepath.Join(root, "config")
	dataHome := filepath.Join(root, "data")
	write(t, filepath.Join(configHome, "yards", LegacyYard, "config.env"),
		"YARD_TEMPLATE=test-vms\nSSH_PORT=2223\n")
	write(t, filepath.Join(dataHome, "e2e", "controllers", LegacyYard, ".operator-enrollment-v1"),
		"managed\n")
	log := filepath.Join(root, "calls")
	executable := fakeExecutable(t, root)

	if err := Apply(context.Background(), Options{
		Executable: executable, ConfigHome: configHome, DataHome: dataHome,
		Environment: append(os.Environ(), "MIGRATION_CALLS="+log),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(configHome, "yards", CurrentYard, "config.env")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dataHome, "e2e", "controllers", LegacyYard)); !os.IsNotExist(err) {
		t.Fatalf("legacy controller state remains: %v", err)
	}
	calls := read(t, log)
	for _, expected := range []string{
		"-Y e2e-yard check",
		"-Y e2e-yard teardown --yes",
		"-Y test-yard init --yes",
		"-Y test-yard check",
	} {
		if !strings.Contains(calls, expected+"\n") {
			t.Fatalf("calls omitted %q:\n%s", expected, calls)
		}
	}
}

func TestApplyIsNoopWithoutLegacyRegistration(t *testing.T) {
	root := t.TempDir()
	if err := Apply(context.Background(), Options{
		Executable:  fakeExecutable(t, root),
		ConfigHome:  filepath.Join(root, "config"),
		DataHome:    filepath.Join(root, "data"),
		Environment: os.Environ(),
	}); err != nil {
		t.Fatal(err)
	}
}

func TestApplyRollsBackRegistrationAndRecreatesLegacyYard(t *testing.T) {
	root := t.TempDir()
	configHome := filepath.Join(root, "config")
	dataHome := filepath.Join(root, "data")
	oldRegistration := filepath.Join(configHome, "yards", LegacyYard, "config.env")
	write(t, oldRegistration, "YARD_TEMPLATE=test-vms\n")
	oldController := filepath.Join(dataHome, "e2e", "controllers", LegacyYard,
		".operator-enrollment-v1")
	write(t, oldController, "managed\n")
	log := filepath.Join(root, "calls")
	err := Apply(context.Background(), Options{
		Executable: fakeExecutable(t, root), ConfigHome: configHome, DataHome: dataHome,
		Environment: append(os.Environ(),
			"MIGRATION_CALLS="+log,
			"MIGRATION_FAIL=test-yard:init",
		),
	})
	if err == nil || !strings.Contains(err.Error(), "initialize test-yard") {
		t.Fatalf("migration failure = %v", err)
	}
	if _, err := os.Stat(oldRegistration); err != nil {
		t.Fatalf("legacy registration was not restored: %v", err)
	}
	if _, err := os.Stat(oldController); err != nil {
		t.Fatalf("legacy controller state changed before successful migration: %v", err)
	}
	if !strings.Contains(read(t, log), "-Y e2e-yard init --yes\n") {
		t.Fatal("legacy yard was not recreated during recovery")
	}
}

func TestApplyRejectsExistingCurrentYardBeforeLifecycle(t *testing.T) {
	root := t.TempDir()
	configHome := filepath.Join(root, "config")
	write(t, filepath.Join(configHome, "yards", LegacyYard, "config.env"),
		"YARD_TEMPLATE=test-vms\n")
	write(t, filepath.Join(configHome, "yards", CurrentYard, "config.env"),
		"YARD_TEMPLATE=test-vms\n")
	log := filepath.Join(root, "calls")
	err := Apply(context.Background(), Options{
		Executable: fakeExecutable(t, root), ConfigHome: configHome,
		DataHome:    filepath.Join(root, "data"),
		Environment: append(os.Environ(), "MIGRATION_CALLS="+log),
	})
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("collision error = %v", err)
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("collision reached lifecycle commands")
	}
}

func fakeExecutable(t *testing.T, root string) string {
	t.Helper()
	path := filepath.Join(root, "yard")
	write(t, path, `#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MIGRATION_CALLS"
if [ "${MIGRATION_FAIL:-}" = "${2:-}:${3:-}" ]; then exit 1; fi
`)
	if err := os.Chmod(path, 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func write(t *testing.T, path, payload string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	payload, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(payload)
}
