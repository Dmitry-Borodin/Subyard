package migration

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/contracttest"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestCheckValidatesExistingStoresWithoutCreatingMissingOnes(t *testing.T) {
	root := t.TempDir()
	existing := filepath.Join(root, "projects")
	store, err := state.NewFileStore(existing)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), contracttest.ProjectRecord("migration-a")); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(root, "missing")
	report, err := Check(context.Background(), []string{missing, existing}, &testkit.CredentialStore{})
	if err != nil {
		t.Fatal(err)
	}
	if report.ProjectStoresValidated != 1 || report.Changed || report.ProjectStateSchema != 1 {
		t.Fatalf("unexpected migration report: %#v", report)
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("migration check created a missing store")
	}
}

func TestApplyRepairsLegacyProjectPermissions(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "projects")
	store, err := state.NewFileStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), contracttest.ProjectRecord("legacy-a")); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "legacy-a.json")
	if err := os.Chmod(path, 0o664); err != nil {
		t.Fatal(err)
	}
	if _, err := Check(context.Background(), []string{directory}, nil); err == nil {
		t.Fatal("check accepted legacy broad permissions without applying migration")
	}
	report, err := Apply(context.Background(), []string{directory}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Changed || report.ProjectStoresValidated != 1 {
		t.Fatalf("unexpected apply report: %#v", report)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("applied state mode = %o, want 600", info.Mode().Perm())
	}
}
