package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Subyard/Subyard/internal/adapters/testvmsruntime"
	"github.com/Subyard/Subyard/internal/command"
	"github.com/Subyard/Subyard/internal/config"
	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/testkit"
)

func TestTestVMsUsesTypedWorkerInvocation(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	environment = append(environment, "NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=test-vms-revoke")
	incus := lifecycleIncus()
	instance := incus.Instances["subyard/yard"]
	instance.Status = "Running"
	incus.Instances["subyard/yard"] = instance
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "test-vms-revoke", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments:   []string{"test-vms", "revoke", "--slot", "2"},
		Environment: environment, WorkingDir: root, Incus: incus, AdapterRunner: runner,
		Prompt: prompt, Clock: testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("test-vms failed with %d", code)
	}
	if len(runner.Requests) != 1 || runner.Requests[0].Adapter != "test-vms" ||
		runner.Requests[0].Action != "revoke" ||
		!slices.Equal(runner.Requests[0].Arguments, []string{"revoke-slot-2", "--yes"}) {
		t.Fatalf("requests=%#v", runner.Requests)
	}
}

func TestTestVMStatusIsReadOnly(t *testing.T) {
	loaded := config.Loaded{Context: domain.Context{
		NestedE2EVMs: true, InstanceType: domain.InstanceContainer,
	}}
	program := &CLI{}
	execution, err := program.prepareTestVMExecution(
		context.Background(), loaded, []string{"status"},
	)
	if err != nil {
		t.Fatal(err)
	}
	policy := execution.policy(testDefinition("test-vms"), loaded.Context)
	if policy.Effect != domain.CommandRead {
		t.Fatalf("policy=%#v", policy)
	}
}

func TestTestVMLogsReadsHostWideLogWithoutYardBrokerContext(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	dataHome := environmentValue(environment, "SUBYARD_HOME")
	recorder := testvmsruntime.EventRecorder{
		StateDir: filepath.Join(root, "broker"),
		Source:   "test-yard",
		Now:      func() time.Time { return time.Unix(100, 0).UTC() },
	}
	if _, err := recorder.Record(testvmsruntime.BrokerEvent{
		Kind:               "recovery.available",
		SlotID:             "slot-002",
		ResourceGeneration: 2,
	}); err != nil {
		t.Fatal(err)
	}
	batch, err := recorder.Export()
	if err != nil {
		t.Fatal(err)
	}
	if err := (&testvmsruntime.HostSink{
		DataHome:    dataHome,
		Now:         func() time.Time { return time.Unix(100, 0).UTC() },
		OperatorGID: -1,
	}).Ingest(batch); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root,
		Program:        "yard",
		Arguments:      []string{"test-vms", "logs", "--slot", "2", "-n", "1"},
		Environment:    environment,
		WorkingDir:     root,
		Stdout:         &stdout,
		Stderr:         &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("logs failed: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), `"kind":"recovery.available"`) ||
		!strings.Contains(stdout.String(), `"slot_id":"slot-002"`) {
		t.Fatalf("host-wide log output = %q", stdout.String())
	}
}

func environmentValue(environment []string, name string) string {
	prefix := name + "="
	for _, assignment := range environment {
		if strings.HasPrefix(assignment, prefix) {
			return strings.TrimPrefix(assignment, prefix)
		}
	}
	return ""
}

func TestTeardownRejectsUnknownInputAndPublishesMode(t *testing.T) {
	if _, err := prepareTeardownExecution([]string{"keepdata"}); err == nil {
		t.Fatal("unsafe teardown argument was accepted")
	}
	root, environment, _ := nativeFixture(t)
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "teardown-test", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"teardown", "--keep-data"},
		Environment: append(environment, "SUBYARD_OPERATION_ID=teardown-test"), WorkingDir: root,
		AdapterRunner: runner, Prompt: prompt, Clock: testkit.NewManualClock(time.Unix(100, 0)),
		Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("teardown failed: code=%d stderr=%q", code, stderr.String())
	}
	if len(runner.Requests) != 1 || runner.Requests[0].Adapter != "teardown" ||
		runner.Requests[0].Context["SUBYARD_TEARDOWN_KEEP_DATA"] != "1" ||
		runner.Requests[0].Context["SUBYARD_TEARDOWN_KEEP_SHARED"] != "0" {
		t.Fatalf("requests=%#v", runner.Requests)
	}
}

func TestTeardownKeepsSharedIncusForAnotherRegisteredLocalYard(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	yardDirectory := filepath.Join(filepath.Dir(stateDirectory), "yards", "other")
	if err := os.MkdirAll(yardDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	writeCLIFile(t, filepath.Join(yardDirectory, "config.env"), "SSH_PORT=2223\n", 0o600)
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "teardown-shared-test", Status: "ok",
	}}}}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"teardown", "--yes"},
		Environment: append(environment, "SUBYARD_OPERATION_ID=teardown-shared-test"), WorkingDir: root,
		AdapterRunner: runner, Prompt: &testkit.Prompt{},
		Clock: testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("teardown failed with %d", code)
	}
	if len(runner.Requests) != 1 ||
		runner.Requests[0].Context["SUBYARD_TEARDOWN_KEEP_SHARED"] != "1" {
		t.Fatalf("shared Incus lifecycle was not preserved: %#v", runner.Requests)
	}
}

func testDefinition(name string) command.Definition {
	return command.Definition{Name: name, Effect: command.EffectMutate, Remote: command.RemoteForward}
}
