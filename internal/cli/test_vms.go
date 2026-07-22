package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type testVMExecution struct{ action string }

func prepareTestVMExecution(loaded config.Loaded, arguments []string) (*testVMExecution, error) {
	if !loaded.Context.NestedE2EVMs {
		return nil, errors.New("nested E2E VMs are disabled for this yard")
	}
	if loaded.Context.InstanceType != domain.InstanceContainer {
		return nil, errors.New("nested E2E VMs require a container yard")
	}
	action := ""
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
		case "-h", "--help":
			return nil, errors.New("help is not an executable test-vms operation")
		default:
			if action != "" {
				return nil, errors.New("test-vms accepts one command")
			}
			action = argument
		}
	}
	if action != "up" && action != "status" && action != "down" {
		return nil, fmt.Errorf("unknown test-vms command %q", action)
	}
	return &testVMExecution{action: action}, nil
}

func (execution *testVMExecution) policy(definition command.Definition, yard domain.Context) domain.CommandPolicy {
	effect := domain.CommandEffect(definition.Effect)
	consequences := []string{"read the two-VM allocation status"}
	if execution.action == "status" {
		effect = domain.CommandRead
	} else if execution.action == "up" {
		consequences = []string{
			"create or start two disposable VMs inside " + yard.InstanceName,
			"publish restricted agent SSH access and enforce the allocation TTL",
		}
	} else {
		consequences = []string{
			"delete the two managed VMs and their inner Incus project",
			"revoke agent forwarding and remove the synthetic worker identity",
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
	arguments := []string{execution.action}
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
