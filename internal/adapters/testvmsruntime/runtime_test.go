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
		TTL: 15 * time.Minute, BootTimeout: 30 * time.Second, DevUser: "dev",
		StateDir: filepath.Join(root, "state"), PublicDir: filepath.Join(root, "public"),
		AgentUser: "root", AgentPublicKey: fixturePublicKey(t),
		AgentHome:     filepath.Join(root, "agent"),
		StatusCommand: DefaultInstalledPath + " _test-vms-status", Incus: "incus",
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

func TestConfigRejectsUnsafeRuntimeValues(t *testing.T) {
	base := map[string]string{"NESTED_E2E_VMS": "1"}
	if _, err := ConfigFromValues(base); err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{
		"E2E_VM_PROJECT": "../foreign", "E2E_VM_CPU": "0",
		"E2E_VM_DISK": "9GiB", "E2E_VM_TTL_MINUTES": "14",
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

func TestAgentPolicyManifestAndStatusAreAtomic(t *testing.T) {
	cfg := fixtureConfig(t)
	cfg.AgentAuthorizedKeys = filepath.Join(cfg.AgentHome, ".ssh", "authorized_keys")
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	created := time.Unix(1_800_000_000, 0)
	if err := writePrivateFile(cfg.createdAt(), []byte(fmt.Sprintf("%d\n", created.Unix()))); err != nil {
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
	host1 := fixturePublicKey(t)
	host2 := fixturePublicKey(t)
	if err := runtime.writeManifest("ready", "ready",
		"10.42.0.11", host1, "10.42.0.12", host2); err != nil {
		t.Fatal(err)
	}
	var status bytes.Buffer
	if err := WritePublicStatus(&status, cfg.manifest()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status.String(), "\nvm\t1\te2e-vm-1\t10.42.0.11\tssh-ed25519 ") {
		t.Fatalf("status = %q", status.String())
	}
	if mode := fileMode(t, cfg.manifest()); mode != 0o644 {
		t.Fatalf("manifest mode = %o", mode)
	}
	if err := runtime.restrictAgentAccess("operator-down"); err != nil {
		t.Fatal(err)
	}
	authorized, _ = os.ReadFile(cfg.AgentAuthorizedKeys)
	if strings.Contains(string(authorized), "port-forwarding") {
		t.Fatal("down policy retained forwarding")
	}
	manifest, _ := os.ReadFile(cfg.manifest())
	if !strings.Contains(string(manifest), "state\tdown\n") {
		t.Fatal("down state was not published")
	}
}

func TestExpiredAllocationIsCleaned(t *testing.T) {
	cfg := fixtureConfig(t)
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	if err := writePrivateFile(cfg.createdAt(),
		[]byte(fmt.Sprintf("%d\n", now.Add(-cfg.TTL-time.Second).Unix()))); err != nil {
		t.Fatal(err)
	}
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
	if !strings.Contains(callsText(runner.calls), "incus project delete "+cfg.Project) {
		t.Fatal("expired project was not cleaned")
	}
}

func TestPublicStatusFallsBackWhenManifestIsMissing(t *testing.T) {
	var output bytes.Buffer
	if err := WritePublicStatus(&output, filepath.Join(t.TempDir(), "missing")); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "reason\tmanifest-missing") {
		t.Fatalf("output = %q", output.String())
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
