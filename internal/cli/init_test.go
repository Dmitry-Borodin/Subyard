package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
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

type initPlatformFixture struct {
	converged      map[string]bool
	applied        []string
	preflightFresh []bool
	configs        int
	teardowns      int
	provisions     int
}

func newInitPlatformFixture() *initPlatformFixture {
	converged := make(map[string]bool)
	for _, id := range []string{
		"incus", "project", "network", "power-import", "instance", "mounts", "provision",
		"test-vms", "ssh", "git-identity", "extras", "power", "keys", "security",
	} {
		converged[id] = true
	}
	converged["project"] = false
	return &initPlatformFixture{converged: converged}
}

func (fixture *initPlatformFixture) CheckStage(_ context.Context, stage string) (bool, error) {
	return fixture.converged[stage], nil
}

func (fixture *initPlatformFixture) ApplyStage(_ context.Context, stage string) error {
	fixture.applied = append(fixture.applied, stage)
	fixture.converged[stage] = true
	return nil
}

func (fixture *initPlatformFixture) VerifyStage(_ context.Context, stage string) (bool, error) {
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

func (fixture *initPlatformFixture) Teardown(context.Context) error {
	fixture.teardowns++
	for stage := range fixture.converged {
		fixture.converged[stage] = false
	}
	return nil
}

func (fixture *initPlatformFixture) Provision(context.Context) error {
	fixture.provisions++
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
		!slices.Equal(platform.applied, []string{"project", "finalize"}) {
		t.Fatalf("native init bypassed live plan/apply/finalize: preflight=%v applied=%v",
			platform.preflightFresh, platform.applied)
	}
	if !strings.Contains(stdout.String(), "[do  ] Create the Incus project") ||
		!strings.Contains(stdout.String(), "[skip] Provision the yard") {
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
