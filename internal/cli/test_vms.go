package cli

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/testvmsruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
)

type TestVMEnrollmentApplyFunc func(
	context.Context, config.Loaded, string, io.Writer,
) error

type testVMEnrollmentSource struct {
	match               state.Match
	loaded              config.Loaded
	key                 string
	fingerprint         string
	directory           string
	revoke              bool
	previousManaged     bool
	previousKey         string
	previousFingerprint string
}

type testVMExecution struct {
	action     string
	enrollment *testVMEnrollmentSource
}

const readProjectEnrollmentScript = `
root=$1
target=$2
[ -d "$root" ] && [ ! -L "$root" ]
[ "$(realpath -e -- "$root")" = "$root" ]
[ -f "$target" ] && [ ! -L "$target" ]
[ "$(realpath -e -- "$target")" = "$target" ]
[ "$(stat -c %h -- "$target")" = 1 ]
[ "$(stat -c %s -- "$target")" -le 1024 ]
cat -- "$target"
`

const publishProjectEnrollmentScript = `
root=$1
directory=$2
route=$3
known=$4
[ -d "$root" ] && [ ! -L "$root" ]
[ "$(realpath -e -- "$root")" = "$root" ]
parent=$directory
while [ "$parent" != "$root" ]; do
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] && [ ! -L "$parent" ]
    [ "$(realpath -e -- "$parent")" = "$parent" ]
  fi
  next=$(dirname -- "$parent")
  [ "$next" != "$parent" ]
  parent=$next
done
mkdir -p -- "$directory"
[ -d "$directory" ] && [ ! -L "$directory" ]
[ "$(realpath -e -- "$directory")" = "$directory" ]
tmp=$(mktemp -d "$root/.subyard-enrollment.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
printf %s "$route" | base64 -d >"$tmp/route.tsv"
printf %s "$known" | base64 -d >"$tmp/known_hosts"
chmod 0644 "$tmp/route.tsv" "$tmp/known_hosts"
mv -fT -- "$tmp/route.tsv" "$directory/route.tsv"
mv -fT -- "$tmp/known_hosts" "$directory/known_hosts"
`

const removeProjectEnrollmentScript = `
root=$1
directory=$2
[ -d "$root" ] && [ ! -L "$root" ]
[ "$(realpath -e -- "$root")" = "$root" ]
if [ -e "$directory" ] || [ -L "$directory" ]; then
  [ -d "$directory" ] && [ ! -L "$directory" ]
  [ "$(realpath -e -- "$directory")" = "$directory" ]
  rm -f -- "$directory/route.tsv" "$directory/known_hosts"
fi
`

func (cli *CLI) prepareTestVMExecution(
	ctx context.Context,
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
	project := ""
	revoke := false
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		switch argument {
		case "-y", "--yes":
		case "-h", "--help":
			return nil, errors.New("help is not an executable test-vms operation")
		case "--revoke":
			revoke = true
		case "--project":
			index++
			if index >= len(arguments) || arguments[index] == "" {
				return nil, errors.New("--project requires a selector")
			}
			project = arguments[index]
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
	if action != "up" && action != "status" && action != "down" && action != "enroll" {
		return nil, fmt.Errorf("unknown test-vms command %q", action)
	}
	if action != "enroll" {
		if project != "" || revoke {
			return nil, errors.New("--project and --revoke are valid only with enroll")
		}
		return &testVMExecution{action: action}, nil
	}
	if project == "" {
		return nil, errors.New("enroll requires --project <selector>")
	}
	match, err := cli.resolveGlobalProject(ctx, loaded.Context, project)
	if err != nil {
		return nil, fmt.Errorf("resolve enrollment project: %w", err)
	}
	sourceLoaded, err := cli.loadInventoryLoaded(match.Yard, loaded)
	if err != nil {
		return nil, fmt.Errorf("load enrollment project yard: %w", err)
	}
	if !sameYardOwner(loaded.Context, sourceLoaded.Context) {
		return nil, errors.New(
			"enrollment project and test-vms lab must have the same owner host",
		)
	}
	directory, err := testvmsruntime.EnrollmentDirectory(
		loaded.Context.Paths.DataHome, loaded.Context.YardName,
	)
	if err != nil {
		return nil, err
	}
	source := &testVMEnrollmentSource{
		match: match, loaded: sourceLoaded, directory: directory, revoke: revoke,
	}
	source.previousManaged, source.previousKey, source.previousFingerprint, err =
		testvmsruntime.CurrentEnrollment(directory)
	if err != nil {
		return nil, fmt.Errorf("inspect current enrollment: %w", err)
	}
	if !revoke {
		payload, err := cli.readProjectEnrollment(ctx, loaded.Context.YardName, source)
		if err != nil {
			return nil, err
		}
		source.key, source.fingerprint, err = testvmsruntime.ParseEnrollment(payload)
		if err != nil {
			return nil, fmt.Errorf(
				"project enrollment request must be one regular Ed25519 public-key line: %w",
				err,
			)
		}
	}
	return &testVMExecution{action: action, enrollment: source}, nil
}

func (execution *testVMExecution) policy(
	definition command.Definition,
	yard domain.Context,
) domain.CommandPolicy {
	effect := domain.CommandEffect(definition.Effect)
	consequences := []string{"read the two-VM allocation status"}
	switch execution.action {
	case "status":
		effect = domain.CommandRead
	case "up":
		consequences = []string{
			"create or start two disposable VMs inside " + yard.InstanceName,
			"publish restricted agent SSH access and enforce the allocation TTL",
		}
	case "down":
		consequences = []string{
			"delete the two managed VMs and their inner Incus project",
			"revoke agent forwarding and remove the synthetic worker identity",
		}
	case "enroll":
		source := execution.enrollment
		project := source.match.Record.ProjectID
		if domain.SafeID(source.match.Record.Name) {
			project = source.match.Record.Name + " (" + project + ")"
		}
		if source.revoke {
			revoke := "revoke current agent controller access from the running " +
				yard.YardName + " lab"
			if source.previousFingerprint != "" {
				revoke = "revoke active agent controller " + source.previousFingerprint +
					" from the running " + yard.YardName + " lab"
			}
			consequences = []string{
				revoke,
				"remove public route artifacts from project " + project,
				"leave yard and VM allocation lifecycle unchanged",
			}
		} else {
			change := "enroll agent controller " + source.fingerprint
			if source.previousFingerprint != "" {
				change = "replace active agent controller " +
					source.previousFingerprint + " with " + source.fingerprint
			}
			consequences = []string{
				change,
				"reconcile access in the running " + yard.YardName + " lab",
				"publish only route.tsv and known_hosts to project " + project,
				"leave yard and VM allocation lifecycle unchanged",
			}
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
	if execution.action == "enroll" {
		orchestrator.Runner = testVMEnrollmentAdapter{
			cli: cli, loaded: loaded, source: execution.enrollment, output: diagnostics,
		}
		request := domain.AdapterRequest{
			Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
			Adapter: "test-vms", Action: "enroll",
		}
		result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
		writeAdapterDiagnostics(diagnostics, stderr)
		return result, err
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

type testVMEnrollmentAdapter struct {
	cli    *CLI
	loaded config.Loaded
	source *testVMEnrollmentSource
	output io.Writer
}

func (adapter testVMEnrollmentAdapter) Run(
	ctx context.Context,
	request domain.AdapterRequest,
	_ io.Reader,
) (domain.AdapterResult, string, error) {
	if request.Adapter != "test-vms" || request.Action != "enroll" ||
		request.Schema != shelladapter.ProtocolSchema {
		return domain.AdapterResult{}, "", errors.New("invalid test-vms enrollment adapter request")
	}
	if err := adapter.cli.executeTestVMEnrollment(
		ctx, adapter.loaded, adapter.source, adapter.output,
	); err != nil {
		return domain.AdapterResult{}, "", err
	}
	return domain.AdapterResult{
		Schema: request.Schema, OperationID: request.OperationID, Status: "ok",
	}, "", nil
}

func (cli *CLI) executeTestVMEnrollment(
	ctx context.Context,
	loaded config.Loaded,
	source *testVMEnrollmentSource,
	diagnostics io.Writer,
) error {
	if source == nil {
		return errors.New("prepared enrollment is required")
	}
	managed, previousKey, _, err := testvmsruntime.CurrentEnrollment(source.directory)
	if err != nil {
		return fmt.Errorf("inspect current enrollment: %w", err)
	}
	if managed != source.previousManaged || previousKey != source.previousKey {
		return errors.New("enrollment changed after preview; rerun the command")
	}
	if !source.revoke {
		payload, readErr := cli.readProjectEnrollment(
			ctx, loaded.Context.YardName, source,
		)
		if readErr != nil {
			return readErr
		}
		currentKey, _, parseErr := testvmsruntime.ParseEnrollment(payload)
		if parseErr != nil || currentKey != source.key {
			return errors.New("project enrollment request changed after preview; rerun the command")
		}
	}
	key := source.key
	if source.revoke {
		key = ""
	}
	if err := testvmsruntime.SetEnrollment(source.directory, key); err != nil {
		return fmt.Errorf("persist enrollment: %w", err)
	}
	rollback := func(cause error) error {
		restoreDirectory := source.directory
		restoreErr := error(nil)
		if managed {
			restoreErr = testvmsruntime.SetEnrollment(source.directory, previousKey)
		} else {
			restoreDirectory = ""
			restoreErr = testvmsruntime.RemoveManagedEnrollment(source.directory)
		}
		if restoreErr == nil {
			restoreErr = cli.applyTestVMEnrollment(
				ctx, loaded, restoreDirectory, diagnostics,
			)
		}
		if restoreErr != nil {
			return errors.Join(cause, fmt.Errorf("enrollment rollback failed: %w", restoreErr))
		}
		return cause
	}
	if err := cli.applyTestVMEnrollment(ctx, loaded, source.directory, diagnostics); err != nil {
		return rollback(fmt.Errorf("reconcile enrolled controller: %w", err))
	}
	if source.revoke {
		if err := cli.removeProjectEnrollmentArtifacts(ctx, loaded.Context.YardName, source); err != nil {
			return rollback(fmt.Errorf("remove project enrollment artifacts: %w", err))
		}
		fmt.Fprintln(diagnostics, "  [ ok ] agent E2E controller revoked")
		return nil
	}
	route, known, err := testvmsruntime.ReadClientArtifacts(source.directory)
	if err != nil {
		return rollback(fmt.Errorf("validate reconciled client artifacts: %w", err))
	}
	if err := cli.publishProjectEnrollmentArtifacts(
		ctx, loaded.Context.YardName, source, route, known,
	); err != nil {
		return rollback(fmt.Errorf("publish project enrollment artifacts: %w", err))
	}
	fmt.Fprintf(diagnostics, "  [ ok ] agent E2E controller enrolled (%s)\n",
		source.fingerprint)
	return nil
}

func (cli *CLI) applyTestVMEnrollment(
	ctx context.Context,
	loaded config.Loaded,
	directory string,
	output io.Writer,
) error {
	if cli.options.TestVMEnrollmentApply != nil {
		return cli.options.TestVMEnrollmentApply(ctx, loaded, directory, output)
	}
	environment := structuredCommandContext(loaded)
	environment["SUBYARD_DISPATCHER_PATH"] = cli.options.DispatcherPath
	if directory != "" {
		environment["SUBYARD_E2E_CLIENT_EXPORT_DIR"] = directory
	}
	backend := testvmsruntime.Backend{
		RepositoryRoot: cli.options.RepositoryRoot,
		DataHome:       loaded.Context.Paths.DataHome,
		Dispatcher:     cli.options.DispatcherPath,
		Project:        loaded.Context.IncusProject,
		Instance:       loaded.Context.InstanceName,
		YardName:       loaded.Context.YardName,
		DesiredPower:   application.PowerRunning,
		Environment:    environment,
		Output:         output,
	}
	return backend.Apply(ctx)
}

func (cli *CLI) readProjectEnrollment(
	ctx context.Context,
	lab string,
	source *testVMEnrollmentSource,
) ([]byte, error) {
	path := projectEnrollmentPath(source.match.Record, lab, "agent-access.pub")
	request := ports.InstanceExecRequest{
		Command: []string{
			"sh", "-eu", "-c", readProjectEnrollmentScript,
			"subyard-read-enrollment", source.match.Record.YardPath, path,
		},
		User:  uint32(source.loaded.Context.DevUID),
		Group: uint32(source.loaded.Context.DevUID),
	}
	result, err := cli.projectDataPlane().Execute(ctx, source.loaded.Context, request)
	if err != nil || result.ExitCode != 0 {
		return nil, errors.New(
			"cannot read the fixed enrollment request from the selected project",
		)
	}
	return result.Stdout, nil
}

func (cli *CLI) publishProjectEnrollmentArtifacts(
	ctx context.Context,
	lab string,
	source *testVMEnrollmentSource,
	route, known []byte,
) error {
	directory := projectEnrollmentPath(source.match.Record, lab, "")
	request := ports.InstanceExecRequest{
		Command: []string{
			"sh", "-eu", "-c", publishProjectEnrollmentScript,
			"subyard-publish-enrollment", source.match.Record.YardPath, directory,
			base64.StdEncoding.EncodeToString(route),
			base64.StdEncoding.EncodeToString(known),
		},
		User:  uint32(source.loaded.Context.DevUID),
		Group: uint32(source.loaded.Context.DevUID),
	}
	result, err := cli.projectDataPlane().Execute(ctx, source.loaded.Context, request)
	if err != nil || result.ExitCode != 0 {
		return errors.New("cannot publish bounded enrollment artifacts to the selected project")
	}
	return nil
}

func (cli *CLI) removeProjectEnrollmentArtifacts(
	ctx context.Context,
	lab string,
	source *testVMEnrollmentSource,
) error {
	directory := projectEnrollmentPath(source.match.Record, lab, "")
	request := ports.InstanceExecRequest{
		Command: []string{
			"sh", "-eu", "-c", removeProjectEnrollmentScript,
			"subyard-remove-enrollment", source.match.Record.YardPath, directory,
		},
		User:  uint32(source.loaded.Context.DevUID),
		Group: uint32(source.loaded.Context.DevUID),
	}
	result, err := cli.projectDataPlane().Execute(ctx, source.loaded.Context, request)
	if err != nil || result.ExitCode != 0 {
		return errors.New("cannot remove bounded enrollment artifacts from the selected project")
	}
	return nil
}

func projectEnrollmentPath(record domain.ProjectRecord, lab, name string) string {
	path := filepath.Join(record.YardPath, "temp", "agent-e2e", lab)
	if name != "" {
		path = filepath.Join(path, name)
	}
	return path
}

func sameYardOwner(first, second domain.Context) bool {
	if first.YardType != second.YardType {
		return false
	}
	if first.YardType == domain.YardLocal {
		return true
	}
	return first.RemoteDest != "" && first.RemoteDest == second.RemoteDest
}
