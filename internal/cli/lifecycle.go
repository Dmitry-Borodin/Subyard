package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type lifecycleExecution struct {
	action string
	force  bool
}

func prepareLifecycleExecution(
	definition command.Definition,
	arguments []string,
) (*lifecycleExecution, error) {
	if definition.Handler != "@lifecycle" ||
		(definition.Name != "start" && definition.Name != "stop") {
		return nil, errors.New("invalid lifecycle command")
	}
	execution := &lifecycleExecution{action: definition.Name}
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
		case "--force":
			if definition.Name != "stop" {
				return nil, errors.New("--force is only valid with stop")
			}
			execution.force = true
		case "-h", "--help":
			return nil, errors.New("help is not an executable lifecycle operation")
		default:
			return nil, fmt.Errorf("unknown option %q", argument)
		}
	}
	return execution, nil
}

func (execution *lifecycleExecution) policy(
	definition command.Definition,
	yard domain.Context,
) domain.CommandPolicy {
	consequences := []string{
		fmt.Sprintf("%s Incus instance %s in project %s", execution.action,
			yard.InstanceName, yard.IncusProject),
	}
	if execution.action == "start" {
		consequences = append(consequences,
			"verify the host route before and after the start",
			"record desired power as running only after the safety checks pass",
		)
	} else {
		if execution.force {
			consequences = append(consequences, "bypass the active SSH session guard")
		} else {
			consequences = append(consequences, "refuse to stop while an SSH session is active")
		}
		consequences = append(consequences,
			"record desired power as stopped only after the instance stops",
		)
	}
	return domain.CommandPolicy{
		Name: definition.Name, Effect: domain.CommandEffect(definition.Effect),
		RemotePolicy: domain.RemotePolicy(definition.Remote), Consequences: consequences,
	}
}

func (cli *CLI) executeLifecycle(
	ctx context.Context,
	orchestrator *application.Orchestrator,
	yard domain.Context,
	plan domain.OperationPlan,
	execution *lifecycleExecution,
	diagnostics io.Writer,
) (domain.AdapterResult, error) {
	if execution == nil {
		return domain.AdapterResult{}, errors.New("lifecycle execution is required")
	}
	if execution.action == "start" && cli.options.AdapterRunner == nil {
		if err := cli.prepareStartPrivileges(ctx, diagnostics, os.Geteuid()); err != nil {
			return domain.AdapterResult{}, err
		}
	}
	power, err := cli.lifecyclePowerService()
	if err != nil {
		return domain.AdapterResult{}, err
	}
	contextValues := structuredAdapterContext(yard)
	arguments := make([]string, 0, 1)
	if execution.force {
		arguments = append(arguments, "--force")
	}
	if execution.action == "start" {
		contextValues["SUBYARD_SUDO_PREAUTHORIZED"] = "1"
	}
	orchestrator.Runner = application.LifecycleRunner{
		Power:    power,
		Physical: orchestrator.Runner, Yard: yard,
	}
	request := domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
		Adapter: "lifecycle", Action: execution.action, Arguments: arguments, Context: contextValues,
	}
	result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
	if stderr != "" {
		_, _ = io.WriteString(diagnostics, stderr)
	}
	if err == nil && result.Status == "ok" {
		if execution.action == "start" {
			fmt.Fprintf(diagnostics, "  [ ok ] %s started (desired=running)\n", yard.InstanceName)
		} else {
			fmt.Fprintf(diagnostics, "  [ ok ] %s stopped (desired=stopped)\n", yard.InstanceName)
		}
	}
	return result, err
}

func (cli *CLI) lifecyclePowerService() (application.PowerService, error) {
	incusPort, _ := cli.statusPorts()
	configWriter, ok := incusPort.(ports.InstanceConfigWriter)
	if !ok {
		return application.PowerService{}, errors.New("Incus instance config writer is required")
	}
	return application.PowerService{Instances: incusPort, Config: configWriter}, nil
}

func (cli *CLI) preparePowerIntent(ctx context.Context, yard domain.Context) (string, error) {
	power, err := cli.lifecyclePowerService()
	if err != nil {
		return "", err
	}
	intent, err := power.Ensure(ctx, yard)
	if err != nil {
		return "", err
	}
	return intent.Desired, nil
}
