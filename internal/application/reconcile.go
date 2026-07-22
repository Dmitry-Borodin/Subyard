package application

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type ReconcileStage struct {
	ID    string
	Label string
}

type ReconcileStep struct {
	Stage     ReconcileStage
	Converged bool
}

type ReconcilePlan struct {
	Steps []ReconcileStep
}

func (plan ReconcilePlan) Pending() int {
	pending := 0
	for _, step := range plan.Steps {
		if !step.Converged {
			pending++
		}
	}
	return pending
}

type ReconcileReporter interface {
	StageSkipped(ReconcileStage)
	StageStarted(ReconcileStage)
}

type Reconciler struct {
	Stages   []ReconcileStage
	Runner   ports.ReconcileStageRunner
	Reporter ReconcileReporter
}

func (reconciler Reconciler) Plan(ctx context.Context) (ReconcilePlan, error) {
	if err := validateStages(reconciler.Stages); err != nil {
		return ReconcilePlan{}, err
	}
	if reconciler.Runner == nil {
		return ReconcilePlan{}, errors.New("reconcile stage runner is required")
	}
	plan := ReconcilePlan{Steps: make([]ReconcileStep, 0, len(reconciler.Stages))}
	for _, stage := range reconciler.Stages {
		converged, err := reconciler.Runner.CheckStage(ctx, stage.ID)
		if err != nil {
			return ReconcilePlan{}, fmt.Errorf("check init stage %q: %w", stage.ID, err)
		}
		plan.Steps = append(plan.Steps, ReconcileStep{Stage: stage, Converged: converged})
	}
	return plan, nil
}

func (reconciler Reconciler) Apply(ctx context.Context) error {
	if err := validateStages(reconciler.Stages); err != nil {
		return err
	}
	if reconciler.Runner == nil {
		return errors.New("reconcile stage runner is required")
	}
	for _, stage := range reconciler.Stages {
		converged, err := reconciler.Runner.CheckStage(ctx, stage.ID)
		if err != nil {
			return fmt.Errorf("check init stage %q: %w", stage.ID, err)
		}
		if converged {
			if reconciler.Reporter != nil {
				reconciler.Reporter.StageSkipped(stage)
			}
			continue
		}
		if reconciler.Reporter != nil {
			reconciler.Reporter.StageStarted(stage)
		}
		if err := reconciler.Runner.ApplyStage(ctx, stage.ID); err != nil {
			return fmt.Errorf("apply init stage %q: %w", stage.ID, err)
		}
		verified, err := reconciler.Runner.VerifyStage(ctx, stage.ID)
		if err != nil {
			return fmt.Errorf("verify init stage %q: %w", stage.ID, err)
		}
		if !verified {
			return fmt.Errorf("init stage %q completed but did not converge: %s", stage.ID, stage.Label)
		}
	}
	return nil
}

func InitStages(yard domain.Context) []ReconcileStage {
	instance := "Create the yard instance (+ /dev/kvm, /srv volume)"
	if yard.NestedE2EVMs {
		instance = "Create the yard instance (+ trusted nested-VM KVM/vsock/BPF boundary, /srv volume)"
	}
	testVMs := "Keep the nested VM test backend disabled"
	if yard.NestedE2EVMs {
		testVMs = "Install/reconcile the trusted two-VM test backend inside the yard"
	}
	return []ReconcileStage{
		{ID: "incus", Label: "Install or upgrade Incus and initialize storage"},
		{ID: "project", Label: fmt.Sprintf("Create the Incus project %q", yard.IncusProject)},
		{ID: "network", Label: "Open host DHCP/DNS for the yard bridge"},
		{ID: "power-import", Label: "Import desired-power state for registered local yards"},
		{ID: "instance", Label: instance},
		{ID: "mounts", Label: fmt.Sprintf("Create host dirs under %s and mount them", yard.Paths.HostBase)},
		{ID: "provision", Label: "Provision the yard"},
		{ID: "test-vms", Label: testVMs},
		{ID: "ssh", Label: "Set up SSH access into the yard"},
		{ID: "git-identity", Label: "Reconcile in-yard git config and bind-worktree trust"},
		{ID: "extras", Label: "Apply yard extras requested by projects"},
		{ID: "power", Label: "Persist desired yard power and install host boot reconciliation"},
		{ID: "keys", Label: "Initialize the encrypted credential ledger and sync timer"},
		{ID: "security", Label: "Validate host-boundary security invariants"},
	}
}

func validateStages(stages []ReconcileStage) error {
	if len(stages) == 0 {
		return errors.New("reconcile stage registry is empty")
	}
	seen := make([]string, 0, len(stages))
	for _, stage := range stages {
		if !domain.SafeName(stage.ID) || stage.Label == "" {
			return fmt.Errorf("invalid reconcile stage %q", stage.ID)
		}
		if slices.Contains(seen, stage.ID) {
			return fmt.Errorf("duplicate reconcile stage %q", stage.ID)
		}
		seen = append(seen, stage.ID)
	}
	return nil
}
