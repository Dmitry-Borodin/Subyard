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
	"syscall"
	"time"

	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/ports"
	"github.com/Subyard/Subyard/internal/resource"
)

type Runtime struct {
	Environment  map[string]string
	Resources    []resource.Definition
	Program      string
	Security     ports.SecurityChecker
	Now          func() time.Time
	ProbeTimeout time.Duration
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
	refreshing := false
	if stale && ctx.Err() == nil {
		refreshing = runtime.startSpaceRefresh(yard, cache)
	}
	if figure == "" {
		if refreshing {
			return "in-yard size unavailable — refresh started"
		}
		return "in-yard size unavailable"
	}
	age := now.Sub(measured)
	if age < 0 {
		age = 0
	}
	note := ""
	if stale {
		note = ", refresh unavailable"
		if refreshing {
			note = ", refresh started"
		}
	}
	return fmt.Sprintf("%s  (in-yard rootfs, %s ago%s)", figure, ageHuman(age), note)
}

func (runtime Runtime) startSpaceRefresh(yard domain.Context, cache string) bool {
	directory := filepath.Dir(cache)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return false
	}
	probe, err := os.CreateTemp(directory, ".space-refresh-probe-")
	if err != nil {
		return false
	}
	probeName := probe.Name()
	if closeErr := probe.Close(); closeErr != nil {
		_ = os.Remove(probeName)
		return false
	}
	if err := os.Remove(probeName); err != nil {
		return false
	}
	refresh := exec.Command(
		"/bin/sh", "-c", spaceRefreshScript, "yard-space-refresh",
		cache, yard.IncusProject, yard.InstanceName,
	)
	refresh.Env = environment(runtime.Environment)
	refresh.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := refresh.Start(); err != nil {
		return false
	}
	_ = refresh.Process.Release()
	return true
}

func spaceCachePath(dataHome, yardName string) string {
	suffix := ""
	if yardName != "" && yardName != "default" {
		suffix = "-" + yardName
	}
	return filepath.Join(dataHome, "space"+suffix+".cache")
}

// Incus 6.0.6 returns no disk state for managed / and /srv devices on both containers and VMs,
// so detailed status keeps size off its foreground path and refreshes this compatible cache.
const spaceRefreshScript = `
set -eu
cache=$1
project=$2
instance=$3
lock=$cache.lock
temporary=$cache.tmp
umask 077
exec 9>"$lock"
flock -n 9 || exit 0
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
if [ -n "${SUBYARD_INCUS_SOCKET:-}" ]; then
  export INCUS_SOCKET=$SUBYARD_INCUS_SOCKET
fi
figure="$(
  timeout --signal=TERM --kill-after=1s 10s \
    incus exec "$instance" --project "$project" -- sh -c '
      set -- /
      grep -qs " /srv " /proc/mounts && set -- "$@" /srv
      du -sxch "$@" 2>/dev/null | awk "END { print \$1 }"
    '
)" || exit 0
printf '%s\n' "$figure" | grep -Eq '^[0-9]+([.][0-9]+)?[KMGTPEZY]?(i?B)?$' || exit 0
[ -e "$lock" ] || exit 0
printf '%s %s\n' "$figure" "$(date +%s)" >"$temporary"
mv -f -- "$temporary" "$cache"
trap - EXIT HUP INT TERM
`

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
	timeout := runtime.ProbeTimeout
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	for _, definition := range runtime.Resources {
		status := domain.SharedResourceStatus{
			Profile: definition.Profile, Name: definition.Name, State: "?",
		}
		if running {
			probeCtx, cancel := context.WithTimeout(ctx, timeout)
			probe := exec.CommandContext(probeCtx, definition.HandlerPath(), "is-up")
			probe.Env = environment(runtime.Environment)
			err := probe.Run()
			timedOut := probeCtx.Err() != nil
			cancel()
			if timedOut {
				result = append(result, status)
				continue
			}
			if err == nil {
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
