package application

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
)

type ProjectActionRunner struct {
	Data       ports.YardExecutor
	Devices    ports.InstanceDeviceManager
	Archive    ports.DirectoryArchiver
	Exports    ports.ProjectExportStore
	Instances  ports.Incus
	VSCode     ports.VSCode
	Extensions []string
	Yard       domain.Context
	Project    domain.ProjectRecord
	SoftRemove bool
}

var workspaceUnsafe = regexp.MustCompile(`[^A-Za-z0-9._-]`)
var extensionToken = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

func (runner ProjectActionRunner) Run(
	ctx context.Context,
	request domain.AdapterRequest,
	_ io.Reader,
) (domain.AdapterResult, string, error) {
	if request.Adapter != "project" ||
		request.Action != "clone" && request.Action != "remove" &&
			request.Action != "sync" && request.Action != "bind" && request.Action != "export" &&
			request.Action != "code" {
		return domain.AdapterResult{}, "", errors.New("unsupported project action")
	}
	if runner.Data == nil {
		return domain.AdapterResult{}, "", errors.New("project data plane is required")
	}
	if err := runner.Project.Validate(runner.Project.ProjectID); err != nil {
		return domain.AdapterResult{}, "", err
	}
	message := ""
	output := map[string]any{"projectId": runner.Project.ProjectID, "yardPath": runner.Project.YardPath}
	switch request.Action {
	case "clone":
		if runner.Project.Mode != domain.ProjectGit || runner.Project.HostPath == "" {
			return domain.AdapterResult{}, "", errors.New("clone requires a git project with a repository URL")
		}
		if err := runner.clone(ctx); err != nil {
			return domain.AdapterResult{}, "", err
		}
		message = fmt.Sprintf("cloned %s -> %s\n", runner.Project.Name, runner.Project.YardPath)
	case "remove":
		if err := runner.remove(ctx); err != nil {
			return domain.AdapterResult{}, "", err
		}
		message = fmt.Sprintf("removed %s\n", runner.Project.Name)
	case "sync":
		if runner.Project.Mode != domain.ProjectSync {
			return domain.AdapterResult{}, "", errors.New("sync requires a sync project")
		}
		if err := runner.sync(ctx); err != nil {
			return domain.AdapterResult{}, "", err
		}
		message = fmt.Sprintf("synced %s -> %s\n", runner.Project.Name, runner.Project.YardPath)
	case "bind":
		if runner.Project.Mode != domain.ProjectBind {
			return domain.AdapterResult{}, "", errors.New("bind requires a bind project")
		}
		if err := runner.bind(ctx); err != nil {
			return domain.AdapterResult{}, "", err
		}
		message = fmt.Sprintf("bound %s -> %s\n", runner.Project.HostPath, runner.Project.YardPath)
	case "export":
		exportMessage, path, err := runner.export(ctx, request.OperationID)
		if err != nil {
			return domain.AdapterResult{}, "", err
		}
		message = exportMessage
		if path != "" {
			output["patch"] = path
		}
	case "code":
		codeMessage, err := runner.code(ctx)
		if err != nil {
			return domain.AdapterResult{}, "", err
		}
		message = codeMessage
	}
	return domain.AdapterResult{
		Schema: 1, OperationID: request.OperationID, Status: "ok",
		Output: output,
	}, message, nil
}

func (runner ProjectActionRunner) code(ctx context.Context) (string, error) {
	if err := runner.codeTargetReady(ctx); err != nil {
		return "", err
	}
	extensions := runner.Extensions
	if len(extensions) == 0 {
		extensions = []string{"anthropic.claude-code", "openai.chatgpt", "sst-dev.opencode"}
	}
	for _, extension := range extensions {
		if !extensionToken.MatchString(extension) {
			return "", fmt.Errorf("invalid recommended VS Code extension %q", extension)
		}
	}
	workspaceName := workspaceUnsafe.ReplaceAllString(runner.Project.Name, "_")
	workspace := filepath.Join("/home", runner.Yard.DevUser, ".subyard", "workspaces", workspaceName+".code-workspace")
	payload, err := json.Marshal(map[string]any{
		"folders":    []map[string]string{{"name": runner.Project.Name, "path": runner.Project.YardPath}},
		"extensions": map[string]any{"recommendations": extensions},
	})
	if err != nil {
		return "", err
	}
	dev := uint32(runner.Yard.DevUID)
	if err := runner.execute(ctx, "create VS Code workspace directory", ports.InstanceExecRequest{
		Command: []string{"install", "-d", "--", filepath.Dir(workspace)}, User: dev, Group: dev,
	}); err != nil {
		return "", err
	}
	if err := runner.execute(ctx, "write VS Code workspace", ports.InstanceExecRequest{
		Command: []string{"tee", workspace}, Stdin: append(payload, '\n'), User: dev, Group: dev,
	}); err != nil {
		return "", err
	}
	uri := "vscode-remote://ssh-remote+" + runner.Project.SSHHost + workspace
	message := ""
	if runner.Project.Target != "" && runner.Project.Target != "yard" {
		message = fmt.Sprintf("attach Dev Containers to subyard-box-%s at /workspace\n", runner.Project.ProjectID)
	}
	if runner.VSCode == nil {
		return message + "VS Code CLI is unavailable; open manually:\n  code --file-uri " + uri + "\n", nil
	}
	if _, err := runner.VSCode.Run(ctx, "--file-uri", uri); err != nil {
		return "", err
	}
	return message + fmt.Sprintf("opened %s (%s:%s) in VS Code\n", runner.Project.Name, runner.Project.SSHHost, runner.Project.YardPath), nil
}

func (runner ProjectActionRunner) codeTargetReady(ctx context.Context) error {
	if runner.Yard.YardType == domain.YardRemote {
		return runner.execute(ctx, "reach remote yard", ports.InstanceExecRequest{Command: []string{"true"}})
	}
	if runner.Instances == nil {
		return errors.New("Incus reader is required for VS Code")
	}
	instance, err := runner.Instances.Instance(ctx, runner.Yard.IncusProject, runner.Yard.InstanceName)
	if err != nil {
		return err
	}
	if !strings.EqualFold(instance.Status, "running") {
		return errors.New("yard is not running")
	}
	if _, present := instance.Devices["ssh"]; !present {
		return errors.New("yard SSH access is not configured; run yard init")
	}
	return nil
}

func (runner ProjectActionRunner) export(ctx context.Context, operationID string) (string, string, error) {
	if runner.Project.Mode != domain.ProjectSync {
		return "", "", fmt.Errorf("%s projects cannot be exported", runner.Project.Mode)
	}
	if runner.Archive == nil || runner.Exports == nil {
		return "", "", errors.New("project archive and export store are required")
	}
	temporary := filepath.Join("/tmp", "subyard-export-"+operationID)
	defer func() { _ = runner.cleanup(ctx, temporary) }()
	if err := runner.execute(ctx, "prepare export snapshot", ports.InstanceExecRequest{
		Command: []string{"install", "-d", "--", filepath.Join(temporary, "a")},
	}); err != nil {
		return "", "", err
	}
	archive, err := runner.Archive.Open(ctx, runner.Project.HostPath)
	if err != nil {
		return "", "", fmt.Errorf("read host copy: %w", err)
	}
	result, streamErr := runner.Data.Stream(ctx, runner.Yard, ports.InstanceExecRequest{
		Command: []string{"tar", "-C", filepath.Join(temporary, "a"), "-xf", "-"},
	}, archive)
	if err := errors.Join(streamErr, archive.Close()); err != nil {
		return "", "", executionError("copy host snapshot", result, err)
	}
	result, err = runner.Data.Execute(ctx, runner.Yard, ports.InstanceExecRequest{
		Command: []string{"diff", "-ruN", "--exclude=.git", filepath.Join(temporary, "a"), runner.Project.YardPath},
	})
	if err == nil && result.ExitCode == 0 {
		return fmt.Sprintf("no changes in the yard (%s)\n", runner.Project.Name), "", nil
	}
	if result.ExitCode != 1 {
		return "", "", executionError("diff project copies", result, err)
	}
	patch := portablePatch(result.Stdout, filepath.Join(temporary, "a"), runner.Project.YardPath)
	path, err := runner.Exports.Publish(ctx, runner.Project.ProjectID, patch)
	if err != nil {
		return "", "", fmt.Errorf("publish export: %w", err)
	}
	return fmt.Sprintf("exported %s\npatch: %s\n", runner.Project.Name, path), path, nil
}

func portablePatch(patch []byte, hostSnapshot, yardPath string) []byte {
	var portable bytes.Buffer
	for _, line := range bytes.SplitAfter(patch, []byte("\n")) {
		if bytes.HasPrefix(line, []byte("diff ")) || bytes.HasPrefix(line, []byte("--- ")) ||
			bytes.HasPrefix(line, []byte("+++ ")) || bytes.HasPrefix(line, []byte("Only in ")) {
			line = bytes.ReplaceAll(line, []byte(hostSnapshot), []byte("a"))
			line = bytes.ReplaceAll(line, []byte(yardPath), []byte("b"))
		}
		portable.Write(line)
	}
	return portable.Bytes()
}

func (runner ProjectActionRunner) clone(ctx context.Context) error {
	directory := filepath.Dir(runner.Project.YardPath)
	if err := runner.execute(ctx, "remove stale workspace", ports.InstanceExecRequest{
		Command: []string{"rm", "-rf", "--", directory},
	}); err != nil {
		return err
	}
	create := ports.InstanceExecRequest{Command: []string{"install", "-d", "--", directory}}
	if runner.Yard.YardType != domain.YardRemote {
		uid := fmt.Sprint(runner.Yard.DevUID)
		create.Command = []string{"install", "-d", "-o", uid, "-g", uid, "--", directory}
	}
	if err := runner.execute(ctx, "create workspace", create); err != nil {
		return err
	}
	dev := uint32(runner.Yard.DevUID)
	clone := ports.InstanceExecRequest{
		Command:     []string{"git", "clone", "--", runner.Project.HostPath, runner.Project.YardPath},
		Environment: map[string]string{"HOME": "/home/" + runner.Yard.DevUser}, User: dev, Group: dev,
	}
	if err := runner.execute(ctx, "git clone", clone); err != nil {
		return errors.Join(err, runner.cleanup(ctx, directory))
	}
	if err := runner.writeMetadata(ctx); err != nil {
		return errors.Join(err, runner.cleanup(ctx, directory))
	}
	return nil
}

func (runner ProjectActionRunner) writeMetadata(ctx context.Context) error {
	dev := uint32(runner.Yard.DevUID)
	metadata, err := json.Marshal(struct {
		Schema     int                `json:"schema"`
		ProjectID  string             `json:"projectId"`
		Name       string             `json:"name"`
		Mode       domain.ProjectMode `json:"mode"`
		Target     string             `json:"target,omitempty"`
		ImportedAt string             `json:"importedAt,omitempty"`
	}{1, runner.Project.ProjectID, runner.Project.Name, runner.Project.Mode,
		runner.Project.Target, runner.Project.ImportedAt})
	if err != nil {
		return err
	}
	directory := filepath.Dir(runner.Project.YardPath)
	write := ports.InstanceExecRequest{
		Command: []string{"tee", filepath.Join(directory, ".subyard-meta.json")},
		Stdin:   append(metadata, '\n'), User: dev, Group: dev,
	}
	if err := runner.execute(ctx, "write project metadata", write); err != nil {
		return err
	}
	return nil
}

func (runner ProjectActionRunner) sync(ctx context.Context) error {
	if runner.Archive == nil {
		return errors.New("project archive adapter is required")
	}
	directory := filepath.Dir(runner.Project.YardPath)
	create := ports.InstanceExecRequest{
		Command: []string{"install", "-d", "--", directory, runner.Project.YardPath},
	}
	if runner.Yard.YardType != domain.YardRemote {
		uid := fmt.Sprint(runner.Yard.DevUID)
		create.Command = []string{"install", "-d", "-o", uid, "-g", uid, "--",
			directory, runner.Project.YardPath}
	}
	if err := runner.execute(ctx, "create sync workspace", create); err != nil {
		return err
	}
	archive, err := runner.Archive.Open(ctx, runner.Project.HostPath)
	if err != nil {
		return err
	}
	dev := uint32(runner.Yard.DevUID)
	result, streamErr := runner.Data.Stream(ctx, runner.Yard, ports.InstanceExecRequest{
		Command: []string{"tar", "-C", runner.Project.YardPath, "-xf", "-"}, User: dev, Group: dev,
	}, archive)
	archiveErr := archive.Close()
	if streamErr != nil {
		streamErr = executionError("copy project archive", result, streamErr)
	}
	if err := errors.Join(streamErr, archiveErr); err != nil {
		return err
	}
	return runner.writeMetadata(ctx)
}

func (runner ProjectActionRunner) bind(ctx context.Context) error {
	if runner.Yard.YardType == domain.YardRemote {
		return errors.New("bind is host-local; use sync or clone")
	}
	if runner.Devices == nil {
		return errors.New("Incus device manager is required for bind")
	}
	directory := filepath.Dir(runner.Project.YardPath)
	uid := fmt.Sprint(runner.Yard.DevUID)
	if err := runner.execute(ctx, "create bind metadata directory", ports.InstanceExecRequest{
		Command: []string{"install", "-d", "-o", uid, "-g", uid, "--", directory},
	}); err != nil {
		return err
	}
	device := state.WorkspaceDevice(runner.Project.ProjectID)
	changed, err := runner.Devices.EnsureDiskDevice(ctx, runner.Yard.IncusProject,
		runner.Yard.InstanceName, device, runner.Project.HostPath, runner.Project.YardPath)
	if err != nil {
		return err
	}
	if err := runner.writeMetadata(ctx); err != nil {
		if changed {
			_, rollbackErr := runner.Devices.RemoveDevice(ctx, runner.Yard.IncusProject,
				runner.Yard.InstanceName, device)
			return errors.Join(err, rollbackErr)
		}
		return err
	}
	return nil
}

func (runner ProjectActionRunner) cleanup(ctx context.Context, directory string) error {
	return runner.execute(ctx, "clean partial workspace", ports.InstanceExecRequest{
		Command: []string{"rm", "-rf", "--", directory},
	})
}

func (runner ProjectActionRunner) remove(ctx context.Context) error {
	if runner.Project.Target != "" && runner.Project.Target != "yard" {
		if err := runner.removeEnvironment(ctx); err != nil {
			return fmt.Errorf("remove project environment before state: %w", err)
		}
	}
	if runner.Project.Mode == domain.ProjectBind {
		if runner.Yard.YardType == domain.YardRemote {
			return errors.New("remote yards cannot own bind projects")
		}
		if runner.Devices == nil {
			return errors.New("Incus device manager is required for bind removal")
		}
		_, err := runner.Devices.RemoveDevice(ctx, runner.Yard.IncusProject,
			runner.Yard.InstanceName, state.WorkspaceDevice(runner.Project.ProjectID))
		return err
	}
	if runner.SoftRemove {
		return nil
	}
	return runner.cleanup(ctx, filepath.Dir(runner.Project.YardPath))
}

func (runner ProjectActionRunner) removeEnvironment(ctx context.Context) error {
	if err := runner.execute(ctx, "reach project environment", ports.InstanceExecRequest{
		Command: []string{"docker", "info"},
	}); err != nil {
		return err
	}
	box := "subyard-box-" + runner.Project.ProjectID
	if _, err := runner.Data.Execute(ctx, runner.Yard, ports.InstanceExecRequest{
		Command: []string{"docker", "inspect", box},
	}); err == nil {
		if err := runner.execute(ctx, "remove project environment", ports.InstanceExecRequest{
			Command: []string{"docker", "rm", "-f", box},
		}); err != nil {
			return err
		}
	}
	return runner.execute(ctx, "remove staged project environment", ports.InstanceExecRequest{
		Command: []string{"rm", "-rf", "--", "/srv/env-secrets/" + runner.Project.ProjectID,
			"/srv/env-meta/" + runner.Project.ProjectID},
	})
}

func (runner ProjectActionRunner) execute(ctx context.Context, step string, request ports.InstanceExecRequest) error {
	result, err := runner.Data.Execute(ctx, runner.Yard, request)
	if err == nil {
		return nil
	}
	return executionError(step, result, err)
}

func executionError(step string, result ports.InstanceExecResult, err error) error {
	diagnostic := strings.TrimSpace(string(result.Stderr))
	if diagnostic != "" {
		return fmt.Errorf("%s: %s: %w", step, diagnostic, err)
	}
	return fmt.Errorf("%s: %w", step, err)
}
