package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type provisionExecution struct {
	profiles []string
	list     bool
}

type provisionReporter struct{ output io.Writer }

func (reporter provisionReporter) ProfileStarted(name string) {
	fmt.Fprintf(reporter.output, "  [ .. ] provisioning %s\n", name)
}

func (reporter provisionReporter) ProfileCompleted(name string) {
	fmt.Fprintf(reporter.output, "  [ ok ] provisioned %s\n", name)
}

func (cli *CLI) prepareProvisionExecution(
	loaded config.Loaded,
	arguments []string,
	project *projectExecution,
) (*provisionExecution, error) {
	want := ""
	list := false
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
		case "-l", "--list":
			list = true
		case "-h", "--help":
			return nil, errors.New("help is not an executable provision operation")
		default:
			if strings.HasPrefix(argument, "-") {
				return nil, fmt.Errorf("unknown option %q", argument)
			}
			if want != "" {
				return nil, errors.New("provision accepts at most one profile")
			}
			if !domain.SafeName(argument) {
				return nil, fmt.Errorf("invalid profile %q", argument)
			}
			want = argument
		}
	}
	if list && want != "" {
		return nil, errors.New("--list does not accept a profile")
	}

	available, err := provisionableProfiles(cli.options.RepositoryRoot)
	if err != nil {
		return nil, err
	}
	if list {
		return &provisionExecution{profiles: available, list: true}, nil
	}
	byName := make(map[string]bool, len(available))
	for _, profile := range available {
		byName[profile] = true
	}
	selected := make([]string, 0)
	projectProfiles := ""
	if project != nil {
		projectProfiles = project.Environment["SUBYARD_PROJECT_PROFILES"]
	}
	switch {
	case want != "":
		selected = append(selected, want)
	case loaded.Environment["YARD_PROFILES"] != "":
		selected = append(selected, strings.Fields(loaded.Environment["YARD_PROFILES"])...)
		selected = append(selected, strings.Fields(projectProfiles)...)
	case projectProfiles != "":
		selected = append(selected, strings.Fields(projectProfiles)...)
	default:
		selected = append(selected, available...)
	}
	seen := make(map[string]bool, len(selected))
	profiles := make([]string, 0, len(selected))
	for _, name := range selected {
		if seen[name] {
			continue
		}
		seen[name] = true
		if !byName[name] {
			if want != "" {
				return nil, fmt.Errorf("profile %q has no provision hook", name)
			}
			continue
		}
		profiles = append(profiles, name)
	}
	return &provisionExecution{profiles: profiles}, nil
}

func provisionableProfiles(root string) ([]string, error) {
	directories, err := filepath.Glob(filepath.Join(root, "config", "profiles", "*"))
	if err != nil {
		return nil, err
	}
	profiles := make([]string, 0, len(directories))
	for _, directory := range directories {
		name := filepath.Base(directory)
		if !domain.SafeName(name) {
			continue
		}
		hookPath := filepath.Join(directory, "provision.sh")
		info, err := os.Stat(hookPath)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("profile %q provision hook is not a regular file", name)
		}
		profiles = append(profiles, name)
	}
	sort.Strings(profiles)
	return profiles, nil
}

func (execution *provisionExecution) policy(
	definition command.Definition,
	yard domain.Context,
) domain.CommandPolicy {
	return domain.CommandPolicy{
		Name: definition.Name, Effect: domain.CommandEffect(definition.Effect),
		RemotePolicy: domain.RemotePolicy(definition.Remote), Consequences: []string{
			fmt.Sprintf("provision profiles [%s] in %s", strings.Join(execution.profiles, ", "), yard.InstanceName),
			"temporarily start the yard if required and restore its desired power",
		},
	}
}

func (execution *provisionExecution) printList(output io.Writer) {
	if len(execution.profiles) == 0 {
		fmt.Fprintln(output, "No provisionable profiles")
		return
	}
	fmt.Fprintln(output, "Provisionable profiles:")
	for _, profile := range execution.profiles {
		fmt.Fprintf(output, "  %s\n", profile)
	}
}

func (cli *CLI) executeProvision(
	ctx context.Context,
	orchestrator *application.Orchestrator,
	loaded config.Loaded,
	plan domain.OperationPlan,
	execution *provisionExecution,
	diagnostics io.Writer,
) (domain.AdapterResult, error) {
	if execution == nil || execution.list {
		return domain.AdapterResult{}, errors.New("provision execution is required")
	}
	if len(execution.profiles) == 0 {
		fmt.Fprintln(diagnostics, "  [ ok ] No profile provision hook selected")
		return domain.AdapterResult{
			Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID, Status: "ok",
			Output: map[string]any{"profiles": 0},
		}, nil
	}
	incusPort, _ := cli.statusPorts()
	instance, err := incusPort.Instance(ctx, loaded.Context.IncusProject, loaded.Context.InstanceName)
	if err != nil {
		return domain.AdapterResult{}, err
	}
	contextValues := structuredCommandContext(loaded)
	if strings.EqualFold(instance.Status, "stopped") && cli.options.AdapterRunner == nil {
		if err := cli.prepareStartPrivileges(ctx, diagnostics, os.Geteuid()); err != nil {
			return domain.AdapterResult{}, err
		}
		contextValues["SUBYARD_SUDO_PREAUTHORIZED"] = "1"
	}
	power, err := cli.lifecyclePowerService()
	if err != nil {
		return domain.AdapterResult{}, err
	}
	orchestrator.Runner = application.ProvisionRunner{
		Power: power, Physical: orchestrator.Runner,
		Yard: loaded.Context, Profiles: execution.profiles, Reporter: provisionReporter{output: diagnostics},
	}
	request := domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
		Adapter: "provision", Action: "apply", Context: contextValues,
	}
	result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
	writeAdapterDiagnostics(diagnostics, stderr)
	return result, err
}
