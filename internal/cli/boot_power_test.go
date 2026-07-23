package cli

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

type bootNetworkGuard struct{}

func (bootNetworkGuard) Check(context.Context, []string) error { return nil }

func TestRunBootPowerAndHasManaged(t *testing.T) {
	instance := ports.InstanceInfo{
		Project: "p", Name: "yard", Status: "Stopped",
		LocalConfig: map[string]string{
			"user.subyard.managed": "true", "user.subyard.initialized": "true",
			"user.subyard.desired_power": "running", "user.subyard.bridge": "incusbr0",
			"boot.autostart": "false",
		},
	}
	fake := &testkit.Incus{Instances: map[string]ports.InstanceInfo{"p/yard": instance}}
	reconciler := application.BootPowerReconciler{
		Inventory: fake, Instances: fake, Power: fake, Network: bootNetworkGuard{},
	}
	var stdout, stderr bytes.Buffer
	if code := RunBootPower(context.Background(), []string{"has-managed"}, &stdout, &stderr, reconciler); code != 0 {
		t.Fatalf("has-managed failed with %d: %s", code, stderr.String())
	}
	if code := RunBootPower(context.Background(), nil, &stdout, &stderr, reconciler); code != 0 {
		t.Fatalf("reconcile failed with %d: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "started p/yard") {
		t.Fatalf("missing reconcile output: %q", stdout.String())
	}
}

func TestRunBootPowerHasManagedExitCodes(t *testing.T) {
	fake := &testkit.Incus{Instances: map[string]ports.InstanceInfo{}}
	reconciler := application.BootPowerReconciler{Inventory: fake}
	if code := RunBootPower(context.Background(), []string{"has-managed"}, &bytes.Buffer{}, &bytes.Buffer{}, reconciler); code != 1 {
		t.Fatalf("unmanaged inventory returned %d", code)
	}
	if code := RunBootPower(context.Background(), []string{"unknown"}, &bytes.Buffer{}, &bytes.Buffer{}, reconciler); code != 2 {
		t.Fatalf("unknown argument returned %d", code)
	}
}
