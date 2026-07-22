package projectruntime

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPatchStorePublishesProtectedArtifact(t *testing.T) {
	root := filepath.Join(t.TempDir(), "exports")
	store := PatchStore{Directory: root, Now: func() time.Time {
		return time.Date(2026, 7, 22, 8, 39, 0, 0, time.UTC)
	}}
	path, err := store.Publish(context.Background(), "demo-12345678", []byte("patch"))
	if err != nil {
		t.Fatal(err)
	}
	if path != filepath.Join(root, "demo-12345678-20260722T083900.000000000Z.patch") {
		t.Fatalf("unexpected export path: %s", path)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("export is not protected: info=%v err=%v", info, err)
	}
	directory, err := os.Stat(root)
	if err != nil || directory.Mode().Perm() != 0o700 {
		t.Fatalf("export directory is not protected: info=%v err=%v", directory, err)
	}
}
