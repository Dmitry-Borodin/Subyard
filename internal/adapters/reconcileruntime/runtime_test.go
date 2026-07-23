package reconcileruntime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestPowerImportIsNativeAcrossRegisteredLocalYards(t *testing.T) {
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"},
		Instances: map[string]ports.InstanceInfo{
			"subyard/yard": {Name: "yard", Project: "subyard", Status: "Running"},
			"subyard-demo/yard-demo": {
				Name: "yard-demo", Project: "subyard-demo", Status: "Stopped",
				LocalConfig: map[string]string{
					"user.subyard.managed": "true", "user.subyard.initialized": "false",
					"user.subyard.desired_power": "stopped", "user.subyard.name": "old",
					"user.subyard.bridge": "old", "boot.autostart": "true",
				},
			},
		},
	}
	runtime := Runtime{
		Incus: incus, ConfigWriter: incus,
		PowerYards: []domain.Context{
			{YardName: "default", IncusProject: "subyard", InstanceName: "yard", IncusBridge: "incusbr0"},
			{YardName: "demo", IncusProject: "subyard-demo", InstanceName: "yard-demo", IncusBridge: "incusbr1"},
			{YardName: "remote", YardType: domain.YardRemote},
		},
	}
	assertStage(t, runtime, "power-import", false, "pending native import")
	if err := runtime.ApplyStage(context.Background(), "power-import"); err != nil {
		t.Fatal(err)
	}
	if len(incus.ConfigUpdates) != 2 ||
		incus.Instances["subyard/yard"].LocalConfig["user.subyard.desired_power"] != "running" ||
		incus.Instances["subyard-demo/yard-demo"].LocalConfig["user.subyard.name"] != "demo" {
		t.Fatalf("registered power state was not imported atomically: %#v", incus.ConfigUpdates)
	}
	assertStage(t, runtime, "power-import", true, "completed native import")
	broken := incus.Instances["subyard-demo/yard-demo"]
	broken.LocalConfig["user.subyard.managed"] = "invalid"
	incus.Instances["subyard-demo/yard-demo"] = broken
	if _, err := runtime.CheckStage(context.Background(), "power-import"); err == nil {
		t.Fatal("invalid managed metadata was treated as convergence")
	}
}

func TestGitIdentityProbeUsesTypedInstanceState(t *testing.T) {
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"},
		Reconcile: ports.ReconcileState{InstanceFound: true, Instance: ports.InstanceInfo{
			Status: "Running",
		}},
		ExecSteps: []testkit.IncusExecStep{{Result: ports.InstanceExecResult{}}},
	}
	runtime := Runtime{
		Incus: incus, Executor: incus,
		Yard:        domain.Context{IncusProject: "subyard", InstanceName: "yard"},
		Environment: []string{"DEV_USER=developer"},
	}
	assertStage(t, runtime, "git-identity", true, "running yard with git config")
	if calls := incus.ExecCalls; len(calls) != 1 ||
		calls[0].Request.Command[2] != "/home/developer/.gitconfig" {
		t.Fatalf("unexpected git identity probe: %#v", calls)
	}
	incus.ExecSteps = []testkit.IncusExecStep{{
		Result: ports.InstanceExecResult{ExitCode: 1}, Err: errors.New("missing"),
	}}
	assertStage(t, runtime, "git-identity", false, "running yard without git config")

	incus.Reconcile.Instance = ports.InstanceInfo{Status: "Stopped", LocalConfig: map[string]string{
		"user.subyard.managed": "true", "user.subyard.initialized": "true",
		"user.subyard.desired_power": "stopped",
	}}
	assertStage(t, runtime, "git-identity", true, "intentionally stopped yard")
	incus.Reconcile.Instance.LocalConfig["user.subyard.desired_power"] = "running"
	assertStage(t, runtime, "git-identity", false, "unexpected stopped yard")
}

func TestPowerProbeSeparatesInstallFromFinalMetadata(t *testing.T) {
	root := t.TempDir()
	bin := filepath.Join(root, "bin")
	installed := filepath.Join(root, "installed")
	for _, directory := range []string{bin, installed} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, contents string, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(path, []byte(contents), mode); err != nil {
			t.Fatal(err)
		}
	}
	reconcilerSource := filepath.Join(root, "yard-engine")
	reconciler := filepath.Join(installed, "yard-boot-reconcile")
	unit := filepath.Join(installed, "subyard-power-reconcile.service")
	write(reconcilerSource, "reconciler\n", 0o700)
	write(reconciler, "reconciler\n", 0o700)
	write(unit, "[Service]\nExecStart="+reconciler+" _power-reconcile\n", 0o600)
	write(filepath.Join(bin, "systemctl"), "#!/bin/sh\nexit 0\n", 0o700)

	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"},
		Reconcile: ports.ReconcileState{InstanceFound: true, Instance: ports.InstanceInfo{
			LocalConfig: map[string]string{
				"user.subyard.managed": "true", "user.subyard.initialized": "true",
				"user.subyard.desired_power": "running", "user.subyard.bridge": "incusbr0",
				"boot.autostart": "false",
			},
		}},
	}
	runtime := Runtime{RepositoryRoot: root, Incus: incus, Environment: []string{
		"PATH=" + bin, "SUBYARD_POWER_RECONCILER_PATH=" + reconciler,
		"SUBYARD_POWER_ENGINE_SOURCE=" + reconcilerSource, "SUBYARD_POWER_UNIT_PATH=" + unit,
	}}
	assertStage(t, runtime, "power", true, "installed and finalized power state")
	incus.Reconcile.Instance.LocalConfig["user.subyard.initialized"] = "false"
	assertStage(t, runtime, "power", false, "unfinished desired-power transaction")
	verified, err := runtime.VerifyStage(context.Background(), "power")
	if err != nil || !verified {
		t.Fatalf("fresh install did not verify before finalization: %v, %v", verified, err)
	}
	write(reconciler, "drift\n", 0o700)
	verified, err = runtime.VerifyStage(context.Background(), "power")
	if err != nil || verified {
		t.Fatalf("drifted reconciler passed verification: %v, %v", verified, err)
	}
}

func TestFinalizeMapsDesiredPowerToLifecycleAction(t *testing.T) {
	for _, test := range []struct {
		desired string
		action  string
	}{
		{desired: "running", action: "start --reconcile"},
		{desired: "stopped", action: "stop --reconcile"},
	} {
		t.Run(test.desired, func(t *testing.T) {
			root := t.TempDir()
			if err := os.Mkdir(filepath.Join(root, "scripts"), 0o700); err != nil {
				t.Fatal(err)
			}
			arguments := filepath.Join(root, "arguments")
			if err := os.WriteFile(filepath.Join(root, "scripts", "lifecycle-guard.sh"), []byte(
				"#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$ARGUMENTS\"\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			incus := &testkit.Incus{Instances: map[string]ports.InstanceInfo{
				"subyard/yard": {
					Name: "yard", Project: "subyard", Status: test.desired,
					LocalConfig: map[string]string{
						"user.subyard.managed": "true", "user.subyard.initialized": "false",
						"user.subyard.desired_power": test.desired, "user.subyard.name": "default",
						"user.subyard.bridge": "incusbr0", "boot.autostart": "false",
					},
				},
			}}
			runtime := Runtime{
				RepositoryRoot: root, Environment: append(os.Environ(), "ARGUMENTS="+arguments),
				Incus: incus, ConfigWriter: incus,
				Yard: domain.Context{IncusProject: "subyard", InstanceName: "yard"},
			}
			if err := runtime.ApplyStage(context.Background(), "finalize"); err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(arguments)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != test.action+"\n" {
				t.Fatalf("lifecycle arguments = %q, want %q", got, test.action)
			}
			if incus.Instances["subyard/yard"].LocalConfig["user.subyard.initialized"] != "true" {
				t.Fatal("final power state was not committed")
			}
		})
	}
}

func TestSSHProbeOwnsProxyAndClientConfig(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	subyardHome := filepath.Join(root, "subyard")
	bin := filepath.Join(root, "bin")
	for _, directory := range []string{filepath.Join(home, ".ssh"), filepath.Join(subyardHome, "ssh"), bin} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, ".ssh", "subyard.config"), []byte(
		"Host yard\n    Port 2222\n    StrictHostKeyChecking yes\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".ssh", "config"), []byte("Include subyard.config\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(subyardHome, "ssh", "known_hosts"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "ssh-keygen"), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"},
		Reconcile: ports.ReconcileState{InstanceFound: true, Instance: ports.InstanceInfo{
			Status: "Stopped", LocalConfig: map[string]string{
				"user.subyard.managed": "true", "user.subyard.initialized": "true",
				"user.subyard.desired_power": "stopped",
			}, LocalDevices: map[string]map[string]string{"ssh": {
				"type": "proxy", "listen": "tcp:127.0.0.1:2222", "connect": "tcp:127.0.0.1:22",
			}},
		}},
	}
	runtime := Runtime{
		Incus: incus, Executor: incus,
		Yard: domain.Context{
			YardName: "default", IncusProject: "subyard", InstanceName: "yard",
			SSHHost: "yard", SSHPort: 2222,
			Paths: domain.RuntimePaths{OperatorHome: home, DataHome: subyardHome},
		},
		Environment: []string{"PATH=" + bin},
	}
	assertStage(t, runtime, "ssh", true, "matching SSH state")
	incus.Reconcile.Instance.LocalDevices["ssh"]["listen"] = "tcp:127.0.0.1:2299"
	assertStage(t, runtime, "ssh", false, "drifted SSH proxy")
	incus.Reconcile.Instance.LocalDevices["ssh"]["listen"] = "tcp:127.0.0.1:2222"
	if err := os.Rename(
		filepath.Join(home, ".ssh", "subyard.config"),
		filepath.Join(home, ".ssh", "subyard-demo.config"),
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(home, ".ssh", "config"), []byte("Include subyard-demo.config\n"), 0o600,
	); err != nil {
		t.Fatal(err)
	}
	runtime.Yard.YardName = "demo"
	assertStage(t, runtime, "ssh", true, "matching named-yard SSH state")
}

func TestProvisionProbeChecksGuestAndStoppedMarker(t *testing.T) {
	steps := func(stat string) []testkit.IncusExecStep {
		return []testkit.IncusExecStep{
			{}, {}, {Result: ports.InstanceExecResult{Stdout: []byte("dev:x:1000:1000::/home/dev:/bin/bash\n")}},
			{Result: ports.InstanceExecResult{Stdout: []byte(stat + "\n")}},
			{Result: ports.InstanceExecResult{Stdout: []byte(" 7f 45 4c 46\n")}},
			{Result: ports.InstanceExecResult{Stdout: []byte("ccusage 1.2.3\n")}},
			{}, {}, {Result: ports.InstanceExecResult{ExitCode: 1}, Err: errors.New("not a link")},
		}
	}
	instructions := filepath.Join(t.TempDir(), "AGENTS.md")
	if err := os.WriteFile(instructions, []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"}, ExecSteps: steps("regular file|755|0:0"),
		Reconcile: ports.ReconcileState{InstanceFound: true, Instance: ports.InstanceInfo{
			Status: "Running", LocalConfig: map[string]string{"user.subyard.ccusage_version": "1.2.3"},
		}},
	}
	runtime := Runtime{
		Incus: incus, Executor: incus,
		Yard:        domain.Context{IncusProject: "subyard", InstanceName: "yard", DevUser: "dev"},
		Environment: []string{"CCUSAGE_VERSION=1.2.3", "HOST_OPENCODE_AGENTS_MD=" + instructions},
	}
	assertStage(t, runtime, "provision", true, "matching running provision state")
	if command := incus.ExecCalls[6].Request.Command; len(command) != 3 ||
		command[2] != "/home/dev/.config/opencode/AGENTS.md" {
		t.Fatalf("OpenCode instructions were not checked natively: %#v", command)
	}
	incus.ExecSteps = steps("regular file|777|0:0")
	assertStage(t, runtime, "provision", false, "wrong ccusage mode")

	incus.Reconcile.Instance = ports.InstanceInfo{Status: "Stopped", LocalConfig: map[string]string{
		"user.subyard.managed": "true", "user.subyard.initialized": "true",
		"user.subyard.desired_power": "stopped", "user.subyard.ccusage_version": "1.2.3",
	}}
	assertStage(t, runtime, "provision", true, "matching stopped provision marker")
	runtime.Environment = []string{"CCUSAGE_VERSION=1.2.4", "HOST_OPENCODE_AGENTS_MD=" + instructions}
	assertStage(t, runtime, "provision", false, "stale stopped provision marker")
}

func TestIncusProbeOwnsVersionPoolAndNetwork(t *testing.T) {
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus", Version: "6.0.6-debian13"},
		Reconcile:  ports.ReconcileState{HostPoolFound: true, HostNetworkFound: true},
	}
	runtime := Runtime{Incus: incus, Yard: domain.Context{IncusBridge: "incusbr0"}}
	assertStage(t, runtime, "incus", true, "matching Incus bootstrap")
	incus.ServerInfo.Version = "6.0.5"
	assertStage(t, runtime, "incus", false, "old Incus")
	incus.ServerInfo.Version = "6.1.0"
	incus.Reconcile.HostNetworkFound = false
	assertStage(t, runtime, "incus", false, "missing bridge")
}

func TestProvisionAgentCommandsAreValidated(t *testing.T) {
	hook := filepath.Join(t.TempDir(), "provision.sh")
	if err := os.WriteFile(hook, []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runtime := Runtime{Environment: []string{
		"AGENTS=opencode", "AGENT_opencode_PROVISION=" + hook, "AGENT_opencode_COMMAND=opencode",
	}}
	commands, err := runtime.provisionAgentCommands()
	if err != nil || len(commands) != 1 || commands[0] != "opencode" {
		t.Fatalf("valid agent command rejected: %v, %v", commands, err)
	}
	runtime.Environment[2] = "AGENT_opencode_COMMAND=bad command"
	if _, err := runtime.provisionAgentCommands(); err == nil {
		t.Fatal("unsafe agent command accepted")
	}
}

func TestProjectProbeOwnsRestrictedPolicy(t *testing.T) {
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"},
		Reconcile: ports.ReconcileState{
			ProjectFound: true, ProfileFound: true,
			ProjectConfig: map[string]string{
				"restricted": "true", "restricted.containers.nesting": "allow",
				"restricted.containers.privilege":    "unprivileged",
				"restricted.containers.interception": "block",
				"restricted.devices.disk":            "allow", "restricted.devices.disk.paths": "",
				"restricted.devices.unix-char": "allow", "restricted.devices.proxy": "allow",
			},
			ProfileDevices: map[string]map[string]string{
				"root": {"type": "disk"}, "eth0": {"type": "nic"},
			},
		},
	}
	runtime := Runtime{
		Incus: incus,
		Yard:  domain.Context{IncusProject: "subyard", InstanceType: domain.InstanceContainer},
	}
	converged, err := runtime.CheckStage(context.Background(), "project")
	if err != nil || !converged {
		t.Fatalf("matching project rejected: %v, %v", converged, err)
	}
	incus.Reconcile.ProjectConfig["restricted"] = "false"
	converged, err = runtime.CheckStage(context.Background(), "project")
	if err != nil || converged {
		t.Fatalf("project policy drift accepted: %v, %v", converged, err)
	}
	incus.Reconcile.ProjectConfig["restricted"] = "true"
	runtime.Yard.NestedE2EVMs = true
	incus.Reconcile.ProjectConfig["restricted.containers.interception"] = "allow"
	converged, err = runtime.CheckStage(context.Background(), "project")
	if err != nil || !converged {
		t.Fatalf("trusted nested project rejected: %v, %v", converged, err)
	}
	delete(incus.Reconcile.ProfileDevices, "eth0")
	converged, err = runtime.CheckStage(context.Background(), "project")
	if err != nil || converged {
		t.Fatalf("missing project NIC accepted: %v, %v", converged, err)
	}
}

func TestInstanceProbeOwnsVolumeAndNestedBoundary(t *testing.T) {
	deviceRoot := t.TempDir()
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"},
		Reconcile: ports.ReconcileState{
			InstanceFound: true, VolumeFound: true,
			Instance: ports.InstanceInfo{
				LocalConfig: map[string]string{"security.nesting": "true"},
				LocalDevices: map[string]map[string]string{
					"srv": {"source": "yard-srv", "path": "/srv", "pool": "default"},
				},
			},
		},
	}
	runtime := Runtime{
		Incus: incus,
		Yard: domain.Context{
			IncusProject: "subyard", InstanceName: "yard", InstanceType: domain.InstanceContainer,
		},
		HostDeviceRoot: deviceRoot,
	}
	assertStageConverged(t, runtime, true, "matching instance")
	incus.Reconcile.Instance.LocalDevices["srv"]["source"] = "wrong"
	assertStageConverged(t, runtime, false, "drifted volume")
	incus.Reconcile.Instance.LocalDevices["srv"]["source"] = "yard-srv"
	if err := os.WriteFile(filepath.Join(deviceRoot, "kvm"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	assertStageConverged(t, runtime, false, "missing host KVM mapping")
	incus.Reconcile.Instance.LocalDevices["kvm"] = charDevice("/dev/kvm")
	assertStageConverged(t, runtime, true, "host KVM mapping")

	runtime.Yard.NestedE2EVMs = true
	incus.Reconcile.Instance.LocalConfig["security.syscalls.intercept.bpf"] = "true"
	incus.Reconcile.Instance.LocalConfig["security.syscalls.intercept.bpf.devices"] = "true"
	incus.Reconcile.Instance.LocalDevices["e2e-vsock"] = charDevice("/dev/vsock")
	incus.Reconcile.Instance.LocalDevices["e2e-vhost-vsock"] = charDevice("/dev/vhost-vsock")
	incus.Reconcile.Instance.LocalDevices["e2e-tun"] = charDevice("/dev/net/tun")
	assertStageConverged(t, runtime, true, "nested VM boundary")
	delete(incus.Reconcile.Instance.LocalDevices, "e2e-vhost-vsock")
	assertStageConverged(t, runtime, false, "missing vhost-vsock mapping")

	runtime.Yard.InstanceType = domain.InstanceVM
	incus.Reconcile.Instance.LocalConfig = nil
	incus.Reconcile.Instance.LocalDevices = map[string]map[string]string{
		"srv": {"source": "yard-srv", "path": "/srv", "pool": "default"},
	}
	assertStageConverged(t, runtime, true, "VM volume")
}

func TestMountProbeDetectsMissingDriftedAndStaleDevices(t *testing.T) {
	incus := &testkit.Incus{
		ServerInfo: ports.ServerInfo{Environment: "incus"},
		Reconcile: ports.ReconcileState{InstanceFound: true, Instance: ports.InstanceInfo{
			LocalDevices: map[string]map[string]string{"host-cache": {
				"source": "/srv/subyard/host-cache", "path": "/mnt/cache",
			}},
		}},
	}
	runtime := Runtime{
		Incus: incus, Yard: domain.Context{Paths: domain.RuntimePaths{HostBase: "/srv/subyard"}},
		Environment: []string{"HOST_MOUNTS=host-cache:/mnt/cache:rw:0755"},
	}
	assertStage(t, runtime, "mounts", true, "matching mount")
	incus.Reconcile.Instance.LocalDevices["host-cache"]["path"] = "/wrong"
	assertStage(t, runtime, "mounts", false, "drifted mount")
	incus.Reconcile.Instance.LocalDevices["host-cache"]["path"] = "/mnt/cache"
	incus.Reconcile.Instance.LocalDevices["host-old"] = map[string]string{}
	assertStage(t, runtime, "mounts", false, "stale mount")
}

func assertStageConverged(t *testing.T, runtime Runtime, want bool, label string) {
	assertStage(t, runtime, "instance", want, label)
}

func assertStage(t *testing.T, runtime Runtime, stage string, want bool, label string) {
	t.Helper()
	got, err := runtime.CheckStage(context.Background(), stage)
	if err != nil || got != want {
		t.Fatalf("%s: converged=%v, want %v, error=%v", label, got, want, err)
	}
}

func charDevice(path string) map[string]string {
	return map[string]string{"type": "unix-char", "source": path, "path": path}
}
