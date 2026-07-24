package testvmsruntime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Runtime struct {
	Config         Config
	ConfigPath     string
	Runner         CommandRunner
	Stdout         io.Writer
	Stderr         io.Writer
	Now            func() time.Time
	Sleep          func(context.Context, time.Duration) error
	ExecutablePath string
}

func LoadRuntime(path string, stdout, stderr io.Writer) (*Runtime, error) {
	cfg, err := LoadConfig(path)
	if err != nil {
		return nil, err
	}
	return &Runtime{Config: cfg, ConfigPath: path, Stdout: stdout, Stderr: stderr}, nil
}

func (runtime *Runtime) Run(ctx context.Context, arguments []string, environment map[string]string) error {
	if runtime.Runner == nil {
		runtime.Runner = ProcessRunner{}
	}
	if runtime.Stdout == nil {
		runtime.Stdout = io.Discard
	}
	if runtime.Stderr == nil {
		runtime.Stderr = io.Discard
	}
	if runtime.Now == nil {
		runtime.Now = time.Now
	}
	if runtime.Sleep == nil {
		runtime.Sleep = sleepContext
	}
	yes := false
	var positional []string
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
			yes = true
		default:
			positional = append(positional, argument)
		}
	}
	if len(positional) != 1 {
		return errors.New("test-vms worker requires exactly one command")
	}
	action := positional[0]
	if action == "doctor" {
		return runtime.doctor(ctx, environment)
	}
	if err := runtime.Config.Validate(); err != nil {
		return err
	}
	if !runtime.Config.Enabled {
		return errors.New("nested E2E VMs are disabled; enable test-vms and run yard init")
	}
	if _, err := runtime.Runner.LookPath(runtime.Config.Incus); err != nil {
		return errors.New("inner Incus is not installed")
	}
	switch action {
	case "up":
		if !yes {
			return errors.New("confirmation required (re-run with --yes for automation)")
		}
		return runtime.up(ctx)
	case "status":
		return runtime.status(ctx)
	case "down":
		if !yes {
			return errors.New("confirmation required (re-run with --yes for automation)")
		}
		fmt.Fprintln(runtime.Stdout,
			"Delete both disposable VMs, their inner Incus project and synthetic SSH identity.")
		return runtime.cleanupManaged(ctx, false)
	case "gc":
		return runtime.gc(ctx)
	case "reconcile-access":
		return runtime.reconcileExistingAgentAccess(ctx)
	default:
		return fmt.Errorf("unknown command %q (expected up, status or down)", action)
	}
}

func (runtime *Runtime) up(ctx context.Context) (err error) {
	cfg := runtime.Config
	fmt.Fprintf(runtime.Stdout,
		"Create/start exactly two disposable nested VMs with SSH and passwordless sudo.\n"+
			"They expire automatically after %d minutes.\n", int(cfg.TTL/time.Minute))
	if err = runtime.restrictAgentAccess("provisioning"); err != nil {
		return err
	}
	if err = runtime.ensureKey(ctx); err != nil {
		return err
	}
	_ = os.Remove(cfg.failureLog())
	defer func() {
		if err == nil {
			return
		}
		_ = runtime.restrictAgentAccess("allocation-failed")
		_ = runtime.collectFailureDiagnostics(ctx, err)
		fmt.Fprintln(runtime.Stderr,
			"test-vms: failed allocation was left in place for diagnosis; operator cleanup: yard test-vms down")
	}()
	if err = runtime.ensureProject(ctx); err != nil {
		return err
	}
	if err = writePrivateFile(cfg.createdAt(),
		[]byte(strconv.FormatInt(runtime.Now().Unix(), 10)+"\n")); err != nil {
		return err
	}
	if err = writePrivateFile(cfg.knownHosts(), nil); err != nil {
		return err
	}
	for index := 1; index <= 2; index++ {
		if err = runtime.ensureVM(ctx, cfg.vm(index)); err != nil {
			return err
		}
	}
	if err = runtime.tightenProject(ctx); err != nil {
		return err
	}
	for index := 1; index <= 2; index++ {
		if err = runtime.startVM(ctx, cfg.vm(index)); err != nil {
			return err
		}
	}
	for index := 1; index <= 2; index++ {
		vm := cfg.vm(index)
		if err = runtime.waitAgent(ctx, vm); err != nil {
			return err
		}
		if err = runtime.ensureGuestTools(ctx, vm); err != nil {
			return err
		}
		if err = runtime.installManagedGuestKeys(ctx, vm); err != nil {
			return err
		}
		if err = runtime.recordHostKey(ctx, vm); err != nil {
			return err
		}
	}
	if err = os.Chmod(cfg.knownHosts(), 0o600); err != nil {
		return err
	}
	if err = runtime.ensurePeerTrust(ctx); err != nil {
		return err
	}
	for index := 1; index <= 2; index++ {
		if err = runtime.sshSmoke(ctx, cfg.vm(index)); err != nil {
			return err
		}
	}
	if err = runtime.enableAgentAccess(ctx); err != nil {
		return err
	}
	_ = os.Remove(cfg.revokedKey())
	fmt.Fprintln(runtime.Stdout,
		"  [ ok ] both VMs are ready for the enrolled agent and operator diagnostics")
	return nil
}

func (runtime *Runtime) ensureProject(ctx context.Context) error {
	cfg := runtime.Config
	totalCPU := strconv.Itoa(cfg.CPU * 2)
	totalMemory := doubleSize(cfg.Memory)
	exists := runtime.projectExists(ctx)
	if exists {
		marker, err := runtime.incus(ctx, "project", "get", cfg.Project, "user.subyard.managed")
		if err != nil {
			return err
		}
		if strings.TrimSpace(marker) != managedMarker {
			return fmt.Errorf("project %q exists without the Subyard marker; refusing to modify it",
				cfg.Project)
		}
		names, err := runtime.projectInstances(ctx)
		if err != nil {
			return err
		}
		if err := cfg.validateManagedNames(names); err != nil {
			return err
		}
		currentCPU, err := runtime.incus(ctx, "project", "get", cfg.Project, "limits.cpu")
		if err != nil {
			return err
		}
		if number, parseErr := strconv.Atoi(strings.TrimSpace(currentCPU)); parseErr == nil &&
			number < cfg.CPU*2 {
			if _, err := runtime.incus(ctx, "project", "set", cfg.Project, "limits.cpu", totalCPU); err != nil {
				return err
			}
		}
		currentMemory, err := runtime.incus(ctx, "project", "get", cfg.Project, "limits.memory")
		if err != nil {
			return err
		}
		if strings.TrimSpace(currentMemory) != "" {
			currentMiB, parseErr := sizeMiB(strings.TrimSpace(currentMemory))
			if parseErr != nil {
				return fmt.Errorf("managed project has an unsupported memory limit: %s",
					strings.TrimSpace(currentMemory))
			}
			targetMiB, _ := sizeMiB(totalMemory)
			if currentMiB < targetMiB {
				if _, err := runtime.incus(ctx, "project", "set", cfg.Project,
					"limits.memory", totalMemory); err != nil {
					return err
				}
			}
		}
	} else {
		if err := runtime.progress(ctx, "creating inner Incus project '"+cfg.Project+"'", func() error {
			_, err := runtime.incus(ctx, "project", "create", cfg.Project,
				"-c", "features.images=false",
				"-c", "user.subyard.managed="+managedMarker,
				"-c", "limits.instances=2",
				"-c", "limits.virtual-machines=2",
				"-c", "limits.cpu="+totalCPU,
				"-c", "limits.memory="+totalMemory,
				"-c", "restricted=true")
			return err
		}); err != nil {
			return err
		}
		fmt.Fprintf(runtime.Stdout, "  [ ok ] created inner Incus project %q\n", cfg.Project)
	}
	for _, setting := range [][2]string{
		{"limits.instances", "2"}, {"limits.virtual-machines", "2"},
		{"restricted", "true"}, {"user.subyard.managed", managedMarker},
	} {
		if _, err := runtime.incus(ctx, "project", "set", cfg.Project, setting[0], setting[1]); err != nil {
			return err
		}
	}
	devices, err := runtime.incus(ctx, "profile", "device", "list", "default", "--project", cfg.Project)
	if err != nil {
		return err
	}
	if !linePresent(devices, "root") {
		if _, err := runtime.incus(ctx, "profile", "device", "add", "default", "root",
			"disk", "pool=default", "path=/", "--project", cfg.Project); err != nil {
			return err
		}
	}
	if _, err := runtime.incus(ctx, "profile", "device", "set", "default", "root",
		"size", cfg.Disk, "--project", cfg.Project); err != nil {
		return err
	}
	if !linePresent(devices, "eth0") {
		if _, err := runtime.incus(ctx, "profile", "device", "add", "default", "eth0",
			"nic", "network=incusbr0", "name=eth0", "--project", cfg.Project); err != nil {
			return err
		}
	}
	return nil
}

func (cfg Config) validateManagedNames(names []string) error {
	for _, name := range names {
		if name != cfg.vm(1) && name != cfg.vm(2) {
			return fmt.Errorf("unexpected instance blocks reconciliation: %s", name)
		}
	}
	return nil
}

func (runtime *Runtime) ensureVM(ctx context.Context, vm string) error {
	cfg := runtime.Config
	if runtime.vmExists(ctx, vm) {
		kind, err := runtime.incus(ctx, "list", vm, "--project", cfg.Project, "-f", "csv", "-c", "t")
		if err != nil {
			return err
		}
		if strings.TrimSpace(kind) != "VIRTUAL-MACHINE" {
			return fmt.Errorf("managed name %q is not a virtual machine", vm)
		}
		if err := runtime.requireVMMarker(ctx, vm); err != nil {
			return err
		}
	} else {
		if err := runtime.progress(ctx, "creating "+vm+" from "+cfg.Image, func() error {
			_, err := runtime.incus(ctx, "init", cfg.Image, vm, "--vm", "--project", cfg.Project,
				"-c", "limits.cpu="+strconv.Itoa(cfg.CPU),
				"-c", "limits.memory="+cfg.Memory,
				"-c", "user.subyard.managed="+managedMarker)
			return err
		}); err != nil {
			return err
		}
		if _, err := runtime.incus(ctx, "config", "set", vm, "cloud-init.user-data",
			runtime.cloudConfig(), "--project", cfg.Project); err != nil {
			return err
		}
		fmt.Fprintf(runtime.Stdout, "  [ ok ] created %s\n", vm)
	}
	if _, err := runtime.incus(ctx, "config", "set", vm, "limits.cpu",
		strconv.Itoa(cfg.CPU), "--project", cfg.Project); err != nil {
		return err
	}
	if _, err := runtime.incus(ctx, "config", "set", vm, "limits.memory",
		cfg.Memory, "--project", cfg.Project); err != nil {
		return err
	}
	raw, err := runtime.incus(ctx, "config", "get", vm, "raw.apparmor", "--project", cfg.Project)
	if err != nil {
		return err
	}
	if strings.TrimSpace(raw) != "" {
		_, err = runtime.incus(ctx, "config", "unset", vm, "raw.apparmor", "--project", cfg.Project)
	}
	return err
}

func (runtime *Runtime) tightenProject(ctx context.Context) error {
	cfg := runtime.Config
	for _, setting := range [][2]string{
		{"limits.cpu", strconv.Itoa(cfg.CPU * 2)}, {"limits.memory", doubleSize(cfg.Memory)},
	} {
		if _, err := runtime.incus(ctx, "project", "set", cfg.Project, setting[0], setting[1]); err != nil {
			return err
		}
	}
	_, err := runtime.incus(ctx, "project", "unset", cfg.Project,
		"restricted.virtual-machines.lowlevel")
	return err
}

func (runtime *Runtime) startVM(ctx context.Context, vm string) error {
	state, err := runtime.incus(ctx, "list", vm, "--project", runtime.Config.Project,
		"-f", "csv", "-c", "s")
	if err != nil {
		return err
	}
	if strings.TrimSpace(state) == "RUNNING" {
		return nil
	}
	if err := runtime.progress(ctx, "starting "+vm, func() error {
		_, err := runtime.incus(ctx, "start", vm, "--project", runtime.Config.Project)
		return err
	}); err != nil {
		return err
	}
	fmt.Fprintf(runtime.Stdout, "  [ ok ] started %s\n", vm)
	return nil
}

func (runtime *Runtime) status(ctx context.Context) error {
	cfg := runtime.Config
	if !runtime.projectExists(ctx) {
		fmt.Fprintln(runtime.Stdout, "test-vms: down")
		return nil
	}
	if err := runtime.requireProjectMarker(ctx); err != nil {
		return err
	}
	remaining := time.Duration(0)
	if created, ok := readEpoch(cfg.createdAt()); ok {
		remaining = created.Add(cfg.TTL).Sub(runtime.Now())
		if remaining < 0 {
			remaining = 0
		}
	}
	for index := 1; index <= 2; index++ {
		vm := cfg.vm(index)
		if !runtime.vmExists(ctx, vm) {
			fmt.Fprintf(runtime.Stdout, "%s\tMISSING\t-\n", vm)
			continue
		}
		if err := runtime.requireVMMarker(ctx, vm); err != nil {
			return err
		}
		state, err := runtime.incus(ctx, "list", vm, "--project", cfg.Project, "-f", "csv", "-c", "s")
		if err != nil {
			return err
		}
		address, _ := runtime.vmIP(ctx, vm)
		if address == "" {
			address = "-"
		}
		fmt.Fprintf(runtime.Stdout, "%s\t%s\t%s\n", vm, strings.TrimSpace(state), address)
	}
	fmt.Fprintf(runtime.Stdout, "ttl_remaining_seconds\t%d\n", int64(remaining/time.Second))
	return nil
}

func (runtime *Runtime) gc(ctx context.Context) error {
	if !runtime.projectExists(ctx) {
		return nil
	}
	marker, err := runtime.incus(ctx, "project", "get", runtime.Config.Project,
		"user.subyard.managed")
	if err != nil || strings.TrimSpace(marker) != managedMarker {
		return nil
	}
	created, ok := readEpoch(runtime.Config.createdAt())
	if !ok || runtime.Now().Sub(created) < runtime.Config.TTL {
		return nil
	}
	return runtime.cleanupManaged(ctx, true)
}

func (runtime *Runtime) cleanupManaged(ctx context.Context, quiet bool) error {
	cfg := runtime.Config
	if err := runtime.restrictAgentAccess("down"); err != nil {
		return err
	}
	if runtime.projectExists(ctx) {
		if err := runtime.requireProjectMarker(ctx); err != nil {
			return err
		}
		names, err := runtime.projectInstances(ctx)
		if err != nil {
			return errors.New("could not inventory managed project before cleanup")
		}
		for _, name := range names {
			if name != cfg.vm(1) && name != cfg.vm(2) {
				return fmt.Errorf("unexpected instance blocks cleanup: %s", name)
			}
		}
		for index := 1; index <= 2; index++ {
			vm := cfg.vm(index)
			if !runtime.vmExists(ctx, vm) {
				continue
			}
			if err := runtime.requireVMMarker(ctx, vm); err != nil {
				return err
			}
			if _, err := runtime.incus(ctx, "delete", vm, "--project", cfg.Project, "--force"); err != nil {
				return err
			}
		}
		if _, err := runtime.incus(ctx, "project", "delete", cfg.Project); err != nil {
			return err
		}
	}
	for _, path := range []string{
		cfg.keyPath(), cfg.keyPath() + ".pub", cfg.knownHosts(), cfg.createdAt(),
		cfg.failureLog(), cfg.keyRevision(), cfg.revokedKey(),
	} {
		_ = os.Remove(path)
	}
	if !quiet {
		fmt.Fprintln(runtime.Stdout,
			"  [ ok ] deleted both disposable VMs, inner project and operator worker identity")
	}
	return nil
}

func (runtime *Runtime) projectExists(ctx context.Context) bool {
	_, err := runtime.incus(ctx, "project", "show", runtime.Config.Project)
	return err == nil
}

func (runtime *Runtime) vmExists(ctx context.Context, vm string) bool {
	_, err := runtime.incus(ctx, "info", vm, "--project", runtime.Config.Project)
	return err == nil
}

func (runtime *Runtime) projectInstances(ctx context.Context) ([]string, error) {
	value, err := runtime.incus(ctx, "list", "--project", runtime.Config.Project, "-f", "csv", "-c", "n")
	if err != nil {
		return nil, err
	}
	return nonemptyLines(value), nil
}

func (runtime *Runtime) requireProjectMarker(ctx context.Context) error {
	value, err := runtime.incus(ctx, "project", "get", runtime.Config.Project,
		"user.subyard.managed")
	if err != nil {
		return err
	}
	if strings.TrimSpace(value) != managedMarker {
		return fmt.Errorf("project %q is not Subyard-managed", runtime.Config.Project)
	}
	return nil
}

func (runtime *Runtime) requireVMMarker(ctx context.Context, vm string) error {
	value, err := runtime.incus(ctx, "config", "get", vm, "user.subyard.managed",
		"--project", runtime.Config.Project)
	if err != nil {
		return err
	}
	if strings.TrimSpace(value) != managedMarker {
		return fmt.Errorf("VM %q is not Subyard-managed", vm)
	}
	return nil
}

func (runtime *Runtime) vmIP(ctx context.Context, vm string) (string, error) {
	routes, err := runtime.guest(ctx, vm, nil, "ip", "-4", "route", "show", "default")
	if err != nil {
		return "", err
	}
	interfaces := map[string]bool{}
	for _, line := range strings.Split(routes, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != "default" {
			continue
		}
		for index := 0; index+1 < len(fields); index++ {
			if fields[index] == "dev" {
				interfaces[fields[index+1]] = true
			}
		}
	}
	if len(interfaces) != 1 {
		return "", fmt.Errorf("expected exactly one default-route interface for %s", vm)
	}
	var name string
	for candidate := range interfaces {
		name = candidate
	}
	payload, err := runtime.incus(ctx, "list", vm, "--project", runtime.Config.Project,
		"--format", "json")
	if err != nil {
		return "", err
	}
	var instances []struct {
		State struct {
			Network map[string]struct {
				Addresses []struct {
					Family  string `json:"family"`
					Scope   string `json:"scope"`
					Address string `json:"address"`
				} `json:"addresses"`
			} `json:"network"`
		} `json:"state"`
	}
	if err := json.Unmarshal([]byte(payload), &instances); err != nil || len(instances) != 1 {
		return "", fmt.Errorf("decode %s network state", vm)
	}
	unique := map[string]bool{}
	for _, address := range instances[0].State.Network[name].Addresses {
		if address.Family == "inet" && address.Scope == "global" &&
			net.ParseIP(address.Address).To4() != nil {
			unique[address.Address] = true
		}
	}
	if len(unique) != 1 {
		return "", errors.New("expected exactly one global IPv4 address on the default-route interface")
	}
	for address := range unique {
		return address, nil
	}
	panic("unreachable")
}

func (runtime *Runtime) incus(ctx context.Context, arguments ...string) (string, error) {
	stdout, _, err := runtime.Runner.Run(ctx, runtime.Config.Incus, arguments, nil, nil)
	return string(stdout), err
}

func (runtime *Runtime) guest(
	ctx context.Context,
	vm string,
	environment []string,
	arguments ...string,
) (string, error) {
	incusArguments := []string{"exec", vm, "--project", runtime.Config.Project}
	for _, value := range environment {
		incusArguments = append(incusArguments, "--env", value)
	}
	incusArguments = append(incusArguments, "--")
	incusArguments = append(incusArguments, arguments...)
	return runtime.incus(ctx, incusArguments...)
}

func (runtime *Runtime) progress(ctx context.Context, label string, operation func() error) error {
	fmt.Fprintf(runtime.Stdout, "  [ .. ] %s\n", label)
	done := make(chan error, 1)
	go func() { done <- operation() }()
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	started := runtime.Now()
	for {
		select {
		case err := <-done:
			return err
		case <-ticker.C:
			fmt.Fprintf(runtime.Stdout, "  [ .. ] %s (still working, %ds elapsed)\n",
				label, int(runtime.Now().Sub(started)/time.Second))
		case <-ctx.Done():
			return context.Cause(ctx)
		}
	}
}

func (runtime *Runtime) waitFor(
	ctx context.Context,
	label string,
	probe func() error,
) error {
	deadline := runtime.Now().Add(runtime.Config.BootTimeout)
	started := runtime.Now()
	nextReport := started.Add(10 * time.Second)
	fmt.Fprintf(runtime.Stdout, "  [ .. ] %s\n", label)
	for {
		if err := probe(); err == nil {
			return nil
		}
		now := runtime.Now()
		if !now.Before(deadline) {
			return fmt.Errorf("%s did not become ready within %s", label, runtime.Config.BootTimeout)
		}
		if !now.Before(nextReport) {
			fmt.Fprintf(runtime.Stdout, "  [ .. ] %s (%ds elapsed)\n",
				label, int(now.Sub(started)/time.Second))
			nextReport = now.Add(10 * time.Second)
		}
		if err := runtime.Sleep(ctx, 2*time.Second); err != nil {
			return err
		}
	}
}

func sleepContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return context.Cause(ctx)
	}
}

func (runtime *Runtime) ensureStateDir() error {
	cfg := runtime.Config
	if os.Geteuid() == 0 {
		if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
			return err
		}
		return os.Chmod(cfg.StateDir, 0o700)
	}
	info, err := os.Stat(cfg.StateDir)
	if err != nil || !info.IsDir() {
		return errors.New("state directory is not writable; re-run yard init on the owner host")
	}
	file, err := os.CreateTemp(cfg.StateDir, ".write-check-*")
	if err != nil {
		return errors.New("state directory is not writable; re-run yard init on the owner host")
	}
	name := file.Name()
	_ = file.Close()
	_ = os.Remove(name)
	return nil
}

func (runtime *Runtime) ensureKey(ctx context.Context) error {
	cfg := runtime.Config
	if err := runtime.ensureStateDir(); err != nil {
		return err
	}
	if _, err := os.Stat(cfg.keyRevision()); os.IsNotExist(err) {
		if payload, readErr := os.ReadFile(cfg.keyPath() + ".pub"); readErr == nil {
			if key, normalizeErr := normalizedPublicKey(string(payload)); normalizeErr == nil {
				_ = writePrivateFile(cfg.revokedKey(), []byte(key+"\n"))
			}
		}
		_ = os.Remove(cfg.keyPath())
		_ = os.Remove(cfg.keyPath() + ".pub")
	}
	if !regularNonempty(cfg.keyPath()) || !regularNonempty(cfg.keyPath()+".pub") {
		_ = os.Remove(cfg.keyPath())
		_ = os.Remove(cfg.keyPath() + ".pub")
		if _, _, err := runtime.Runner.Run(ctx, "ssh-keygen", []string{
			"-q", "-t", "ed25519", "-N", "", "-C", "subyard-managed-e2e-worker",
			"-f", cfg.keyPath(),
		}, nil, nil); err != nil {
			return err
		}
	}
	if err := writePrivateFile(cfg.keyRevision(), nil); err != nil {
		return err
	}
	if err := os.Chmod(cfg.keyPath(), 0o600); err != nil {
		return err
	}
	return os.Chmod(cfg.keyPath()+".pub", 0o644)
}

func writePrivateFile(path string, payload []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func writeAtomic(path string, payload []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	if _, err = file.Write(payload); err == nil {
		err = file.Chmod(mode)
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(temp, path)
}

func regularNonempty(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Size() > 0
}

func linePresent(value, line string) bool {
	for _, candidate := range strings.Split(value, "\n") {
		if strings.TrimSpace(candidate) == line {
			return true
		}
	}
	return false
}

func nonemptyLines(value string) []string {
	var result []string
	for _, line := range strings.Split(value, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			result = append(result, line)
		}
	}
	return result
}

func readEpoch(path string) (time.Time, bool) {
	payload, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}, false
	}
	value, err := strconv.ParseInt(strings.TrimSpace(string(payload)), 10, 64)
	if err != nil || value < 1 {
		return time.Time{}, false
	}
	return time.Unix(value, 0), true
}

func userGroup(name string) (int, error) {
	account, err := user.Lookup(name)
	if err != nil {
		return -1, err
	}
	return strconv.Atoi(account.Gid)
}
