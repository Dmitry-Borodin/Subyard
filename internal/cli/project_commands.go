package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/Subyard/Subyard/internal/application"
	"github.com/Subyard/Subyard/internal/command"
	"github.com/Subyard/Subyard/internal/config"
	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/shellquote"
	"github.com/Subyard/Subyard/internal/state"
)

type projectCommit string

const (
	projectCommitNone   projectCommit = ""
	projectCommitPut    projectCommit = "put"
	projectCommitDelete projectCommit = "delete"
)

type projectExecution struct {
	Loaded         config.Loaded
	YardIdentity   string
	Arguments      []string
	Environment    map[string]string
	Record         domain.ProjectRecord
	Store          *state.FileStore
	Commit         projectCommit
	Profile        application.ProjectEnvironmentProfile
	SecretPath     string
	HostLinks      []string
	Reservation    *state.ProjectReservation
	OperationID    string
	ExplicitName   bool
	RequestedName  string
	RemoteReserved bool
}

func (cli *CLI) prepareProjectExecution(
	ctx context.Context,
	loaded config.Loaded,
	definition command.Definition,
	arguments []string,
	explicit bool,
) (*projectExecution, error) {
	switch definition.Name {
	case "init", "provision":
		return cli.prepareProjectInventory(ctx, loaded, arguments)
	case "sync", "bind":
		return cli.prepareProjectImport(ctx, loaded, definition.Name, arguments)
	case "clone":
		return cli.prepareProjectClone(ctx, loaded, arguments)
	case "code", "export", "remove", "shell", "up", "down", "info":
		return cli.prepareExistingProject(ctx, loaded, definition.Name, arguments, explicit)
	default:
		return nil, nil
	}
}

func (cli *CLI) prepareProjectInventory(
	ctx context.Context,
	loaded config.Loaded,
	arguments []string,
) (*projectExecution, error) {
	store, err := openProjectStore(ctx, loaded.Context.Paths.StateDir)
	if err != nil {
		return nil, err
	}
	records, err := store.List(ctx)
	if err != nil {
		return nil, err
	}
	seen := make(map[string]bool)
	profiles := make([]string, 0)
	for _, record := range records {
		profile := record.Profile
		if profile == "" && record.Target != "" && record.Target != "yard" {
			profile = record.Target
		}
		if profile != "" && domain.SafeName(profile) && !seen[profile] {
			seen[profile] = true
			profiles = append(profiles, profile)
		}
	}
	return &projectExecution{
		Loaded: loaded, Arguments: arguments,
		Environment: map[string]string{"SUBYARD_PROJECT_PROFILES": strings.Join(profiles, " ")},
	}, nil
}

func (cli *CLI) prepareProjectImport(
	ctx context.Context,
	loaded config.Loaded,
	name string,
	arguments []string,
) (*projectExecution, error) {
	path, requestedTarget, targetYard, requestedName, err := parseProjectImportArguments(arguments)
	if err != nil {
		return nil, err
	}
	if name == "bind" && loaded.Context.YardType == domain.YardRemote {
		return nil, errors.New("bind is host-local - use sync or clone")
	}
	hostPath := path
	if !filepath.IsAbs(hostPath) {
		hostPath = filepath.Join(cli.options.WorkingDir, hostPath)
	}
	hostPath, err = filepath.EvalSymlinks(hostPath)
	if err != nil {
		return nil, fmt.Errorf("resolve project path: %w", err)
	}
	hostPath, err = filepath.Abs(hostPath)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(hostPath)
	if err != nil || !info.IsDir() {
		return nil, fmt.Errorf("not a directory: %s", path)
	}
	projectName := filepath.Base(hostPath)
	explicitName := requestedName != ""
	if explicitName {
		projectName = requestedName
	}
	if !domain.SafeProjectName(projectName) {
		return nil, fmt.Errorf(
			"invalid project name %q; choose a safe name with --name", projectName,
		)
	}
	selected, err := cli.routeProjectSource(ctx, loaded.Context, hostPath, targetYard)
	if err != nil {
		return nil, err
	}
	selectedLoaded, err := cli.activateProjectContext(selected, loaded)
	if err != nil {
		return nil, err
	}
	if name == "bind" && selectedLoaded.Context.YardType == domain.YardRemote {
		return nil, errors.New("bind is host-local - use sync or clone")
	}
	store, err := openProjectStore(ctx, selectedLoaded.Context.Paths.StateDir)
	if err != nil {
		return nil, err
	}
	mode := domain.ProjectMode(name)
	operationID := cli.projectOperationID()
	admission, err := store.Admit(
		ctx, operationID, hostPath, mode, projectName, explicitName,
	)
	if err != nil {
		return nil, err
	}
	exists := admission.Existing != nil
	target := requestedTarget
	if target == "" && exists {
		target = admission.Existing.Target
	}
	if target == "" {
		target = "yard"
	}
	if err := validateProjectTarget(cli.options.RepositoryRoot, target); err != nil {
		if admission.Reservation != nil {
			_ = store.AbortAdmission(ctx, admission.Reservation.OperationID)
		}
		return nil, err
	}
	record := domain.ProjectRecord{
		Schema: 1, IdentityVersion: 2, ProjectID: admission.ProjectID, Name: admission.Name,
		HostPath: hostPath, SourceKey: state.SourceKey(hostPath),
		YardPath: state.YardPath(admission.ProjectID),
		Mode:     mode, SSHHost: selectedLoaded.Context.SSHHost,
		ImportedAt: time.Now().UTC().Format(time.RFC3339), Target: target,
	}
	if exists {
		record.IdentityVersion = admission.Existing.IdentityVersion
		record.ImportedAt = admission.Existing.ImportedAt
		record.RegistrySource = admission.Existing.RegistrySource
	}
	if target != "yard" {
		record.Profile = target
	}
	return &projectExecution{
		Loaded: selectedLoaded, Arguments: arguments, Environment: projectSnapshot(record, exists),
		Record: record, Store: store, Commit: projectCommitPut,
		Reservation: admission.Reservation, OperationID: operationID,
		ExplicitName: explicitName, RequestedName: projectName,
	}, nil
}

func (cli *CLI) prepareProjectClone(
	ctx context.Context,
	loaded config.Loaded,
	arguments []string,
) (*projectExecution, error) {
	url, name, target, targetYard, explicitName, err := parseProjectCloneArguments(arguments)
	if err != nil {
		return nil, err
	}
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(url), ".git")
	}
	if !domain.SafeProjectName(name) {
		return nil, fmt.Errorf("invalid project name %q; choose a safe name with --name", name)
	}
	selected, err := cli.routeProjectSource(ctx, loaded.Context, url, targetYard)
	if err != nil {
		return nil, err
	}
	selectedLoaded, err := cli.activateProjectContext(selected, loaded)
	if err != nil {
		return nil, err
	}
	store, err := openProjectStore(ctx, selectedLoaded.Context.Paths.StateDir)
	if err != nil {
		return nil, err
	}
	if err := validateProjectTarget(cli.options.RepositoryRoot, target); err != nil {
		return nil, err
	}
	operationID := cli.projectOperationID()
	admission, err := store.Admit(
		ctx, operationID, url, domain.ProjectGit, name, explicitName,
	)
	if err != nil {
		return nil, err
	}
	if admission.Existing != nil {
		return nil, fmt.Errorf(
			"%q is already in the yard (id %s); remove it first",
			admission.Existing.Name, admission.Existing.ProjectID,
		)
	}
	record := domain.ProjectRecord{
		Schema: 1, IdentityVersion: 2, ProjectID: admission.ProjectID, Name: admission.Name,
		HostPath: url, SourceKey: state.SourceKey(url),
		YardPath: state.YardPath(admission.ProjectID),
		Mode:     domain.ProjectGit, SSHHost: selectedLoaded.Context.SSHHost,
		ImportedAt: time.Now().UTC().Format(time.RFC3339), Target: target,
	}
	if target != "yard" {
		record.Profile = target
	}
	return &projectExecution{
		Loaded: selectedLoaded, Arguments: arguments, Environment: projectSnapshot(record, false),
		Record: record, Store: store, Commit: projectCommitPut,
		Reservation: admission.Reservation, OperationID: operationID,
		ExplicitName: explicitName, RequestedName: name,
	}, nil
}

func (cli *CLI) projectOperationID() string {
	if cli.env["SUBYARD_OPERATION_ID"] == "" {
		cli.env["SUBYARD_OPERATION_ID"] = newOperationID()
	}
	return cli.env["SUBYARD_OPERATION_ID"]
}

func (cli *CLI) prepareExistingProject(
	ctx context.Context,
	loaded config.Loaded,
	name string,
	arguments []string,
	explicit bool,
) (*projectExecution, error) {
	selector, present, err := parseProjectSelector(name, arguments)
	if err != nil {
		return nil, err
	}
	if !present {
		return nil, nil
	}
	revalidate := name != "shell" && name != "info"
	match, err := cli.resolveProjectForCommand(ctx, loaded, selector, explicit, revalidate)
	if err != nil {
		return nil, err
	}
	selectedLoaded, err := cli.activateProjectContext(match.Yard, loaded)
	if err != nil {
		return nil, err
	}
	yardIdentity := ""
	if name == "code" {
		yardIdentity, err = canonicalYardIdentity(selectedLoaded)
		if err != nil {
			return nil, err
		}
	}
	store, err := openProjectStore(ctx, selectedLoaded.Context.Paths.StateDir)
	if err != nil {
		return nil, err
	}
	execution := &projectExecution{
		Loaded: selectedLoaded, YardIdentity: yardIdentity,
		Arguments: arguments, Environment: projectSnapshot(match.Record, true),
		Record: match.Record, Store: store,
	}
	if name == "remove" {
		execution.Commit = projectCommitDelete
		execution.Environment["SUBYARD_PROJECT_REMOVE_SOFT"] = argumentValue(arguments, "--soft")
		if argumentValue(arguments, "--purge") == "1" {
			fmt.Fprintln(cli.options.Stderr, "warning: --purge is deprecated; full removal is the default (--soft keeps the copy)")
		}
	}
	if name == "up" {
		execution.Environment["SUBYARD_PROJECT_REBUILD"] = argumentValue(arguments, "--rebuild")
		if match.Record.Target != "" && match.Record.Target != "yard" {
			execution.Profile, execution.SecretPath, err = loadProjectEnvironmentProfile(
				cli.options.RepositoryRoot, match.Record.Target, selectedLoaded.Environment,
			)
			if err != nil {
				return nil, err
			}
			execution.HostLinks = strings.Split(selectedLoaded.Environment["HOST_LINKS"], "\n")
		}
	}
	// Owner-forwarded commands receive a stable ID, never a controller-only host path.
	if selectedLoaded.Context.YardType == domain.YardRemote &&
		(name == "shell" || name == "up" || name == "down" || name == "info") {
		execution.Arguments = replaceProjectSelector(name, arguments, match.Record.ProjectID)
	}
	return execution, nil
}

var projectEnvironmentControlKeys = map[string]struct{}{
	"PROFILE_NAME": {}, "BASE_IMAGE": {}, "CACHES": {}, "DEVICES": {}, "OPTIONAL_FEATURES": {},
	"IMAGE_DOCKERFILE": {}, "IMAGE_CONTEXT": {}, "IMAGE_TAG": {}, "ENV_MOUNTS": {},
	"YARD_MOUNTS": {}, "YARD_CAPS": {}, "YARD_DEVICES": {},
}

func loadProjectEnvironmentProfile(
	root string,
	name string,
	base map[string]string,
) (application.ProjectEnvironmentProfile, string, error) {
	if !domain.SafeName(name) {
		return application.ProjectEnvironmentProfile{}, "", fmt.Errorf("invalid project profile %q", name)
	}
	path := filepath.Join(root, "config", "profiles", name, "profile.conf")
	declared, err := config.ReadAssignments(path)
	if err != nil {
		return application.ProjectEnvironmentProfile{}, "", err
	}
	values, err := config.ReadAssignmentsOver(path, base)
	if err != nil {
		return application.ProjectEnvironmentProfile{}, "", err
	}
	public := make(map[string]string)
	for key := range declared {
		if _, control := projectEnvironmentControlKeys[key]; !control {
			public[key] = values[key]
		}
	}
	profile := application.ProjectEnvironmentProfile{
		BaseImage: values["BASE_IMAGE"], Dockerfile: values["IMAGE_DOCKERFILE"],
		Context: values["IMAGE_CONTEXT"], Image: values["IMAGE_TAG"],
		Caches: strings.Fields(values["CACHES"]), Features: strings.Fields(values["OPTIONAL_FEATURES"]),
		Devices: strings.Fields(values["DEVICES"]), Mounts: strings.Fields(values["ENV_MOUNTS"]),
		Environment: public,
	}
	if profile.Dockerfile != "" && profile.Context == "" {
		profile.Context = filepath.Dir(profile.Dockerfile)
	}
	secretsRoot := base["SUBYARD_CONFIG_SECRETS_DIR"]
	if secretsRoot == "" {
		return application.ProjectEnvironmentProfile{}, "",
			errors.New("operator secret directory is required")
	}
	secret := filepath.Join(secretsRoot, "profiles", name, "profile.env")
	info, statErr := os.Lstat(secret)
	if errors.Is(statErr, os.ErrNotExist) {
		secret = ""
	} else if statErr != nil {
		return application.ProjectEnvironmentProfile{}, "", statErr
	} else if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return application.ProjectEnvironmentProfile{}, "", errors.New("profile.env must be a regular non-symlink file")
	}
	return profile, secret, nil
}

func argumentValue(arguments []string, wanted string) string {
	for _, argument := range arguments {
		if argument == wanted {
			return "1"
		}
	}
	return "0"
}

func (cli *CLI) resolveProjectForCommand(
	ctx context.Context,
	loaded config.Loaded,
	selector string,
	explicit bool,
	force bool,
) (state.Match, error) {
	if !isExplicitProjectPath(selector) {
		return cli.resolveOwnerProject(ctx, loaded, selector, explicit, force)
	}
	if explicit {
		selector = stripCurrentYardQualifier(selector, loaded.Context.YardName)
		store, err := openProjectStore(ctx, loaded.Context.Paths.StateDir)
		if err != nil {
			return state.Match{}, err
		}
		match, resolveErr := cli.resolveLocalProject(ctx, loaded.Context, store, selector)
		if resolveErr == nil {
			return match, nil
		}
		return state.Match{}, resolveErr
	}
	return cli.resolveGlobalProject(ctx, loaded.Context, selector)
}

func (cli *CLI) activateProjectContext(name string, loaded config.Loaded) (config.Loaded, error) {
	if selected, ok := cli.inventoryRoutes[name]; ok {
		for key, value := range selected.Environment {
			cli.env[key] = value
		}
		cli.env["SUBYARD_YARD"] = name
		cli.env["SUBYARD_CONFIG_LOADED"] = "1"
		cli.env["SUBYARD_ENGINE_CONTEXT"] = "1"
		return selected, nil
	}
	if name == loaded.Context.YardName {
		return loaded, nil
	}
	selected, err := cli.loadInventoryLoaded(name, loaded)
	if err != nil {
		return config.Loaded{}, err
	}
	for _, key := range []string{
		"YARD_NAME", "YARD_TYPE", "YARD_PROFILES", "INSTANCE_TYPE", "INSTANCE_NAME", "INCUS_PROJECT",
		"INCUS_BRIDGE", "SSH_HOST", "SSH_PORT", "REMOTE_DEST", "REMOTE_YARD", "SHIFT_MODE",
		"FORWARD_SSH_AGENT", "DEV_SUDO", "DEV_UID", "DEV_USER", "NESTED_E2E_VMS",
		"SUBYARD_STATE_DIR", "RESTRICTED_DISK_PATHS", "HOST_BASE", "SRV_VOLUME",
	} {
		delete(cli.env, key)
	}
	for key, value := range selected.Environment {
		cli.env[key] = value
	}
	cli.env["SUBYARD_YARD"] = name
	cli.env["SUBYARD_CONFIG_LOADED"] = "1"
	cli.env["SUBYARD_ENGINE_CONTEXT"] = "1"
	return selected, nil
}

func (cli *CLI) commitProjectExecution(ctx context.Context, execution *projectExecution) error {
	switch execution.Commit {
	case projectCommitNone:
		return nil
	case projectCommitPut:
		if execution.Loaded.Context.YardType == domain.YardRemote {
			action := "upsert"
			arguments := []string{
				action, execution.Record.ProjectID, execution.Record.Name,
				string(execution.Record.Mode), execution.Record.Target,
				execution.Record.HostPath, execution.Record.ImportedAt,
				fmt.Sprint(execution.Record.IdentityVersion),
			}
			if execution.RemoteReserved {
				arguments[0] = "finalize"
				arguments = append(
					[]string{"finalize", execution.OperationID},
					arguments[1:]...,
				)
			}
			if _, err := cli.remoteProjectStateCall(
				ctx, execution.Loaded.Context, arguments,
			); err != nil {
				return errors.New("physical operation completed, but owner project state was not updated; re-run the command")
			}
			execution.RemoteReserved = false
			if err := cli.invalidateOwnerInventory(execution.Loaded); err != nil {
				return fmt.Errorf("owner state updated, but inventory invalidation failed: %w", err)
			}
			if err := execution.Store.Delete(ctx, execution.Record.ProjectID); err != nil &&
				!errors.Is(err, state.ErrNotFound) {
				return fmt.Errorf("owner state updated, but obsolete controller state cleanup failed: %w", err)
			}
			if execution.Reservation != nil {
				if err := execution.Store.AbortAdmission(
					ctx, execution.Reservation.OperationID,
				); err != nil {
					return fmt.Errorf("owner state updated, but controller reservation cleanup failed: %w", err)
				}
				execution.Reservation = nil
			}
			if err := cli.cleanupObsoleteRemoteProjectState(
				ctx, execution.Loaded, execution.Record.ProjectID,
			); err != nil {
				return fmt.Errorf("owner state updated, but obsolete controller state cleanup failed: %w", err)
			}
			return nil
		}
		if execution.Reservation != nil {
			if err := execution.Store.FinalizeOperation(
				ctx, execution.Reservation.OperationID, execution.Record,
			); err != nil {
				return err
			}
			execution.Reservation = nil
			return nil
		}
		return execution.Store.Put(ctx, execution.Record)
	case projectCommitDelete:
		if execution.Loaded.Context.YardType == domain.YardRemote {
			sourceKey := execution.Record.SourceKey
			if sourceKey == "" && execution.Record.HostPath != "" {
				sourceKey = state.SourceKey(execution.Record.HostPath)
			}
			if code := cli.forwardRemote(ctx, execution.Loaded.Context, "_project-state",
				[]string{
					"remove", execution.Record.ProjectID, sourceKey,
				}); code != 0 {
				return errors.New("physical removal completed, but owner project state was not updated; re-run the command")
			}
			if err := cli.invalidateOwnerInventory(execution.Loaded); err != nil {
				return fmt.Errorf("owner state updated, but inventory invalidation failed: %w", err)
			}
			if err := execution.Store.Delete(ctx, execution.Record.ProjectID); err != nil &&
				!errors.Is(err, state.ErrNotFound) {
				return fmt.Errorf("owner state updated, but obsolete controller state cleanup failed: %w", err)
			}
			if err := cli.cleanupObsoleteRemoteProjectState(
				ctx, execution.Loaded, execution.Record.ProjectID,
			); err != nil {
				return fmt.Errorf("owner state updated, but obsolete controller state cleanup failed: %w", err)
			}
			return nil
		}
		return execution.Store.Delete(ctx, execution.Record.ProjectID)
	default:
		return errors.New("unknown project commit")
	}
}

func (cli *CLI) abortProjectExecution(ctx context.Context, execution *projectExecution) {
	if execution == nil {
		return
	}
	if execution.RemoteReserved {
		_, _ = cli.remoteProjectStateCall(
			ctx, execution.Loaded.Context,
			[]string{"abort", execution.OperationID},
		)
		execution.RemoteReserved = false
	}
	if execution.Reservation != nil && execution.Store != nil {
		_ = execution.Store.AbortAdmission(ctx, execution.Reservation.OperationID)
		execution.Reservation = nil
	}
}

func (cli *CLI) reserveRemoteProject(
	ctx context.Context,
	execution *projectExecution,
) error {
	if execution == nil || execution.Commit != projectCommitPut ||
		execution.Loaded.Context.YardType != domain.YardRemote {
		return nil
	}
	explicit := "0"
	if execution.ExplicitName {
		explicit = "1"
	}
	output, err := cli.remoteProjectStateCall(ctx, execution.Loaded.Context, []string{
		"reserve", execution.OperationID, execution.Record.HostPath,
		string(execution.Record.Mode), execution.RequestedName, explicit,
	})
	if err != nil {
		return fmt.Errorf("reserve project identity on owner: %w", err)
	}
	var response struct {
		ProjectID string                `json:"projectId"`
		Name      string                `json:"name"`
		Reserved  bool                  `json:"reserved"`
		Existing  *domain.ProjectRecord `json:"existing"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(output), &response); err != nil {
		return fmt.Errorf("decode owner project reservation: %w", err)
	}
	if response.Existing == nil && !response.Reserved {
		return errors.New("owner returned neither an existing project nor a reservation")
	}
	if response.Existing != nil {
		if err := response.Existing.Validate(response.ProjectID); err != nil ||
			response.Existing.ProjectID != response.ProjectID ||
			response.Existing.Name != response.Name {
			if err == nil {
				err = errors.New("owner project identity does not match its admission")
			}
			return fmt.Errorf("validate owner project admission: %w", err)
		}
		if response.Existing.Mode != execution.Record.Mode {
			return errors.New("owner project admission returned a different mode")
		}
		execution.Record.IdentityVersion = response.Existing.IdentityVersion
		execution.Record.ImportedAt = response.Existing.ImportedAt
		execution.Record.RegistrySource = response.Existing.RegistrySource
	} else if !domain.SafeProjectName(response.ProjectID) ||
		response.ProjectID != response.Name {
		_, _ = cli.remoteProjectStateCall(ctx, execution.Loaded.Context, []string{
			"abort", execution.OperationID,
		})
		return errors.New("owner returned an invalid canonical project identity")
	} else {
		execution.Record.IdentityVersion = 2
	}
	if execution.Reservation != nil {
		if err := execution.Store.AbortAdmission(
			ctx, execution.Reservation.OperationID,
		); err != nil {
			if response.Reserved {
				_, _ = cli.remoteProjectStateCall(ctx, execution.Loaded.Context, []string{
					"abort", execution.OperationID,
				})
			}
			return fmt.Errorf("release controller project reservation: %w", err)
		}
		execution.Reservation = nil
	}
	execution.Record.ProjectID = response.ProjectID
	execution.Record.Name = response.Name
	execution.Record.YardPath = state.YardPath(response.ProjectID)
	execution.Environment = projectSnapshot(
		execution.Record, response.Existing != nil,
	)
	execution.RemoteReserved = response.Reserved
	return nil
}

func (cli *CLI) remoteProjectStateCall(
	ctx context.Context,
	yard domain.Context,
	arguments []string,
) ([]byte, error) {
	remote := []string{"yard"}
	if yard.RemoteYard != "" {
		remote = append(remote, "-Y", yard.RemoteYard)
	}
	remote = append(remote, "_project-state")
	remote = append(remote, arguments...)
	parts := make([]string, len(remote))
	for index, argument := range remote {
		parts[index] = shellquote.Word(argument)
	}
	line := "SUBYARD_OPERATION_ID=" + shellquote.Word(cli.env["SUBYARD_OPERATION_ID"]) +
		" " + strings.Join(parts, " ")
	command := exec.CommandContext(
		ctx, "ssh", "-T", yard.RemoteDest, "--", "bash", "-lc", shellquote.Word(line),
	)
	command.Dir = cli.options.WorkingDir
	command.Env = environmentList(cli.env, nil)
	command.Stderr = cli.options.Stderr
	output, err := command.Output()
	if err != nil {
		return nil, err
	}
	return output, nil
}

func projectSnapshot(record domain.ProjectRecord, exists bool) map[string]string {
	existsValue := "0"
	if exists {
		existsValue = "1"
	}
	return map[string]string{
		"SUBYARD_PROJECT_SNAPSHOT":  "1",
		"SUBYARD_PROJECT_ID":        record.ProjectID,
		"SUBYARD_PROJECT_NAME":      record.Name,
		"SUBYARD_PROJECT_HOST_PATH": record.HostPath,
		"SUBYARD_PROJECT_YARD_PATH": record.YardPath,
		"SUBYARD_PROJECT_MODE":      string(record.Mode),
		"SUBYARD_PROJECT_SSH_HOST":  record.SSHHost,
		"SUBYARD_PROJECT_TARGET":    record.Target,
		"SUBYARD_PROJECT_PROFILE":   record.Profile,
		"SUBYARD_PROJECT_DEVICE":    state.WorkspaceDeviceFor(record),
		"SUBYARD_PROJECT_EXISTS":    existsValue,
	}
}

func parseProjectImportArguments(arguments []string) (path, target, yard, name string, err error) {
	path = "."
	positional := false
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		switch {
		case argument == "-y" || argument == "--yes":
		case argument == "--target":
			index++
			if index >= len(arguments) {
				return "", "", "", "", errors.New("--target needs yard or a profile")
			}
			target = arguments[index]
		case strings.HasPrefix(argument, "--target="):
			target = strings.TrimPrefix(argument, "--target=")
		case argument == "--name":
			index++
			if index >= len(arguments) {
				return "", "", "", "", errors.New("--name needs a project name")
			}
			name = arguments[index]
			if name == "" {
				return "", "", "", "", errors.New("--name needs a project name")
			}
		case strings.HasPrefix(argument, "--name="):
			name = strings.TrimPrefix(argument, "--name=")
			if name == "" {
				return "", "", "", "", errors.New("--name needs a project name")
			}
		case strings.HasPrefix(argument, "@") && len(argument) > 1:
			yard = strings.TrimPrefix(argument, "@")
		case strings.HasPrefix(argument, "-"):
			return "", "", "", "", fmt.Errorf("unknown option %q", argument)
		default:
			if positional {
				return "", "", "", "", errors.New("only one project path may be selected")
			}
			path, positional = argument, true
		}
	}
	return path, target, yard, name, nil
}

func parseProjectCloneArguments(arguments []string) (
	url, name, target, yard string, explicitName bool, err error,
) {
	target = "yard"
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		switch {
		case argument == "-y" || argument == "--yes":
		case argument == "--target":
			index++
			if index >= len(arguments) {
				return "", "", "", "", false, errors.New("--target needs yard or a profile")
			}
			target = arguments[index]
		case strings.HasPrefix(argument, "--target="):
			target = strings.TrimPrefix(argument, "--target=")
		case argument == "--name":
			index++
			if index >= len(arguments) {
				return "", "", "", "", false, errors.New("--name needs a project name")
			}
			name, explicitName = arguments[index], true
			if name == "" {
				return "", "", "", "", false, errors.New("--name needs a project name")
			}
		case strings.HasPrefix(argument, "--name="):
			name, explicitName = strings.TrimPrefix(argument, "--name="), true
			if name == "" {
				return "", "", "", "", false, errors.New("--name needs a project name")
			}
		case strings.HasPrefix(argument, "@") && len(argument) > 1:
			yard = strings.TrimPrefix(argument, "@")
		case strings.HasPrefix(argument, "-"):
			return "", "", "", "", false, fmt.Errorf("unknown option %q", argument)
		case url == "":
			url = argument
		case name == "":
			name, explicitName = argument, true
		default:
			return "", "", "", "", false, errors.New("too many clone arguments")
		}
	}
	if url == "" {
		return "", "", "", "", false, errors.New("clone needs a git URL")
	}
	return url, name, target, yard, explicitName, nil
}

func parseProjectSelector(name string, arguments []string) (string, bool, error) {
	selector := ""
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		if argument == "--" {
			break
		}
		switch argument {
		case "-y", "--yes", "--soft", "--purge", "--root", "--rebuild":
			continue
		case "-h", "--help":
			return "", false, nil
		}
		if strings.HasPrefix(argument, "-") {
			return "", false, fmt.Errorf("unknown option %q", argument)
		}
		if selector != "" {
			return "", false, errors.New("only one project may be selected")
		}
		selector = argument
	}
	if selector == "" {
		if name == "shell" {
			return "", false, nil
		}
		selector = "."
	}
	return selector, true, nil
}

func replaceProjectSelector(name string, arguments []string, id string) []string {
	result := append([]string(nil), arguments...)
	for index, argument := range result {
		if argument == "--" {
			break
		}
		if argument == "-y" || argument == "--yes" || argument == "--root" || argument == "--rebuild" {
			continue
		}
		if !strings.HasPrefix(argument, "-") {
			result[index] = id
			return result
		}
	}
	if name != "shell" {
		result = append(result, id)
	}
	return result
}

func validateProjectTarget(root, target string) error {
	if target == "yard" {
		return nil
	}
	if !domain.SafeName(target) {
		return fmt.Errorf("invalid project target %q", target)
	}
	path := filepath.Join(root, "config", "profiles", target, "profile.conf")
	if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("unknown project target %q", target)
	}
	return nil
}

func stripCurrentYardQualifier(selector, yard string) string {
	prefix, rest, qualified := strings.Cut(selector, "/")
	if qualified && prefix == yard && rest != "" {
		return rest
	}
	return selector
}
