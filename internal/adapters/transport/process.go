package transport

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const defaultLimit = 4 * 1024 * 1024

type Process struct {
	Program   string
	Arguments []string
	Directory string
	Env       []string
	Timeout   time.Duration
	MaxBytes  int64
}

func Local(engine, repositoryRoot string) Process {
	return Process{
		Program: engine, Arguments: []string{"rpc", "--stdio"}, Directory: repositoryRoot,
		Env: append(os.Environ(), "SUBYARD_REPOSITORY_ROOT="+repositoryRoot),
	}
}

func SSH(program, target string, connectTimeout time.Duration) (Process, error) {
	if program == "" {
		program = "ssh"
	}
	if !safeTarget(target) {
		return Process{}, fmt.Errorf("invalid SSH target %q", target)
	}
	seconds := int(connectTimeout.Round(time.Second) / time.Second)
	if seconds < 1 {
		seconds = 2
	}
	return Process{
		Program: program,
		Arguments: []string{
			"-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=" + strconv.Itoa(seconds),
			target, "--", "yard", "rpc", "--stdio",
		},
	}, nil
}

func (transport Process) Call(ctx context.Context, _ string, request []byte) ([]byte, error) {
	if transport.Program == "" {
		return nil, errors.New("transport program is required")
	}
	callContext := ctx
	cancel := func() {}
	if transport.Timeout > 0 {
		callContext, cancel = context.WithTimeout(ctx, transport.Timeout)
	}
	defer cancel()
	command := exec.CommandContext(callContext, transport.Program, transport.Arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	command.WaitDelay = 2 * time.Second
	command.Dir = transport.Directory
	if transport.Env != nil {
		command.Env = transport.Env
	}
	command.Stdin = bytes.NewReader(request)
	limit := transport.MaxBytes
	if limit <= 0 {
		limit = defaultLimit
	}
	stdout := &limitedBuffer{limit: limit}
	stderr := &limitedBuffer{limit: limit}
	command.Stdout = stdout
	command.Stderr = stderr
	err := command.Run()
	if stdout.exceeded || stderr.exceeded {
		return nil, errors.New("transport output exceeded limit")
	}
	if callContext.Err() != nil {
		return nil, fmt.Errorf("transport cancelled: %w", context.Cause(callContext))
	}
	if err != nil {
		message := strings.TrimSpace(stderr.buffer.String())
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("transport failed: %s", message)
	}
	return bytes.Clone(stdout.buffer.Bytes()), nil
}

func safeTarget(value string) bool {
	if value == "" || strings.HasPrefix(value, "-") {
		return false
	}
	for _, char := range value {
		if !(char >= 'a' && char <= 'z') && !(char >= 'A' && char <= 'Z') &&
			!(char >= '0' && char <= '9') && !strings.ContainsRune("._@:-", char) {
			return false
		}
	}
	return true
}

type limitedBuffer struct {
	buffer   bytes.Buffer
	limit    int64
	exceeded bool
}

func (buffer *limitedBuffer) Write(value []byte) (int, error) {
	remaining := buffer.limit - int64(buffer.buffer.Len())
	if remaining <= 0 {
		buffer.exceeded = true
		return len(value), nil
	}
	write := value
	if int64(len(write)) > remaining {
		write = write[:remaining]
		buffer.exceeded = true
	}
	_, _ = buffer.buffer.Write(write)
	return len(value), nil
}
