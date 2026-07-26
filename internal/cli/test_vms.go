package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/Subyard/Subyard/internal/adapters/shelladapter"
	"github.com/Subyard/Subyard/internal/application"
	"github.com/Subyard/Subyard/internal/command"
	"github.com/Subyard/Subyard/internal/config"
	"github.com/Subyard/Subyard/internal/domain"
)

type testVMExecution struct {
	action string
	slot   int
}

func (cli *CLI) prepareTestVMExecution(
	_ context.Context,
	loaded config.Loaded,
	arguments []string,
) (*testVMExecution, error) {
	if !loaded.Context.NestedE2EVMs {
		return nil, errors.New("nested E2E VMs are disabled for this yard")
	}
	if loaded.Context.InstanceType != domain.InstanceContainer {
		return nil, errors.New("nested E2E VMs require a container yard")
	}
	action := ""
	slot := 0
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		switch argument {
		case "-y", "--yes":
		case "-h", "--help":
			return nil, errors.New("help is not an executable test-vms operation")
		case "--slot":
			index++
			if index >= len(arguments) {
				return nil, errors.New("--slot requires a number")
			}
			var err error
			slot, err = strconv.Atoi(arguments[index])
			if err != nil || slot < 1 {
				return nil, errors.New("--slot requires a positive integer")
			}
		default:
			if strings.HasPrefix(argument, "-") {
				return nil, fmt.Errorf("unknown test-vms option %q", argument)
			}
			if action != "" {
				return nil, errors.New("test-vms accepts one command")
			}
			action = argument
		}
	}
	switch action {
	case "status":
		if slot != 0 {
			return nil, errors.New("--slot is not valid for status")
		}
	case "revoke", "recover":
		if slot == 0 {
			return nil, fmt.Errorf("%s requires --slot N", action)
		}
	default:
		return nil, fmt.Errorf("unknown test-vms command %q", action)
	}
	return &testVMExecution{action: action, slot: slot}, nil
}

func (execution *testVMExecution) policy(
	definition command.Definition,
	_ domain.Context,
) domain.CommandPolicy {
	effect := domain.CommandEffect(definition.Effect)
	consequences := []string{"read the configured test VM lease pool"}
	switch execution.action {
	case "status":
		effect = domain.CommandRead
	case "revoke":
		consequences = []string{
			fmt.Sprintf("fence and stop active lease slot %d", execution.slot),
			"retain both VM disks and the slot network/project",
		}
	case "recover":
		consequences = []string{
			fmt.Sprintf("recover quarantined lease slot %d", execution.slot),
			"delete only marker-owned VM instances stuck in ERROR state",
			"repeat lease fencing and stop before publishing the slot as available",
		}
	}
	return domain.CommandPolicy{
		Name: definition.Name, Effect: effect, RemotePolicy: domain.RemotePolicy(definition.Remote),
		Consequences: consequences,
	}
}

func (cli *CLI) executeTestVMs(
	ctx context.Context,
	orchestrator *application.Orchestrator,
	loaded config.Loaded,
	plan domain.OperationPlan,
	execution *testVMExecution,
	diagnostics io.Writer,
) (domain.AdapterResult, error) {
	if execution == nil {
		return domain.AdapterResult{}, errors.New("test-vms execution is required")
	}
	incusPort, _ := cli.statusPorts()
	instance, err := incusPort.Instance(ctx, loaded.Context.IncusProject, loaded.Context.InstanceName)
	if err != nil {
		return domain.AdapterResult{}, err
	}
	if !strings.EqualFold(instance.Status, "running") {
		return domain.AdapterResult{}, fmt.Errorf("yard %q must be running", loaded.Context.InstanceName)
	}
	argument := execution.action
	if execution.action == "revoke" {
		argument = fmt.Sprintf("revoke-slot-%d", execution.slot)
	} else if execution.action == "recover" {
		argument = fmt.Sprintf("recover-slot-%d", execution.slot)
	}
	arguments := []string{argument}
	if execution.action != "status" {
		arguments = append(arguments, "--yes")
	}
	request := domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
		Adapter: "test-vms", Action: execution.action, Arguments: arguments,
		Context: structuredCommandContext(loaded),
	}
	result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
	writeAdapterDiagnostics(diagnostics, stderr)
	return result, err
}
