package application

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestPlanRoutesAndConfirmsMutation(t *testing.T) {
	clock := testkit.NewManualClock(time.Unix(100, 0))
	prompt := &testkit.Prompt{Answers: []bool{true}}
	orchestrator := &Orchestrator{Clock: clock, IDs: &testkit.IDs{Values: []string{"operation-1"}}, Prompt: prompt}
	plan, err := orchestrator.Plan(context.Background(), domain.Context{YardType: domain.YardRemote}, domain.CommandPolicy{
		Name: "start", Effect: domain.CommandMutate, RemotePolicy: domain.RemoteOnOwner,
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Target != domain.TargetRemoteOwner || !plan.Confirmed || len(prompt.Seen) != 1 {
		t.Fatalf("unexpected plan: %#v", plan)
	}
}

func TestPlanDeclineAndRemoteDeny(t *testing.T) {
	orchestrator := &Orchestrator{
		Clock: testkit.NewManualClock(time.Unix(100, 0)), IDs: &testkit.IDs{Values: []string{"unused"}},
		Prompt: &testkit.Prompt{Answers: []bool{false}},
	}
	_, err := orchestrator.Plan(context.Background(), domain.Context{YardType: domain.YardLocal}, domain.CommandPolicy{
		Name: "stop", Effect: domain.CommandMutate, RemotePolicy: domain.RemoteOnOwner,
	}, false)
	if !errors.Is(err, ErrDeclined) {
		t.Fatalf("expected decline, got %v", err)
	}
	_, err = orchestrator.Plan(context.Background(), domain.Context{YardType: domain.YardRemote}, domain.CommandPolicy{
		Name: "bind", Effect: domain.CommandMutate, RemotePolicy: domain.RemoteDenied,
	}, true)
	if err == nil {
		t.Fatal("remote bind was planned")
	}
}

func TestPlanRejectsInvalidRemotePolicyForLocalYard(t *testing.T) {
	orchestrator := &Orchestrator{
		Clock: testkit.NewManualClock(time.Unix(100, 0)), IDs: &testkit.IDs{Values: []string{"unused"}},
	}
	_, err := orchestrator.Plan(context.Background(), domain.Context{YardType: domain.YardLocal}, domain.CommandPolicy{
		Name: "status", Effect: domain.CommandRead, RemotePolicy: "unknown",
	}, false)
	if err == nil || !strings.Contains(err.Error(), "invalid remote command policy") {
		t.Fatalf("invalid policy was accepted: %v", err)
	}
}

func TestRunAdapterCorrelatesAuditAndEvents(t *testing.T) {
	clock := testkit.NewManualClock(time.Unix(100, 0))
	audit := &testkit.Audit{}
	events := &testkit.Events{}
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-1", Status: "ok",
	}}}}
	orchestrator := &Orchestrator{Clock: clock, Runner: runner, Audit: audit, Events: events}
	plan := domain.OperationPlan{OperationID: "operation-1", Command: "fixture"}
	request := domain.AdapterRequest{Schema: 1, OperationID: "operation-1", Adapter: "fixture", Action: "run"}
	if _, _, err := orchestrator.RunAdapter(context.Background(), plan, request, strings.NewReader("protected")); err != nil {
		t.Fatal(err)
	}
	if len(audit.Events) != 2 || len(events.Events) != 2 || audit.Events[0].OperationID != "operation-1" {
		t.Fatalf("events were not correlated: %#v %#v", audit.Events, events.Events)
	}
}

func TestEventTrackerDetectsDuplicateGapAndRevisionRegression(t *testing.T) {
	tracker := NewEventTracker(3)
	if err := tracker.Accept(domain.OperationEvent{Sequence: 1, Revision: 4}); err != nil {
		t.Fatal(err)
	}
	if err := tracker.Accept(domain.OperationEvent{Sequence: 1, Revision: 4}); !errors.Is(err, ErrEventReordered) {
		t.Fatalf("duplicate not detected: %v", err)
	}
	if err := tracker.Accept(domain.OperationEvent{Sequence: 3, Revision: 5}); !errors.Is(err, ErrEventGap) {
		t.Fatalf("gap not detected: %v", err)
	}
	if err := tracker.Accept(domain.OperationEvent{Sequence: 2, Revision: 2}); !errors.Is(err, ErrEventReordered) {
		t.Fatalf("revision regression not detected: %v", err)
	}
	if err := NewEventTracker(3).Accept(domain.OperationEvent{Sequence: 2, Revision: 4}); !errors.Is(err, ErrEventGap) {
		t.Fatalf("initial gap not detected: %v", err)
	}
}
