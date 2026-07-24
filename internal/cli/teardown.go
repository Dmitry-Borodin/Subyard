package cli

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type teardownExecution struct{ keepData bool }

func prepareTeardownExecution(arguments []string) (*teardownExecution, error) {
	execution := &teardownExecution{}
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
		case "--keep-data":
			execution.keepData = true
		case "-h", "--help":
			return nil, errors.New("help is not an executable teardown operation")
		default:
			return nil, fmt.Errorf("unknown teardown argument %q", argument)
		}
	}
	return execution, nil
}

func (execution *teardownExecution) policy(definition command.Definition, yard domain.Context) domain.CommandPolicy {
	consequences := []string{
		"delete yard instance " + yard.InstanceName,
		"remove this yard's SSH config and project state",
	}
	if execution.keepData {
		consequences = append(consequences, "keep the project, bridge, storage pool and /srv data")
	} else {
		consequences = append(consequences,
			"delete the yard project and /srv volume",
			"delete the shared bridge, storage pool and disk data only when no other instance or registered local yard uses them",
			"remove the NetworkManager guard only after the bridge disappears",
		)
	}
	return domain.CommandPolicy{
		Name: definition.Name, Effect: domain.CommandEffect(definition.Effect),
		RemotePolicy: domain.RemotePolicy(definition.Remote), Consequences: consequences,
	}
}

func (cli *CLI) executeTeardown(
	ctx context.Context,
	orchestrator *application.Orchestrator,
	loaded config.Loaded,
	plan domain.OperationPlan,
	execution *teardownExecution,
	diagnostics io.Writer,
) (domain.AdapterResult, error) {
	if execution == nil {
		return domain.AdapterResult{}, errors.New("teardown execution is required")
	}
	contextValues := structuredCommandContext(loaded)
	if execution.keepData {
		contextValues["SUBYARD_TEARDOWN_KEEP_DATA"] = "1"
	} else {
		contextValues["SUBYARD_TEARDOWN_KEEP_DATA"] = "0"
	}
	yards, err := cli.powerYardContexts(loaded)
	if err != nil {
		return domain.AdapterResult{}, fmt.Errorf("discover local yards before teardown: %w", err)
	}
	contextValues["SUBYARD_TEARDOWN_KEEP_SHARED"] = "0"
	if hasOtherRegisteredLocalYard(loaded.Context.YardName, yards) {
		contextValues["SUBYARD_TEARDOWN_KEEP_SHARED"] = "1"
	}
	request := domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
		Adapter: "teardown", Action: "apply", Arguments: []string{"--yes"}, Context: contextValues,
	}
	result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
	writeAdapterDiagnostics(diagnostics, stderr)
	return result, err
}

func hasOtherRegisteredLocalYard(current string, yards []domain.Context) bool {
	for _, yard := range yards {
		if yard.YardType == domain.YardLocal &&
			yard.YardName != "default" && yard.YardName != current {
			return true
		}
	}
	return false
}
