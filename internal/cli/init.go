package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/reconcileruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type initMode uint8

const (
	initReconcile initMode = iota
	initConfigs
	initReset
)

type initExecution struct {
	loaded   config.Loaded
	mode     initMode
	plan     application.ReconcilePlan
	platform ports.InitPlatform
}

type initReporter struct{ output io.Writer }

func (reporter initReporter) StageSkipped(stage application.ReconcileStage) {
	fmt.Fprintf(reporter.output, "  [ .. ] %s (already converged)\n", stage.ID)
}

func (reporter initReporter) StageStarted(stage application.ReconcileStage) {
	fmt.Fprintf(reporter.output, "  [ .. ] %s\n", stage.ID)
}

func parseInitArguments(arguments []string) (initMode, error) {
	mode := initReconcile
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
		case "--configs":
			if mode == initReset {
				return 0, errors.New("--configs and --reset cannot be used together")
			}
			mode = initConfigs
		case "--reset":
			if mode == initConfigs {
				return 0, errors.New("--configs and --reset cannot be used together")
			}
			mode = initReset
		default:
			return 0, fmt.Errorf("unknown option %q", argument)
		}
	}
	return mode, nil
}

func (cli *CLI) initPlatform(loaded config.Loaded, powerYards []domain.Context) ports.InitPlatform {
	if cli.options.InitPlatform != nil {
		return cli.options.InitPlatform
	}
	environment := structuredCommandContext(loaded)
	environment["SUBYARD_DISPATCHER_PATH"] = cli.options.DispatcherPath
	incusPort, executor := cli.statusPorts()
	configWriter, _ := incusPort.(ports.InstanceConfigWriter)
	return reconcileruntime.Runtime{
		RepositoryRoot: cli.options.RepositoryRoot,
		Environment:    environmentList(cli.env, environment),
		Stdin:          cli.options.Stdin,
		Stdout:         cli.options.Stderr,
		Stderr:         cli.options.Stderr,
		Incus:          incusPort,
		ConfigWriter:   configWriter,
		Executor:       executor,
		Yard:           loaded.Context,
		PowerYards:     powerYards,
		SRVPool:        loaded.Environment["SRV_POOL"],
		SRVVolume:      loaded.Environment["SRV_VOLUME"],
	}
}

func (cli *CLI) powerYardContexts(current config.Loaded) ([]domain.Context, error) {
	directories := config.RegistryDirectories(
		current.Context.Paths.ConfigDir, current.Context.Paths.ConfigHome,
	)
	names, err := config.YardNames(directories...)
	if err != nil {
		return nil, err
	}
	operatorHome := current.Context.Paths.OperatorHome
	result := make([]domain.Context, 0, len(names))
	for _, name := range names {
		environment := make(map[string]string, len(cli.baseEnv))
		for key, value := range cli.baseEnv {
			environment[key] = value
		}
		loaded, err := config.Load(config.LoadOptions{
			RepositoryRoot: cli.options.RepositoryRoot,
			OperatorHome:   operatorHome,
			YardName:       name,
			Environment:    environment,
		})
		if err != nil {
			return nil, fmt.Errorf("load power context %q: %w", name, err)
		}
		if loaded.Context.YardType != domain.YardRemote {
			result = append(result, loaded.Context)
		}
	}
	return result, nil
}

func (cli *CLI) prepareInitExecution(
	ctx context.Context,
	loaded config.Loaded,
	arguments []string,
) (*initExecution, error) {
	mode, err := parseInitArguments(arguments)
	if err != nil {
		return nil, err
	}
	var platform ports.InitPlatform
	if cli.options.InitPlatform != nil {
		platform = cli.options.InitPlatform
	} else {
		powerYards, err := cli.powerYardContexts(loaded)
		if err != nil {
			return nil, err
		}
		platform = cli.initPlatform(loaded, powerYards)
	}
	execution := &initExecution{loaded: loaded, mode: mode, platform: platform}
	if mode == initConfigs {
		return execution, nil
	}
	stages := application.InitStages(loaded.Context)
	if mode == initReset {
		execution.plan.Steps = make([]application.ReconcileStep, 0, len(stages))
		for _, stage := range stages {
			execution.plan.Steps = append(execution.plan.Steps, application.ReconcileStep{Stage: stage})
		}
	} else {
		execution.plan, err = (application.Reconciler{Stages: stages, Runner: execution.platform}).Plan(ctx)
		if err != nil {
			return nil, err
		}
	}
	if execution.plan.Pending() != 0 {
		if err := execution.platform.Preflight(ctx, mode == initReset); err != nil {
			return nil, fmt.Errorf("host preflight failed: %w", err)
		}
	}
	return execution, nil
}

func (execution *initExecution) consequences() []string {
	switch execution.mode {
	case initConfigs:
		return []string{"refresh in-yard agent instructions and default configs"}
	case initReset:
		result := []string{"delete the yard instance and its disk data"}
		for _, step := range execution.plan.Steps {
			result = append(result, step.Stage.Label)
		}
		return result
	default:
		result := make([]string, 0, execution.plan.Pending())
		for _, step := range execution.plan.Steps {
			if !step.Converged {
				result = append(result, step.Stage.Label)
			}
		}
		return result
	}
}

func (cli *CLI) printInitPlan(execution *initExecution) {
	if execution.mode == initConfigs {
		fmt.Fprintln(cli.options.Stdout, "init --configs: refresh agent configuration")
		return
	}
	fmt.Fprintln(cli.options.Stdout, "\nSubyard init")
	for _, step := range execution.plan.Steps {
		state := "do"
		if step.Converged {
			state = "skip"
		}
		fmt.Fprintf(cli.options.Stdout, "  [%-4s] %s\n", state, step.Stage.Label)
	}
}

func (execution *initExecution) run(ctx context.Context, cli *CLI, output io.Writer) error {
	if execution.mode == initConfigs {
		return execution.platform.RefreshConfigs(ctx)
	}
	if execution.mode == initReset {
		if err := execution.platform.Teardown(ctx); err != nil {
			return fmt.Errorf("teardown before reset: %w", err)
		}
	}
	reconciler := application.Reconciler{
		Stages: application.InitStages(execution.loaded.Context), Runner: execution.platform,
		Reporter: initReporter{output: output},
	}
	if err := reconciler.Apply(ctx); err != nil {
		return err
	}
	if err := cli.printInitProvisionHint(ctx, execution, output); err != nil {
		return err
	}
	finalizer := application.Reconciler{
		Stages: []application.ReconcileStage{{
			ID: "finalize", Label: "Restore and commit the configured desired yard power state",
		}},
		Runner: execution.platform, Reporter: initReporter{output: output},
	}
	if err := finalizer.Apply(ctx); err != nil {
		return err
	}
	fmt.Fprintln(output, "  [ ok ] Subyard initialized")
	return nil
}

func (cli *CLI) printInitProvisionHint(
	ctx context.Context,
	execution *initExecution,
	output io.Writer,
) error {
	project, err := cli.prepareProjectInventory(ctx, execution.loaded, nil)
	if err != nil {
		return err
	}
	provision, err := cli.prepareProvisionExecution(execution.loaded, nil, project)
	if err != nil {
		return err
	}
	profiles := provision.profiles
	hint := cli.yardHint(execution.loaded.Context)
	if len(profiles) == 0 {
		fmt.Fprintf(output, "  %s provision -l\n", hint)
		return nil
	}
	fmt.Fprintf(output, "  %s provision    # %s\n", hint, strings.Join(profiles, " "))
	return nil
}

type initAdapter struct {
	execution *initExecution
	cli       *CLI
	output    io.Writer
}

func (adapter initAdapter) Run(
	ctx context.Context,
	request domain.AdapterRequest,
	_ io.Reader,
) (domain.AdapterResult, string, error) {
	if request.Adapter != "init" || request.Action != "reconcile" || adapter.execution == nil {
		return domain.AdapterResult{}, "", errors.New("invalid init adapter request")
	}
	if err := adapter.execution.run(ctx, adapter.cli, adapter.output); err != nil {
		return domain.AdapterResult{}, "", err
	}
	return domain.AdapterResult{
		Schema: 1, OperationID: request.OperationID, Status: "ok",
		Output: map[string]any{"pending": adapter.execution.plan.Pending()},
	}, "", nil
}
