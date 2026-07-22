package application

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type ProvisionReporter interface {
	ProfileStarted(string)
	ProfileCompleted(string)
}

type ProvisionRunner struct {
	Power    PowerService
	Physical ports.AdapterRunner
	Yard     domain.Context
	Profiles []string
	Reporter ProvisionReporter
}

func (runner ProvisionRunner) Run(
	ctx context.Context,
	request domain.AdapterRequest,
	_ io.Reader,
) (result domain.AdapterResult, diagnostics string, err error) {
	if request.Adapter != "provision" || request.Action != "apply" {
		return domain.AdapterResult{}, "", errors.New("invalid provision adapter request")
	}
	if runner.Power.Instances == nil || runner.Physical == nil {
		return domain.AdapterResult{}, "", errors.New("provision ports are required")
	}
	intent, err := runner.Power.Ensure(ctx, runner.Yard)
	if err != nil {
		return domain.AdapterResult{}, "", fmt.Errorf("prepare power metadata: %w", err)
	}
	instance, err := runner.Power.Instances.Instance(ctx, runner.Yard.IncusProject, runner.Yard.InstanceName)
	if err != nil {
		return domain.AdapterResult{}, "", err
	}
	started := false
	var output strings.Builder
	if strings.EqualFold(instance.Status, "stopped") {
		physical := request
		physical.Adapter = "lifecycle"
		physical.Action = "start"
		physical.Arguments = []string{"--reconcile"}
		physicalResult, text, physicalErr := runner.Physical.Run(ctx, physical, nil)
		output.WriteString(text)
		if physicalErr != nil || physicalResult.Status != "ok" {
			return physicalResult, output.String(), physicalErr
		}
		started = true
	} else if !strings.EqualFold(instance.Status, "running") {
		return domain.AdapterResult{}, output.String(), fmt.Errorf("cannot provision while yard state is %q", instance.Status)
	}

	restore := func() error {
		if !started || intent.Desired != PowerStopped {
			return nil
		}
		physical := request
		physical.Adapter = "lifecycle"
		physical.Action = "stop"
		physical.Arguments = []string{"--reconcile"}
		physicalResult, text, physicalErr := runner.Physical.Run(ctx, physical, nil)
		output.WriteString(text)
		if physicalErr != nil {
			return physicalErr
		}
		if physicalResult.Status != "ok" {
			return fmt.Errorf("restore stopped yard: adapter returned %s", physicalResult.Status)
		}
		started = false
		return nil
	}

	for _, profile := range runner.Profiles {
		if runner.Reporter != nil {
			runner.Reporter.ProfileStarted(profile)
		}
		physical := request
		physical.Action = "profile"
		physical.Arguments = []string{profile}
		physicalResult, text, execErr := runner.Physical.Run(ctx, physical, nil)
		output.WriteString(text)
		if execErr == nil && physicalResult.Status != "ok" {
			execErr = fmt.Errorf("adapter returned %s", physicalResult.Status)
		}
		if execErr != nil {
			restoreErr := restore()
			if restoreErr != nil {
				return domain.AdapterResult{}, output.String(), errors.Join(
					fmt.Errorf("provision profile %q: %w", profile, execErr),
					fmt.Errorf("restore yard power: %w", restoreErr),
				)
			}
			return domain.AdapterResult{}, output.String(), fmt.Errorf("provision profile %q: %w", profile, execErr)
		}
		if runner.Reporter != nil {
			runner.Reporter.ProfileCompleted(profile)
		}
	}
	if err := restore(); err != nil {
		return domain.AdapterResult{}, output.String(), fmt.Errorf("restore yard power: %w", err)
	}
	return domain.AdapterResult{
		Schema: request.Schema, OperationID: request.OperationID, Status: "ok",
		Output: map[string]any{"profiles": len(runner.Profiles), "desiredPower": intent.Desired},
	}, output.String(), nil
}
