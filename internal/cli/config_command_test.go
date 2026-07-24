package cli

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestConfigPathsShowsEffectiveLayersWithoutValues(t *testing.T) {
	root, home, configHome, environment := configCommandFixture(t)
	hostRule := filepath.Join(configHome, "overrides", "host", "agents", "codex", "rules", "repo.rules")
	writeConfigCommandFile(t, hostRule, "private-canary-value\n")
	writeConfigCommandFile(t, filepath.Join(configHome, "config.env"),
		"AGENT_codex_RULES=\"$SUBYARD_CONFIG_DIR/../private/agents/codex/rules/repo.rules\"\n", 0o600)
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"config", "paths"},
		Environment: environment, WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("config paths failed: code=%d stderr=%s", code, stderr.String())
	}
	output := stdout.String()
	for _, expected := range []string{
		"runtime-defaults: " + filepath.Join(root, "config"),
		"config-root: " + configHome,
		"asset codex.rules: " + hostRule + " (host)",
	} {
		if !strings.Contains(output, expected) {
			t.Fatalf("config paths omitted %q:\n%s", expected, output)
		}
	}
	if strings.Contains(output, "private-canary-value") || strings.Contains(output, home+"/.subyard/operator-overlay") {
		t.Fatalf("config paths leaked a value or legacy source:\n%s", output)
	}
}

func TestConfigStatusAndApplyAllLocalExcludeRemoteYards(t *testing.T) {
	root, _, configHome, environment := configCommandFixture(t)
	environment = append(environment,
		"SUBYARD_ENGINE_CONTEXT=1", "SUBYARD_CONFIG_LOADED=1", "YARD_TYPE=local")
	writeConfigCommandFile(t, filepath.Join(configHome, "yards", "named", "config.env"),
		"SSH_PORT=3333\n")
	writeConfigCommandFile(t, filepath.Join(configHome, "yards", "remote", "config.env"),
		"YARD_TYPE=remote\nREMOTE_DEST=owner.example\nREMOTE_YARD=inner\nSSH_PORT=4444\n")

	defaultLoaded := loadConfigCommandContext(t, root, environment, "default")
	namedLoaded := loadConfigCommandContext(t, root, environment, "named")
	fake := &testkit.Incus{Instances: map[string]ports.InstanceInfo{
		defaultLoaded.Context.IncusProject + "/" + defaultLoaded.Context.InstanceName: {
			Name: defaultLoaded.Context.InstanceName, Project: defaultLoaded.Context.IncusProject,
			Status: "Running",
		},
		namedLoaded.Context.IncusProject + "/" + namedLoaded.Context.InstanceName: {
			Name: namedLoaded.Context.InstanceName, Project: namedLoaded.Context.IncusProject,
			Status: "Running",
		},
	}}
	appendHashSteps(t, fake, defaultLoaded)
	appendHashSteps(t, fake, namedLoaded)
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "status", "--all-local"},
		Environment: environment, WorkingDir: root,
		Incus: fake, Executor: fake, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("config status failed: code=%d stderr=%s stdout=%s", code, stderr.String(), stdout.String())
	}
	if !strings.Contains(stdout.String(), "yard default: converged") ||
		!strings.Contains(stdout.String(), "yard named: converged") ||
		strings.Contains(stdout.String(), "yard remote:") {
		t.Fatalf("all-local selection is wrong:\n%s", stdout.String())
	}

	fake.ExecSteps = nil
	appendHashSteps(t, fake, defaultLoaded)
	appendHashSteps(t, fake, namedLoaded)
	applier := &recordingConfigApplier{}
	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "apply", "--all-local", "--yes"},
		Environment: environment, WorkingDir: root,
		Incus: fake, Executor: fake, Config: applier, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("config apply failed: code=%d stderr=%s stdout=%s", code, stderr.String(), stdout.String())
	}
	if strings.Join(applier.yards, ",") != "default,named" {
		t.Fatalf("config apply selected %#v", applier.yards)
	}
}

func TestConfigStatusDetectsGuestDriftWithoutPrintingContents(t *testing.T) {
	root, _, _, environment := configCommandFixture(t)
	loaded := loadConfigCommandContext(t, root, environment, "default")
	fake := &testkit.Incus{Instances: map[string]ports.InstanceInfo{
		loaded.Context.IncusProject + "/" + loaded.Context.InstanceName: {
			Name: loaded.Context.InstanceName, Project: loaded.Context.IncusProject, Status: "Running",
		},
	}, ExecSteps: []testkit.IncusExecStep{{
		Result: ports.InstanceExecResult{Stdout: []byte(strings.Repeat("0", 64) + "  file\n"), ExitCode: 0},
	}}}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"config", "status"},
		Environment: environment, WorkingDir: root,
		Incus: fake, Executor: fake, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 ||
		!strings.Contains(stderr.String(), "agent config drift") {
		t.Fatalf("drift was not detected: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if strings.Contains(stdout.String()+stderr.String(), "permissions") {
		t.Fatal("status printed agent config contents")
	}
}

func TestConfigApplyRejectsUnsafeOperatorTreeBeforeMutation(t *testing.T) {
	root, _, configHome, environment := configCommandFixture(t)
	unsafe := filepath.Join(configHome, "overrides", "host", "unsafe.conf")
	writeConfigCommandFile(t, unsafe, "value\n")
	if err := os.Chmod(unsafe, 0o666); err != nil {
		t.Fatal(err)
	}
	applier := &recordingConfigApplier{}
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "apply", "--yes"},
		Environment: environment, WorkingDir: root,
		Config: applier, Stdout: &bytes.Buffer{}, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 ||
		!strings.Contains(stderr.String(), "group/world writable") {
		t.Fatalf("unsafe tree was not rejected: code=%d stderr=%s", code, stderr.String())
	}
	if len(applier.yards) != 0 {
		t.Fatalf("unsafe tree was applied to %#v", applier.yards)
	}
}

func TestConfigValidationExcludesRuntimeStateTrees(t *testing.T) {
	_, _, configHome, _ := configCommandFixture(t)
	for _, path := range []string{
		filepath.Join(configHome, "keys", "ledger.lock"),
		filepath.Join(configHome, "projects", "default.json"),
		filepath.Join(configHome, "tools", "bin", "sops"),
	} {
		writeConfigCommandFile(t, path, "runtime state\n")
		if err := os.Chmod(path, 0o666); err != nil {
			t.Fatal(err)
		}
	}
	if err := validateManagedConfigTree(configHome); err != nil {
		t.Fatalf("runtime state was treated as managed operator config: %v", err)
	}
}

type recordingConfigApplier struct {
	yards []string
}

func (applier *recordingConfigApplier) ApplyConfig(_ context.Context, yard string) error {
	applier.yards = append(applier.yards, yard)
	return nil
}

func configCommandFixture(t *testing.T) (string, string, string, []string) {
	t.Helper()
	root := repositoryRoot(t)
	temp := t.TempDir()
	home := filepath.Join(temp, "home")
	configHome := filepath.Join(home, ".config", "subyard")
	for _, directory := range []string{home, configHome} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeConfigCommandFile(t, filepath.Join(configHome, "config.env"), "")
	environment := []string{
		"HOME=" + home,
		"SUBYARD_OPERATOR_HOME=" + home,
		"SUBYARD_CONFIG_HOME=" + configHome,
		"SUBYARD_HOME=" + filepath.Join(home, ".subyard"),
		"SUBYARD_NO_AUDIT=1",
	}
	return root, home, configHome, environment
}

func writeConfigCommandFile(t *testing.T, path, contents string, _ ...os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

func loadConfigCommandContext(t *testing.T, root string, environment []string, yard string) config.Loaded {
	t.Helper()
	values := map[string]string{}
	for _, assignment := range environment {
		name, value, _ := strings.Cut(assignment, "=")
		values[name] = value
	}
	loaded, err := config.Load(config.LoadOptions{
		RepositoryRoot: root, OperatorHome: values["SUBYARD_OPERATOR_HOME"],
		YardName: yard, Environment: values, DisablePrivate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	return loaded
}

func appendHashSteps(t *testing.T, fake *testkit.Incus, loaded config.Loaded) {
	t.Helper()
	assets, err := effectiveConfigAssets(loaded)
	if err != nil {
		t.Fatal(err)
	}
	for _, asset := range assets {
		hash, err := hashRegularFile(asset.Source)
		if err != nil {
			t.Fatal(err)
		}
		fake.ExecSteps = append(fake.ExecSteps, testkit.IncusExecStep{
			Result: ports.InstanceExecResult{
				Stdout: []byte(fmt.Sprintf("%s  %s\n", hash, asset.Destination)), ExitCode: 0,
			},
		})
	}
}
