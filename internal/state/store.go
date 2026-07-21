package state

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

var ErrNotFound = errors.New("project state not found")

type FileStore struct {
	directory string
}

func NewFileStore(directory string) (*FileStore, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("state directory must be absolute")
	}
	return &FileStore{directory: filepath.Clean(directory)}, nil
}

func (store *FileStore) Directory() string { return store.directory }

func (store *FileStore) List(ctx context.Context) ([]domain.ProjectRecord, error) {
	lock, err := store.lock(ctx, false)
	if err != nil {
		return nil, err
	}
	if lock != nil {
		defer unlock(lock)
	}
	entries, err := os.ReadDir(store.directory)
	if errors.Is(err, os.ErrNotExist) {
		return []domain.ProjectRecord{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read state directory: %w", err)
	}
	records := make([]domain.ProjectRecord, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		record, err := readRecord(filepath.Join(store.directory, entry.Name()), id)
		if err != nil {
			return nil, fmt.Errorf("invalid project state: %w", err)
		}
		records = append(records, record)
	}
	sort.Slice(records, func(left, right int) bool { return records[left].ProjectID < records[right].ProjectID })
	return records, nil
}

func (store *FileStore) Get(ctx context.Context, id string) (domain.ProjectRecord, error) {
	if !domain.SafeID(id) {
		return domain.ProjectRecord{}, fmt.Errorf("invalid project ID %q", id)
	}
	lock, err := store.lock(ctx, false)
	if err != nil {
		return domain.ProjectRecord{}, err
	}
	if lock != nil {
		defer unlock(lock)
	}
	record, err := readRecord(store.path(id), id)
	if errors.Is(err, os.ErrNotExist) {
		return domain.ProjectRecord{}, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	if err != nil {
		return domain.ProjectRecord{}, fmt.Errorf("invalid project state: %w", err)
	}
	return record, err
}

func (store *FileStore) Put(ctx context.Context, record domain.ProjectRecord) error {
	if err := record.Validate(record.ProjectID); err != nil {
		return err
	}
	lock, err := store.lock(ctx, true)
	if err != nil {
		return err
	}
	defer unlock(lock)

	temporary, err := os.CreateTemp(store.directory, "."+record.ProjectID+".json.tmp.*")
	if err != nil {
		return fmt.Errorf("create state candidate: %w", err)
	}
	temporaryPath := temporary.Name()
	published := false
	defer func() {
		_ = temporary.Close()
		if !published {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return fmt.Errorf("protect state candidate: %w", err)
	}
	encoder := json.NewEncoder(temporary)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(record); err != nil {
		return fmt.Errorf("encode state candidate: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		return fmt.Errorf("sync state candidate: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close state candidate: %w", err)
	}
	if _, err := readRecord(temporaryPath, record.ProjectID); err != nil {
		return fmt.Errorf("validate state candidate: %w", err)
	}
	if err := os.Rename(temporaryPath, store.path(record.ProjectID)); err != nil {
		return fmt.Errorf("publish state: %w", err)
	}
	published = true
	return syncDirectory(store.directory)
}

func (store *FileStore) Delete(ctx context.Context, id string) error {
	if !domain.SafeID(id) {
		return fmt.Errorf("invalid project ID %q", id)
	}
	lock, err := store.lock(ctx, true)
	if err != nil {
		return err
	}
	defer unlock(lock)
	if err := os.Remove(store.path(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove project state: %w", err)
	}
	return syncDirectory(store.directory)
}

func (store *FileStore) path(id string) string {
	return filepath.Join(store.directory, id+".json")
}

func (store *FileStore) lock(ctx context.Context, exclusive bool) (*os.File, error) {
	if err := ensurePrivateDirectory(store.directory); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(store.directory, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open state lock: %w", err)
	}
	operation := syscall.LOCK_SH
	if exclusive {
		operation = syscall.LOCK_EX
	}
	for {
		err = syscall.Flock(int(lock.Fd()), operation|syscall.LOCK_NB)
		if err == nil {
			return lock, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			_ = lock.Close()
			return nil, fmt.Errorf("lock state: %w", err)
		}
		select {
		case <-ctx.Done():
			_ = lock.Close()
			return nil, fmt.Errorf("lock state: %w", context.Cause(ctx))
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func unlock(file *os.File) {
	_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	_ = file.Close()
}

func ensurePrivateDirectory(path string) error {
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return errors.New("state path is not a real directory")
		}
		if info.Mode().Perm()&0o077 != 0 {
			return fmt.Errorf("state directory permissions are too broad: %o", info.Mode().Perm())
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	return os.Chmod(path, 0o700)
}

func readRecord(path, expectedID string) (domain.ProjectRecord, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return domain.ProjectRecord{}, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return domain.ProjectRecord{}, fmt.Errorf("project state is not a regular file: %s", path)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return domain.ProjectRecord{}, fmt.Errorf("project state permissions are too broad: %o", info.Mode().Perm())
	}
	if info.Size() > 1024*1024 {
		return domain.ProjectRecord{}, fmt.Errorf("project state exceeds size limit: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return domain.ProjectRecord{}, err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 1024*1024))
	var record domain.ProjectRecord
	if err := decoder.Decode(&record); err != nil {
		return domain.ProjectRecord{}, fmt.Errorf("decode project state %s: %w", path, err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return domain.ProjectRecord{}, fmt.Errorf("project state %s has trailing data", path)
	}
	if err := record.Validate(expectedID); err != nil {
		return domain.ProjectRecord{}, fmt.Errorf("invalid project state %s: %w", path, err)
	}
	return record, nil
}

// ValidateFile checks an unpublished candidate using the same compatibility and
// permission boundary as normal reads. The path must be inside this store.
func (store *FileStore) ValidateFile(path, expectedID string) error {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(store.directory, absolute)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return errors.New("project state candidate escapes state directory")
	}
	_, err = readRecord(absolute, expectedID)
	return err
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return fmt.Errorf("sync state directory: %w", err)
	}
	return nil
}
