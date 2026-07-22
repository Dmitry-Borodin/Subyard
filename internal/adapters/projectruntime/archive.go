package projectruntime

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

type TarArchiver struct {
	Program     string
	Environment []string
}

func (archiver TarArchiver) Open(ctx context.Context, directory string) (io.ReadCloser, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("archive directory must be absolute")
	}
	info, err := os.Stat(directory)
	if err != nil || !info.IsDir() {
		return nil, fmt.Errorf("archive source is not a directory: %s", directory)
	}
	program := archiver.Program
	if program == "" {
		program = "tar"
	}
	command := exec.CommandContext(ctx, program, "-C", directory, "-cf", "-", ".")
	if archiver.Environment != nil {
		command.Env = archiver.Environment
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		return nil, err
	}
	return &archiveReader{ReadCloser: stdout, command: command, stderr: &stderr}, nil
}

type archiveReader struct {
	io.ReadCloser
	command *exec.Cmd
	stderr  *bytes.Buffer
	once    sync.Once
	waitErr error
	drained bool
}

func (reader *archiveReader) Read(payload []byte) (int, error) {
	count, err := reader.ReadCloser.Read(payload)
	if errors.Is(err, io.EOF) {
		reader.drained = true
		if waitErr := reader.wait(); waitErr != nil {
			return count, waitErr
		}
	}
	return count, err
}

func (reader *archiveReader) Close() error {
	var closeErr error
	if !reader.drained {
		closeErr = reader.ReadCloser.Close()
	}
	return errors.Join(closeErr, reader.wait())
}

func (reader *archiveReader) wait() error {
	reader.once.Do(func() {
		reader.waitErr = reader.command.Wait()
		if diagnostic := strings.TrimSpace(reader.stderr.String()); reader.waitErr != nil && diagnostic != "" {
			reader.waitErr = fmt.Errorf("archive source: %s: %w", diagnostic, reader.waitErr)
		}
	})
	return reader.waitErr
}
