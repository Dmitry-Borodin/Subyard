package projectruntime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type PatchStore struct {
	Directory string
	Now       func() time.Time
}

func (store PatchStore) Publish(ctx context.Context, projectID string, patch []byte) (string, error) {
	if err := context.Cause(ctx); err != nil {
		return "", err
	}
	if !domain.SafeID(projectID) || !filepath.IsAbs(store.Directory) {
		return "", errors.New("invalid project export target")
	}
	if err := os.MkdirAll(store.Directory, 0o700); err != nil {
		return "", err
	}
	if info, err := os.Lstat(store.Directory); err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("export directory must be a real directory")
	}
	if err := os.Chmod(store.Directory, 0o700); err != nil {
		return "", err
	}
	now := time.Now()
	if store.Now != nil {
		now = store.Now()
	}
	path := filepath.Join(store.Directory, projectID+"-"+now.UTC().Format("20060102T150405.000000000Z")+".patch")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	_, writeErr := file.Write(patch)
	if err := errors.Join(writeErr, file.Close()); err != nil {
		_ = os.Remove(path)
		return "", err
	}
	return path, nil
}
