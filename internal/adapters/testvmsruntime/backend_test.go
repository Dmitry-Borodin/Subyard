package testvmsruntime

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixtureBackend(t *testing.T, enrolled bool) *Backend {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts", "e2e-lab"), 0o755); err != nil {
		t.Fatal(err)
	}
	dispatcher := filepath.Join(root, "yard-engine")
	if err := os.WriteFile(dispatcher, []byte("fixture-engine"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "scripts", "e2e-lab", "provision.sh"),
		[]byte("fixture-provision\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	client := filepath.Join(root, "client")
	if enrolled {
		if err := os.MkdirAll(client, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(client, "agent-access.pub"),
			[]byte(fixturePublicKey(t)+" fixture\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return &Backend{
		RepositoryRoot: root, Dispatcher: dispatcher, Project: "subyard-test",
		Instance: "yard-test", YardName: "test-yard", DesiredPower: "stopped",
		Environment: map[string]string{
			"NESTED_E2E_VMS": "1", "DEV_USER": "dev",
			"E2E_VM_IMAGE": "images:debian/13/cloud", "E2E_VM_CPU": "2",
			"E2E_VM_MEMORY": "4GiB", "E2E_VM_DISK": "10GiB",
			"E2E_VM_TTL_MINUTES": "1200", "E2E_VM_BOOT_TIMEOUT": "300",
			"SUBYARD_E2E_CLIENT_EXPORT_DIR": client,
		},
		Output: io.Discard,
	}
}

func TestBackendApplyInstallsCurrentEngineAndPublishesRoute(t *testing.T) {
	backend := fixtureBackend(t, true)
	var power []string
	backend.Start = func(context.Context) error {
		power = append(power, "start")
		return nil
	}
	backend.Stop = func(context.Context) error {
		power = append(power, "stop")
		return nil
	}
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, stdin io.Reader) ([]byte, []byte, error) {
		joined := strings.Join(arguments, " ")
		switch {
		case joined == "list yard-test --project subyard-test -f csv -c s":
			return []byte("STOPPED\n"), nil, nil
		case strings.HasPrefix(joined, "file push "):
			if !strings.Contains(joined, backend.Dispatcher+" yard-test"+DefaultInstalledPath) {
				return nil, nil, fmt.Errorf("wrong engine push: %s", joined)
			}
			return nil, nil, nil
		case strings.HasSuffix(joined, "-- bash -euo pipefail -s"):
			payload, err := io.ReadAll(stdin)
			if err != nil || string(payload) != "fixture-provision\n" {
				return nil, nil, fmt.Errorf("wrong provision payload: %q", payload)
			}
			if !strings.Contains(joined, "--env E2E_AGENT_PUBLIC_KEY=ssh-ed25519 ") {
				return nil, nil, fmt.Errorf("normalized enrollment was not forwarded")
			}
			return nil, nil, nil
		case joined == "exec yard-test --project subyard-test -- ip -4 -o route show default":
			return []byte("default via 10.10.0.1 dev eth0\n"), nil, nil
		case joined == "exec yard-test --project subyard-test -- ip -4 -o address show dev eth0 scope global":
			return []byte("2: eth0 inet 10.10.0.5/24 scope global eth0\n"), nil, nil
		case joined == "exec yard-test --project subyard-test -- cat /etc/ssh/ssh_host_ed25519_key.pub":
			return []byte(fixturePublicKey(t) + "\n"), nil, nil
		case strings.HasPrefix(joined,
			"config set yard-test user.subyard.test_vms_revision "):
			return nil, nil, nil
		}
		return nil, nil, fmt.Errorf("unexpected incus call: %s", joined)
	}}
	backend.Runner = runner
	if err := backend.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}
	if strings.Join(power, ",") != "start,stop" {
		t.Fatalf("temporary power = %v", power)
	}
	route, err := os.ReadFile(filepath.Join(
		backend.Environment["SUBYARD_E2E_CLIENT_EXPORT_DIR"], "route.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(route), "hostname\t10.10.0.5\n") {
		t.Fatalf("route = %q", route)
	}
	known, err := os.ReadFile(filepath.Join(
		backend.Environment["SUBYARD_E2E_CLIENT_EXPORT_DIR"], "known_hosts"))
	if err != nil || !strings.HasPrefix(string(known), "subyard-e2e-bastion ssh-ed25519 ") {
		t.Fatalf("known_hosts = %q, %v", known, err)
	}
}

func TestStoppedBackendConvergenceUsesExactBundleMarker(t *testing.T) {
	backend := fixtureBackend(t, false)
	state, err := backend.state()
	if err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{handler: func(_ string, arguments, _ []string, _ io.Reader) ([]byte, []byte, error) {
		switch strings.Join(arguments, " ") {
		case "config get yard-test user.subyard.test_vms_revision --project subyard-test":
			return []byte(state.marker + "\n"), nil, nil
		case "list yard-test --project subyard-test -f csv -c s":
			return []byte("STOPPED\n"), nil, nil
		default:
			return nil, nil, fmt.Errorf("unexpected call: %v", arguments)
		}
	}}
	backend.Runner = runner
	converged, err := backend.Converged(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !converged {
		t.Fatal("exact stopped backend was not converged")
	}
	if err := os.WriteFile(backend.Dispatcher, []byte("drift"), 0o755); err != nil {
		t.Fatal(err)
	}
	converged, err = backend.Converged(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if converged {
		t.Fatal("engine drift was accepted")
	}
}

func TestBackendRejectsSymlinkEnrollment(t *testing.T) {
	backend := fixtureBackend(t, false)
	client := backend.Environment["SUBYARD_E2E_CLIENT_EXPORT_DIR"]
	if err := os.MkdirAll(client, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(client, "target.pub")
	if err := os.WriteFile(target, []byte(fixturePublicKey(t)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(client, "agent-access.pub")); err != nil {
		t.Fatal(err)
	}
	if _, err := backend.state(); err == nil {
		t.Fatal("symlink enrollment was accepted")
	}
}

func TestDisabledBackendRemovesPublishedRoute(t *testing.T) {
	backend := fixtureBackend(t, false)
	backend.Environment["NESTED_E2E_VMS"] = "0"
	client := backend.Environment["SUBYARD_E2E_CLIENT_EXPORT_DIR"]
	if err := os.MkdirAll(client, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"route.tsv", "known_hosts"} {
		if err := os.WriteFile(filepath.Join(client, name), []byte("stale"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	backend.Runner = &fakeRunner{handler: func(_ string, arguments, _ []string, stdin io.Reader) ([]byte, []byte, error) {
		joined := strings.Join(arguments, " ")
		switch {
		case joined == "list yard-test --project subyard-test -f csv -c s":
			return []byte("RUNNING\n"), nil, nil
		case strings.HasPrefix(joined, "file push "):
			return nil, nil, nil
		case strings.HasSuffix(joined, "-- bash -euo pipefail -s"):
			_, _ = io.Copy(io.Discard, stdin)
			return nil, nil, nil
		case strings.HasPrefix(joined, "config set yard-test user.subyard.test_vms_revision "):
			return nil, nil, nil
		}
		return nil, nil, fmt.Errorf("unexpected call: %s", joined)
	}}
	if err := backend.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"route.tsv", "known_hosts"} {
		if _, err := os.Stat(filepath.Join(client, name)); !os.IsNotExist(err) {
			t.Fatalf("%s remains", name)
		}
	}
}
