package cli

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Subyard/Subyard/internal/adapters/reconcileruntime"
	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/ports"
)

func TestPowerYardContextsAreDiscoveredWithoutChangingSelection(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	yardDirectory := filepath.Join(root, "state", "yards")
	if err := os.MkdirAll(yardDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	writeCLIFile(t, filepath.Join(yardDirectory, "demo.env"), "SSH_PORT=2233\n", 0o600)
	writeCLIFile(t, filepath.Join(yardDirectory, "remote.env"),
		"YARD_TYPE=remote\nREMOTE_DEST=owner.example\nREMOTE_YARD=default\n", 0o600)
	program, err := New(Options{RepositoryRoot: root, Program: "yard", Environment: environment})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	yards, err := program.powerYardContexts(loaded)
	if err != nil {
		t.Fatal(err)
	}
	if len(yards) != 2 || yards[0].YardName != "default" || yards[1].YardName != "demo" ||
		program.env["YARD_NAME"] != "" {
		t.Fatalf("power discovery changed selection or included remote yards: %#v", yards)
	}
}

func TestRealInitPlatformCarriesOnlyPreparedSudoContext(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	program, err := New(Options{RepositoryRoot: root, Program: "yard", Environment: environment})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	hasMarker := func() bool {
		platform, ok := program.initPlatform(
			loaded, []domain.Context{loaded.Context},
		).(reconcileruntime.Runtime)
		if !ok {
			t.Fatalf("unexpected real init platform %T", platform)
		}
		return slices.Contains(platform.Environment, "SUBYARD_SUDO_PREAUTHORIZED=1")
	}
	if hasMarker() {
		t.Fatal("real init platform fabricated the preauthorized sudo marker")
	}
	if err := program.prepareSudoPrivileges(
		context.Background(), io.Discard, 0, "init",
	); err != nil {
		t.Fatal(err)
	}
	if !hasMarker() {
		t.Fatal("real init platform omitted the successfully prepared sudo marker")
	}
}

type initPlatformFixture struct {
	converged      map[ports.ReconcileStageID]bool
	applied        []ports.ReconcileStageID
	preflightFresh []bool
	configs        int
	teardowns      int
}

func newInitPlatformFixture() *initPlatformFixture {
	converged := make(map[ports.ReconcileStageID]bool)
	for _, id := range []ports.ReconcileStageID{
		ports.ReconcileStageIncus, ports.ReconcileStageProject, ports.ReconcileStageNetwork,
		ports.ReconcileStagePowerImport, ports.ReconcileStageInstance, ports.ReconcileStageMounts,
		ports.ReconcileStageProvision, ports.ReconcileStageTestVMs, ports.ReconcileStageSSH,
		ports.ReconcileStageGitIdentity, ports.ReconcileStageExtras, ports.ReconcileStagePower,
		ports.ReconcileStageKeys, ports.ReconcileStageSecurity,
	} {
		converged[id] = true
	}
	converged[ports.ReconcileStageProject] = false
	return &initPlatformFixture{converged: converged}
}

func (fixture *initPlatformFixture) CheckStage(_ context.Context, stage ports.ReconcileStageID) (bool, error) {
	return fixture.converged[stage], nil
}

func (fixture *initPlatformFixture) ApplyStage(_ context.Context, stage ports.ReconcileStageID) error {
	fixture.applied = append(fixture.applied, stage)
	fixture.converged[stage] = true
	return nil
}

func (fixture *initPlatformFixture) VerifyStage(_ context.Context, stage ports.ReconcileStageID) (bool, error) {
	return fixture.converged[stage], nil
}

func (fixture *initPlatformFixture) Preflight(_ context.Context, fresh bool) error {
	fixture.preflightFresh = append(fixture.preflightFresh, fresh)
	return nil
}

func (fixture *initPlatformFixture) RefreshConfigs(context.Context) error {
	fixture.configs++
	return nil
}

func TestMigrationBrokerReconcileIsBoundedToTestVMStage(t *testing.T) {
	root := repositoryRoot(t)
	home := t.TempDir()
	configHome := filepath.Join(home, ".config", "subyard")
	yardDirectory := filepath.Join(configHome, "yards", "test-yard")
	if err := os.MkdirAll(yardDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	writeCLIFile(t, filepath.Join(yardDirectory, "config.env"),
		"YARD_TEMPLATE=test-vms\nSSH_PORT=2223\n", 0o600)
	environment := []string{
		"HOME=" + home,
		"SUBYARD_OPERATOR_HOME=" + home,
		"SUBYARD_CONFIG_HOME=" + configHome,
		"SUBYARD_HOME=" + filepath.Join(home, ".subyard"),
		"SUBYARD_NO_AUDIT=1",
	}

	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"-Y", "test-yard", "_migrate", "reconcile-test-vm-broker"},
		Environment: environment, WorkingDir: home, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code == 0 ||
		!strings.Contains(stderr.String(), "migration child is required") {
		t.Fatalf("broker reconcile accepted a public invocation: code=%d stderr=%q",
			code, stderr.String())
	}

	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	sudoLog := filepath.Join(home, "sudo.log")
	writeCLIFile(t, filepath.Join(bin, "sudo"), `#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
case "$*" in
  "-n true")
    [ -f "$SUDO_LOG.auth" ]
    ;;
  "-v")
    IFS= read -r input
    printf 'input=%s\n' "$input" >> "$SUDO_LOG"
    : > "$SUDO_LOG.auth"
    ;;
  *) exit 90 ;;
esac
`, 0o700)
	t.Setenv("PATH", bin)
	terminalPath := filepath.Join(home, "terminal")
	writeCLIFile(t, terminalPath, "migration-password\n", 0o600)
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{"-Y", "test-yard", "_migrate", "reconcile-test-vm-broker"},
		Environment: append(
			environment,
			"PATH="+bin,
			"SUDO_LOG="+sudoLog,
			"SUBYARD_INTERNAL_MIGRATION_CHILD=1",
		),
		WorkingDir: home, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	program.operatorTerminal = func() bool { return false }
	program.openTerminal = func() (*os.File, error) {
		return os.OpenFile(terminalPath, os.O_RDWR, 0)
	}
	program.effectiveUID = func() int { return 1000 }
	_ = program.Run(context.Background())
	sudoCalls, err := os.ReadFile(sudoLog)
	if err != nil {
		t.Fatal(err)
	}
	if string(sudoCalls) != "-n true\n-v\ninput=migration-password\n-n true\n" ||
		strings.Contains(stderr.String(), "sudo authorization expired") {
		t.Fatalf("migration did not authorize sudo before its real platform: calls=%q stderr=%q",
			sudoCalls, stderr.String())
	}

	platform := newInitPlatformFixture()
	platform.converged[ports.ReconcileStageTestVMs] = false
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"-Y", "test-yard", "_migrate", "reconcile-test-vm-broker"},
		Environment: append(environment, "SUBYARD_INTERNAL_MIGRATION_CHILD=1"),
		WorkingDir:  home, Stderr: &stderr, InitPlatform: platform,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("broker reconcile failed: code=%d stderr=%q", code, stderr.String())
	}
	if !slices.Equal(platform.applied, []ports.ReconcileStageID{
		ports.ReconcileStageTestVMs,
	}) {
		t.Fatalf("migration broker reconcile applied stages %v", platform.applied)
	}
	if len(platform.preflightFresh) != 0 {
		t.Fatalf("migration broker reconcile ran host preflight: %v",
			platform.preflightFresh)
	}

	platform.applied = nil
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"-Y", "test-yard", "_migrate", "reconcile-test-vm-broker"},
		Environment: append(environment, "SUBYARD_INTERNAL_MIGRATION_CHILD=1"),
		WorkingDir:  home, Stderr: &stderr, InitPlatform: platform,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("converged broker reconcile failed: code=%d stderr=%q",
			code, stderr.String())
	}
	if len(platform.applied) != 0 {
		t.Fatalf("converged migration broker reapplied stages %v", platform.applied)
	}
}

func (fixture *initPlatformFixture) Teardown(context.Context) error {
	fixture.teardowns++
	for stage := range fixture.converged {
		fixture.converged[stage] = false
	}
	return nil
}

func TestNativeInitOwnsPlanResumeAndFinalization(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	platform := newInitPlatformFixture()
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"init", "--yes"},
		Environment: environment, WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
		InitPlatform: platform,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("init failed: code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if !slices.Equal(platform.preflightFresh, []bool{false}) ||
		!slices.Equal(platform.applied, []ports.ReconcileStageID{
			ports.ReconcileStageProject, ports.ReconcileStageFinalize,
		}) {
		t.Fatalf("native init bypassed live plan/apply/finalize: preflight=%v applied=%v",
			platform.preflightFresh, platform.applied)
	}
	if !strings.Contains(stdout.String(), "[do  ] Create the Incus project") ||
		!strings.Contains(stdout.String(), "[do  ] Provision the yard") {
		t.Fatalf("init plan omitted live stage state:\n%s", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"init", "--yes"},
		Environment: environment, WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
		InitPlatform: platform,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 ||
		!strings.Contains(stdout.String(), "Everything is already set up") {
		t.Fatalf("no-op init failed: code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if len(platform.applied) != 2 {
		t.Fatalf("no-op init reapplied stages: %v", platform.applied)
	}
}

func TestNativeInitModesStayInOneConfirmedWorkflow(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	platform := newInitPlatformFixture()
	for _, arguments := range [][]string{{"init", "--configs", "--yes"}, {"init", "--reset", "--yes"}} {
		program, err := New(Options{
			RepositoryRoot: root, Program: "yard", Arguments: arguments, Environment: environment,
			WorkingDir: root, InitPlatform: platform,
		})
		if err != nil {
			t.Fatal(err)
		}
		if code := program.Run(context.Background()); code != 0 {
			t.Fatalf("%v failed with code %d", arguments, code)
		}
	}
	if platform.configs != 1 || platform.teardowns != 1 ||
		!slices.Contains(platform.preflightFresh, true) {
		t.Fatalf("init modes bypassed native workflow: %#v", platform)
	}
}
