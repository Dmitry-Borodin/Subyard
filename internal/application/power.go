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

const (
	PowerRunning = "running"
	PowerStopped = "stopped"
)

var ErrPowerUnmanaged = errors.New("power intent is unmanaged")

type PowerIntent struct {
	Desired  string
	Imported bool
}

type PowerService struct {
	Instances ports.Incus
	Config    ports.InstanceConfigWriter
}

func (service PowerService) Converged(
	ctx context.Context,
	yard domain.Context,
) (bool, error) {
	if service.Instances == nil {
		return false, errors.New("Incus instance reader is required")
	}
	instance, err := service.Instances.Instance(ctx, yard.IncusProject, yard.InstanceName)
	if err != nil {
		return false, err
	}
	return powerMetadataConverged(instance, yard)
}

func (service PowerService) Ensure(
	ctx context.Context,
	yard domain.Context,
) (PowerIntent, error) {
	if service.Instances == nil || service.Config == nil {
		return PowerIntent{}, errors.New("Incus instance reader and config writer are required")
	}
	instance, err := service.Instances.Instance(ctx, yard.IncusProject, yard.InstanceName)
	if err != nil {
		return PowerIntent{}, err
	}
	values, intent, err := powerMetadataUpdate(instance, yard)
	if err != nil {
		return PowerIntent{}, err
	}
	if err := service.Config.SetInstanceConfig(
		ctx, yard.IncusProject, yard.InstanceName, values,
	); err != nil {
		return PowerIntent{}, err
	}
	return intent, nil
}

func (service PowerService) Intent(
	ctx context.Context,
	yard domain.Context,
) (PowerIntent, error) {
	if service.Instances == nil {
		return PowerIntent{}, errors.New("Incus instance reader is required")
	}
	instance, err := service.Instances.Instance(ctx, yard.IncusProject, yard.InstanceName)
	if err != nil {
		return PowerIntent{}, err
	}
	converged, err := powerMetadataConverged(instance, yard)
	if err != nil {
		return PowerIntent{}, err
	}
	if !converged {
		return PowerIntent{}, fmt.Errorf("%w: %s/%s", ErrPowerUnmanaged,
			yard.IncusProject, yard.InstanceName)
	}
	return PowerIntent{Desired: instanceConfig(instance, "user.subyard.desired_power")}, nil
}

func InitialPower(yard domain.Context) string {
	if yard.YardName == "" || yard.YardName == "default" {
		return PowerRunning
	}
	return PowerStopped
}

func (service PowerService) Set(
	ctx context.Context,
	yard domain.Context,
	desired string,
	initialized bool,
) error {
	if service.Config == nil {
		return errors.New("Incus instance config writer is required")
	}
	if desired != PowerRunning && desired != PowerStopped {
		return fmt.Errorf("invalid desired power %q", desired)
	}
	name, bridge := powerIdentity(yard)
	return service.Config.SetInstanceConfig(ctx, yard.IncusProject, yard.InstanceName, map[string]string{
		"boot.autostart":             "false",
		"user.subyard.managed":       "true",
		"user.subyard.name":          name,
		"user.subyard.bridge":        bridge,
		"user.subyard.desired_power": desired,
		"user.subyard.initialized":   fmt.Sprint(initialized),
	})
}

func (service PowerService) Commit(
	ctx context.Context,
	yard domain.Context,
	desired string,
) error {
	return service.Set(ctx, yard, desired, true)
}

type LifecycleRunner struct {
	Power    PowerService
	Physical ports.AdapterRunner
	Yard     domain.Context
}

func (runner LifecycleRunner) Run(
	ctx context.Context,
	request domain.AdapterRequest,
	protected io.Reader,
) (domain.AdapterResult, string, error) {
	if request.Adapter != "lifecycle" || (request.Action != "start" && request.Action != "stop") {
		return domain.AdapterResult{}, "", errors.New("invalid lifecycle adapter request")
	}
	if runner.Physical == nil {
		return domain.AdapterResult{}, "", errors.New("physical lifecycle adapter is required")
	}
	if _, err := runner.Power.Ensure(ctx, runner.Yard); err != nil {
		return domain.AdapterResult{}, "", fmt.Errorf("prepare power metadata: %w", err)
	}
	physical := request
	physical.Arguments = append([]string{request.Action}, request.Arguments...)
	result, diagnostics, err := runner.Physical.Run(ctx, physical, protected)
	if err != nil || result.Status != "ok" {
		return result, diagnostics, err
	}
	desired := PowerStopped
	if request.Action == "start" {
		desired = PowerRunning
	}
	if err := runner.Power.Commit(ctx, runner.Yard, desired); err != nil {
		return result, diagnostics, fmt.Errorf("physical %s succeeded but desired power was not committed: %w",
			request.Action, err)
	}
	if result.Output == nil {
		result.Output = make(map[string]any)
	}
	result.Output["desiredPower"] = desired
	return result, diagnostics, nil
}

func powerMetadataConverged(instance ports.InstanceInfo, yard domain.Context) (bool, error) {
	managed := instanceConfig(instance, "user.subyard.managed")
	if managed == "" {
		return false, nil
	}
	if managed != "true" {
		return false, fmt.Errorf("%s/%s has invalid managed power metadata %q",
			yard.IncusProject, yard.InstanceName, managed)
	}
	desired := instanceConfig(instance, "user.subyard.desired_power")
	if desired != PowerRunning && desired != PowerStopped {
		return false, fmt.Errorf("%s/%s has invalid desired power %q",
			yard.IncusProject, yard.InstanceName, desired)
	}
	initialized := instanceConfig(instance, "user.subyard.initialized")
	if initialized != "true" && initialized != "false" {
		return false, fmt.Errorf("%s/%s has invalid initialized power metadata %q",
			yard.IncusProject, yard.InstanceName, initialized)
	}
	name, bridge := powerIdentity(yard)
	return instanceConfig(instance, "user.subyard.name") == name &&
		instanceConfig(instance, "user.subyard.bridge") == bridge &&
		instanceConfig(instance, "boot.autostart") == "false", nil
}

func powerMetadataUpdate(
	instance ports.InstanceInfo,
	yard domain.Context,
) (map[string]string, PowerIntent, error) {
	name, bridge := powerIdentity(yard)
	values := map[string]string{
		"user.subyard.name": name, "user.subyard.bridge": bridge, "boot.autostart": "false",
	}
	managed := instanceConfig(instance, "user.subyard.managed")
	if managed == "true" {
		if _, err := powerMetadataConverged(instance, yard); err != nil {
			return nil, PowerIntent{}, err
		}
		return values, PowerIntent{Desired: instanceConfig(instance, "user.subyard.desired_power")}, nil
	}
	if managed != "" {
		return nil, PowerIntent{}, fmt.Errorf("%s/%s has invalid managed power metadata %q",
			yard.IncusProject, yard.InstanceName, managed)
	}
	desired := ""
	switch strings.ToLower(instance.Status) {
	case "running":
		desired = PowerRunning
	case "stopped":
		desired = PowerStopped
	default:
		return nil, PowerIntent{}, fmt.Errorf("cannot import %s/%s power state from %q",
			yard.IncusProject, yard.InstanceName, instance.Status)
	}
	values["user.subyard.managed"] = "true"
	values["user.subyard.desired_power"] = desired
	values["user.subyard.initialized"] = "true"
	return values, PowerIntent{Desired: desired, Imported: true}, nil
}

func powerIdentity(yard domain.Context) (string, string) {
	name := yard.YardName
	if name == "" {
		name = "default"
	}
	bridge := yard.IncusBridge
	if bridge == "" {
		bridge = "incusbr0"
	}
	return name, bridge
}

func instanceConfig(instance ports.InstanceInfo, name string) string {
	if value := instance.LocalConfig[name]; value != "" {
		return value
	}
	return instance.Config[name]
}
