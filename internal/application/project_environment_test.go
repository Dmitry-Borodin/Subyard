package application

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

func TestProjectEnvironmentUpStagesProtectedInputAndNativeManifest(t *testing.T) {
	data := &projectDataStub{run: func(request ports.InstanceExecRequest) (ports.InstanceExecResult, error) {
		command := request.Command
		if len(command) >= 2 && command[0] == "docker" && command[1] == "inspect" ||
			slices.Equal(command, []string{"test", "-d", "/mnt/host/agent-sessions"}) {
			return ports.InstanceExecResult{}, errors.New("not found")
		}
		return ports.InstanceExecResult{}, nil
	}}
	runner := ProjectEnvironmentRunner{
		Data: data, Yard: domain.Context{DevUID: 1000}, Project: cloneRecord(), HasSecret: true,
		Profile: ProjectEnvironmentProfile{
			BaseImage: "ubuntu:24.04", Caches: []string{"/srv/cache/npm"},
			Features: []string{"browser"}, Devices: []string{"kvm"},
			Environment: map[string]string{"PUBLIC_VALUE": "visible"},
		},
	}
	result, diagnostics, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-env-up", Adapter: "project-env", Action: "up",
	}, strings.NewReader("SECRET_VALUE=hidden\n"))
	if err != nil || result.Status != "ok" || !strings.Contains(diagnostics, "box \"Demo\" up") {
		t.Fatalf("project environment up failed: result=%#v diagnostics=%q err=%v", result, diagnostics, err)
	}
	var streams [][]byte
	for _, request := range data.requests {
		if len(request.Stdin) != 0 {
			streams = append(streams, request.Stdin)
		}
	}
	if len(streams) != 2 || string(streams[0]) != "SECRET_VALUE=hidden\n" {
		t.Fatalf("protected input was not staged once: %#v", streams)
	}
	var manifest map[string]any
	if err := json.Unmarshal(streams[1], &manifest); err != nil || manifest["profile"] != "openclaw" {
		t.Fatalf("invalid native manifest: %q err=%v", streams[1], err)
	}
	if strings.Contains(string(streams[1]), "hidden") {
		t.Fatal("secret leaked into the public manifest")
	}
	var dockerRun []string
	for _, request := range data.requests {
		if len(request.Command) >= 2 && request.Command[0] == "docker" && request.Command[1] == "run" {
			dockerRun = request.Command
		}
	}
	joined := strings.Join(dockerRun, " ")
	if len(dockerRun) == 0 || !strings.Contains(joined, "PUBLIC_VALUE=visible") ||
		!strings.Contains(joined, "/run/subyard/profile.env:ro") || strings.Contains(joined, "hidden") {
		t.Fatalf("unsafe Docker invocation: %#v", dockerRun)
	}
}

func TestProjectEnvironmentRejectsControlSocketMount(t *testing.T) {
	data := &projectDataStub{}
	runner := ProjectEnvironmentRunner{
		Data: data, Yard: domain.Context{DevUID: 1000}, Project: cloneRecord(),
		Profile: ProjectEnvironmentProfile{
			BaseImage: "ubuntu:24.04", Mounts: []string{"/var/run/docker.sock:/var/run/docker.sock"},
		},
	}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-env-unsafe", Adapter: "project-env", Action: "up",
	}, nil); err == nil || !strings.Contains(err.Error(), "control socket") {
		t.Fatalf("unsafe mount was accepted: %v", err)
	}
	for _, request := range data.requests {
		if len(request.Stdin) != 0 {
			t.Fatal("unsafe profile staged data before validation")
		}
	}
}

func TestProjectEnvironmentInfoAndDownUseDataPlane(t *testing.T) {
	manifestJSON := "{\"profile\":\"openclaw\"}\n"
	data := &projectDataStub{run: func(request ports.InstanceExecRequest) (ports.InstanceExecResult, error) {
		if len(request.Command) == 2 && request.Command[0] == "cat" {
			return ports.InstanceExecResult{Stdout: []byte(manifestJSON)}, nil
		}
		return ports.InstanceExecResult{}, nil
	}}
	runner := ProjectEnvironmentRunner{Data: data, Project: cloneRecord()}
	_, output, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-env-info", Adapter: "project-env", Action: "info",
	}, nil)
	if err != nil || output != manifestJSON {
		t.Fatalf("project environment info failed: output=%q err=%v", output, err)
	}
	_, output, err = runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-env-down", Adapter: "project-env", Action: "down",
	}, nil)
	if err != nil || !strings.Contains(output, "stopped") {
		t.Fatalf("project environment down failed: output=%q err=%v", output, err)
	}
	last := data.requests[len(data.requests)-1].Command
	if !slices.Equal(last, []string{"docker", "stop", "subyard-box-demo-12345678"}) {
		t.Fatalf("unexpected down command: %#v", last)
	}
}
