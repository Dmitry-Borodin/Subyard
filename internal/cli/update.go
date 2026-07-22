package cli

import (
	"context"
	"errors"
	"io"
	"path/filepath"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/releaseruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type releaseAdapter struct{ prepared releaseruntime.Prepared }

type releaseExecution struct{ prepared releaseruntime.Prepared }

func (adapter releaseAdapter) Run(ctx context.Context, request domain.AdapterRequest, _ io.Reader) (domain.AdapterResult, string, error) {
	if request.Adapter != "release" || request.Action != "execute" {
		return domain.AdapterResult{}, "", errors.New("unsupported release adapter request")
	}
	if err := adapter.prepared.Execute(ctx); err != nil {
		return domain.AdapterResult{}, "", err
	}
	return domain.AdapterResult{Schema: shelladapter.ProtocolSchema, OperationID: request.OperationID, Status: "ok"}, "", nil
}

func (cli *CLI) runUpdate(ctx context.Context, loaded config.Loaded, definition command.Definition, arguments []string) int {
	execution, err := cli.prepareRelease(ctx, loaded, arguments)
	if err != nil {
		cli.errorf("update: %v", err)
		return 1
	}
	assumeYes := cli.env["ASSUME_YES"] == "1"
	for _, argument := range arguments {
		if argument == "-y" || argument == "--yes" {
			assumeYes = true
		}
	}
	orchestrator := cli.operationOrchestrator(cli.env["SUBYARD_OPERATION_ID"], loaded, nil, &definition)
	plan, err := orchestrator.Plan(ctx, loaded.Context, execution.policy(definition), assumeYes)
	if err != nil {
		if errors.Is(err, application.ErrDeclined) {
			cli.errorf("operation declined")
		} else {
			cli.errorf("plan update: %v", err)
		}
		return 1
	}
	result, err := cli.executeRelease(ctx, orchestrator, plan, execution)
	if err != nil {
		cli.errorf("update: %v", err)
		return 1
	}
	if result.Status != "ok" {
		cli.errorf("update returned %s", result.Status)
		return 1
	}
	return 0
}

func (cli *CLI) prepareRelease(ctx context.Context, loaded config.Loaded, arguments []string) (*releaseExecution, error) {
	runtime := releaseruntime.New(releaseruntime.Config{
		Environment: loaded.Environment,
		Installer:   filepath.Join(cli.options.RepositoryRoot, "scripts", "install-runtime-release.sh"),
		Stdout:      cli.options.Stdout,
		Stderr:      cli.options.Stderr,
	})
	prepared, err := runtime.Prepare(ctx, arguments)
	if err != nil {
		return nil, err
	}
	return &releaseExecution{prepared: prepared}, nil
}

func (execution *releaseExecution) policy(definition command.Definition) domain.CommandPolicy {
	return domain.CommandPolicy{Name: "update", Effect: execution.prepared.Effect,
		RemotePolicy: domain.RemotePolicy(definition.Remote), Consequences: execution.prepared.Consequences}
}

func (cli *CLI) executeRelease(ctx context.Context, orchestrator *application.Orchestrator,
	plan domain.OperationPlan, execution *releaseExecution) (domain.AdapterResult, error) {
	orchestrator.Runner = releaseAdapter{prepared: execution.prepared}
	result, _, err := orchestrator.RunAdapter(ctx, plan, domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID, Adapter: "release", Action: "execute",
	}, nil)
	return result, err
}
