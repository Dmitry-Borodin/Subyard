package audit

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

const defaultMaximum = int64(1024 * 1024)

var credentialURL = regexp.MustCompile(`(://[^/:@[:space:]]+:)[^/@[:space:]]+@|(://)[^/:@[:space:]]+@`)

type Invocation struct {
	Home        string
	Command     string
	Arguments   []string
	WorkingDir  string
	Yard        string
	Remote      string
	OperationID string
	Side        string
	Maximum     int64
	Now         time.Time
	PID         int
}

type OperationLog struct {
	Home       string
	WorkingDir string
	Yard       string
	Remote     string
	Maximum    int64
}

func (sink OperationLog) WriteAudit(_ context.Context, event domain.OperationEvent) error {
	return WriteInvocation(Invocation{
		Home: sink.Home, Command: event.Kind, WorkingDir: sink.WorkingDir,
		Yard: sink.Yard, Remote: sink.Remote, Maximum: sink.Maximum,
		OperationID: event.OperationID, Now: event.At,
	})
}

func WriteInvocation(invocation Invocation) error {
	if invocation.Home == "" {
		return nil
	}
	directory := filepath.Join(invocation.Home, "logs")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(directory, ".yard.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN) //nolint:errcheck
	path := filepath.Join(directory, "yard.log")
	maximum := invocation.Maximum
	if maximum <= 0 {
		maximum = defaultMaximum
	}
	if info, err := os.Stat(path); err == nil && info.Size() >= maximum {
		if err := os.Rename(path, path+".1"); err != nil {
			return err
		}
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	now := invocation.Now
	if now.IsZero() {
		now = time.Now()
	}
	pid := invocation.PID
	if pid == 0 {
		pid = os.Getpid()
	}
	side := invocation.Side
	if side == "" {
		side = detectSide()
	}
	fields := ""
	if invocation.Yard != "" && invocation.Yard != "default" {
		fields += " yard=" + cleanField(invocation.Yard)
	}
	if invocation.Remote != "" {
		fields += " remote=" + cleanField(invocation.Remote)
	}
	if invocation.OperationID != "" {
		fields += " op=" + cleanField(invocation.OperationID)
	}
	message := redactArguments(append([]string{invocation.Command}, invocation.Arguments...))
	_, err = fmt.Fprintf(file, "%s pid=%d cwd=%s where=%s%s -- %s\n",
		now.UTC().Format(time.RFC3339), pid, cleanField(invocation.WorkingDir), side, fields, message)
	return err
}

func redactArguments(arguments []string) string {
	redacted := make([]string, 0, len(arguments))
	for _, argument := range arguments {
		if argument == "--" {
			redacted = append(redacted, "--", "***")
			break
		}
		argument = strings.ReplaceAll(argument, "\n", "\\n")
		argument = strings.ReplaceAll(argument, "\r", "\\r")
		redacted = append(redacted, credentialURL.ReplaceAllString(argument, `${1}${2}***@`))
	}
	return strings.Join(redacted, " ")
}

func cleanField(value string) string {
	value = strings.ReplaceAll(value, "\n", "\\n")
	value = strings.ReplaceAll(value, "\r", "\\r")
	value = strings.ReplaceAll(value, " ", "\\x20")
	return value
}

func detectSide() string {
	if value := os.Getenv("SUBYARD_SIDE"); value == "host" || value == "yard" {
		return value
	}
	if data, err := os.ReadFile("/run/systemd/container"); err == nil && strings.TrimSpace(string(data)) != "" {
		return "yard"
	}
	return "host"
}

func MaximumFrom(value string) int64 {
	maximum, err := strconv.ParseInt(value, 10, 64)
	if err != nil || maximum <= 0 {
		return defaultMaximum
	}
	return maximum
}
