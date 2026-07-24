package reconcileruntime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type guestConfigFile struct {
	label       string
	source      string
	destination string
}

func (runtime Runtime) RefreshConfigs(ctx context.Context) error {
	if runtime.Executor == nil {
		return errors.New("Incus executor is required")
	}
	if !domain.SafeName(runtime.devUser()) {
		return errors.New("invalid developer user")
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound {
		return firstError(err, errors.New("yard instance is missing"))
	}
	if !strings.EqualFold(state.Instance.Status, "running") {
		return errors.New("yard is not running")
	}
	files, err := runtime.guestConfigFiles()
	if err != nil {
		return err
	}
	output := runtime.Stdout
	if output == nil {
		output = io.Discard
	}
	fmt.Fprintf(output, "Refresh agent instructions and configs in %s\n", runtime.Yard.InstanceName)
	copied := make(map[string]bool)
	for _, file := range files {
		info, statErr := os.Stat(file.source)
		if statErr != nil {
			if os.IsNotExist(statErr) {
				fmt.Fprintf(output, "  [ ok ] %s: no source — skipping\n", file.label)
				continue
			}
			return statErr
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("%s source is not a regular file", file.label)
		}
		payload, err := os.ReadFile(file.source)
		if err != nil {
			return err
		}
		if err := runtime.writeGuestFile(ctx, file.destination, payload); err != nil {
			return fmt.Errorf("apply %s: %w", file.label, err)
		}
		copied[file.label] = true
		fmt.Fprintf(output, "  [ ok ] %s -> ~%s/%s\n",
			file.label, runtime.devUser(), strings.TrimPrefix(file.destination, "/home/"+runtime.devUser()+"/"))
	}
	for _, agent := range strings.Fields(runtime.environmentValue("AGENTS")) {
		if !copied[agent+" config"] && !copied[agent+" rules"] {
			fmt.Fprintf(output, "  [ ok ] %s: no default config — skipping\n", agent)
		}
	}
	fmt.Fprintln(output, "  [ ok ] Agent instructions and configs refreshed.")
	return nil
}

func (runtime Runtime) applyGitIdentity(ctx context.Context) error {
	if runtime.Executor == nil {
		return errors.New("Incus executor is required")
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound {
		return firstError(err, errors.New("yard instance is missing"))
	}
	if !strings.EqualFold(state.Instance.Status, "running") {
		return errors.New("yard is not running")
	}
	user := runtime.devUser()
	if !domain.SafeName(user) {
		return errors.New("invalid developer user")
	}
	home := "/home/" + user
	dropin := filepath.Join(runtime.Yard.Paths.DataHome, "gitconfig")
	if regularFile(dropin) {
		payload, err := os.ReadFile(dropin)
		if err != nil {
			return err
		}
		if err := runtime.writeGuestFile(ctx, home+"/.gitconfig", payload); err != nil {
			return err
		}
	} else {
		name := runtime.environmentValue("GIT_USER_NAME")
		email := runtime.environmentValue("GIT_USER_EMAIL")
		if name == "" {
			name = runtime.hostGitValue("user.name")
		}
		if email == "" {
			email = runtime.hostGitValue("user.email")
		}
		if name != "" {
			if err := runtime.runGuestAsDev(ctx,
				[]string{"git", "config", "--global", "user.name", name}); err != nil {
				return err
			}
		}
		if email != "" {
			if err := runtime.runGuestAsDev(ctx,
				[]string{"git", "config", "--global", "user.email", email}); err != nil {
				return err
			}
		}
	}
	if err := runtime.runGuestAsDev(ctx,
		[]string{"git", "config", "--global", "--replace-all", "safe.directory", "*"}); err != nil {
		return err
	}
	if runtime.Stdout != nil {
		fmt.Fprintf(runtime.Stdout, "  [ ok ] git config ready for %s\n", user)
	}
	return nil
}

func (runtime Runtime) guestConfigFiles() ([]guestConfigFile, error) {
	user := runtime.devUser()
	home := "/home/" + user
	files := []guestConfigFile{
		{label: "Claude instructions", source: runtime.environmentValue("HOST_CLAUDE_MD"),
			destination: home + "/.claude/CLAUDE.md"},
		{label: "Codex instructions", source: runtime.environmentValue("HOST_CODEX_AGENTS_MD"),
			destination: home + "/.codex/AGENTS.md"},
		{label: "OpenCode instructions", source: runtime.environmentValue("HOST_OPENCODE_AGENTS_MD"),
			destination: home + "/.config/opencode/AGENTS.md"},
	}
	for _, agent := range strings.Fields(runtime.environmentValue("AGENTS")) {
		if !domain.SafeName(agent) {
			return nil, fmt.Errorf("invalid agent name %q", agent)
		}
		for _, kind := range []string{"CONFIG", "RULES"} {
			source := runtime.environmentValue("AGENT_" + agent + "_" + kind)
			destination := runtime.environmentValue("AGENT_" + agent + "_" + kind + "_DEST")
			if source == "" || destination == "" {
				continue
			}
			clean, err := safeGuestRelativePath(destination)
			if err != nil {
				return nil, fmt.Errorf("agent %s %s destination: %w",
					agent, strings.ToLower(kind), err)
			}
			files = append(files, guestConfigFile{
				label: agent + " " + strings.ToLower(kind), source: source,
				destination: filepath.Join(home, clean),
			})
		}
	}
	return files, nil
}

func (runtime Runtime) writeGuestFile(ctx context.Context, destination string, payload []byte) error {
	if !domain.SafeName(runtime.devUser()) ||
		!strings.HasPrefix(destination, "/home/"+runtime.devUser()+"/") {
		return errors.New("guest config destination leaves the developer home")
	}
	uid := runtime.Yard.DevUID
	if uid <= 0 {
		uid = 1000
	}
	request := ports.InstanceExecRequest{
		Command: []string{"sh", "-eu", "-c", `
destination=$1
uid=$2
directory=${destination%/*}
install -d -m 0755 -o "$uid" -g "$uid" "$directory"
temporary=$(mktemp "$directory/.subyard-config.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
cat > "$temporary"
chown "$uid:$uid" "$temporary"
chmod 0644 "$temporary"
mv -f -- "$temporary" "$destination"
trap - EXIT HUP INT TERM
`, "subyard", destination, fmt.Sprint(uid)},
		Stdin: payload,
	}
	return runtime.runGuest(ctx, request)
}

func (runtime Runtime) runGuestAsDev(ctx context.Context, command []string) error {
	if !domain.SafeName(runtime.devUser()) {
		return errors.New("invalid developer user")
	}
	uid := runtime.Yard.DevUID
	if uid <= 0 {
		uid = 1000
	}
	return runtime.runGuest(ctx, ports.InstanceExecRequest{
		Command: command, User: uint32(uid), Group: uint32(uid),
		Environment: map[string]string{"HOME": "/home/" + runtime.devUser()},
	})
}

func (runtime Runtime) runGuest(ctx context.Context, request ports.InstanceExecRequest) error {
	result, err := runtime.Executor.Exec(
		ctx, runtime.Yard.IncusProject, runtime.Yard.InstanceName, request)
	if err == nil && result.ExitCode == 0 {
		return nil
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("guest command exited with status %d", result.ExitCode)
}

func (runtime Runtime) hostGitValue(key string) string {
	git, err := runtime.executableFromPath("git")
	if err != nil {
		return ""
	}
	command := exec.Command(git, "config", "--global", "--get", key)
	command.Env = runtime.Environment
	output, err := command.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func (runtime Runtime) devUser() string {
	if runtime.Yard.DevUser != "" {
		return runtime.Yard.DevUser
	}
	return runtime.environmentDefault("DEV_USER", "dev")
}

func safeGuestRelativePath(value string) (string, error) {
	if value == "" || filepath.IsAbs(value) {
		return "", errors.New("path must be relative")
	}
	clean := filepath.Clean(value)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", errors.New("path leaves the developer home")
	}
	return clean, nil
}

func firstError(primary, fallback error) error {
	if primary != nil {
		return primary
	}
	return fallback
}
