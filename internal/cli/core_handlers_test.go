package cli

import (
	"bytes"
	"context"
	"slices"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestTestVMsUsesTypedWorkerInvocation(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	environment = append(environment, "NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=test-vms-up")
	incus := lifecycleIncus()
	instance := incus.Instances["subyard/yard"]
	instance.Status = "Running"
	incus.Instances["subyard/yard"] = instance
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "test-vms-up", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"test-vms", "up"},
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
		runner.Requests[0].Action != "up" ||
		!slices.Equal(runner.Requests[0].Arguments, []string{"up", "--yes"}) {
		t.Fatalf("requests=%#v", runner.Requests)
	}
}

func TestTestVMStatusIsReadOnly(t *testing.T) {
	loaded := config.Loaded{Context: domain.Context{
		NestedE2EVMs: true, InstanceType: domain.InstanceContainer,
	}}
	execution, err := prepareTestVMExecution(loaded, []string{"status"})
	if err != nil {
		t.Fatal(err)
	}
	policy := execution.policy(testDefinition("test-vms"), loaded.Context)
	if policy.Effect != domain.CommandRead {
		t.Fatalf("policy=%#v", policy)
	}
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
		runner.Requests[0].Context["SUBYARD_TEARDOWN_KEEP_DATA"] != "1" {
		t.Fatalf("requests=%#v", runner.Requests)
	}
}

func testDefinition(name string) command.Definition {
	return command.Definition{Name: name, Effect: command.EffectMutate, Remote: command.RemoteForward}
}
