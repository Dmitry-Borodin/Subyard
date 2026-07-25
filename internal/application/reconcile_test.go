package application

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

type reconcileFixture struct {
	converged map[string]bool
	checkErr  map[string]error
	checked   []string
	failOnce  map[string]bool
	verified  map[string]bool
	applied   []string
}

func (fixture *reconcileFixture) CheckStage(_ context.Context, id string) (bool, error) {
	fixture.checked = append(fixture.checked, id)
	if err := fixture.checkErr[id]; err != nil {
		return false, err
	}
	return fixture.converged[id], nil
}

func (fixture *reconcileFixture) ApplyStage(_ context.Context, id string) error {
	fixture.applied = append(fixture.applied, id)
	if fixture.failOnce[id] {
		delete(fixture.failOnce, id)
		return errors.New("fixture failure")
	}
	fixture.converged[id] = true
	return nil
}

func (fixture *reconcileFixture) VerifyStage(_ context.Context, id string) (bool, error) {
	if value, exists := fixture.verified[id]; exists {
		return value, nil
	}
	return fixture.converged[id], nil
}

func TestReconcilerPlansLiveStateAndResumesAfterFailure(t *testing.T) {
	stages := []ReconcileStage{{ID: "a", Label: "A"}, {ID: "b", Label: "B"}}
	fixture := &reconcileFixture{
		converged: map[string]bool{"a": true}, failOnce: map[string]bool{"b": true},
		verified: map[string]bool{},
	}
	reconciler := Reconciler{Stages: stages, Runner: fixture}
	plan, err := reconciler.Plan(context.Background())
	if err != nil || plan.Pending() != 1 || !plan.Steps[0].Converged || plan.Steps[1].Converged {
		t.Fatalf("unexpected plan: %#v, %v", plan, err)
	}
	if err := reconciler.Apply(context.Background()); err == nil {
		t.Fatal("partial failure was reported as success")
	}
	if err := reconciler.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fixture.applied, []string{"b", "b"}) {
		t.Fatalf("resume reapplied converged work: %#v", fixture.applied)
	}
	fixture.converged["a"] = false
	if err := reconciler.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fixture.applied, []string{"b", "b", "a"}) {
		t.Fatalf("drift repair disturbed converged work: %#v", fixture.applied)
	}
}

func TestReconcilerPlanDoesNotCheckStagesAfterFirstPendingStage(t *testing.T) {
	stages := []ReconcileStage{{ID: "base", Label: "Base"}, {ID: "dependent", Label: "Dependent"}}
	fixture := &reconcileFixture{
		converged: map[string]bool{"base": false},
		checkErr:  map[string]error{"dependent": errors.New("base is unavailable")},
	}
	plan, err := (Reconciler{Stages: stages, Runner: fixture}).Plan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if plan.Pending() != 2 || !reflect.DeepEqual(fixture.checked, []string{"base"}) {
		t.Fatalf("dependent stages were checked before their prerequisites: plan=%#v checked=%v",
			plan, fixture.checked)
	}
}

func TestReconcilerFailsClosedOnRegistryAndVerification(t *testing.T) {
	fixture := &reconcileFixture{
		converged: map[string]bool{}, failOnce: map[string]bool{}, verified: map[string]bool{"a": false},
	}
	reconciler := Reconciler{Stages: []ReconcileStage{{ID: "a", Label: "A"}}, Runner: fixture}
	if err := reconciler.Apply(context.Background()); err == nil || !strings.Contains(err.Error(), "did not converge") {
		t.Fatalf("failed verification was accepted: %v", err)
	}
	for _, stages := range [][]ReconcileStage{
		nil,
		{{ID: "a", Label: "A"}, {ID: "a", Label: "duplicate"}},
		{{ID: "../bad", Label: "bad"}},
	} {
		if _, err := (Reconciler{Stages: stages, Runner: fixture}).Plan(context.Background()); err == nil {
			t.Fatalf("invalid registry was accepted: %#v", stages)
		}
	}
}
