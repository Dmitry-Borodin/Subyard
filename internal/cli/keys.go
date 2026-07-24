package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/credentialruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type credentialAdapter struct{ prepared credentialruntime.Prepared }

func (adapter credentialAdapter) Run(
	ctx context.Context,
	request domain.AdapterRequest,
	_ io.Reader,
) (domain.AdapterResult, string, error) {
	if request.Adapter != "credential" || request.Action != "execute" {
		return domain.AdapterResult{}, "", errors.New("unsupported credential adapter request")
	}
	if err := adapter.prepared.Execute(ctx); err != nil {
		return domain.AdapterResult{}, "", err
	}
	return domain.AdapterResult{
		Schema: shelladapter.ProtocolSchema, OperationID: request.OperationID, Status: "ok",
	}, "", nil
}

func (cli *CLI) credentialRuntime(loaded config.Loaded) (*credentialruntime.Runtime, error) {
	root := loaded.Environment["SUBYARD_KEYS_ROOT"]
	if root == "" {
		root = filepath.Join(loaded.Context.Paths.ConfigHome, "keys")
	}
	consumerRoot := loaded.Environment["SUBYARD_KEYS_CONSUMER_ROOT"]
	if consumerRoot == "" {
		consumerRoot = filepath.Join(loaded.Context.Paths.ConfigHome, "generated")
	}
	return credentialruntime.New(credentialruntime.Config{
		RepositoryRoot:    cli.options.RepositoryRoot,
		Root:              root,
		ConsumerRoot:      consumerRoot,
		ToolsDirectory:    loaded.Environment["SUBYARD_KEYS_TOOLS_DIR"],
		HostBase:          loaded.Context.Paths.HostBase,
		Context:           loaded.Context.YardName,
		Dispatcher:        cli.options.DispatcherPath,
		Environment:       environmentList(cli.env, loaded.Environment),
		TargetEnvironment: environmentList(cli.baseEnv, nil),
		Stdin:             cli.options.Stdin,
		Stdout:            cli.options.Stdout,
		Stderr:            cli.options.Stderr,
		Resolve: func(ctx context.Context, name string) (credentialruntime.Target, error) {
			if !domain.SafeName(name) {
				return credentialruntime.Target{}, fmt.Errorf("invalid credential target %q", name)
			}
			targetLoaded, err := cli.loadInventoryLoaded(name, loaded)
			if err != nil {
				return credentialruntime.Target{}, err
			}
			if targetLoaded.Context.YardType == domain.YardRemote {
				return credentialruntime.Target{
					Name: name, Transport: "ssh", Destination: targetLoaded.Context.RemoteDest,
					RemoteYard: targetLoaded.Context.RemoteYard,
				}, nil
			}
			return credentialruntime.Target{Name: name, Transport: "local"}, nil
		},
	})
}

func (cli *CLI) runKeys(
	ctx context.Context,
	loaded config.Loaded,
	definition command.Definition,
	arguments []string,
) int {
	runtime, err := cli.credentialRuntime(loaded)
	if err != nil {
		cli.errorf("keys: %v", err)
		return 1
	}
	prepared, err := runtime.Prepare(ctx, definition.Arg0, arguments)
	if err != nil {
		cli.errorf("keys: %v", err)
		return 1
	}
	assumeYes := definition.Visibility != command.VisibilityPublic || cli.env["ASSUME_YES"] == "1"
	for _, argument := range arguments {
		if argument == "-y" || argument == "--yes" {
			assumeYes = true
		}
	}
	name := definition.Name
	if definition.Name == "keys" && len(arguments) != 0 && !strings.HasPrefix(arguments[0], "-") {
		name += " " + arguments[0]
	}
	orchestrator := cli.operationOrchestrator(cli.env["SUBYARD_OPERATION_ID"], loaded, nil, &definition)
	plan, err := orchestrator.Plan(ctx, loaded.Context, domain.CommandPolicy{
		Name: name, Effect: prepared.Effect, RemotePolicy: domain.RemotePolicy(definition.Remote),
		Consequences: prepared.Consequences,
	}, assumeYes)
	if err != nil {
		if errors.Is(err, application.ErrDeclined) {
			cli.errorf("operation declined")
		} else {
			cli.errorf("plan %s: %v", name, err)
		}
		return 1
	}
	orchestrator.Runner = credentialAdapter{prepared: prepared}
	result, _, err := orchestrator.RunAdapter(ctx, plan, domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
		Adapter: "credential", Action: "execute",
	}, nil)
	if err != nil {
		cli.errorf("%s: %v", name, err)
		return 1
	}
	if result.Status != "ok" {
		cli.errorf("%s returned %s", name, result.Status)
		return 1
	}
	return 0
}
