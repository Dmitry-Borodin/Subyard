package testkit

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"path/filepath"
	"strings"
	"sync"
)

type sandboxFile struct {
	data []byte
	mode uint32
}

// SandboxFS is an in-memory filesystem whose absolute paths are confined to
// Root. A failed or partial AtomicWrite never publishes candidate data.
type SandboxFS struct {
	Root       string
	ReadErr    error
	WriteErr   error
	RemoveErr  error
	WriteLimit int

	mu    sync.RWMutex
	files map[string]sandboxFile
}

func NewSandboxFS(root string) (*SandboxFS, error) {
	if !filepath.IsAbs(root) {
		return nil, errors.New("sandbox root must be absolute")
	}
	root = filepath.Clean(root)
	if root == string(filepath.Separator) {
		return nil, errors.New("sandbox root must not be filesystem root")
	}
	return &SandboxFS{Root: root, files: make(map[string]sandboxFile)}, nil
}

func (sandbox *SandboxFS) ReadFile(ctx context.Context, path string) ([]byte, error) {
	if err := context.Cause(ctx); err != nil {
		return nil, err
	}
	resolved, err := sandbox.resolve(path)
	if err != nil {
		return nil, err
	}
	sandbox.mu.RLock()
	defer sandbox.mu.RUnlock()
	if sandbox.ReadErr != nil {
		return nil, sandbox.ReadErr
	}
	file, ok := sandbox.files[resolved]
	if !ok {
		return nil, fs.ErrNotExist
	}
	return append([]byte(nil), file.data...), nil
}

func (sandbox *SandboxFS) AtomicWrite(ctx context.Context, path string, data []byte, mode uint32) error {
	if err := context.Cause(ctx); err != nil {
		return err
	}
	resolved, err := sandbox.resolve(path)
	if err != nil {
		return err
	}
	sandbox.mu.Lock()
	defer sandbox.mu.Unlock()
	if sandbox.WriteErr != nil {
		return sandbox.WriteErr
	}
	if sandbox.WriteLimit > 0 && len(data) > sandbox.WriteLimit {
		return io.ErrShortWrite
	}
	sandbox.files[resolved] = sandboxFile{data: append([]byte(nil), data...), mode: mode}
	return nil
}

func (sandbox *SandboxFS) Remove(ctx context.Context, path string) error {
	if err := context.Cause(ctx); err != nil {
		return err
	}
	resolved, err := sandbox.resolve(path)
	if err != nil {
		return err
	}
	sandbox.mu.Lock()
	defer sandbox.mu.Unlock()
	if sandbox.RemoveErr != nil {
		return sandbox.RemoveErr
	}
	delete(sandbox.files, resolved)
	return nil
}

func (sandbox *SandboxFS) Mode(path string) (uint32, error) {
	resolved, err := sandbox.resolve(path)
	if err != nil {
		return 0, err
	}
	sandbox.mu.RLock()
	defer sandbox.mu.RUnlock()
	file, ok := sandbox.files[resolved]
	if !ok {
		return 0, fs.ErrNotExist
	}
	return file.mode, nil
}

func (sandbox *SandboxFS) resolve(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("sandbox path must be absolute")
	}
	path = filepath.Clean(path)
	relative, err := filepath.Rel(sandbox.Root, path)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", errors.New("sandbox path escapes root")
	}
	return path, nil
}
