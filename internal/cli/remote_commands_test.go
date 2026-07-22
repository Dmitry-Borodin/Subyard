package cli

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/rpc"
)

type remoteControlStub struct{ applied int }

func (control *remoteControlStub) Lookup(context.Context, string) (domain.RemoteRecord, bool, error) {
	return domain.RemoteRecord{}, false, nil
}
func (control *remoteControlStub) List(context.Context) ([]domain.RemoteRecord, error) {
	return nil, nil
}
func (control *remoteControlStub) ProbeOwner(context.Context, domain.RemoteSpec) (domain.RemoteInfo, error) {
	return domain.RemoteInfo{State: "RUNNING", SSHPort: 2222, DevUser: "dev"}, nil
}
func (control *remoteControlStub) ObserveOwner(context.Context, domain.RemoteSpec) (domain.RemoteInfo, time.Time, error) {
	return domain.RemoteInfo{}, time.Time{}, nil
}
func (control *remoteControlStub) ScanYardKeys(context.Context, domain.RemoteSpec, int) ([]domain.RemoteKey, error) {
	return []domain.RemoteKey{{Material: "ssh-ed25519 fixture", Fingerprint: "SHA256:new"}}, nil
}
func (control *remoteControlStub) RecordedYardKeys(context.Context, string) ([]domain.RemoteKey, error) {
	return nil, nil
}
func (control *remoteControlStub) Apply(_ context.Context, prepared domain.RemotePrepared) (domain.RemoteResult, error) {
	control.applied++
	return domain.RemoteResult{Message: string(prepared.Action)}, nil
}

func TestRPCRemotePlanContainsPreparedFingerprintBeforeApply(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	control := &remoteControlStub{}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, RemoteControl: control,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	handler := &rpcHandler{cli: program, loaded: loaded, plans: make(map[string]rpcPlannedOperation)}
	params, _ := json.Marshal(map[string]any{
		"command": "remote", "arguments": []string{"add", "demo", "owner"},
	})
	result, err := handler.Handle(context.Background(), rpc.Call{
		Method: "operation.plan", OperationID: "operation-remote", Params: params,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	plan := result.(domain.OperationPlan)
	if control.applied != 0 || !strings.Contains(strings.Join(plan.Consequences, " "), "SHA256:new") {
		t.Fatalf("remote prepare mutated state or omitted fingerprint: %#v", plan)
	}
	execute, _ := json.Marshal(map[string]bool{"confirmed": true})
	if _, err := handler.Handle(context.Background(), rpc.Call{
		Method: "operation.execute", OperationID: plan.OperationID, Params: execute,
	}, func(string, any) (uint64, error) { return 1, nil }); err != nil {
		t.Fatal(err)
	}
	if control.applied != 1 {
		t.Fatalf("confirmed plan applied %d times", control.applied)
	}
}
