package testvmsruntime

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

type fakeRunner struct {
	calls   [][]string
	handler func(string, []string, []string, io.Reader) ([]byte, []byte, error)
	missing map[string]bool
}

func (runner *fakeRunner) Run(
	_ context.Context,
	name string,
	arguments []string,
	environment []string,
	stdin io.Reader,
) ([]byte, []byte, error) {
	call := append([]string{name}, arguments...)
	runner.calls = append(runner.calls, call)
	if runner.handler != nil {
		return runner.handler(name, arguments, environment, stdin)
	}
	return nil, nil, nil
}

func (runner *fakeRunner) LookPath(name string) (string, error) {
	if runner.missing[name] {
		return "", errors.New("missing")
	}
	return "/fixture/" + name, nil
}

func fixtureConfig(t *testing.T) Config {
	t.Helper()
	root := t.TempDir()
	cfg := Config{
		Enabled: true, Project: "subyard-e2e-vms", Prefix: "e2e-vm",
		Image: "images:debian/13/cloud", CPU: 2, Memory: "1GiB", Disk: "10GiB",
		SlotCount: 2, BootTimeout: 30 * time.Second, DevUser: "dev",
		StateDir:  filepath.Join(root, "state"),
		AgentUser: "root", AgentPublicKey: fixturePublicKey(t),
		AgentHome:     filepath.Join(root, "agent"),
		StatusCommand: "sudo -n " + DefaultInstalledPath + " _test-vms-facade", Incus: "incus",
	}
	cfg.AgentAuthorizedKeys = filepath.Join(cfg.AgentHome, ".ssh", "authorized_keys")
	return cfg
}

func fixturePublicKey(t *testing.T) string {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ssh.NewPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))
}

func TestAcquireSlotRejectsInsufficientCapacityBeforeMutation(t *testing.T) {
	runtime := &Runtime{Config: fixtureConfig(t)}
	runtime.AvailableBytes = func(string) (uint64, error) {
		return HostReserveBytes + 2*InitialVMHeadroomBytes - 1, nil
	}
	var mutations int
	runtime.Runner = &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		joined := strings.Join(arguments, " ")
		if strings.HasPrefix(joined, "info ") {
			return nil, nil, errors.New("not found")
		}
		mutations++
		return nil, nil, fmt.Errorf("unexpected mutation: %s", joined)
	}}
	store := LeaseStore{Path: filepath.Join(t.TempDir(), "leases.json"), SlotCount: 2}
	grant, err := store.Acquire("client", "SHA256:key", "", "")
	if err != nil {
		t.Fatal(err)
	}
	_, err = runtime.AcquireSlot(context.Background(), store, grant, fixturePublicKey(t))
	if err == nil || !strings.Contains(err.Error(), "insufficient test-vms pool capacity") {
		t.Fatalf("capacity error = %v", err)
	}
	if mutations != 0 {
		t.Fatalf("capacity preflight performed %d mutation(s)", mutations)
	}
}

func TestStopRunningVMAcceptsConcurrentSuccessfulStop(t *testing.T) {
	cfg := fixtureConfig(t)
	runner := &fakeRunner{handler: func(
		_ string, arguments, _ []string, _ io.Reader,
	) ([]byte, []byte, error) {
		switch strings.Join(arguments, " ") {
		case "stop e2e-vm-1 --project subyard-e2e-vms --timeout 60":
			return nil, nil, errors.New("matching non-reusable operation has now succeeded")
		case "list e2e-vm-1 --project subyard-e2e-vms -f csv -c s":
			return []byte("STOPPED\n"), nil, nil
		default:
			return nil, nil, fmt.Errorf("unexpected call: %s", strings.Join(arguments, " "))
		}
	}}
	runtime := &Runtime{Config: cfg, Runner: runner}
	if err := runtime.stopRunningVM(context.Background(), "e2e-vm-1"); err != nil {
		t.Fatalf("concurrent successful stop was rejected: %v", err)
	}
}

func TestReleaseStopsRebootingGuestWhenKeyCleanupIsTemporarilyUnavailable(t *testing.T) {
	cfg := fixtureConfig(t)
	cfg.Project += "-slot-1"
	cfg.AgentPublicKey = ""
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg.keyPath()+".pub",
		[]byte(fixturePublicKey(t)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	stopped := false
	runner := &fakeRunner{handler: func(
		_ string, arguments, _ []string, _ io.Reader,
	) ([]byte, []byte, error) {
		joined := strings.Join(arguments, " ")
		switch joined {
		case "project show " + cfg.Project:
			return nil, nil, nil
		case "project get " + cfg.Project + " user.subyard.managed":
			return []byte(managedMarker + "\n"), nil, nil
		case "info e2e-vm-1 --project " + cfg.Project:
			return nil, nil, nil
		case "info e2e-vm-2 --project " + cfg.Project:
			return nil, nil, errors.New("not found")
		case "list e2e-vm-1 --project " + cfg.Project + " -f csv -c s":
			if stopped {
				return []byte("STOPPED\n"), nil, nil
			}
			return []byte("RUNNING\n"), nil, nil
		case "stop e2e-vm-1 --project " + cfg.Project + " --timeout 60":
			stopped = true
			return nil, nil, nil
		}
		if len(arguments) > 0 && arguments[0] == "exec" {
			return nil, nil, errors.New("VM agent isn't currently running")
		}
		return nil, nil, fmt.Errorf("unexpected call: %s", joined)
	}}
	var warnings bytes.Buffer
	runtime := &Runtime{Config: cfg, Runner: runner, Stderr: &warnings}
	if err := runtime.stopRetained(context.Background()); err != nil {
		t.Fatalf("rebooting guest was not stopped: %v", err)
	}
	if !strings.Contains(callsText(runner.calls),
		"incus stop e2e-vm-1 --project "+cfg.Project+" --timeout 60") {
		t.Fatal("release did not stop the rebooting guest after key cleanup failed")
	}
	if !strings.Contains(warnings.String(), "guest key cleanup deferred") {
		t.Fatalf("deferred cleanup warning = %q", warnings.String())
	}
}

func TestRecordedFirstBootFailureIsNarrow(t *testing.T) {
	cfg := fixtureConfig(t)
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg.failureLog(),
		[]byte("incus stop e2e-vm-1: synthetic failure\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if recordedFirstBootFailure(cfg.failureLog()) {
		t.Fatal("ordinary stop failure was treated as failed first boot")
	}
	if err := os.WriteFile(cfg.failureLog(),
		[]byte("timeout 600 cloud-init status --wait: status: error\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !recordedFirstBootFailure(cfg.failureLog()) {
		t.Fatal("recorded cloud-init failure was not recoverable by recreation")
	}
}

func TestReconcilePoolRetriesPhysicalShrinkAndRejectsForeignNetwork(t *testing.T) {
	for _, test := range []struct {
		name          string
		networkMarker string
		failFirst     bool
		wantSuccess   bool
	}{
		{name: "partial cleanup retry", networkMarker: managedMarker, failFirst: true, wantSuccess: true},
		{name: "foreign marker", networkMarker: "foreign", wantSuccess: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			cfg := fixtureConfig(t)
			cfg.SlotCount = 1
			storePath := cfg.leaseState()
			large := LeaseStore{Path: storePath, SlotCount: 2}
			if _, err := large.PrepareResize(); err != nil {
				t.Fatal(err)
			}
			deleteAttempts := 0
			runner := &fakeRunner{handler: func(
				_ string, arguments, _ []string, _ io.Reader,
			) ([]byte, []byte, error) {
				joined := strings.Join(arguments, " ")
				switch joined {
				case "project show subyard-e2e-vms-slot-2":
					return nil, nil, errors.New("not found")
				case "network show e2e-vm-net-2 --project default":
					return nil, nil, nil
				case "network get e2e-vm-net-2 user.subyard.managed --project default":
					return []byte(test.networkMarker + "\n"), nil, nil
				case "network delete e2e-vm-net-2 --project default":
					deleteAttempts++
					if test.failFirst && deleteAttempts == 1 {
						return nil, nil, errors.New("synthetic delete failure")
					}
					return nil, nil, nil
				default:
					return nil, nil, fmt.Errorf("unexpected call: %s", joined)
				}
			}}
			var output bytes.Buffer
			runtime := &Runtime{
				Config: cfg, Runner: runner, Stdout: &output,
				AvailableBytes: func(string) (uint64, error) {
					return 20 * 1024 * 1024 * 1024, nil
				},
			}
			small := LeaseStore{Path: storePath, SlotCount: 1}
			err := runtime.ReconcilePool(context.Background(), small)
			if test.failFirst && err != nil {
				err = runtime.ReconcilePool(context.Background(), small)
			}
			if test.wantSuccess {
				if err != nil {
					t.Fatal(err)
				}
				pool, statusErr := small.Status()
				if statusErr != nil || len(pool.Slots) != 1 {
					t.Fatalf("shrunk pool = %#v, %v", pool.Slots, statusErr)
				}
				if !strings.Contains(output.String(), "slots 2 -> 1, maximum VMs 2") {
					t.Fatalf("resize plan missing from output: %q", output.String())
				}
			} else {
				if err == nil || !strings.Contains(err.Error(), "not Subyard-managed") {
					t.Fatalf("foreign marker error = %v", err)
				}
				payload, readErr := os.ReadFile(storePath)
				if readErr != nil || !bytes.Contains(payload, []byte(`"slot_id": "slot-002"`)) {
					t.Fatalf("retiring state was truncated: %q, %v", payload, readErr)
				}
			}
		})
	}
}

func TestConfigRejectsUnsafeRuntimeValues(t *testing.T) {
	base := map[string]string{"NESTED_E2E_VMS": "1"}
	if _, err := ConfigFromValues(base); err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{
		"E2E_VM_PROJECT": "../foreign", "E2E_VM_CPU": "0",
		"E2E_VM_DISK": "9GiB", "E2E_VM_SLOT_COUNT": "0",
		"E2E_VM_BOOT_TIMEOUT": "1801", "E2E_AGENT_HOME": "/home/dev",
		"E2E_AGENT_STATUS_COMMAND": "/bin/sh",
	} {
		values := map[string]string{"NESTED_E2E_VMS": "1", name: value}
		if _, err := ConfigFromValues(values); err == nil {
			t.Errorf("%s=%q was accepted", name, value)
		}
	}
}

func TestVMIPFollowsTheOnlyDefaultRouteInterface(t *testing.T) {
	cfg := fixtureConfig(t)
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		switch {
		case reflect.DeepEqual(arguments[:2], []string{"exec", cfg.vm(1)}):
			return []byte("default via 10.42.0.1 dev enp5s0 proto dhcp\n"), nil, nil
		case arguments[0] == "list":
			return []byte(`[{"state":{"network":{
				"enp5s0":{"addresses":[{"family":"inet","scope":"global","address":"10.42.0.7"}]},
				"incusbr0":{"addresses":[{"family":"inet","scope":"global","address":"10.99.0.1"}]}
			}}}]`), nil, nil
		}
		return nil, nil, fmt.Errorf("unexpected call: %v", arguments)
	}}
	runtime := Runtime{Config: cfg, Runner: runner}
	address, err := runtime.vmIP(context.Background(), cfg.vm(1))
	if err != nil {
		t.Fatal(err)
	}
	if address != "10.42.0.7" {
		t.Fatalf("address = %q", address)
	}
}

func TestVMIPRejectsAmbiguousDefaultRoutes(t *testing.T) {
	cfg := fixtureConfig(t)
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		if arguments[0] == "exec" {
			return []byte("default via 10.42.0.1 dev enp5s0\n" +
				"default via 10.43.0.1 dev enp6s0\n"), nil, nil
		}
		return nil, nil, errors.New("should not inspect addresses")
	}}
	runtime := Runtime{Config: cfg, Runner: runner}
	if _, err := runtime.vmIP(context.Background(), cfg.vm(1)); err == nil {
		t.Fatal("ambiguous routes were accepted")
	}
}

func TestExistingProjectRejectsUnexpectedInstances(t *testing.T) {
	cfg := fixtureConfig(t)
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		switch strings.Join(arguments, " ") {
		case "project show " + cfg.Project:
			return nil, nil, nil
		case "project get " + cfg.Project + " user.subyard.managed":
			return []byte(managedMarker + "\n"), nil, nil
		case "list --project " + cfg.Project + " -f csv -c n":
			return []byte("foreign-vm\n"), nil, nil
		}
		return nil, nil, fmt.Errorf("unexpected call: %v", arguments)
	}}
	runtime := Runtime{Config: cfg, Runner: runner}
	if err := runtime.ensureProject(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "unexpected instance") {
		t.Fatalf("error = %v", err)
	}
}

func TestProjectLimitsShrinkOnlyAfterVMReconciliation(t *testing.T) {
	cfg := fixtureConfig(t)
	cfg.Memory = "768MiB"
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		switch strings.Join(arguments, " ") {
		case "project show " + cfg.Project:
			return nil, nil, nil
		case "project get " + cfg.Project + " user.subyard.managed":
			return []byte(managedMarker + "\n"), nil, nil
		case "list --project " + cfg.Project + " -f csv -c n":
			return []byte(cfg.vm(1) + "\n" + cfg.vm(2) + "\n"), nil, nil
		case "project get " + cfg.Project + " limits.cpu":
			return []byte("4\n"), nil, nil
		case "project get " + cfg.Project + " limits.memory":
			return []byte("2GiB\n"), nil, nil
		case "profile device list default --project " + cfg.Project:
			return []byte("root\neth0\n"), nil, nil
		}
		return nil, nil, nil
	}}
	runtime := Runtime{Config: cfg, Runner: runner}
	if err := runtime.ensureProject(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, call := range runner.calls {
		if strings.Join(call, " ") ==
			"incus project set "+cfg.Project+" limits.memory 1536MiB" {
			t.Fatal("aggregate memory was lowered before VM limits")
		}
	}
	runner.calls = nil
	if err := runtime.tightenProject(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := callsText(runner.calls)
	for _, expected := range []string{
		"incus project set " + cfg.Project + " limits.cpu 4",
		"incus project set " + cfg.Project + " limits.memory 1536MiB",
		"incus project unset " + cfg.Project + " restricted.virtual-machines.lowlevel",
	} {
		if !strings.Contains(got, expected) {
			t.Errorf("missing call %q in:\n%s", expected, got)
		}
	}
	if strings.Contains(got, "lowlevel allow") {
		t.Fatal("obsolete low-level allowance returned")
	}
}

func TestExistingVMDropsLegacyRawAppArmorPolicy(t *testing.T) {
	cfg := fixtureConfig(t)
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		switch strings.Join(arguments, " ") {
		case "info " + cfg.vm(1) + " --project " + cfg.Project:
			return nil, nil, nil
		case "list " + cfg.vm(1) + " --project " + cfg.Project + " -f csv -c t":
			return []byte("VIRTUAL-MACHINE\n"), nil, nil
		case "config get " + cfg.vm(1) + " user.subyard.managed --project " + cfg.Project:
			return []byte(managedMarker + "\n"), nil, nil
		case "config get " + cfg.vm(1) + " raw.apparmor --project " + cfg.Project:
			return []byte("legacy-rule\n"), nil, nil
		}
		return nil, nil, nil
	}}
	runtime := Runtime{Config: cfg, Runner: runner}
	if err := runtime.ensureVM(context.Background(), cfg.vm(1)); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(callsText(runner.calls),
		"incus config unset "+cfg.vm(1)+" raw.apparmor --project "+cfg.Project) {
		t.Fatal("legacy raw.apparmor was not removed")
	}
}

func TestGuardedCleanupUsesNormalProjectDelete(t *testing.T) {
	cfg := fixtureConfig(t)
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		switch strings.Join(arguments, " ") {
		case "project show " + cfg.Project:
			return nil, nil, nil
		case "project get " + cfg.Project + " user.subyard.managed":
			return []byte(managedMarker + "\n"), nil, nil
		case "list --project " + cfg.Project + " -f csv -c n":
			return []byte(cfg.vm(1) + "\n" + cfg.vm(2) + "\n"), nil, nil
		case "info " + cfg.vm(1) + " --project " + cfg.Project,
			"info " + cfg.vm(2) + " --project " + cfg.Project:
			return nil, nil, nil
		case "config get " + cfg.vm(1) + " user.subyard.managed --project " + cfg.Project,
			"config get " + cfg.vm(2) + " user.subyard.managed --project " + cfg.Project:
			return []byte(managedMarker + "\n"), nil, nil
		}
		return nil, nil, nil
	}}
	runtime := Runtime{Config: cfg, Runner: runner, Stdout: io.Discard}
	if err := runtime.cleanupManaged(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	got := callsText(runner.calls)
	if !strings.Contains(got, "incus project delete "+cfg.Project) {
		t.Fatal("empty project was not deleted")
	}
	if strings.Contains(got, "project delete "+cfg.Project+" --force") {
		t.Fatal("interactive forced project deletion was used")
	}
}

func TestCleanupRejectsForeignProject(t *testing.T) {
	cfg := fixtureConfig(t)
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		if arguments[0] == "project" && arguments[1] == "show" {
			return nil, nil, nil
		}
		if arguments[0] == "project" && arguments[1] == "get" {
			return []byte("foreign\n"), nil, nil
		}
		return nil, nil, nil
	}}
	runtime := Runtime{Config: cfg, Runner: runner, Stdout: io.Discard}
	if err := runtime.cleanupManaged(context.Background(), true); err == nil {
		t.Fatal("foreign project was accepted")
	}
}

func TestLeaseDataAccountPolicyIsAtomic(t *testing.T) {
	cfg := fixtureConfig(t)
	cfg.AgentAuthorizedKeys = filepath.Join(cfg.AgentHome, ".ssh", "authorized_keys")
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	runtime := Runtime{Config: cfg, Runner: &fakeRunner{}}
	if err := runtime.writeAgentAuthorizedKeys("10.42.0.11", "10.42.0.12"); err != nil {
		t.Fatal(err)
	}
	authorized, err := os.ReadFile(cfg.AgentAuthorizedKeys)
	if err != nil {
		t.Fatal(err)
	}
	expected := `restrict,port-forwarding,permitopen="10.42.0.11:22",` +
		`permitopen="10.42.0.12:22",command="` + cfg.StatusCommand + `"`
	if !strings.HasPrefix(string(authorized), expected) {
		t.Fatalf("authorized_keys = %q", authorized)
	}
	first := append([]byte(nil), authorized...)
	if err := runtime.writeAgentAuthorizedKeys("10.42.0.11", "10.42.0.12"); err != nil {
		t.Fatal(err)
	}
	second, _ := os.ReadFile(cfg.AgentAuthorizedKeys)
	if !bytes.Equal(first, second) {
		t.Fatal("agent reconciliation is not idempotent")
	}
	if err := runtime.restrictAgentAccess("operator-down"); err != nil {
		t.Fatal(err)
	}
	authorized, _ = os.ReadFile(cfg.AgentAuthorizedKeys)
	if strings.Contains(string(authorized), "port-forwarding") {
		t.Fatal("down policy retained forwarding")
	}
}

func TestLeaseReaperDoesNotDeleteRetainedAllocation(t *testing.T) {
	cfg := fixtureConfig(t)
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		switch strings.Join(arguments, " ") {
		case "project show " + cfg.Project:
			return nil, nil, nil
		case "project get " + cfg.Project + " user.subyard.managed":
			return []byte(managedMarker + "\n"), nil, nil
		case "list --project " + cfg.Project + " -f csv -c n":
			return nil, nil, nil
		}
		if arguments[0] == "info" {
			return nil, nil, errors.New("missing")
		}
		return nil, nil, nil
	}}
	runtime := Runtime{
		Config: cfg, Runner: runner, Stdout: io.Discard, Now: func() time.Time { return now },
	}
	if err := runtime.gc(context.Background()); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(callsText(runner.calls), "incus project delete "+cfg.Project) {
		t.Fatal("lease reaper deleted retained project")
	}
	if _, err := os.Stat(cfg.leaseState()); err != nil {
		t.Fatalf("lease reaper did not initialize broker state: %v", err)
	}
}

func callsText(calls [][]string) string {
	var lines []string
	for _, call := range calls {
		lines = append(lines, strings.Join(call, " "))
	}
	return strings.Join(lines, "\n")
}

func fileMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode().Perm()
}
