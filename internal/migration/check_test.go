package migration

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/Subyard/Subyard/internal/contracttest"
	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/state"
	"github.com/Subyard/Subyard/internal/testkit"
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
	report, err := Check(
		context.Background(), []string{missing, existing}, &testkit.CredentialMetadataReader{},
	)
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

func TestCheckAndApplyLegacyProjectNameMigration(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "projects")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	records := []domain.ProjectRecord{
		{
			Schema: 1, ProjectID: "legacy-a", Name: "Demo",
			HostPath: "/workspace/one/Demo", YardPath: state.YardPath("legacy-a"),
			Mode: domain.ProjectSync, SSHHost: "yard",
			ImportedAt: "2026-01-01T00:00:00Z",
		},
		{
			Schema: 1, ProjectID: "legacy-b", Name: "demo",
			HostPath: "/workspace/two/Demo", YardPath: state.YardPath("legacy-b"),
			Mode: domain.ProjectSync, SSHHost: "yard",
			ImportedAt: "2026-02-01T00:00:00Z",
		},
	}
	for _, record := range records {
		payload, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		payload = append(payload, '\n')
		if err := os.WriteFile(
			filepath.Join(directory, record.ProjectID+".json"), payload, 0o600,
		); err != nil {
			t.Fatal(err)
		}
	}

	report, err := Check(context.Background(), []string{directory}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Pending ||
		!slices.Equal(report.RequiredMigrations, []string{projectNameMigrationID}) ||
		!slices.Equal(report.AffectedResources, []string{directory}) {
		t.Fatalf("legacy name migration was not reported: %#v", report)
	}
	firstBefore, err := os.ReadFile(filepath.Join(directory, "legacy-a.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(firstBefore) != string(appendMustMarshal(t, records[0], '\n')) {
		t.Fatal("migration check changed project state")
	}

	report, err = Apply(context.Background(), []string{directory}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Changed {
		t.Fatalf("legacy name migration was not applied: %#v", report)
	}
	store, err := state.NewFileStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.Get(context.Background(), "legacy-a")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.Get(context.Background(), "legacy-b")
	if err != nil {
		t.Fatal(err)
	}
	if first.Name != "Demo" || second.Name != "Demo-2" {
		t.Fatalf("migrated project names = %q, %q", first.Name, second.Name)
	}
	report, err = Check(context.Background(), []string{directory}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if report.Pending || len(report.RequiredMigrations) != 0 {
		t.Fatalf("applied name migration remained pending: %#v", report)
	}
}

func appendMustMarshal(t *testing.T, value any, suffix byte) []byte {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return append(payload, suffix)
}
