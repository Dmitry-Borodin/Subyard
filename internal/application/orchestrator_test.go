package application

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/testkit"
)

func TestPlanRoutesAndConfirmsMutation(t *testing.T) {
	clock := testkit.NewManualClock(time.Unix(100, 0))
	prompt := &testkit.Prompt{Answers: []bool{true}}
	orchestrator := &Orchestrator{Clock: clock, IDs: &testkit.IDs{Values: []string{"operation-1"}}, Prompt: prompt}
	plan, err := orchestrator.Plan(context.Background(), domain.Context{YardType: domain.YardRemote}, domain.CommandPolicy{
		Name: "start", Effect: domain.CommandMutate, Confirmation: domain.ConfirmationRequired,
		RemotePolicy: domain.RemoteOnOwner,
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
		Name: "stop", Effect: domain.CommandMutate, Confirmation: domain.ConfirmationRequired,
		RemotePolicy: domain.RemoteOnOwner,
	}, false)
	if !errors.Is(err, ErrDeclined) {
		t.Fatalf("expected decline, got %v", err)
	}
	_, err = orchestrator.Plan(context.Background(), domain.Context{YardType: domain.YardRemote}, domain.CommandPolicy{
		Name: "bind", Effect: domain.CommandMutate, Confirmation: domain.ConfirmationRequired,
		RemotePolicy: domain.RemoteDenied,
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
		Name: "status", Effect: domain.CommandRead, Confirmation: domain.ConfirmationNever,
		RemotePolicy: "unknown",
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
	plan := domain.OperationPlan{
		OperationID: "operation-1", Command: "fixture", Effect: domain.CommandMutate,
		Confirmation: domain.ConfirmationRequired, Confirmed: true,
	}
	request := domain.AdapterRequest{Schema: 1, OperationID: "operation-1", Adapter: "fixture", Action: "run"}
	if _, _, err := orchestrator.RunAdapter(context.Background(), plan, request, strings.NewReader("protected")); err != nil {
		t.Fatal(err)
	}
	if len(audit.Events) != 2 || len(events.Events) != 2 || audit.Events[0].OperationID != "operation-1" {
		t.Fatalf("events were not correlated: %#v %#v", audit.Events, events.Events)
	}
}

func TestPrepareKeepsMutationUnconfirmedUntilExplicitConfirmation(t *testing.T) {
	orchestrator := &Orchestrator{
		Clock: testkit.NewManualClock(time.Unix(100, 0)), IDs: &testkit.IDs{Values: []string{"operation-1"}},
	}
	plan, err := orchestrator.Prepare(domain.Context{YardType: domain.YardLocal}, domain.CommandPolicy{
		Name: "start", Effect: domain.CommandMutate, Confirmation: domain.ConfirmationRequired,
		RemotePolicy: domain.RemoteOnOwner,
		Consequences: []string{"start the fixture"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Confirmed || plan.Effect != domain.CommandMutate || len(plan.Consequences) != 1 {
		t.Fatalf("unexpected prepared plan: %#v", plan)
	}
	confirmed, err := orchestrator.Confirm(context.Background(), plan, true)
	if err != nil || !confirmed.Confirmed {
		t.Fatalf("explicit confirmation failed: plan=%#v err=%v", confirmed, err)
	}
	request := domain.AdapterRequest{Schema: 1, OperationID: plan.OperationID, Adapter: "fixture", Action: "run"}
	if _, _, err := orchestrator.RunAdapter(context.Background(), plan, request, nil); err == nil {
		t.Fatal("unconfirmed plan reached the adapter")
	}
}

func TestPlanSkipsPromptOnlyForExplicitNeverPolicy(t *testing.T) {
	prompt := &testkit.Prompt{}
	orchestrator := &Orchestrator{
		Clock: testkit.NewManualClock(time.Unix(100, 0)),
		IDs:   &testkit.IDs{Values: []string{"operation-launch"}}, Prompt: prompt,
	}
	plan, err := orchestrator.Plan(context.Background(), domain.Context{YardType: domain.YardLocal}, domain.CommandPolicy{
		Name: "code", Effect: domain.CommandMutate, Confirmation: domain.ConfirmationNever,
		RemotePolicy: domain.RemoteOnController,
	}, false)
	if err != nil || !plan.Confirmed || len(prompt.Seen) != 0 {
		t.Fatalf("prompt-free plan = %#v, prompts=%#v, err=%v", plan, prompt.Seen, err)
	}
	if _, err := orchestrator.Prepare(domain.Context{YardType: domain.YardLocal}, domain.CommandPolicy{
		Name: "missing", Effect: domain.CommandMutate, RemotePolicy: domain.RemoteOnOwner,
	}); err == nil {
		t.Fatal("missing confirmation policy was accepted")
	}
}
