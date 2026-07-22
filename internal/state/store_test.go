package state

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/contracttest"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestProjectStoreConformance(t *testing.T) {
	t.Run("file", func(t *testing.T) { contracttest.ProjectStore(t, newTestStore(t)) })
	t.Run("memory", func(t *testing.T) { contracttest.ProjectStore(t, testkit.NewMemoryState()) })
}

func TestFileStoreAtomicConcurrentWrites(t *testing.T) {
	store := newTestStore(t)
	var wait sync.WaitGroup
	for index := 0; index < 20; index++ {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			record := fixtureRecord("project-a")
			record.Name = fmt.Sprintf("project-%02d", index)
			if err := store.Put(context.Background(), record); err != nil {
				t.Errorf("put: %v", err)
			}
		}(index)
	}
	wait.Wait()
	record, err := store.Get(context.Background(), "project-a")
	if err != nil {
		t.Fatal(err)
	}
	if record.Name == "" {
		t.Fatal("published record is incomplete")
	}
}

func TestFileStoreRejectsCorruptAndSymlinkedState(t *testing.T) {
	store := newTestStore(t)
	if _, err := store.List(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store.Directory(), "bad.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.List(context.Background()); err == nil {
		t.Fatal("corrupt state was accepted")
	}
	if err := os.Remove(filepath.Join(store.Directory(), "bad.json")); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "target.json")
	if err := os.WriteFile(target, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(store.Directory(), "linked.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := store.List(context.Background()); err == nil {
		t.Fatal("symlinked state was accepted")
	}
}

func TestFileStoreRejectsBroadPermissionsAndOversizedState(t *testing.T) {
	store := newTestStore(t)
	if _, err := store.List(context.Background()); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.Directory(), "unsafe.json")
	if err := os.WriteFile(path, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := store.List(context.Background()); err == nil {
		t.Fatal("broad state-file permissions were accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, 1024*1024+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.List(context.Background()); err == nil {
		t.Fatal("oversized state file was accepted")
	}
}

func TestFileStoreRepairsValidatedLegacyPermissions(t *testing.T) {
	store := newTestStore(t)
	record := fixtureRecord("legacy")
	if err := store.Put(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.Directory(), "legacy.json")
	if err := os.Chmod(path, 0o664); err != nil {
		t.Fatal(err)
	}
	changed, err := store.RepairLegacyPermissions(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("legacy state permissions were not repaired")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("legacy state mode = %o, want 600", info.Mode().Perm())
	}
	if _, err := store.Get(context.Background(), record.ProjectID); err != nil {
		t.Fatal(err)
	}
	changed, err = store.RepairLegacyPermissions(context.Background())
	if err != nil || changed {
		t.Fatalf("canonical state repair = %t, %v", changed, err)
	}
}

func TestFileStoreDoesNotRepairInvalidBroadState(t *testing.T) {
	store := newTestStore(t)
	if _, err := store.List(context.Background()); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.Directory(), "invalid.json")
	if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// Normalize the legacy mode across process umasks.
	if err := os.Chmod(path, 0o664); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o664); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RepairLegacyPermissions(context.Background()); err == nil {
		t.Fatal("invalid broad state was repaired")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o664 {
		t.Fatalf("invalid state mode changed to %o", info.Mode().Perm())
	}
}

func TestFileStoreDoesNotRepairAnomalousLegacyMode(t *testing.T) {
	store := newTestStore(t)
	if err := store.Put(context.Background(), fixtureRecord("executable")); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.Directory(), "executable.json")
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RepairLegacyPermissions(context.Background()); err == nil {
		t.Fatal("executable state mode was repaired")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("anomalous state mode changed to %o", info.Mode().Perm())
	}
}

func TestFileStoreDeleteIsIdempotent(t *testing.T) {
	store := newTestStore(t)
	if err := store.Put(context.Background(), fixtureRecord("gone")); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete(context.Background(), "gone"); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete(context.Background(), "gone"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Get(context.Background(), "gone"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected not found, got %v", err)
	}
}

func newTestStore(t *testing.T) *FileStore {
	t.Helper()
	store, err := NewFileStore(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func fixtureRecord(id string) domain.ProjectRecord {
	return domain.ProjectRecord{
		Schema:     1,
		ProjectID:  id,
		Name:       id,
		HostPath:   "/workspace/" + id,
		YardPath:   "/srv/workspaces/" + id + "/src",
		Mode:       domain.ProjectSync,
		SSHHost:    "yard",
		ImportedAt: "2026-07-20T00:00:00Z",
	}
}
