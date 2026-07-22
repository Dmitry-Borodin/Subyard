package application

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type projectDataStub struct {
	requests []ports.InstanceExecRequest
	failAt   int
}

type projectDevicesStub struct {
	ensured []string
	removed []string
}

func (stub *projectDevicesStub) EnsureDiskDevice(
	_ context.Context,
	_, _, device, _, _ string,
) (bool, error) {
	stub.ensured = append(stub.ensured, device)
	return true, nil
}

func (stub *projectDevicesStub) RemoveDevice(
	_ context.Context,
	_, _, device string,
) (bool, error) {
	stub.removed = append(stub.removed, device)
	return true, nil
}

func (stub *projectDataStub) Execute(
	_ context.Context,
	_ domain.Context,
	request ports.InstanceExecRequest,
) (ports.InstanceExecResult, error) {
	stub.requests = append(stub.requests, request)
	if len(stub.requests) == stub.failAt {
		return ports.InstanceExecResult{Stderr: []byte("fixture failure")}, errors.New("failed")
	}
	return ports.InstanceExecResult{}, nil
}

func (stub *projectDataStub) Stream(
	_ context.Context,
	_ domain.Context,
	request ports.InstanceExecRequest,
	input io.Reader,
) (ports.InstanceExecResult, error) {
	request.Stdin, _ = io.ReadAll(input)
	return stub.Execute(context.Background(), domain.Context{}, request)
}

type projectArchiveStub struct {
	payload string
}

func (stub projectArchiveStub) Open(context.Context, string) (io.ReadCloser, error) {
	return io.NopCloser(strings.NewReader(stub.payload)), nil
}

func TestProjectCloneOwnsSequenceAndMetadata(t *testing.T) {
	data := &projectDataStub{}
	runner := ProjectActionRunner{
		Data:    data,
		Yard:    domain.Context{YardType: domain.YardLocal, DevUser: "dev", DevUID: 1000},
		Project: cloneRecord(),
	}
	result, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-clone", Adapter: "project", Action: "clone",
	}, nil)
	if err != nil || result.Status != "ok" || len(data.requests) != 4 {
		t.Fatalf("clone failed: result=%#v calls=%#v err=%v", result, data.requests, err)
	}
	if got := data.requests[2].Command; len(got) != 5 || got[0] != "git" || got[2] != "--" ||
		got[3] != cloneRecord().HostPath || data.requests[2].User != 1000 {
		t.Fatalf("unsafe clone command: %#v", data.requests[2])
	}
	var metadata map[string]any
	if err := json.Unmarshal(data.requests[3].Stdin, &metadata); err != nil ||
		metadata["projectId"] != cloneRecord().ProjectID || metadata["target"] != "openclaw" {
		t.Fatalf("invalid portable metadata: %q err=%v", data.requests[3].Stdin, err)
	}
}

func TestProjectCloneCleansPartialWorkspace(t *testing.T) {
	data := &projectDataStub{failAt: 3}
	runner := ProjectActionRunner{
		Data:    data,
		Yard:    domain.Context{YardType: domain.YardRemote, DevUser: "dev", DevUID: 1000},
		Project: cloneRecord(),
	}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-clone", Adapter: "project", Action: "clone",
	}, nil); err == nil {
		t.Fatal("clone failure was hidden")
	}
	if len(data.requests) != 4 || data.requests[3].Command[0] != "rm" {
		t.Fatalf("partial clone was not cleaned: %#v", data.requests)
	}
}

func TestProjectRemoveCleansEnvironmentBeforeWorkspace(t *testing.T) {
	data := &projectDataStub{}
	record := cloneRecord()
	record.Mode = domain.ProjectSync
	runner := ProjectActionRunner{
		Data: data, Yard: domain.Context{YardType: domain.YardRemote}, Project: record,
	}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-remove", Adapter: "project", Action: "remove",
	}, nil); err != nil {
		t.Fatal(err)
	}
	if len(data.requests) != 5 || data.requests[0].Command[0] != "docker" ||
		data.requests[4].Command[0] != "rm" || data.requests[4].Command[3] != "/srv/workspaces/demo-12345678" {
		t.Fatalf("unexpected removal order: %#v", data.requests)
	}
}

func TestProjectRemoveFailureKeepsWorkspace(t *testing.T) {
	data := &projectDataStub{failAt: 1}
	record := cloneRecord()
	record.Mode = domain.ProjectSync
	runner := ProjectActionRunner{
		Data: data, Yard: domain.Context{YardType: domain.YardRemote}, Project: record,
	}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-remove", Adapter: "project", Action: "remove",
	}, nil); err == nil {
		t.Fatal("environment cleanup failure was hidden")
	}
	if len(data.requests) != 1 {
		t.Fatalf("workspace changed after failed environment cleanup: %#v", data.requests)
	}
}

func TestProjectRemoveDetachesBindWithoutDeletingHostData(t *testing.T) {
	data, devices := &projectDataStub{}, &projectDevicesStub{}
	record := cloneRecord()
	record.Mode, record.Target = domain.ProjectBind, "yard"
	runner := ProjectActionRunner{
		Data: data, Devices: devices, Yard: domain.Context{YardType: domain.YardLocal}, Project: record,
	}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-remove", Adapter: "project", Action: "remove",
	}, nil); err != nil {
		t.Fatal(err)
	}
	if len(data.requests) != 0 || len(devices.removed) != 1 || devices.removed[0] != "ws-demo-12345678" {
		t.Fatalf("bind removal crossed the data boundary: calls=%#v devices=%#v", data.requests, devices.removed)
	}
}

func TestProjectSyncStreamsArchiveAndWritesMetadata(t *testing.T) {
	data := &projectDataStub{}
	record := cloneRecord()
	record.Mode, record.HostPath = domain.ProjectSync, "/host/demo"
	runner := ProjectActionRunner{
		Data: data, Archive: projectArchiveStub{payload: "archive"},
		Yard: domain.Context{YardType: domain.YardRemote, DevUID: 1000}, Project: record,
	}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-sync", Adapter: "project", Action: "sync",
	}, nil); err != nil {
		t.Fatal(err)
	}
	if len(data.requests) != 3 || data.requests[1].Command[0] != "tar" ||
		string(data.requests[1].Stdin) != "archive" || data.requests[2].Command[0] != "tee" {
		t.Fatalf("unexpected sync sequence: %#v", data.requests)
	}
}

func TestProjectBindUsesIncusDeviceAndWritesMetadata(t *testing.T) {
	data, devices := &projectDataStub{}, &projectDevicesStub{}
	record := cloneRecord()
	record.Mode, record.HostPath = domain.ProjectBind, "/host/demo"
	runner := ProjectActionRunner{
		Data: data, Devices: devices,
		Yard: domain.Context{YardType: domain.YardLocal, DevUID: 1000}, Project: record,
	}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation-bind", Adapter: "project", Action: "bind",
	}, nil); err != nil {
		t.Fatal(err)
	}
	if len(devices.ensured) != 1 || devices.ensured[0] != "ws-demo-12345678" ||
		len(data.requests) != 2 || data.requests[1].Command[0] != "tee" {
		t.Fatalf("unexpected bind sequence: calls=%#v devices=%#v", data.requests, devices.ensured)
	}
}

func cloneRecord() domain.ProjectRecord {
	return domain.ProjectRecord{
		Schema: 1, ProjectID: "demo-12345678", Name: "Demo",
		HostPath: "https://example.invalid/demo.git", YardPath: "/srv/workspaces/demo-12345678/src",
		Mode: domain.ProjectGit, SSHHost: "yard", Target: "openclaw", ImportedAt: "2026-07-22T00:00:00Z",
	}
}
