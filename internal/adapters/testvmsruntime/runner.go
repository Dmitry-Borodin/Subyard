package testvmsruntime

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

type CommandRunner interface {
	Run(context.Context, string, []string, []string, io.Reader) ([]byte, []byte, error)
	LookPath(string) (string, error)
}

type ProcessRunner struct{}

func (ProcessRunner) Run(
	ctx context.Context,
	name string,
	arguments []string,
	environment []string,
	stdin io.Reader,
) ([]byte, []byte, error) {
	command := exec.CommandContext(ctx, name, arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	command.WaitDelay = 2 * time.Second
	command.Env = append(os.Environ(), environment...)
	if stdin == nil {
		stdin = strings.NewReader("")
	}
	command.Stdin = stdin
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	if err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = strings.TrimSpace(stdout.String())
		}
		if message == "" {
			message = err.Error()
		}
		err = fmt.Errorf("%s %s: %s", name, strings.Join(arguments, " "), message)
	}
	return stdout.Bytes(), stderr.Bytes(), err
}

func (ProcessRunner) LookPath(name string) (string, error) { return exec.LookPath(name) }
