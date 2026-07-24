package statusruntime

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/resource"
)

type Runtime struct {
	Environment map[string]string
	Resources   []resource.Definition
	Program     string
	Security    ports.SecurityChecker
	Executor    ports.InstanceExecutor
	Now         func() time.Time
}

func (runtime Runtime) ReadStatusFacts(
	ctx context.Context,
	yard domain.Context,
	running bool,
) (domain.StatusFacts, error) {
	security := "FAIL"
	if runtime.Security != nil {
		security, _ = runtime.Security.CheckSecurity(ctx, true, true)
		if security == "FAIL" {
			security, _ = runtime.Security.CheckSecurity(ctx, false, true)
		}
	}
	result := domain.StatusFacts{Security: security, Space: runtime.space(ctx, yard, running)}
	result.Shared = runtime.resourceStatus(ctx, running)
	return result, nil
}

func (runtime Runtime) space(ctx context.Context, yard domain.Context, running bool) string {
	dataHome := yard.Paths.DataHome
	if dataHome == "" {
		dataHome = runtime.Environment["SUBYARD_HOME"]
	}
	if !running {
		return fmt.Sprintf("—  (yard stopped; on-host size: sudo du -sh %s)", dataHome)
	}
	now := time.Now()
	if runtime.Now != nil {
		now = runtime.Now()
	}
	cache := spaceCachePath(dataHome, yard.YardName)
	figure, measured := readSpaceCache(cache)
	ttl := 10 * time.Minute
	if seconds, err := strconv.Atoi(runtime.Environment["SPACE_TTL"]); err == nil && seconds > 0 {
		ttl = time.Duration(seconds) * time.Second
	}
	stale := figure == "" || now.Sub(measured) > ttl
	refreshFailed := false
	if stale {
		refreshCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		next, ok := runtime.measureSpace(refreshCtx, yard)
		cancel()
		if ok {
			figure, measured = next, now
			_ = writeSpaceCache(cache, next, now)
		} else {
			refreshFailed = figure != ""
		}
	}
	if figure == "" {
		return "in-yard size unavailable — re-run status in a moment"
	}
	age := now.Sub(measured)
	if age < 0 {
		age = 0
	}
	note := ""
	if refreshFailed {
		note = ", refresh failed"
	}
	return fmt.Sprintf("%s  (in-yard rootfs, %s ago%s)", figure, ageHuman(age), note)
}

func (runtime Runtime) measureSpace(
	ctx context.Context,
	yard domain.Context,
) (string, bool) {
	if runtime.Executor == nil {
		return "", false
	}
	result, err := runtime.Executor.Exec(ctx, yard.IncusProject, yard.InstanceName,
		ports.InstanceExecRequest{Command: []string{"sh", "-c", `
set --
while read -r _ mountpoint _; do
  case "$mountpoint" in /|/srv) ;; *) set -- "$@" "--exclude=$mountpoint" ;; esac
done < /proc/mounts
du -sxh "$@" / 2>/dev/null | awk '{print $1}'
`}})
	if err != nil || result.ExitCode != 0 {
		return "", false
	}
	fields := strings.Fields(string(result.Stdout))
	if len(fields) != 1 || !validSpaceFigure(fields[0]) {
		return "", false
	}
	return fields[0], true
}

func spaceCachePath(dataHome, yardName string) string {
	suffix := ""
	if yardName != "" {
		suffix = "-" + yardName
	}
	return filepath.Join(dataHome, "space"+suffix+".cache")
}

func readSpaceCache(path string) (string, time.Time) {
	payload, err := os.ReadFile(path)
	if err != nil {
		return "", time.Time{}
	}
	fields := strings.Fields(string(payload))
	if len(fields) != 2 || !validSpaceFigure(fields[0]) {
		return "", time.Time{}
	}
	epoch, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil || epoch < 0 {
		return "", time.Time{}
	}
	return fields[0], time.Unix(epoch, 0)
}

func writeSpaceCache(path, figure string, measured time.Time) error {
	if path == "" || !validSpaceFigure(figure) {
		return fmt.Errorf("invalid status space cache")
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, ".space-cache-")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := fmt.Fprintf(file, "%s %d\n", figure, measured.Unix()); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

func validSpaceFigure(value string) bool {
	if value == "" || len(value) > 32 {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') && character != '.' &&
			!strings.ContainsRune("KMGTPEZYiB", character) {
			return false
		}
	}
	return true
}

func ageHuman(age time.Duration) string {
	seconds := int64(age / time.Second)
	switch {
	case seconds < 60:
		return fmt.Sprintf("%ds", seconds)
	case seconds < 3600:
		return fmt.Sprintf("%dm", seconds/60)
	case seconds < 86400:
		return fmt.Sprintf("%dh", seconds/3600)
	default:
		return fmt.Sprintf("%dd", seconds/86400)
	}
}

func (runtime Runtime) resourceStatus(ctx context.Context, running bool) []domain.SharedResourceStatus {
	result := make([]domain.SharedResourceStatus, 0, len(runtime.Resources))
	program := runtime.Program
	if program == "" {
		program = "yard"
	}
	for _, definition := range runtime.Resources {
		status := domain.SharedResourceStatus{
			Profile: definition.Profile, Name: definition.Name, State: "?",
		}
		if running {
			probe := exec.CommandContext(ctx, definition.HandlerPath(), "is-up")
			probe.Env = environment(runtime.Environment)
			if probe.Run() == nil {
				status.State = "up"
				status.Hint = program + " " + definition.Command + " " + definition.Shutdown
			} else {
				status.State = "down"
				status.Hint = program + " " + definition.Command + " " + definition.BringUp
			}
		}
		result = append(result, status)
	}
	return result
}

func environment(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
}
