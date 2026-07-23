package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
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

func TestStructuredStartSharesPlanAndAdapterAcrossCLIAndRPC(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	clock := testkit.NewManualClock(time.Unix(100, 0))
	cliRunner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-cli", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"start"},
		Environment: append(environment, "SUBYARD_OPERATION_ID=operation-cli"), WorkingDir: root,
		Stdout: &stdout, Stderr: &stderr, AdapterRunner: cliRunner, Prompt: prompt, Clock: clock,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("structured CLI start failed: code=%d stderr=%q", code, stderr.String())
	}
	if len(prompt.Seen) != 1 || len(cliRunner.Requests) != 1 ||
		cliRunner.Requests[0].Adapter != "command" || cliRunner.Requests[0].Action != "start" ||
		cliRunner.Requests[0].Context["SUBYARD_CONFIG_LOADED"] != "1" ||
		cliRunner.Requests[0].Context["SUBYARD_SUDO_PREAUTHORIZED"] != "1" {
		t.Fatalf("CLI bypassed the structured operation: prompt=%#v requests=%#v", prompt.Seen, cliRunner.Requests)
	}

	rpcRunner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-rpc", Status: "ok",
	}}}}
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
		Stderr: &stderr, AdapterRunner: rpcRunner, Clock: clock,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	handler := &rpcHandler{cli: program, loaded: loaded, plans: make(map[string]rpcPlannedOperation)}
	planResult, err := handler.Handle(context.Background(), rpc.Call{
		ID: "plan", OperationID: "operation-rpc", Method: "operation.plan",
		Params: json.RawMessage(`{"command":"start","arguments":[]}`),
	}, func(string, any) (uint64, error) { return 1, nil })
	if err != nil {
		t.Fatal(err)
	}
	plan := planResult.(domain.OperationPlan)
	if plan.Confirmed || plan.Effect != domain.CommandMutate || len(plan.Consequences) != 3 {
		t.Fatalf("RPC returned an invalid plan: %#v", plan)
	}
	if _, err := handler.Handle(context.Background(), rpc.Call{
		ID: "execute-refused", OperationID: "operation-rpc", Method: "operation.execute",
		Params: json.RawMessage(`{"confirmed":false}`),
	}, func(string, any) (uint64, error) { return 1, nil }); err == nil || err.(*rpc.Error).Code != "confirmation_required" {
		t.Fatalf("RPC accepted an unconfirmed mutation: %v", err)
	}
	events := make([]string, 0, 2)
	result, err := handler.Handle(context.Background(), rpc.Call{
		ID: "execute", OperationID: "operation-rpc", Method: "operation.execute",
		Params: json.RawMessage(`{"confirmed":true}`),
	}, func(event string, _ any) (uint64, error) {
		events = append(events, event)
		return uint64(len(events)), nil
	})
	if err != nil || result.(map[string]any)["result"].(domain.AdapterResult).Status != "ok" ||
		len(events) != 2 || events[0] != "operation.started" || events[1] != "operation.finished" ||
		len(rpcRunner.Requests) != 1 {
		t.Fatalf("RPC execution bypassed orchestration: result=%#v events=%#v requests=%#v err=%v",
			result, events, rpcRunner.Requests, err)
	}
	if _, err := handler.Handle(context.Background(), rpc.Call{
		ID: "execute-replay", OperationID: "operation-rpc", Method: "operation.execute",
		Params: json.RawMessage(`{"confirmed":true}`),
	}, func(string, any) (uint64, error) { return 1, nil }); err == nil || err.(*rpc.Error).Code != "plan_not_found" {
		t.Fatalf("RPC replayed an already executed plan: %v", err)
	}
}

func TestNetworkManagerPrivilegesAuthorizeBeforeBoundedAdapter(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(root, "sudo.log")
	writeCLIFile(t, filepath.Join(bin, "systemctl"), "#!/bin/sh\nprintf 'active\\n'\n", 0o700)
	writeCLIFile(t, filepath.Join(bin, "sudo"), `#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
if [ "$*" = "-n true" ]; then
	exit "${SUDO_NONINTERACTIVE_RC:-0}"
fi
`, 0o700)
	t.Setenv("PATH", bin)
	environment = append(environment, "PATH="+bin, "SUDO_LOG="+logPath, "SUDO_NONINTERACTIVE_RC=1")
	var diagnostics bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
		Stdin: strings.NewReader("operator input\n"), Stdout: &diagnostics, Stderr: &diagnostics,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := program.prepareNetworkManagerPrivileges(context.Background(), &diagnostics, 1000); err != nil {
		t.Fatal(err)
	}
	payload, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != "-n true\n-v\n" || !strings.Contains(diagnostics.String(), "authorizing") {
		t.Fatalf("sudo authorization was not explicit: log=%q diagnostics=%q", payload, diagnostics.String())
	}

	writeCLIFile(t, filepath.Join(bin, "systemctl"), "#!/bin/sh\nprintf 'inactive\\n'\nexit 3\n", 0o700)
	if err := os.Remove(logPath); err != nil {
		t.Fatal(err)
	}
	if err := program.prepareNetworkManagerPrivileges(context.Background(), &diagnostics, 1000); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(logPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("inactive NetworkManager invoked sudo: %v", err)
	}
}

func TestRootStepPrivilegesAuthorizeBeforeBoundedAdapter(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(root, "sudo.log")
	writeCLIFile(t, filepath.Join(bin, "sudo"), `#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
if [ "$*" = "-n true" ]; then
	exit "${SUDO_NONINTERACTIVE_RC:-0}"
fi
IFS= read -r input
printf 'input=%s\n' "$input" >> "$SUDO_LOG"
`, 0o700)
	t.Setenv("PATH", bin)
	environment = append(environment, "PATH="+bin, "SUDO_LOG="+logPath, "SUDO_NONINTERACTIVE_RC=1")
	var diagnostics bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
		Stdin: strings.NewReader("operator-terminal-input\n"), Stdout: &diagnostics, Stderr: &diagnostics,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := program.prepareSudoPrivileges(
		context.Background(), &diagnostics, 1000, "teardown",
	); err != nil {
		t.Fatal(err)
	}
	payload, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != "-n true\n-v\ninput=operator-terminal-input\n" ||
		!strings.Contains(diagnostics.String(), "authorizing root steps for teardown") {
		t.Fatalf("root-step sudo authorization did not retain operator stdio: log=%q diagnostics=%q",
			payload, diagnostics.String())
	}

	if err := os.Remove(logPath); err != nil {
		t.Fatal(err)
	}
	noninteractiveEnvironment := append([]string(nil), environment...)
	for index, value := range noninteractiveEnvironment {
		if value == "SUDO_NONINTERACTIVE_RC=1" {
			noninteractiveEnvironment[index] = "SUDO_NONINTERACTIVE_RC=0"
		}
	}
	noninteractive, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: noninteractiveEnvironment, WorkingDir: root,
		Stdin: strings.NewReader("must-not-be-read\n"), Stdout: &diagnostics, Stderr: &diagnostics,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := noninteractive.prepareSudoPrivileges(
		context.Background(), &diagnostics, 1000, "teardown",
	); err != nil {
		t.Fatal(err)
	}
	payload, err = os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != "-n true\n" {
		t.Fatalf("passwordless sudo unexpectedly fell back to terminal authorization: %q", payload)
	}

	if err := os.Remove(logPath); err != nil {
		t.Fatal(err)
	}
	if err := program.prepareSudoPrivileges(
		context.Background(), &diagnostics, 0, "teardown",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(logPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("root execution invoked sudo: %v", err)
	}
}

func TestStructuredInitMarksNetworkManagerProbePreauthorized(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-init", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"init"},
		Environment: append(environment, "SUBYARD_OPERATION_ID=operation-init"), WorkingDir: root,
		Stderr: &stderr, AdapterRunner: runner, Prompt: prompt,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("structured CLI init failed: code=%d stderr=%q", code, stderr.String())
	}
	if len(prompt.Seen) != 1 || len(runner.Requests) != 1 ||
		runner.Requests[0].Adapter != "command" || runner.Requests[0].Action != "init" ||
		runner.Requests[0].Context["SUBYARD_SUDO_PREAUTHORIZED"] != "1" {
		t.Fatalf("init did not carry the preauthorized network probe: prompt=%#v requests=%#v",
			prompt.Seen, runner.Requests)
	}
}

func TestStructuredMutationSharesTypedAdapterAcrossCLIAndRPC(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	clock := testkit.NewManualClock(time.Unix(100, 0))
	cliRunner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-stop-cli", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"stop", "--force"},
		Environment: append(environment, "SUBYARD_OPERATION_ID=operation-stop-cli"), WorkingDir: root,
		Stderr: &stderr, AdapterRunner: cliRunner, Prompt: prompt, Clock: clock,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("structured CLI stop failed: code=%d stderr=%q", code, stderr.String())
	}
	if len(cliRunner.Requests) != 1 || cliRunner.Requests[0].Adapter != "command" ||
		cliRunner.Requests[0].Action != "stop" ||
		!slices.Equal(cliRunner.Requests[0].Arguments, []string{"stop", "--force"}) {
		t.Fatalf("CLI mutation bypassed the typed command adapter: %#v", cliRunner.Requests)
	}

	rpcRunner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-stop-rpc", Status: "ok",
	}}}}
	program, err = New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
		Stderr: &stderr, AdapterRunner: rpcRunner, Clock: clock,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	handler := &rpcHandler{cli: program, loaded: loaded, plans: make(map[string]rpcPlannedOperation)}
	planResult, err := handler.Handle(context.Background(), rpc.Call{
		ID: "plan-stop", OperationID: "operation-stop-rpc", Method: "operation.plan",
		Params: json.RawMessage(`{"command":"stop","arguments":["--force"]}`),
	}, func(string, any) (uint64, error) { return 1, nil })
	if err != nil || planResult.(domain.OperationPlan).Command != "stop" {
		t.Fatalf("typed stop plan failed: %#v %v", planResult, err)
	}
	if _, err := handler.Handle(context.Background(), rpc.Call{
		ID: "execute-stop", OperationID: "operation-stop-rpc", Method: "operation.execute",
		Params: json.RawMessage(`{"confirmed":true}`),
	}, func(string, any) (uint64, error) { return 1, nil }); err != nil {
		t.Fatal(err)
	}
	if len(rpcRunner.Requests) != 1 || rpcRunner.Requests[0].Action != "stop" ||
		!slices.Equal(rpcRunner.Requests[0].Arguments, []string{"stop", "--force"}) {
		t.Fatalf("RPC mutation bypassed the typed command adapter: %#v", rpcRunner.Requests)
	}
}

func TestStructuredStartAutomationSkipsOnlyTheLocalPrompt(t *testing.T) {
	for _, test := range []struct {
		name        string
		arguments   []string
		environment []string
	}{
		{name: "command option", arguments: []string{"start", "--yes"}},
		{name: "global option", arguments: []string{"--yes", "start"}},
		{name: "automation environment", arguments: []string{"start"}, environment: []string{"ASSUME_YES=1"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			root, environment, _ := nativeFixture(t)
			environment = append(environment, test.environment...)
			runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
				Schema: 1, OperationID: "operation-automation", Status: "ok",
			}}}}
			prompt := &testkit.Prompt{}
			var stderr bytes.Buffer
			program, err := New(Options{
				RepositoryRoot: root, Program: "yard", Arguments: test.arguments,
				Environment: append(environment, "SUBYARD_OPERATION_ID=operation-automation"),
				WorkingDir:  root, Stderr: &stderr, AdapterRunner: runner, Prompt: prompt,
			})
			if err != nil {
				t.Fatal(err)
			}
			if code := program.Run(context.Background()); code != 0 {
				t.Fatalf("automated start failed: code=%d stderr=%q", code, stderr.String())
			}
			if len(prompt.Seen) != 0 || len(runner.Requests) != 1 {
				t.Fatalf("automation did not bypass exactly the local prompt: prompt=%#v requests=%#v",
					prompt.Seen, runner.Requests)
			}
		})
	}
}

func TestProductionStartAdapterUsesGuardedShellHandler(t *testing.T) {
	fixtureRoot, environment, _ := nativeFixture(t)
	program, err := New(Options{
		RepositoryRoot: fixtureRoot, Program: "yard", Environment: environment, WorkingDir: fixtureRoot,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	root := repositoryRoot(t)
	temporary := t.TempDir()
	bin := filepath.Join(temporary, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(temporary, "state")
	logPath := filepath.Join(temporary, "incus.log")
	writeCLIFile(t, statePath, "STOPPED\n", 0o600)
	writeCLIFile(t, logPath, "", 0o600)
	writeCLIFile(t, filepath.Join(bin, "incus"), fmt.Sprintf(`#!/bin/sh
set -eu
state=%q
log=%q
case "${1:-}" in
  info) exit 0 ;;
  list) cat "$state" ;;
  start) printf 'RUNNING\n' > "$state"; printf 'start\n' >> "$log" ;;
  config)
    case "${2:-}" in
      get)
        case "${4:-}" in
          user.subyard.managed|user.subyard.initialized) printf 'true\n' ;;
          user.subyard.desired_power) printf 'stopped\n' ;;
          boot.autostart) printf 'false\n' ;;
          user.subyard.bridge) printf 'incusbr0\n' ;;
        esac
        ;;
      set) printf 'set:%%s=%%s\n' "$4" "$5" >> "$log" ;;
    esac
    ;;
  *) exit 90 ;;
esac
`, statePath, logPath), 0o700)
	writeCLIFile(t, filepath.Join(bin, "systemctl"), `#!/bin/sh
case "$*" in
  'is-active NetworkManager') printf 'inactive\n'; exit 3 ;;
esac
exit 90
`, 0o700)
	writeCLIFile(t, filepath.Join(bin, "ip"), "#!/bin/sh\nexit 0\n", 0o700)
	contextValues := structuredAdapterContext(loaded.Context)
	if contextValues["YARD_VERSION"] != Version {
		t.Fatalf("structured adapter context lost engine version: %#v", contextValues)
	}
	remoteContext := loaded.Context
	remoteContext.YardType = domain.YardRemote
	remoteContext.RemoteDest = "dev@owner.example"
	remoteContext.RemoteYard = "named"
	remoteValues := structuredAdapterContext(remoteContext)
	if remoteValues["REMOTE_DEST"] != remoteContext.RemoteDest || remoteValues["REMOTE_YARD"] != remoteContext.RemoteYard {
		t.Fatalf("structured adapter context lost remote route: %#v", remoteValues)
	}
	commandValues := structuredCommandContext(config.Loaded{Context: loaded.Context, Environment: map[string]string{
		"CCUSAGE_PROVISION":       "/config/agents/ccusage/provision.sh",
		"E2E_VM_TTL_MINUTES":      "1200",
		"AGENT_codex_CONFIG":      "/config/agents/codex/config.toml",
		"HOST_OPENCODE_AGENTS_MD": "/home/operator/.config/opencode/AGENTS.md",
		"AGENT_codex_TOKEN":       "must-not-cross",
		"AWS_SECRET_ACCESS_KEY":   "must-not-cross",
		"UNRELATED_AMBIENT_VALUE": "must-not-cross",
	}})
	for name, expected := range map[string]string{
		"CCUSAGE_PROVISION":       "/config/agents/ccusage/provision.sh",
		"E2E_VM_TTL_MINUTES":      "1200",
		"AGENT_codex_CONFIG":      "/config/agents/codex/config.toml",
		"HOST_OPENCODE_AGENTS_MD": "/home/operator/.config/opencode/AGENTS.md",
	} {
		if commandValues[name] != expected {
			t.Fatalf("structured command context lost %s: %#v", name, commandValues)
		}
	}
	for _, name := range []string{"AGENT_codex_TOKEN", "AWS_SECRET_ACCESS_KEY", "UNRELATED_AMBIENT_VALUE"} {
		if _, ok := commandValues[name]; ok {
			t.Fatalf("structured command context leaked %s", name)
		}
	}
	contextKeys := make(map[string]struct{}, len(contextValues))
	for key := range contextValues {
		contextKeys[key] = struct{}{}
	}
	runner := shelladapter.Runner{
		RepositoryRoot: root,
		Actions: map[string]map[string]shelladapter.Action{"command": {
			"start": {
				Path: filepath.Join(root, "scripts", "yard-ctl.sh"), Direct: true,
			},
		}},
		ContextKeys: contextKeys, Path: bin + ":/usr/sbin:/usr/bin:/sbin:/bin", Timeout: time.Second,
	}
	request := domain.AdapterRequest{
		Schema: 1, OperationID: "operation-production", Adapter: "command", Action: "start",
		Arguments: []string{"start", "--yes"}, Context: contextValues,
	}
	result, diagnostics, err := runner.Run(context.Background(), request, nil)
	if err != nil || result.Status != "ok" || !strings.Contains(diagnostics, "started (desired=running") {
		t.Fatalf("production adapter failed: result=%#v diagnostics=%q err=%v", result, diagnostics, err)
	}
	payload, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), "start\n") ||
		!strings.Contains(string(payload), "set:user.subyard.desired_power=running") {
		t.Fatalf("guarded handler did not commit start: %s", payload)
	}
}

func TestStructuredStartRunsOverFramedRPCSession(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "operation-wire", Status: "ok",
	}}}}
	client, server := net.Pipe()
	defer client.Close()
	if err := client.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"rpc", "--stdio"},
		Environment: environment, WorkingDir: root, Stdin: server, Stdout: server, Stderr: &stderr,
		AdapterRunner: runner, Clock: testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan int, 1)
	go func() {
		done <- program.Run(context.Background())
		_ = server.Close()
	}()
	codec := rpc.NewCodec(client, client)
	if err := codec.Write(rpc.Request{Version: 1, Type: "request", ID: "negotiate", Method: "rpc.negotiate"}); err != nil {
		t.Fatal(err)
	}
	negotiated, err := codec.ReadResponse()
	if err != nil || negotiated.Error != nil {
		t.Fatalf("RPC negotiation failed: response=%#v err=%v", negotiated, err)
	}
	if err := codec.Write(rpc.Request{
		Version: 1, Type: "request", ID: "plan", OperationID: "operation-wire", Method: "operation.plan",
		Params: json.RawMessage(`{"command":"start","arguments":[]}`),
	}); err != nil {
		t.Fatal(err)
	}
	planned, err := codec.ReadResponse()
	if err != nil || planned.Error != nil || planned.OperationID != "operation-wire" {
		t.Fatalf("RPC plan failed: response=%#v err=%v", planned, err)
	}
	if err := codec.Write(rpc.Request{
		Version: 1, Type: "request", ID: "execute", OperationID: "operation-wire", Method: "operation.execute",
		Params: json.RawMessage(`{"confirmed":true}`),
	}); err != nil {
		t.Fatal(err)
	}
	seenEvents := make([]string, 0, 2)
	var executed rpc.Response
	for executed.ID == "" {
		response, err := codec.ReadResponse()
		if err != nil {
			t.Fatal(err)
		}
		if response.Type == "event" {
			seenEvents = append(seenEvents, response.Event)
		} else {
			executed = response
		}
	}
	if executed.Error != nil || executed.OperationID != "operation-wire" ||
		len(seenEvents) != 2 || seenEvents[0] != "operation.started" || seenEvents[1] != "operation.finished" ||
		len(runner.Requests) != 1 {
		t.Fatalf("framed execution failed: response=%#v events=%#v requests=%#v stderr=%q",
			executed, seenEvents, runner.Requests, stderr.String())
	}
	_ = client.Close()
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("RPC server exited %d: %s", code, stderr.String())
		}
	case <-time.After(time.Second):
		t.Fatal("RPC server did not stop after EOF")
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

func TestNativeOwnerInfoUsesTypedContextAndLiveInventory(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	fakeIncus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus", Version: "6.23"},
		Instances:  map[string]ports.InstanceInfo{"subyard/yard": {Status: "Running"}},
	}
	observation := domain.ProjectObservation{Reached: true, Live: []domain.ProjectRecord{
		{ProjectID: "demo-12345678"}, {ProjectID: "demo-12345678"},
	}}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"_info"}, Environment: environment,
		WorkingDir: root, Stdout: &stdout, Stderr: &stderr, Incus: fakeIncus,
		ProjectObserver: projectObserverStub{value: observation},
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("_info failed: code=%d stderr=%q", code, stderr.String())
	}
	var info ownerInfo
	if err := json.Unmarshal(stdout.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Name != "default" || info.State != "RUNNING" || info.SSHPort != 2222 ||
		info.Projects == nil || *info.Projects != 1 {
		t.Fatalf("unexpected owner info: %#v", info)
	}
}

func TestNativeAuthorizeValidatesAndWritesOneControllerKey(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	fakeIncus := &testkit.Incus{
		Instances: map[string]ports.InstanceInfo{"subyard/yard": {Status: "Running"}},
		ExecSteps: []testkit.IncusExecStep{{Result: ports.InstanceExecResult{
			Stdout: []byte("added"), ExitCode: 0,
		}}},
	}
	key := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA controller"
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"_authorize"}, Environment: environment,
		WorkingDir: root, Stdin: strings.NewReader(key + "\n"), Stderr: &stderr,
		Incus: fakeIncus, Executor: fakeIncus,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("_authorize failed: code=%d stderr=%q", code, stderr.String())
	}
	if len(fakeIncus.ExecCalls) != 1 || fakeIncus.ExecCalls[0].Request.Environment["PUBKEY"] != key ||
		fakeIncus.ExecCalls[0].Request.Environment["DEV_USER"] != "dev" {
		t.Fatalf("unexpected authorize request: %#v", fakeIncus.ExecCalls)
	}
}

func TestNativeLogArgumentsAreBounded(t *testing.T) {
	arguments, help, err := parseLogArguments([]string{"-n", "25", "docker"})
	if err != nil || help || !slices.Equal(arguments,
		[]string{"journalctl", "-n", "25", "-u", "docker", "--no-pager"}) {
		t.Fatalf("unexpected log arguments: %#v help=%v err=%v", arguments, help, err)
	}
	if _, _, err := parseLogArguments([]string{"-n", "0"}); err == nil {
		t.Fatal("logs accepted an invalid line count")
	}
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

func TestProjectAdaptersReceiveGoResolvedSnapshotAndGoCommitsState(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	projectPath := filepath.Join(root, "Demo")
	if err := os.MkdirAll(projectPath, 0o700); err != nil {
		t.Fatal(err)
	}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	execution, err := program.prepareProjectImport(
		context.Background(), loaded, "sync", []string{projectPath, "--target", "yard"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if execution.Commit != projectCommitPut || execution.Environment["SUBYARD_PROJECT_SNAPSHOT"] != "1" ||
		execution.Environment["SUBYARD_PROJECT_HOST_PATH"] != projectPath ||
		execution.Environment["SUBYARD_PROJECT_YARD_PATH"] != state.YardPath(execution.Record.ProjectID) {
		t.Fatalf("unexpected project adapter snapshot: %#v", execution)
	}
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Get(context.Background(), execution.Record.ProjectID); !errors.Is(err, state.ErrNotFound) {
		t.Fatalf("project state was published before the adapter succeeded: %v", err)
	}
	if err := program.commitProjectExecution(context.Background(), execution); err != nil {
		t.Fatal(err)
	}
	record, err := store.Get(context.Background(), execution.Record.ProjectID)
	if err != nil || record.HostPath != projectPath || record.Target != "yard" {
		t.Fatalf("Go did not publish the adapter result atomically: %#v %v", record, err)
	}
}

func TestBindAcceptsExplicitPathAndPlansExposure(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	projectPath := filepath.Join(root, "home", ".ssh")
	if err := os.MkdirAll(projectPath, 0o700); err != nil {
		t.Fatal(err)
	}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	execution, err := program.prepareProjectImport(
		context.Background(), loaded, "bind", []string{projectPath, "--target", "yard"},
	)
	if err != nil {
		t.Fatal(err)
	}
	consequences := strings.Join(application.ProjectConsequences(
		"bind", execution.Record, false,
	), " ")
	if execution.Record.HostPath != projectPath || !strings.Contains(consequences, "expose "+projectPath) {
		t.Fatalf("explicit bind path or safety plan missing: %#v %q", execution.Record, consequences)
	}
}

func TestProjectSelectionRoutesAcrossYardsBeforeAdapter(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	configHome := ""
	for _, pair := range environment {
		if strings.HasPrefix(pair, "SUBYARD_CONFIG_HOME=") {
			configHome = strings.TrimPrefix(pair, "SUBYARD_CONFIG_HOME=")
		}
	}
	if configHome == "" {
		t.Fatal("fixture has no config home")
	}
	yardRegistry := filepath.Join(configHome, "yards")
	if err := os.MkdirAll(yardRegistry, 0o700); err != nil {
		t.Fatal(err)
	}
	writeCLIFile(t, filepath.Join(yardRegistry, "other.env"), "SSH_PORT=2233\n", 0o600)
	otherState := filepath.Join(yardRegistry, "other", "projects")
	store, err := state.NewFileStore(otherState)
	if err != nil {
		t.Fatal(err)
	}
	record := domain.ProjectRecord{
		Schema: 1, ProjectID: "demo-12345678", Name: "Demo", HostPath: "/host/Demo",
		YardPath: state.YardPath("demo-12345678"), Mode: domain.ProjectSync,
		SSHHost: "yard-other", Target: "yard",
	}
	if err := store.Put(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Environment: environment, WorkingDir: root,
	})
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := program.loadContext("default")
	if err != nil {
		t.Fatal(err)
	}
	execution, err := program.prepareExistingProject(
		context.Background(), loaded, "code", []string{"Demo"}, false,
	)
	if err != nil {
		t.Fatal(err)
	}
	if execution.Loaded.Context.YardName != "other" ||
		execution.Environment["SUBYARD_PROJECT_ID"] != record.ProjectID ||
		execution.Environment["SUBYARD_PROJECT_SSH_HOST"] != "yard-other" {
		t.Fatalf("project was not routed before adapter launch: %#v", execution)
	}
}

func TestParseShellArguments(t *testing.T) {
	root, selector, command, help, err := parseShellArguments(
		[]string{"--root", "Demo", "--", "sh", "-lc", "pwd"},
	)
	if err != nil || !root || help || selector != "Demo" ||
		!slices.Equal(command, []string{"sh", "-lc", "pwd"}) {
		t.Fatalf("unexpected shell parse: root=%v selector=%q command=%q help=%v err=%v",
			root, selector, command, help, err)
	}
	if _, _, _, _, err := parseShellArguments([]string{"one", "two"}); err == nil {
		t.Fatal("multiple project selectors were accepted")
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
		"init|setup|init.sh||forward|mutate|public|lifecycle|simple|init|install or reconcile the yard|--configs --reset --yes --help|",
		"start||yard-ctl.sh|start|forward|mutate|public|lifecycle|simple|start|start|--yes --help|",
		"stop||yard-ctl.sh|stop|forward|mutate|public|lifecycle|simple|stop|stop|--force --yes --help|",
		"status||@status||forward|read|public|lifecycle|status|status|status|--all --help|",
		"logs||@logs||forward|read|public|lifecycle|simple|logs|logs|-f -n --yes --help|",
		"usage||@usage||forward|read|public|lifecycle|simple|usage|usage|--help|",
		"shell||@shell||forward|mutate|public|lifecycle|project-shell|shell|shell|--root --yes --help|",
		"clone||@project||local|mutate|public|projects|clone|clone <url>|clone|--target --yes --help|",
		"remove||@project||local|mutate|public|projects|remove|remove [project]|remove|--soft --yes --help|",
		"yards||@yards||local|read|public|lifecycle|simple|yards|yards|--help|",
		"remote||@remote||local|mutate|public|remote|remote|remote|remote|--yard --yes --help|add repair-key remove list",
		"list||@list||local|read|public|projects|simple|list|list|--live --help|",
		"_info||@info||local|read|hidden|internal|none|_info|info||",
		"_authorize||@authorize||forward|mutate|hidden|internal|none|_authorize|authorize||",
		"rpc||@rpc||local|mutate|hidden|internal|none|rpc --stdio|rpc|--stdio|",
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
