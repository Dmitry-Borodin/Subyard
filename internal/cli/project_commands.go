package cli

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
)

type projectCommit string

const (
	projectCommitNone   projectCommit = ""
	projectCommitPut    projectCommit = "put"
	projectCommitDelete projectCommit = "delete"
)

type projectExecution struct {
	Loaded      config.Loaded
	Arguments   []string
	Environment map[string]string
	Record      domain.ProjectRecord
	Store       ports.ProjectStore
	Commit      projectCommit
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
	path, requestedTarget, targetYard, err := parseProjectImportArguments(arguments)
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
	id, err := state.ProjectID(hostPath)
	if err != nil {
		return nil, err
	}
	selected, err := cli.routeSyncProject(ctx, loaded.Context, id, targetYard)
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
	existing, getErr := store.Get(ctx, id)
	exists := getErr == nil
	if getErr != nil && !errors.Is(getErr, state.ErrNotFound) {
		return nil, getErr
	}
	mode := domain.ProjectMode(name)
	if exists && existing.Mode != mode {
		return nil, fmt.Errorf("%q is already in the yard as %q; remove it before re-adding as %s",
			filepath.Base(hostPath), existing.Mode, name)
	}
	target := requestedTarget
	if target == "" && exists {
		target = existing.Target
	}
	if target == "" {
		target = "yard"
	}
	if err := validateProjectTarget(cli.options.RepositoryRoot, target); err != nil {
		return nil, err
	}
	record := domain.ProjectRecord{
		Schema: 1, ProjectID: id, Name: filepath.Base(hostPath), HostPath: hostPath,
		YardPath: state.YardPath(id), Mode: mode, SSHHost: selectedLoaded.Context.SSHHost,
		ImportedAt: time.Now().UTC().Format(time.RFC3339), Target: target,
	}
	if target != "yard" {
		record.Profile = target
	}
	return &projectExecution{
		Loaded: selectedLoaded, Arguments: arguments, Environment: projectSnapshot(record, exists),
		Record: record, Store: store, Commit: projectCommitPut,
	}, nil
}

func (cli *CLI) prepareProjectClone(
	ctx context.Context,
	loaded config.Loaded,
	arguments []string,
) (*projectExecution, error) {
	url, name, target, targetYard, err := parseProjectCloneArguments(arguments)
	if err != nil {
		return nil, err
	}
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(url), ".git")
	}
	safeName := strings.Map(func(char rune) rune {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '.' || char == '_' || char == '-' {
			return char
		}
		return '-'
	}, name)
	digest := sha256.Sum256([]byte(url))
	id := fmt.Sprintf("%s-%x", safeName, digest[:4])
	selected, err := cli.routeSyncProject(ctx, loaded.Context, id, targetYard)
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
	if _, err := store.Get(ctx, id); err == nil {
		return nil, fmt.Errorf("%q is already in the yard (id %s); remove it first", name, id)
	} else if !errors.Is(err, state.ErrNotFound) {
		return nil, err
	}
	if err := validateProjectTarget(cli.options.RepositoryRoot, target); err != nil {
		return nil, err
	}
	record := domain.ProjectRecord{
		Schema: 1, ProjectID: id, Name: name, HostPath: url, YardPath: state.YardPath(id),
		Mode: domain.ProjectGit, SSHHost: selectedLoaded.Context.SSHHost,
		ImportedAt: time.Now().UTC().Format(time.RFC3339), Target: target,
	}
	if target != "yard" {
		record.Profile = target
	}
	return &projectExecution{
		Loaded: selectedLoaded, Arguments: arguments, Environment: projectSnapshot(record, false),
		Record: record, Store: store, Commit: projectCommitPut,
	}, nil
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
	match, err := cli.resolveProjectForCommand(ctx, loaded, selector, explicit)
	if err != nil {
		return nil, err
	}
	selectedLoaded, err := cli.activateProjectContext(match.Yard, loaded)
	if err != nil {
		return nil, err
	}
	store, err := openProjectStore(ctx, selectedLoaded.Context.Paths.StateDir)
	if err != nil {
		return nil, err
	}
	execution := &projectExecution{
		Loaded: selectedLoaded, Arguments: arguments, Environment: projectSnapshot(match.Record, true),
		Record: match.Record, Store: store,
	}
	if name == "remove" {
		execution.Commit = projectCommitDelete
	}
	// Owner-forwarded commands receive a stable ID, never a controller-only host path.
	if selectedLoaded.Context.YardType == domain.YardRemote &&
		(name == "shell" || name == "up" || name == "down" || name == "info") {
		execution.Arguments = replaceProjectSelector(name, arguments, match.Record.ProjectID)
	}
	return execution, nil
}

func (cli *CLI) resolveProjectForCommand(
	ctx context.Context,
	loaded config.Loaded,
	selector string,
	explicit bool,
) (state.Match, error) {
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
		_, observation, observeErr := (application.ProjectInventory{
			Store: store, Observer: cli.projectObserver(),
		}).Read(ctx, loaded.Context, true)
		if observeErr == nil {
			for _, warning := range observation.Warnings {
				fmt.Fprintf(cli.options.Stderr, "warning: %s\n", warning)
			}
			if match, retryErr := cli.resolveLocalProject(ctx, loaded.Context, store, selector); retryErr == nil {
				fmt.Fprintf(cli.options.Stderr,
					"warning: registered project %q from live yard metadata; host path is unavailable\n", selector)
				return match, nil
			}
		}
		return state.Match{}, resolveErr
	}
	return cli.resolveGlobalProject(ctx, loaded.Context, selector)
}

func (cli *CLI) activateProjectContext(name string, loaded config.Loaded) (config.Loaded, error) {
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
			if code := cli.forwardRemote(ctx, execution.Loaded.Context, "_project-state", []string{
				"upsert", execution.Record.ProjectID, execution.Record.Name,
				string(execution.Record.Mode), execution.Record.Target,
			}); code != 0 {
				return errors.New("physical operation completed, but owner project state was not updated; re-run the command")
			}
		}
		return execution.Store.Put(ctx, execution.Record)
	case projectCommitDelete:
		if execution.Loaded.Context.YardType == domain.YardRemote {
			if code := cli.forwardRemote(ctx, execution.Loaded.Context, "_project-state",
				[]string{"unregister", execution.Record.ProjectID}); code != 0 {
				return errors.New("physical removal completed, but owner project state was not updated; re-run the command")
			}
		}
		return execution.Store.Delete(ctx, execution.Record.ProjectID)
	default:
		return errors.New("unknown project commit")
	}
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
		"SUBYARD_PROJECT_DEVICE":    state.WorkspaceDevice(record.ProjectID),
		"SUBYARD_PROJECT_EXISTS":    existsValue,
	}
}

func parseProjectImportArguments(arguments []string) (path, target, yard string, err error) {
	path = "."
	positional := false
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		switch {
		case argument == "-y" || argument == "--yes":
		case argument == "--target":
			index++
			if index >= len(arguments) {
				return "", "", "", errors.New("--target needs yard or a profile")
			}
			target = arguments[index]
		case strings.HasPrefix(argument, "--target="):
			target = strings.TrimPrefix(argument, "--target=")
		case strings.HasPrefix(argument, "@") && len(argument) > 1:
			yard = strings.TrimPrefix(argument, "@")
		case strings.HasPrefix(argument, "-"):
			return "", "", "", fmt.Errorf("unknown option %q", argument)
		default:
			if positional {
				return "", "", "", errors.New("only one project path may be selected")
			}
			path, positional = argument, true
		}
	}
	return path, target, yard, nil
}

func parseProjectCloneArguments(arguments []string) (url, name, target, yard string, err error) {
	target = "yard"
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
		case strings.HasPrefix(argument, "@") && len(argument) > 1:
			yard = strings.TrimPrefix(argument, "@")
		case strings.HasPrefix(argument, "-"):
			return "", "", "", "", fmt.Errorf("unknown option %q", argument)
		case url == "":
			url = argument
		case name == "":
			name = argument
		default:
			return "", "", "", "", errors.New("too many clone arguments")
		}
	}
	if url == "" {
		return "", "", "", "", errors.New("clone needs a git URL")
	}
	return url, name, target, yard, nil
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
