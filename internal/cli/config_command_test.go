package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/configsync"
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
		"shipped-defaults: " + filepath.Join(root, "config"),
		"configuration-root: " + configHome,
		"source host-scalar-settings: " + filepath.Join(configHome, "config.env") + " (present)",
		"file-setting codex.rules: " + hostRule + " (scope=host, role=file settings, consumer=",
	} {
		if !strings.Contains(output, expected) {
			t.Fatalf("config paths omitted %q:\n%s", expected, output)
		}
	}
	if strings.Contains(output, "private-canary-value") || strings.Contains(output, home+"/.subyard/operator-overlay") {
		t.Fatalf("config paths leaked a value or legacy source:\n%s", output)
	}
}

func TestConfigShowExplainsScalarDerivedAndFileSettingsWithoutSecrets(t *testing.T) {
	root, _, configHome, environment := configCommandFixture(t)
	hostRule := filepath.Join(
		configHome, "overrides", "host", "agents", "codex", "rules", "repo.rules",
	)
	writeConfigCommandFile(t, hostRule, "secret-file-contents\n")
	writeConfigCommandFile(t, filepath.Join(configHome, "config.env"),
		"SSH_PORT=2200\n")
	yardFile := filepath.Join(configHome, "yards", "named", "config.env")
	writeConfigCommandFile(t, yardFile, "SSH_PORT=2300\n")
	environment = append(environment, "SSH_PORT=2400", "SECRET_TOKEN=s3cr3t-command-value")

	for _, test := range []struct {
		name      string
		arguments []string
		contains  []string
	}{
		{
			name: "summary", arguments: []string{"-Y", "named", "config", "show"},
			contains: []string{
				"SETTING", "SSH_PORT", "2400", "command", "environment", "next command",
				"AGENT_codex_RULES", hostRule, "config apply",
			},
		},
		{
			name:      "scalar precedence",
			arguments: []string{"-Y", "named", "config", "show", "SSH_PORT"},
			contains: []string{
				"setting: SSH_PORT", "effective: 2400", "shipped defaults",
				filepath.Join(configHome, "config.env") + ":1", yardFile + ":1",
				"environment", "overridden", "effective",
			},
		},
		{
			name:      "derived setting",
			arguments: []string{"-Y", "named", "config", "show", "INSTANCE_NAME"},
			contains: []string{
				"setting: INSTANCE_NAME", "effective: yard-named", "derived from yard name",
			},
		},
		{
			name:      "file setting",
			arguments: []string{"-Y", "named", "config", "show", "AGENT_codex_RULES"},
			contains: []string{
				"setting: AGENT_codex_RULES", hostRule, "file settings",
				"effective file source",
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			program, err := New(Options{
				RepositoryRoot: root, Program: "yard", Arguments: test.arguments,
				Environment: environment, WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
			})
			if err != nil {
				t.Fatal(err)
			}
			if code := program.Run(context.Background()); code != 0 {
				t.Fatalf("config show failed: code=%d stderr=%s", code, stderr.String())
			}
			output := stdout.String()
			for _, expected := range test.contains {
				if !strings.Contains(output, expected) {
					t.Fatalf("config show omitted %q:\n%s", expected, output)
				}
			}
			for _, secret := range []string{
				"s3cr3t-host-value", "s3cr3t-command-value", "secret-file-contents",
			} {
				if strings.Contains(output+stderr.String(), secret) {
					t.Fatalf("config show leaked %q:\n%s%s", secret, output, stderr.String())
				}
			}
		})
	}

	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"-Y", "named", "config", "show", "SECRET_TOKEN"},
		Environment: environment, WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 2 ||
		!strings.Contains(stderr.String(), `unknown setting "SECRET_TOKEN"`) {
		t.Fatalf("unknown setting diagnostic: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	for _, secret := range []string{"s3cr3t-host-value", "s3cr3t-command-value"} {
		if strings.Contains(stdout.String()+stderr.String(), secret) {
			t.Fatalf("unknown setting diagnostic leaked %q", secret)
		}
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
	if !strings.Contains(stdout.String(), "yard default materialized-config: converged") ||
		!strings.Contains(stdout.String(), "yard named materialized-config: converged") ||
		strings.Contains(stdout.String(), "yard remote materialized-config:") {
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

func TestConfigApplyRejectsUnsafeSettingsTreeBeforeMutation(t *testing.T) {
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
		t.Fatalf("runtime state was treated as managed settings: %v", err)
	}
}

func TestConfigSyncCheckIsReadOnlyAndMutationPromptsOnce(t *testing.T) {
	root, _, configHome, environment := configCommandFixture(t)
	environment = append(environment, "SUBYARD_HOST_ID=owner-a")
	source := filepath.Join(t.TempDir(), "source")
	if err := os.MkdirAll(filepath.Join(source, "hosts", "owner-a"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeConfigCommandFile(t, filepath.Join(source, "subyard-config.json"),
		"{\n  \"schemaVersion\": 1\n}\n")
	writeConfigCommandFile(t, filepath.Join(source, "hosts", "owner-a", "config.env"),
		"SSH_PORT=2290\n")
	runConfigSyncGit(t, source, "init", "-q")
	runConfigSyncGit(t, source, "add", "-A")
	runConfigSyncGit(t, source,
		"-c", "user.name=Subyard Test", "-c", "user.email=test@invalid",
		"commit", "-q", "-m", "initial")

	checkPrompt := &testkit.Prompt{}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "sync", source, "--check", "--adopt"},
		Environment: environment, WorkingDir: root, Prompt: checkPrompt,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 ||
		!strings.Contains(stdout.String(), "changes required") {
		t.Fatalf("config sync check: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if len(checkPrompt.Seen) != 0 {
		t.Fatalf("read-only check prompted: %#v", checkPrompt.Seen)
	}
	content, err := os.ReadFile(filepath.Join(configHome, "config.env"))
	if err != nil || len(content) != 0 {
		t.Fatalf("read-only check changed live config: %q %v", content, err)
	}
	if _, err := os.Lstat(filepath.Join(configHome, ".sync", "manifest.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("read-only check wrote a manifest: %v", err)
	}

	applyPrompt := &testkit.Prompt{Answers: []bool{true}}
	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "sync", source, "--adopt"},
		Environment: environment, WorkingDir: root, Prompt: applyPrompt,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("config sync apply: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if len(applyPrompt.Seen) != 1 {
		t.Fatalf("config sync prompted %d times: %#v", len(applyPrompt.Seen), applyPrompt.Seen)
	}
	content, err = os.ReadFile(filepath.Join(configHome, "config.env"))
	if err != nil || string(content) != "SSH_PORT=2290\n" {
		t.Fatalf("config sync did not apply host settings: %q %v", content, err)
	}

	convergedPrompt := &testkit.Prompt{}
	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "sync", source},
		Environment: environment, WorkingDir: root, Prompt: convergedPrompt,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 ||
		!strings.Contains(stdout.String(), "already converged") {
		t.Fatalf("converged config sync: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if len(convergedPrompt.Seen) != 0 {
		t.Fatalf("converged sync prompted: %#v", convergedPrompt.Seen)
	}
}

func TestConfigSyncCheckLeavesRecoveryPendingAndMutationRecoversFirst(t *testing.T) {
	root, _, configHome, environment := configCommandFixture(t)
	environment = append(environment, "SUBYARD_HOST_ID=owner-a")
	transactionID := "1-dddddddddddddddd"
	transactionRoot := filepath.Join(
		configHome, ".sync", "transactions", transactionID,
	)
	if err := os.MkdirAll(transactionRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	writeConfigCommandFile(
		t, filepath.Join(configHome, ".sync", "transaction.json"),
		fmt.Sprintf(`{
  "schemaVersion": 1,
  "id": %q,
  "phase": "applying",
  "planDigest": %q,
  "newManifestDigest": %q,
  "applied": 0,
  "entries": []
}
`, transactionID, strings.Repeat("a", 64), strings.Repeat("b", 64)),
	)
	source := filepath.Join(t.TempDir(), "source")
	if err := os.MkdirAll(filepath.Join(source, "hosts", "owner-a"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeConfigCommandFile(t, filepath.Join(source, "subyard-config.json"),
		"{\n  \"schemaVersion\": 1\n}\n")
	writeConfigCommandFile(t, filepath.Join(source, "hosts", "owner-a", "config.env"),
		"SSH_PORT=2291\n")
	runConfigSyncGit(t, source, "init", "-q")
	runConfigSyncGit(t, source, "add", "-A")
	runConfigSyncGit(t, source,
		"-c", "user.name=Subyard Test", "-c", "user.email=test@invalid",
		"commit", "-q", "-m", "initial")

	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "sync", source, "--check", "--adopt"},
		Environment: environment, WorkingDir: root, Prompt: &testkit.Prompt{},
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 ||
		!strings.Contains(stderr.String(), "interrupted transaction requires recovery") {
		t.Fatalf("pending recovery check: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if _, err := os.Lstat(filepath.Join(configHome, ".sync", "transaction.json")); err != nil {
		t.Fatalf("read-only check changed pending recovery state: %v", err)
	}

	prompt := &testkit.Prompt{Answers: []bool{true}}
	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "sync", source, "--adopt"},
		Environment: environment, WorkingDir: root, Prompt: prompt,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("recovery-first sync: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if len(prompt.Seen) != 1 {
		t.Fatalf("recovery-first sync prompted %d times: %#v", len(prompt.Seen), prompt.Seen)
	}
	if _, err := os.Lstat(filepath.Join(configHome, ".sync", "transaction.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful recovery left its journal: %v", err)
	}
	content, err := os.ReadFile(filepath.Join(configHome, "config.env"))
	if err != nil || string(content) != "SSH_PORT=2291\n" {
		t.Fatalf("recovery-first sync did not apply source: %q %v", content, err)
	}
}

func TestConfigSourceConnectClonesRegistersAndAppliesWithOnePrompt(t *testing.T) {
	root, home, configHome, environment := configCommandFixture(t)
	source := configSourceGitRepository(t, "owner-a", "SSH_PORT=2292\n")
	checkout := filepath.Join(home, ".local", "share", "subyard-config")
	prompt := &testkit.Prompt{Answers: []bool{true}}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{
			"config", "source", "connect", source,
			"--host-id", "owner-a",
		},
		Environment: environment, WorkingDir: root, Prompt: prompt,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("source connect: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if len(prompt.Seen) != 1 {
		t.Fatalf("source connect prompted %d times: %#v", len(prompt.Seen), prompt.Seen)
	}
	for _, expected := range []string{
		"Configuration source onboarding",
		"checkout: " + checkout,
		"owner-host: owner-a",
		"config source: connected " + checkout,
		"config sync: applied generation 1",
	} {
		if !strings.Contains(stdout.String(), expected) {
			t.Fatalf("source connect omitted %q:\n%s", expected, stdout.String())
		}
	}
	content, err := os.ReadFile(filepath.Join(configHome, "config.env"))
	if err != nil || string(content) != "SSH_PORT=2292\n" {
		t.Fatalf("source connect did not apply host config: %q %v", content, err)
	}
	record, exists, err := configsync.ReadSourceRecord(configHome)
	if err != nil || !exists || record.Checkout != checkout {
		t.Fatalf("source record: %#v exists=%v err=%v", record, exists, err)
	}
	origin := strings.TrimSpace(configSourceGitOutput(
		t, checkout, "remote", "get-url", "origin",
	))
	if origin != source {
		t.Fatalf("cloned origin = %q, want %q", origin, source)
	}

	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "source", "path"},
		Environment: environment, WorkingDir: root,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 ||
		strings.TrimSpace(stdout.String()) != checkout {
		t.Fatalf("source path: code=%d stdout=%q stderr=%q",
			code, stdout.String(), stderr.String())
	}

	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"config", "sync"},
		Environment: environment, WorkingDir: root, Prompt: &testkit.Prompt{},
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 ||
		!strings.Contains(stdout.String(), "already converged") {
		t.Fatalf("registered source sync: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}

	idempotentPrompt := &testkit.Prompt{}
	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{
			"config", "source", "connect", source,
			"--host-id", "owner-a", "--checkout", checkout,
		},
		Environment: environment, WorkingDir: root, Prompt: idempotentPrompt,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 ||
		!strings.Contains(stdout.String(), "already connected and converged") {
		t.Fatalf("idempotent connect: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if len(idempotentPrompt.Seen) != 0 {
		t.Fatalf("idempotent connect prompted: %#v", idempotentPrompt.Seen)
	}
}

func TestConfigSourceConnectDeclineLeavesNoCheckoutOrRegistration(t *testing.T) {
	root, home, configHome, environment := configCommandFixture(t)
	source := configSourceGitRepository(t, "owner-a", "SSH_PORT=2293\n")
	checkout := filepath.Join(home, "declined-source")
	prompt := &testkit.Prompt{Answers: []bool{false}}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{
			"config", "source", "connect", source,
			"--host-id", "owner-a", "--checkout", checkout,
		},
		Environment: environment, WorkingDir: root, Prompt: prompt,
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 ||
		!strings.Contains(stderr.String(), "operation declined") {
		t.Fatalf("declined source connect: code=%d stdout=%s stderr=%s",
			code, stdout.String(), stderr.String())
	}
	if _, err := os.Lstat(checkout); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("declined connect left checkout: %v", err)
	}
	if _, exists, err := configsync.ReadSourceRecord(configHome); err != nil || exists {
		t.Fatalf("declined connect registered source: exists=%v err=%v", exists, err)
	}
	stages, err := filepath.Glob(filepath.Join(home, sourceStagePrefix+"*"))
	if err != nil || len(stages) != 0 {
		t.Fatalf("declined connect left stages: %#v err=%v", stages, err)
	}
	content, err := os.ReadFile(filepath.Join(configHome, "config.env"))
	if err != nil || len(content) != 0 {
		t.Fatalf("declined connect changed live config: %q %v", content, err)
	}
}

func TestConfigSourceConnectRejectsEmbeddedCredentialsAndRemoteForwards(t *testing.T) {
	root, home, configHome, environment := configCommandFixture(t)
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{
			"config", "source", "connect",
			"https://token@example.invalid/private.git",
		},
		Environment: environment, WorkingDir: root,
		Stdout: &bytes.Buffer{}, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 ||
		!strings.Contains(stderr.String(), "credentials must not be embedded") {
		t.Fatalf("credential URL: code=%d stderr=%s", code, stderr.String())
	}

	writeConfigCommandFile(t,
		filepath.Join(configHome, "yards", "remote", "config.env"),
		"YARD_TYPE=remote\nREMOTE_DEST=owner.example\nREMOTE_YARD=inner\nSSH_PORT=4444\n")
	fakeBin := filepath.Join(home, "fake-bin")
	logPath := filepath.Join(home, "ssh-arguments")
	writeConfigCommandFile(t, filepath.Join(fakeBin, "ssh"), `#!/bin/sh
printf '%s\n' "$@" >"$SUBYARD_TEST_SSH_LOG"
`, 0o700)
	t.Setenv("PATH", fakeBin+":"+os.Getenv("PATH"))
	environment = append(environment,
		"PATH="+os.Getenv("PATH"),
		"SUBYARD_TEST_SSH_LOG="+logPath)
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{
			"-Y", "remote", "config", "source", "connect",
			"git@example.invalid:private/config.git",
			"--host-id", "owner-b", "--yes",
		},
		Environment: environment, WorkingDir: root,
		Stdout: &bytes.Buffer{}, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("remote source forwarding: code=%d stderr=%s", code, stderr.String())
	}
	forwarded, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	output := string(forwarded)
	for _, expected := range []string{
		"-t\nowner.example\n--\nbash\n-lc\n",
		`'\''yard'\'' '\''-Y'\'' '\''inner'\'' '\''config'\'' '\''source'\'' '\''connect'\''`,
		"git@example.invalid:private/config.git",
		"--host-id",
		"owner-b",
		"--yes",
	} {
		if !strings.Contains(output, expected) {
			t.Fatalf("remote source forwarding omitted %q:\n%s", expected, output)
		}
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

func writeConfigCommandFile(t *testing.T, path, contents string, modes ...os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	mode := os.FileMode(0o600)
	if len(modes) != 0 {
		mode = modes[0]
	}
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
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

func runConfigSyncGit(t *testing.T, directory string, arguments ...string) {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", directory}, arguments...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v: %s", strings.Join(arguments, " "), err, output)
	}
}

func configSourceGitRepository(
	t *testing.T,
	hostID string,
	hostConfig string,
) string {
	t.Helper()
	source := filepath.Join(t.TempDir(), "source")
	writeConfigCommandFile(t, filepath.Join(source, "subyard-config.json"),
		"{\n  \"schemaVersion\": 1\n}\n")
	writeConfigCommandFile(t,
		filepath.Join(source, "hosts", hostID, "config.env"), hostConfig)
	runConfigSyncGit(t, source, "init", "-q")
	runConfigSyncGit(t, source, "add", "-A")
	runConfigSyncGit(t, source,
		"-c", "user.name=Subyard Test", "-c", "user.email=test@invalid",
		"commit", "-q", "-m", "initial")
	return source
}

func configSourceGitOutput(
	t *testing.T,
	directory string,
	arguments ...string,
) string {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", directory}, arguments...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v: %s", strings.Join(arguments, " "), err, output)
	}
	return string(output)
}
