package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/rpc"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

type statusFactsStub struct{ value domain.StatusFacts }

func (stub statusFactsStub) ReadStatusFacts(context.Context, domain.Context, bool) (domain.StatusFacts, error) {
	return stub.value, nil
}

func TestRPCSnapshotUsesTypedServicesAndRedactedCredentialMetadata(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), domain.ProjectRecord{
		Schema: 1, ProjectID: "demo-12345678", Name: "Demo", HostPath: "/host/Demo",
		YardPath: "/srv/workspaces/demo-12345678/src", Mode: domain.ProjectSync, SSHHost: "yard",
	}); err != nil {
		t.Fatal(err)
	}
	fakeIncus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus", Version: "6.23", APIExtensions: []string{"projects"}},
		Instances: map[string]ports.InstanceInfo{"subyard/yard": {
			Name: "yard", Project: "subyard", Type: domain.InstanceContainer, Status: "Stopped",
			Config: map[string]string{}, Devices: map[string]map[string]string{},
		}},
	}
	metadata := domain.CredentialMetadata{
		SchemaVersion: 1, CredentialID: "cred-0123456789abcdef0123456789abcdef",
		RevisionID: "actor-a-000000000001-aaaaaaaa", Label: "fixture", Kind: "token", Zone: "fixture",
		Scope: "staging", Consumer: "staging-env", State: "active",
		RecipientActors: []string{"actor-a"}, Syncable: true, ActorID: "actor-a",
		ActorCounter: 1, Timestamp: time.Unix(100, 0).UTC(),
	}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
		Incus: fakeIncus, Executor: fakeIncus,
		StatusFacts: statusFactsStub{value: domain.StatusFacts{Security: "static-only", Space: "unknown"}},
		Credentials: &testkit.CredentialStore{Metadata: []domain.CredentialMetadata{metadata}},
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	handler := &rpcHandler{cli: program, loaded: loaded}
	var snapshotEvent string
	var snapshotEventRevision uint64
	result, err := handler.Handle(context.Background(), rpc.Call{Method: "system.snapshot"}, func(event string, _ any) (uint64, error) {
		snapshotEvent, snapshotEventRevision = event, 7
		return snapshotEventRevision, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	snapshot, ok := result.(rpcSnapshot)
	if !ok || snapshot.Revision == 0 || len(snapshot.Projects.Projects) != 1 ||
		len(snapshot.Credentials) != 1 || len(snapshot.CredentialStatus.Credentials) != 1 ||
		snapshot.Status.ProjectCount != 1 {
		t.Fatalf("unexpected typed snapshot: %#v", result)
	}
	if snapshotEvent != "snapshot.ready" || snapshotEventRevision != snapshot.Revision {
		t.Fatalf("snapshot event is not correlated: event=%q revision=%d", snapshotEvent, snapshotEventRevision)
	}
	payload, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"payload", "privateKey", "password"} {
		if strings.Contains(string(payload), forbidden) {
			t.Fatalf("snapshot contains secret-bearing field %q: %s", forbidden, payload)
		}
	}
	if _, err := handler.Handle(context.Background(), rpc.Call{
		Method: "project.list", Params: json.RawMessage(`{"unknown":true}`),
	}, func(string, any) (uint64, error) { return 1, nil }); err == nil {
		t.Fatal("unknown RPC params were accepted")
	}
	route, err := handler.Handle(context.Background(), rpc.Call{
		ID: "request-route", OperationID: "operation-route", Method: "operation.route",
		Params: json.RawMessage(`{"command":"status"}`),
	}, func(string, any) (uint64, error) { return 1, nil })
	if err != nil || route.(map[string]any)["target"] != domain.TargetLocalOwner ||
		route.(map[string]any)["operationId"] != "operation-route" {
		t.Fatalf("typed operation route failed: %#v %v", route, err)
	}
}

func TestRPCIncusEventsAreTypedAndBoundToCancellation(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	events := make(chan domain.OperationEvent, 1)
	errorsOut := make(chan error)
	events <- domain.OperationEvent{
		OperationID: "incus-op", Sequence: 1, Revision: 7, Kind: "lifecycle",
		Data: map[string]any{"action": "instance-started"},
	}
	close(events)
	close(errorsOut)
	fakeIncus := &testkit.Incus{EventsOut: events, ErrorsOut: errorsOut}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
		Incus: fakeIncus, Executor: fakeIncus,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	var emitted domain.OperationEvent
	result, err := (&rpcHandler{cli: program, loaded: loaded}).Handle(
		context.Background(), rpc.Call{ID: "events", Method: "incus.events"},
		func(event string, data any) (uint64, error) {
			if event != "incus.lifecycle" {
				t.Fatalf("unexpected event envelope: %s", event)
			}
			emitted = data.(domain.OperationEvent)
			return 1, nil
		},
	)
	if err != nil || emitted.OperationID != "incus-op" || result.(map[string]any)["closed"] != true {
		t.Fatalf("typed Incus event stream failed: event=%#v result=%#v err=%v", emitted, result, err)
	}
}

type projectObserverStub struct{ value domain.ProjectObservation }

func (stub projectObserverStub) Observe(
	context.Context,
	domain.Context,
	[]domain.ProjectRecord,
	bool,
) (domain.ProjectObservation, error) {
	return stub.value, nil
}

func TestNativeStatusUsesTypedPortsAndRendersParityFields(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), domain.ProjectRecord{
		Schema: 1, ProjectID: "demo-12345678", Name: "Demo", HostPath: "/host/Demo",
		YardPath: "/srv/workspaces/demo-12345678/src", Mode: domain.ProjectSync, SSHHost: "yard",
	}); err != nil {
		t.Fatal(err)
	}
	fakeIncus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus", Version: "6.23"},
		Instances: map[string]ports.InstanceInfo{"subyard/yard": {
			Name: "yard", Project: "subyard", Type: domain.InstanceContainer, Status: "Running",
			Config: map[string]string{
				"user.subyard.desired_power": "running", "user.subyard.initialized": "true",
				"boot.autostart": "false",
			},
			Devices: map[string]map[string]string{"ssh": {"type": "proxy"}, "host-demo": {"type": "disk"}},
		}},
		ExecSteps: []testkit.IncusExecStep{
			{Result: ports.InstanceExecResult{Stdout: []byte("10.0.0.2\n")}},
			{Result: ports.InstanceExecResult{Stdout: []byte("active/active/\n")}},
			{Result: ports.InstanceExecResult{Stdout: []byte("key=yes server=yes git-id=yes")}},
		},
	}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"status"}, Environment: environment,
		WorkingDir: root, Stdout: &stdout, Stderr: &stderr, Incus: fakeIncus, Executor: fakeIncus,
		StatusFacts: statusFactsStub{value: domain.StatusFacts{
			Shared:   []domain.SharedResourceStatus{{Profile: "android", Name: "emulator", State: "up", Hint: "yard emu down"}},
			Security: "static-only", Space: "1G  (in-yard rootfs, 1s ago)",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("status failed: code=%d stderr=%q", code, stderr.String())
	}
	for _, expected := range []string{
		"yard  RUNNING", "desired  running", "ip       10.0.0.2", "host-demo",
		"projects 1", "android   emulator", "security static-only", "space    1G",
	} {
		if !strings.Contains(stdout.String(), expected) {
			t.Fatalf("status omitted %q:\n%s", expected, stdout.String())
		}
	}
}

func TestNativeLiveListConvergesValidatedMetadata(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	observation := domain.ProjectObservation{
		Reached: true,
		Live: []domain.ProjectRecord{{
			Schema: 1, ProjectID: "live-12345678", Name: "Live", Mode: domain.ProjectSync,
			YardPath: "/srv/workspaces/live-12345678/src", SSHHost: "yard", Target: "openclaw",
		}},
		Presence: map[string]domain.ProjectPresence{"live-12345678": domain.ProjectPresent},
		Boxes:    map[string]domain.ProjectBoxState{"live-12345678": domain.ProjectBoxNone},
	}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"list", "--live"},
		Environment: environment, WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
		ProjectObserver: projectObserverStub{value: observation},
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("list failed: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "Live") || !strings.Contains(stdout.String(), "present") ||
		!strings.Contains(stdout.String(), "(yard)") {
		t.Fatalf("unexpected list output:\n%s", stdout.String())
	}
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	record, err := store.Get(context.Background(), "live-12345678")
	if err != nil || record.RegistrySource != "yard" || record.HostPath != "" {
		t.Fatalf("live metadata was not converged safely: record=%#v err=%v", record, err)
	}
}

func TestNativeListRepairsLegacyProjectPermissions(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), domain.ProjectRecord{
		Schema: 1, ProjectID: "legacy-12345678", Name: "Legacy", HostPath: "/host/Legacy",
		YardPath: "/srv/workspaces/legacy-12345678/src", Mode: domain.ProjectSync, SSHHost: "yard",
	}); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDirectory, "legacy-12345678.json")
	if err := os.Chmod(path, 0o664); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"list"}, Environment: environment,
		WorkingDir: root, Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("list failed: code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "Legacy") {
		t.Fatalf("legacy project missing from list:\n%s", stdout.String())
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("legacy state mode = %o, want 600", info.Mode().Perm())
	}
}

func nativeFixture(t *testing.T) (string, []string, string) {
	t.Helper()
	root := t.TempDir()
	for _, directory := range []string{"config", "scripts"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	manifest := strings.Join([]string{
		"status||@status||forward|read|public|lifecycle|status|status|status|--all --help|",
		"list||@list||local|read|public|projects|simple|list|list|--live --help|",
		"_state||@state||local|mutate|hidden|internal|none|_state|state||",
	}, "\n") + "\n"
	writeCLIFile(t, filepath.Join(root, "config", "commands.registry"), manifest, 0o600)
	for _, name := range []string{"incus.project.env", "subyard.env", "host.env", "agents.env", "ports.env"} {
		writeCLIFile(t, filepath.Join(root, "config", name), "", 0o600)
	}
	home := filepath.Join(root, "home")
	configHome := filepath.Join(root, "state")
	stateDirectory := filepath.Join(configHome, "projects")
	hostBase := filepath.Join(root, "host")
	environment := []string{
		"HOME=" + home, "SUBYARD_OPERATOR_HOME=" + home, "SUBYARD_CONFIG_HOME=" + configHome,
		"SUBYARD_HOME=" + filepath.Join(root, "data"),
		"STORAGE_PATH=" + filepath.Join(root, "data", "storage"),
		"HOST_BASE=" + hostBase, "RESTRICTED_DISK_PATHS=" + hostBase,
		"SHIFT_MODE=shift", "FORWARD_SSH_AGENT=0", "DEV_SUDO=0", "DEV_UID=1000",
		"DEV_USER=dev", "SSH_PORT=2222", "SUBYARD_NO_AUDIT=1",
	}
	return root, environment, stateDirectory
}
