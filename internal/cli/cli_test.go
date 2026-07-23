package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestRepositoryQueriesUseGoManifest(t *testing.T) {
	var stdout bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: repositoryRoot(t), Program: "yard", Arguments: []string{"--command-effect", "status"},
		Environment: []string{"HOME=" + t.TempDir(), "SUBYARD_NO_AUDIT=1"}, Stdout: &stdout,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 || stdout.String() != "read\n" {
		t.Fatalf("manifest query failed: code=%d output=%q", code, stdout.String())
	}
}

func TestValidatedContextIsHandedToShellAdapterWithoutReload(t *testing.T) {
	root := t.TempDir()
	for _, directory := range []string{"config", "scripts"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	manifest := "show||show.sh||local|read|public|lifecycle|simple|show|show context||\n"
	writeCLIFile(t, filepath.Join(root, "config", "commands.registry"), manifest, 0o600)
	for _, name := range []string{"incus.project.env", "subyard.env", "host.env", "agents.env", "ports.env"} {
		writeCLIFile(t, filepath.Join(root, "config", name), "", 0o600)
	}
	writeCLIFile(t, filepath.Join(root, "scripts", "show.sh"), `#!/bin/sh
printf '%s|%s|%s\n' "$SUBYARD_CONFIG_LOADED" "$SSH_HOST" "$HOST_BASE"
`, 0o700)
	home := filepath.Join(root, "home")
	hostBase := filepath.Join(root, "host")
	environment := []string{
		"HOME=" + home, "SUBYARD_OPERATOR_HOME=" + home,
		"SUBYARD_CONFIG_HOME=" + filepath.Join(root, "state"),
		"SUBYARD_HOME=" + filepath.Join(root, "data"),
		"STORAGE_PATH=" + filepath.Join(root, "data", "storage"),
		"HOST_BASE=" + hostBase, "RESTRICTED_DISK_PATHS=" + hostBase,
		"SHIFT_MODE=shift", "FORWARD_SSH_AGENT=0", "DEV_SUDO=0", "DEV_UID=1000", "SSH_PORT=2222",
		"SUBYARD_NO_AUDIT=1",
	}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"show"}, Environment: environment,
		WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("adapter failed: code=%d stderr=%q", code, stderr.String())
	}
	if stdout.String() != "1|yard|"+hostBase+"\n" {
		t.Fatalf("validated context was not handed off: %q", stdout.String())
	}
}

func TestUnknownCommandIsDiagnosticOnly(t *testing.T) {
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: repositoryRoot(t), Program: "yard", Arguments: []string{"not-a-command"},
		Environment: []string{"HOME=" + t.TempDir(), "SUBYARD_NO_AUDIT=1"}, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 2 || !strings.Contains(stderr.String(), "unknown command") {
		t.Fatalf("unexpected diagnostic: code=%d stderr=%q", code, stderr.String())
	}
}

func TestOldYardTeardownRequiresCanonicalTemplateMigration(t *testing.T) {
	root := t.TempDir()
	configHome := filepath.Join(root, "config-home")
	yardFile := filepath.Join(configHome, "yards", "e2e-yard.env")
	for _, directory := range []string{
		filepath.Join(root, "config", "yards", "profiles"),
		filepath.Join(configHome, "yards"),
		filepath.Join(root, "scripts"),
	} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeCLIFile(t, filepath.Join(root, "config", "commands.registry"), strings.Join([]string{
		"teardown|uninstall|99-teardown.sh||forward|mutate|public|lifecycle|teardown|teardown|delete the yard|--keep-data --yes --help|",
		"list||@list||local|read|public|projects|simple|list|list projects currently registered in yards|--live --help|",
		"yards||@yards||local|read|public|lifecycle|simple|yards|list registered local and remote yards|--help|",
	}, "\n")+"\n", 0o600)
	for _, name := range []string{"incus.project.env", "subyard.env", "host.env", "agents.env", "ports.env"} {
		writeCLIFile(t, filepath.Join(root, "config", name), "", 0o600)
	}
	writeCLIFile(t, filepath.Join(root, "config", "yards", "profiles", "test-vms.env"),
		"NESTED_E2E_VMS=1\n", 0o600)
	writeCLIFile(t, filepath.Join(root, "scripts", "99-teardown.sh"), "#!/bin/sh\nexit 90\n", 0o700)
	writeCLIFile(t, yardFile, "YARD_TEMPLATE=e2e-vms\nSSH_PORT=3333\n", 0o600)

	home := filepath.Join(root, "home")
	hostBase := filepath.Join(root, "host")
	environment := []string{
		"HOME=" + home,
		"SUBYARD_OPERATOR_HOME=" + home,
		"SUBYARD_CONFIG_HOME=" + configHome,
		"SUBYARD_HOME=" + filepath.Join(root, "data"),
		"STORAGE_PATH=" + filepath.Join(root, "data", "storage"),
		"HOST_BASE=" + hostBase,
		"RESTRICTED_DISK_PATHS=" + hostBase,
		"SHIFT_MODE=shift",
		"FORWARD_SSH_AGENT=0",
		"DEV_SUDO=0",
		"DEV_UID=1000",
		"DEV_USER=dev",
		"SSH_PORT=2222",
		"SUBYARD_NO_AUDIT=1",
		"SUBYARD_OPERATION_ID=operation-teardown",
	}
	for _, query := range []string{"list", "yards"} {
		queryEnvironment := append([]string(nil), environment...)
		queryEnvironment = append(queryEnvironment, "SUBYARD_YARD=e2e-yard")
		var stdout, stderr bytes.Buffer
		program, err := New(Options{
			RepositoryRoot: root,
			Program:        "yard",
			Arguments:      []string{query},
			Environment:    queryEnvironment,
			WorkingDir:     root,
			Stdout:         &stdout,
			Stderr:         &stderr,
		})
		if err != nil {
			t.Fatal(err)
		}
		if code := program.Run(context.Background()); code != 0 {
			t.Fatalf("global %s was blocked by retired registration: code=%d stderr=%q",
				query, code, stderr.String())
		}
		if !strings.Contains(stderr.String(), "requires registration migration") &&
			!strings.Contains(stderr.String(), "until its registration is migrated") {
			t.Fatalf("global %s omitted the retired-yard warning: %q", query, stderr.String())
		}
		if !strings.Contains(stderr.String(), "YARD_TEMPLATE=test-vms") {
			t.Fatalf("global %s omitted the migration command: %q", query, stderr.String())
		}
		if query == "yards" && !strings.Contains(stdout.String(), "NAME") {
			t.Fatalf("global yards omitted its inventory header: %q", stdout.String())
		}
	}

	var explicitListStderr bytes.Buffer
	explicitList, err := New(Options{
		RepositoryRoot: root,
		Program:        "yard",
		Arguments:      []string{"-Y", "e2e-yard", "list"},
		Environment:    environment,
		WorkingDir:     root,
		Stderr:         &explicitListStderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := explicitList.Run(context.Background()); code == 0 ||
		!strings.Contains(explicitListStderr.String(), "YARD_TEMPLATE=test-vms") {
		t.Fatalf("explicit retired-yard list did not fail closed: code=%d stderr=%q",
			code, explicitListStderr.String())
	}

	retiredRunner := &testkit.ScriptedAdapter{}
	var retiredStderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root,
		Program:        "yard",
		Arguments:      []string{"-Y", "e2e-yard", "teardown", "--yes"},
		Environment:    environment,
		WorkingDir:     root,
		Stderr:         &retiredStderr,
		AdapterRunner:  retiredRunner,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code == 0 {
		t.Fatal("teardown loaded the retired template")
	}
	if len(retiredRunner.Requests) != 0 ||
		!strings.Contains(retiredStderr.String(), yardFile) ||
		!strings.Contains(retiredStderr.String(), "YARD_TEMPLATE=test-vms") {
		t.Fatalf("retired registration did not fail before teardown: requests=%#v stderr=%q",
			retiredRunner.Requests, retiredStderr.String())
	}

	writeCLIFile(t, yardFile, "YARD_TEMPLATE=test-vms\nSSH_PORT=3333\n", 0o600)
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-teardown", Status: "ok",
	}}}}
	var stderr bytes.Buffer
	program, err = New(Options{
		RepositoryRoot: root,
		Program:        "yard",
		Arguments:      []string{"-Y", "e2e-yard", "teardown", "--yes"},
		Environment:    environment,
		WorkingDir:     root,
		Stderr:         &stderr,
		AdapterRunner:  runner,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("canonical-template teardown failed: code=%d stderr=%q", code, stderr.String())
	}
	if len(runner.Requests) != 1 ||
		runner.Requests[0].Action != "teardown" ||
		runner.Requests[0].Context["YARD_NAME"] != "e2e-yard" ||
		runner.Requests[0].Context["INCUS_PROJECT"] != "subyard-e2e-yard" ||
		runner.Requests[0].Context["YARD_TEMPLATE"] != "test-vms" ||
		runner.Requests[0].Context["SUBYARD_SUDO_PREAUTHORIZED"] != "1" {
		t.Fatalf("teardown lost the migrated old-yard identity: %#v", runner.Requests)
	}
}

func TestMigrationPathsLoadExplicitMachineContext(t *testing.T) {
	home := t.TempDir()
	configHome := filepath.Join(home, ".config", "subyard")
	dataHome := filepath.Join(home, ".subyard")
	explicitState := filepath.Join(home, "custom-projects")
	for _, directory := range []string{configHome, dataHome, explicitState} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: repositoryRoot(t), Program: "yard",
		Arguments: []string{"_migrate", "paths"},
		Environment: []string{
			"HOME=" + home, "SUBYARD_OPERATOR_HOME=" + home,
			"SUBYARD_CONFIG_HOME=" + configHome, "SUBYARD_HOME=" + dataHome,
			"SUBYARD_STATE_DIR=" + explicitState, "SUBYARD_NO_AUDIT=1",
		},
		WorkingDir: home, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("migration paths failed: code=%d stderr=%q", code, stderr.String())
	}
	var payload struct {
		ConfigHome         string   `json:"configHome"`
		DataHome           string   `json:"dataHome"`
		ProjectDirectories []string `json:"projectDirectories"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.ConfigHome != configHome || payload.DataHome != dataHome {
		t.Fatalf("migration roots do not use loaded context: %#v", payload)
	}
	if len(payload.ProjectDirectories) != 2 ||
		payload.ProjectDirectories[0] != filepath.Join(configHome, "projects") ||
		payload.ProjectDirectories[1] != explicitState {
		t.Fatalf("migration state roots are missing or duplicated: %#v", payload.ProjectDirectories)
	}
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve source path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(source), "..", ".."))
}

func writeCLIFile(t *testing.T, path, contents string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
}
