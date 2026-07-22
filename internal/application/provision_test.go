package application

import (
	"context"
	"errors"
	"io"
	"slices"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type provisionFixture struct {
	instance ports.InstanceInfo
	updates  []map[string]string
	actions  []string
	profiles []string
	fail     string
}

func (fixture *provisionFixture) Instance(context.Context, string, string) (ports.InstanceInfo, error) {
	return fixture.instance, nil
}

func (fixture *provisionFixture) Server(context.Context) (ports.ServerInfo, error) {
	return ports.ServerInfo{}, nil
}

func (fixture *provisionFixture) ReconcileState(context.Context, string, string, string, string, string) (ports.ReconcileState, error) {
	return ports.ReconcileState{}, nil
}

func (fixture *provisionFixture) Events(context.Context, []string) (<-chan domain.OperationEvent, <-chan error) {
	return nil, nil
}

func (fixture *provisionFixture) SetInstanceConfig(_ context.Context, _, _ string, values map[string]string) error {
	fixture.updates = append(fixture.updates, values)
	return nil
}

func (fixture *provisionFixture) Run(_ context.Context, request domain.AdapterRequest, _ io.Reader) (domain.AdapterResult, string, error) {
	if request.Action == "profile" {
		name := request.Arguments[0]
		fixture.profiles = append(fixture.profiles, name)
		if name == fixture.fail {
			return domain.AdapterResult{}, "", errors.New("hook failed")
		}
		return domain.AdapterResult{Schema: 1, OperationID: request.OperationID, Status: "ok"}, "", nil
	}
	fixture.actions = append(fixture.actions, request.Action)
	if request.Action == "start" {
		fixture.instance.Status = "Running"
	}
	if request.Action == "stop" {
		fixture.instance.Status = "Stopped"
	}
	return domain.AdapterResult{Schema: 1, OperationID: request.OperationID, Status: "ok"}, "", nil
}

func TestProvisionRestoresTemporarilyStartedYard(t *testing.T) {
	fixture := &provisionFixture{instance: managedProvisionInstance("Stopped", PowerStopped)}
	runner := provisionRunnerFixture(fixture, "android", "openclaw")
	result, _, err := runner.Run(context.Background(), provisionRequest(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != "ok" || !slices.Equal(fixture.actions, []string{"start", "stop"}) {
		t.Fatalf("result=%+v actions=%v", result, fixture.actions)
	}
	if !slices.Equal(fixture.profiles, []string{"android", "openclaw"}) {
		t.Fatalf("profiles=%v", fixture.profiles)
	}
}

func TestProvisionRestoresPowerAfterHookFailure(t *testing.T) {
	fixture := &provisionFixture{instance: managedProvisionInstance("Stopped", PowerStopped), fail: "openclaw"}
	runner := provisionRunnerFixture(fixture, "android", "openclaw")
	if _, _, err := runner.Run(context.Background(), provisionRequest(), nil); err == nil {
		t.Fatal("expected hook failure")
	}
	if !slices.Equal(fixture.actions, []string{"start", "stop"}) {
		t.Fatalf("actions=%v", fixture.actions)
	}
}

func TestProvisionKeepsDesiredRunningYardStarted(t *testing.T) {
	fixture := &provisionFixture{instance: managedProvisionInstance("Stopped", PowerRunning)}
	runner := provisionRunnerFixture(fixture, "subyard-dev")
	if _, _, err := runner.Run(context.Background(), provisionRequest(), nil); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fixture.actions, []string{"start"}) {
		t.Fatalf("actions=%v", fixture.actions)
	}
}

func provisionRunnerFixture(fixture *provisionFixture, names ...string) ProvisionRunner {
	yard := domain.Context{YardName: "test", IncusProject: "subyard-test", InstanceName: "yard-test"}
	return ProvisionRunner{
		Power: PowerService{Instances: fixture, Config: fixture}, Physical: fixture,
		Yard: yard, Profiles: names,
	}
}

func managedProvisionInstance(status, desired string) ports.InstanceInfo {
	return ports.InstanceInfo{Status: status, Config: map[string]string{
		"user.subyard.managed": "true", "user.subyard.desired_power": desired,
		"user.subyard.initialized": "true", "user.subyard.name": "test",
		"user.subyard.bridge": "incusbr0", "boot.autostart": "false",
	}}
}

func provisionRequest() domain.AdapterRequest {
	return domain.AdapterRequest{Schema: 1, OperationID: "provision-test", Adapter: "provision", Action: "apply"}
}
