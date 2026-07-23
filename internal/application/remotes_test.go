package application

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type remoteControlFixture struct {
	record        domain.RemoteRecord
	exists        bool
	owner         domain.RemoteInfo
	scanned       []domain.RemoteKey
	recorded      []domain.RemoteKey
	lookupErr     error
	probeErr      error
	scanErr       error
	recordedErr   error
	lookupCalls   int
	probeCalls    int
	scanCalls     int
	recordedCalls int
	applied       []domain.RemotePrepared
}

func (fixture *remoteControlFixture) Lookup(
	context.Context,
	string,
) (domain.RemoteRecord, bool, error) {
	fixture.lookupCalls++
	return fixture.record, fixture.exists, fixture.lookupErr
}

func (fixture *remoteControlFixture) List(context.Context) ([]domain.RemoteRecord, error) {
	if fixture.exists {
		return []domain.RemoteRecord{fixture.record}, nil
	}
	return nil, nil
}

func (fixture *remoteControlFixture) ProbeOwner(
	context.Context,
	domain.RemoteSpec,
) (domain.RemoteInfo, error) {
	fixture.probeCalls++
	return fixture.owner, fixture.probeErr
}

func (fixture *remoteControlFixture) ObserveOwner(
	context.Context,
	domain.RemoteSpec,
) (domain.RemoteInfo, time.Time, error) {
	return fixture.owner, time.Time{}, fixture.probeErr
}

func (fixture *remoteControlFixture) ScanYardKeys(
	context.Context,
	domain.RemoteSpec,
	int,
) ([]domain.RemoteKey, error) {
	fixture.scanCalls++
	return fixture.scanned, fixture.scanErr
}

func (fixture *remoteControlFixture) RecordedYardKeys(
	context.Context,
	string,
) ([]domain.RemoteKey, error) {
	fixture.recordedCalls++
	return fixture.recorded, fixture.recordedErr
}

func (fixture *remoteControlFixture) Apply(
	_ context.Context,
	prepared domain.RemotePrepared,
) (domain.RemoteResult, error) {
	fixture.applied = append(fixture.applied, prepared)
	return domain.RemoteResult{Message: string(prepared.Action)}, nil
}

func TestRemotePrepareAddOwnsProbeKeyAndRebindPolicy(t *testing.T) {
	key := domain.RemoteKey{Material: "ssh-ed25519 fixture", Fingerprint: "SHA256:fixture"}
	fixture := &remoteControlFixture{
		owner: domain.RemoteInfo{
			State: "RUNNING", SSHPort: 2222,
		},
		scanned: []domain.RemoteKey{key},
	}
	service := RemoteService{Control: fixture}
	prepared, err := service.Prepare(context.Background(),
		[]string{"add", "demo", "owner.example", "--yard", "inner"})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.Action != domain.RemoteAdd || prepared.Spec.Name != "demo" ||
		prepared.Spec.Destination != "owner.example" || prepared.Spec.OwnerYard != "inner" ||
		prepared.Owner.DevUser != "dev" || len(prepared.Scanned) != 1 ||
		fixture.lookupCalls != 1 || fixture.probeCalls != 1 || fixture.scanCalls != 1 {
		t.Fatalf("remote add plan drifted: prepared=%#v fixture=%#v", prepared, fixture)
	}
	consequences := strings.Join(RemotePolicy(prepared).Consequences, " ")
	if !strings.Contains(consequences, "SHA256:fixture") ||
		!strings.Contains(consequences, "roll back local files") {
		t.Fatalf("remote safety plan omitted key or rollback: %q", consequences)
	}

	fixture.record = domain.RemoteRecord{
		Spec:   domain.RemoteSpec{Name: "demo", Destination: "other.example"},
		Remote: true,
	}
	fixture.exists = true
	beforeProbes := fixture.probeCalls
	if _, err := service.Prepare(context.Background(),
		[]string{"add", "demo", "owner.example"}); err == nil ||
		!strings.Contains(err.Error(), "before rebinding") {
		t.Fatalf("remote rebind was accepted: %v", err)
	}
	if fixture.probeCalls != beforeProbes {
		t.Fatal("rebind rejection contacted the owner")
	}
}

func TestRemotePrepareDetectsStatePortAndTrustDrift(t *testing.T) {
	old := domain.RemoteKey{Material: "ssh-ed25519 old", Fingerprint: "SHA256:old"}
	current := domain.RemoteKey{Material: "ssh-ed25519 current", Fingerprint: "SHA256:current"}
	record := domain.RemoteRecord{
		Spec:   domain.RemoteSpec{Name: "demo", Destination: "owner.example"},
		Remote: true, Path: "/config/demo.env", SSHPort: 2222,
	}
	for name, test := range map[string]struct {
		fixture   *remoteControlFixture
		arguments []string
		expected  string
	}{
		"stopped": {
			fixture: &remoteControlFixture{
				owner:   domain.RemoteInfo{State: "STOPPED", SSHPort: 2222, DevUser: "dev"},
				scanned: []domain.RemoteKey{current},
			},
			arguments: []string{"add", "demo", "owner.example"},
			expected:  "state is STOPPED",
		},
		"invalid port": {
			fixture: &remoteControlFixture{
				owner:   domain.RemoteInfo{State: "RUNNING", SSHPort: 70000, DevUser: "dev"},
				scanned: []domain.RemoteKey{current},
			},
			arguments: []string{"add", "demo", "owner.example"},
			expected:  "invalid sshPort",
		},
		"changed key": {
			fixture: &remoteControlFixture{
				owner:   domain.RemoteInfo{State: "RUNNING", SSHPort: 2222, DevUser: "dev"},
				scanned: []domain.RemoteKey{current}, recorded: []domain.RemoteKey{old},
			},
			arguments: []string{"add", "demo", "owner.example"},
			expected:  "repair-key demo",
		},
		"repair unchanged": {
			fixture: &remoteControlFixture{
				owner:   domain.RemoteInfo{State: "RUNNING", SSHPort: 2222, DevUser: "dev"},
				scanned: []domain.RemoteKey{current}, recorded: []domain.RemoteKey{current},
			},
			arguments: []string{"repair-key", "demo"},
			expected:  "no rotation is needed",
		},
		"repair port change": {
			fixture: &remoteControlFixture{
				owner:   domain.RemoteInfo{State: "RUNNING", SSHPort: 2233, DevUser: "dev"},
				scanned: []domain.RemoteKey{current}, recorded: []domain.RemoteKey{old},
			},
			arguments: []string{"repair-key", "demo"},
			expected:  "ssh port changed",
		},
	} {
		t.Run(name, func(t *testing.T) {
			test.fixture.record, test.fixture.exists = record, true
			service := RemoteService{Control: test.fixture}
			if _, err := service.Prepare(context.Background(), test.arguments); err == nil ||
				!strings.Contains(err.Error(), test.expected) {
				t.Fatalf("got error %v, want %q", err, test.expected)
			}
		})
	}
}

func TestRemoteRemoveIsLocalAndRunnerConsumesExactPlan(t *testing.T) {
	record := domain.RemoteRecord{
		Spec:   domain.RemoteSpec{Name: "demo", Destination: "owner.example"},
		Remote: true, Path: "/config/demo.env", SSHPort: 2222,
	}
	fixture := &remoteControlFixture{record: record, exists: true}
	service := RemoteService{Control: fixture}
	prepared, err := service.Prepare(context.Background(), []string{"remove", "demo"})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.Action != domain.RemoteRemove || prepared.Existing == nil ||
		fixture.probeCalls != 0 || fixture.scanCalls != 0 {
		t.Fatalf("remove unexpectedly contacted the owner: prepared=%#v fixture=%#v",
			prepared, fixture)
	}
	runner := RemoteRunner{Control: fixture, Prepared: prepared}
	if _, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation", Adapter: "remote", Action: "add",
	}, nil); err == nil {
		t.Fatal("runner accepted an adapter action different from the prepared plan")
	}
	result, _, err := runner.Run(context.Background(), domain.AdapterRequest{
		Schema: 1, OperationID: "operation", Adapter: "remote", Action: "remove",
	}, nil)
	if err != nil || result.Status != "ok" || len(fixture.applied) != 1 ||
		fixture.applied[0].Spec != record.Spec {
		t.Fatalf("prepared remote removal was not applied exactly once: result=%#v fixture=%#v err=%v",
			result, fixture, err)
	}
}

func TestRemotePreparePropagatesControlFailures(t *testing.T) {
	sentinel := errors.New("registry unavailable")
	service := RemoteService{Control: &remoteControlFixture{lookupErr: sentinel}}
	if _, err := service.Prepare(context.Background(),
		[]string{"add", "demo", "owner.example"}); !errors.Is(err, sentinel) {
		t.Fatalf("lookup failure was hidden: %v", err)
	}
	if _, err := (RemoteService{}).Prepare(context.Background(),
		[]string{"add", "demo", "owner.example"}); err == nil {
		t.Fatal("missing remote control port was accepted")
	}
}
