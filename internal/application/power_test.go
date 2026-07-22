package application

import (
	"context"
	"errors"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestPowerServiceImportsAndCommitsAtomically(t *testing.T) {
	incus := &testkit.Incus{Instances: map[string]ports.InstanceInfo{
		"subyard/yard": {Name: "yard", Project: "subyard", Status: "Stopped"},
	}}
	yard := domain.Context{
		YardName: "default", IncusProject: "subyard", InstanceName: "yard", IncusBridge: "incusbr0",
	}
	service := PowerService{Instances: incus, Config: incus}
	intent, err := service.Ensure(context.Background(), yard)
	if err != nil || !intent.Imported || intent.Desired != PowerStopped {
		t.Fatalf("power import failed: intent=%#v err=%v", intent, err)
	}
	if err := service.Commit(context.Background(), yard, PowerRunning); err != nil {
		t.Fatal(err)
	}
	instance := incus.Instances["subyard/yard"]
	if instance.LocalConfig["user.subyard.desired_power"] != PowerRunning ||
		instance.LocalConfig["user.subyard.initialized"] != "true" ||
		instance.LocalConfig["boot.autostart"] != "false" {
		t.Fatalf("power commit did not converge metadata: %#v", instance.LocalConfig)
	}
}

func TestInitialPowerAndInitFence(t *testing.T) {
	if InitialPower(domain.Context{}) != PowerRunning ||
		InitialPower(domain.Context{YardName: "build"}) != PowerStopped {
		t.Fatal("initial power policy drifted")
	}
	incus := &testkit.Incus{Instances: map[string]ports.InstanceInfo{
		"subyard-build/yard-build": {Name: "yard-build", Project: "subyard-build", Status: "Running"},
	}}
	yard := domain.Context{
		YardName: "build", IncusProject: "subyard-build", InstanceName: "yard-build",
	}
	service := PowerService{Instances: incus, Config: incus}
	if err := service.Set(context.Background(), yard, PowerStopped, false); err != nil {
		t.Fatal(err)
	}
	config := incus.Instances["subyard-build/yard-build"].LocalConfig
	if config["user.subyard.desired_power"] != PowerStopped ||
		config["user.subyard.initialized"] != "false" {
		t.Fatalf("init fence did not preserve named-yard intent: %#v", config)
	}
}

func TestLifecycleRunnerCommitsOnlyAfterPhysicalSuccess(t *testing.T) {
	yard := domain.Context{YardName: "default", IncusProject: "subyard", InstanceName: "yard"}
	newIncus := func() *testkit.Incus {
		return &testkit.Incus{Instances: map[string]ports.InstanceInfo{"subyard/yard": {
			Name: "yard", Project: "subyard", Status: "Stopped", LocalConfig: map[string]string{
				"user.subyard.managed": "true", "user.subyard.initialized": "true",
				"user.subyard.desired_power": PowerStopped, "user.subyard.name": "default",
				"user.subyard.bridge": "incusbr0", "boot.autostart": "false",
			},
		}}}
	}
	request := domain.AdapterRequest{
		Schema: 1, OperationID: "operation-lifecycle", Adapter: "lifecycle", Action: "start",
	}

	failedIncus := newIncus()
	failed := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Err: errors.New("guard failed")}}}
	runner := LifecycleRunner{
		Power: PowerService{Instances: failedIncus, Config: failedIncus}, Physical: failed, Yard: yard,
	}
	if _, _, err := runner.Run(context.Background(), request, nil); err == nil {
		t.Fatal("failed physical start committed desired power")
	}
	if got := failedIncus.Instances["subyard/yard"].LocalConfig["user.subyard.desired_power"]; got != PowerStopped {
		t.Fatalf("failed start changed desired power to %q", got)
	}

	okIncus := newIncus()
	physical := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: request.OperationID, Status: "ok",
	}}}}
	runner = LifecycleRunner{
		Power: PowerService{Instances: okIncus, Config: okIncus}, Physical: physical, Yard: yard,
	}
	result, _, err := runner.Run(context.Background(), request, nil)
	if err != nil || result.Output["desiredPower"] != PowerRunning {
		t.Fatalf("successful lifecycle failed: result=%#v err=%v", result, err)
	}
	if got := okIncus.Instances["subyard/yard"].LocalConfig["user.subyard.desired_power"]; got != PowerRunning {
		t.Fatalf("successful start did not commit desired power: %q", got)
	}
	if len(physical.Requests) != 1 || len(physical.Requests[0].Arguments) != 1 ||
		physical.Requests[0].Arguments[0] != "start" {
		t.Fatalf("physical adapter did not receive typed start: %#v", physical.Requests)
	}
}
