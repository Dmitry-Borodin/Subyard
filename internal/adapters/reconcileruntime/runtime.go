package reconcileruntime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/credentialruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type Runtime struct {
	RepositoryRoot string
	Environment    []string
	Stdin          io.Reader
	Stdout         io.Writer
	Stderr         io.Writer
	Incus          ports.Incus
	ConfigWriter   ports.InstanceConfigWriter
	Executor       ports.InstanceExecutor
	Yard           domain.Context
	PowerYards     []domain.Context
	SRVPool        string
	SRVVolume      string
	HostDeviceRoot string
}

func (runtime Runtime) CheckStage(ctx context.Context, stage string) (bool, error) {
	var err error
	switch stage {
	case "project":
		return runtime.projectConverged(ctx)
	case "instance":
		return runtime.instanceConverged(ctx)
	case "mounts":
		return runtime.mountsConverged(ctx)
	case "power-import":
		return runtime.powerImportsConverged(ctx)
	case "git-identity":
		return runtime.gitIdentityConverged(ctx)
	case "network":
		err = runtime.runObservedPowerScript(ctx, nil, true, "06-network.sh", "--check")
	case "power", "finalize":
		return runtime.powerConverged(ctx, true)
	case "test-vms":
		err = runtime.runObservedPowerScript(ctx, nil, true, "e2e-lab/reconcile.sh", "--check")
	case "keys":
		return runtime.keysConverged(ctx)
	case "ssh":
		return runtime.sshConverged(ctx)
	case "provision":
		return runtime.provisionConverged(ctx)
	case "incus":
		return runtime.incusConverged(ctx)
	case "extras":
		err = runtime.runScript(ctx, nil, "09-yard-extras.sh", "--check")
	case "security":
		err = runtime.runScript(ctx, nil, "security-lint.sh", "--quiet", "--require-live")
	default:
		return false, fmt.Errorf("unknown reconcile stage %q", stage)
	}
	if err == nil {
		return true, nil
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) && exitError.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}

func (runtime Runtime) ApplyStage(ctx context.Context, stage string) error {
	switch stage {
	case "project":
		return runtime.runScript(ctx, runtime.Stderr, "02-create-project.sh", "--yes")
	case "instance":
		return runtime.applyInstanceStage(ctx)
	case "mounts":
		return runtime.runScript(ctx, runtime.Stderr, "05-mount-host-paths.sh", "--yes")
	case "power-import":
		return runtime.importPowerState(ctx)
	case "git-identity":
		return runtime.runScript(ctx, runtime.Stderr, "08-git-identity.sh", "--yes")
	case "network":
		return runtime.runScript(ctx, runtime.Stderr, "06-network.sh", "--yes")
	case "power":
		return runtime.runScript(ctx, runtime.Stderr, "install-power-reconciler.sh", "--yes")
	case "finalize":
		return runtime.finalizePowerState(ctx)
	case "test-vms":
		return runtime.runPreparedPowerScript(ctx, runtime.Stderr, "e2e-lab/reconcile.sh", "--yes")
	case "keys":
		if err := runtime.runScript(ctx, runtime.Stderr, "install-key-tools.sh", "--yes"); err != nil {
			return err
		}
		credentials, err := runtime.credentialRuntime()
		if err != nil {
			return err
		}
		if err := credentials.Initialize(ctx); err != nil {
			return err
		}
		return runtime.runScript(ctx, runtime.Stderr, "install-keys-auto-sync.sh", "--yes")
	case "ssh":
		return runtime.runScript(ctx, runtime.Stderr, "07-ssh-access.sh", "--yes")
	case "provision":
		return runtime.runScript(ctx, runtime.Stderr, "04-provision-subyard.sh", "--yes")
	case "incus":
		return runtime.installIncus(ctx)
	case "extras":
		return runtime.runScript(ctx, runtime.Stderr, "09-yard-extras.sh", "--yes")
	case "security":
		return runtime.runScript(ctx, runtime.Stderr, "security-lint.sh", "--require-live")
	default:
		return fmt.Errorf("unknown reconcile stage %q", stage)
	}
}

func (runtime Runtime) VerifyStage(ctx context.Context, stage string) (bool, error) {
	if stage == "network" {
		return runtime.observedPowerScriptConverged(ctx, true, "06-network.sh", "--verify")
	}
	if stage == "test-vms" {
		return runtime.observedPowerScriptConverged(ctx, true, "e2e-lab/reconcile.sh", "--verify")
	}
	if stage == "keys" {
		return runtime.keysConverged(ctx)
	}
	if stage == "ssh" {
		return runtime.sshConverged(ctx)
	}
	if stage == "provision" {
		return runtime.provisionConverged(ctx)
	}
	if stage == "power" {
		return runtime.powerConverged(ctx, false)
	}
	if stage == "finalize" {
		return runtime.powerConverged(ctx, true)
	}
	if stage == "project" || stage == "instance" || stage == "mounts" ||
		stage == "power-import" || stage == "git-identity" ||
		stage == "extras" || stage == "security" {
		return runtime.CheckStage(ctx, stage)
	}
	return runtime.CheckStage(ctx, stage)
}

func (runtime Runtime) scriptConverged(ctx context.Context, name string, arguments ...string) (bool, error) {
	err := runtime.runScript(ctx, nil, name, arguments...)
	if err == nil {
		return true, nil
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) && exitError.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}

func (runtime Runtime) projectConverged(ctx context.Context) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.ProjectFound {
		return false, err
	}
	wantInterception := "block"
	if runtime.Yard.NestedE2EVMs {
		wantInterception = "allow"
	}
	want := map[string]string{
		"restricted":                         "true",
		"restricted.containers.nesting":      "allow",
		"restricted.containers.privilege":    "unprivileged",
		"restricted.containers.interception": wantInterception,
		"restricted.devices.disk":            "allow",
		"restricted.devices.disk.paths":      "",
		"restricted.devices.unix-char":       "allow",
		"restricted.devices.proxy":           "allow",
	}
	for key, value := range want {
		if state.ProjectConfig[key] != value {
			return false, nil
		}
	}
	_, root := state.ProfileDevices["root"]
	_, network := state.ProfileDevices["eth0"]
	return state.ProfileFound && root && network, nil
}

func (runtime Runtime) instanceConverged(ctx context.Context) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound || !state.VolumeFound {
		return false, err
	}
	pool, volume := runtime.volumeNames()
	devices := state.Instance.LocalDevices
	srv, exists := devices["srv"]
	if !exists || srv["source"] != volume || srv["path"] != "/srv" || srv["pool"] != pool {
		return false, nil
	}
	if runtime.Yard.InstanceType != domain.InstanceContainer {
		return true, nil
	}
	config := state.Instance.LocalConfig
	if config["security.nesting"] != "true" {
		return false, nil
	}
	if runtime.Yard.NestedE2EVMs {
		if config["security.syscalls.intercept.bpf"] != "true" ||
			config["security.syscalls.intercept.bpf.devices"] != "true" ||
			!charDeviceMatches(devices["kvm"], "/dev/kvm") ||
			!charDeviceMatches(devices["e2e-vsock"], "/dev/vsock") ||
			!charDeviceMatches(devices["e2e-vhost-vsock"], "/dev/vhost-vsock") ||
			!charDeviceMatches(devices["e2e-tun"], "/dev/net/tun") {
			return false, nil
		}
	} else {
		if config["security.syscalls.intercept.bpf"] != "" ||
			config["security.syscalls.intercept.bpf.devices"] != "" {
			return false, nil
		}
		for _, name := range []string{"e2e-vsock", "e2e-vhost-vsock", "e2e-tun"} {
			if _, exists := devices[name]; exists {
				return false, nil
			}
		}
	}
	root := runtime.HostDeviceRoot
	if root == "" {
		root = "/dev"
	}
	if _, err := os.Stat(filepath.Join(root, "kvm")); err == nil &&
		!charDeviceMatches(devices["kvm"], "/dev/kvm") {
		return false, nil
	}
	return true, nil
}

func (runtime Runtime) reconcileState(ctx context.Context) (ports.ReconcileState, error) {
	pool, volume := runtime.volumeNames()
	bridge := runtime.Yard.IncusBridge
	if bridge == "" {
		bridge = runtime.environmentDefault("INCUS_BRIDGE", "incusbr0")
	}
	return runtime.Incus.ReconcileState(
		ctx, runtime.Yard.IncusProject, runtime.Yard.InstanceName, pool, volume, bridge,
	)
}

func (runtime Runtime) mountsConverged(ctx context.Context) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound {
		return false, err
	}
	desired := make(map[string]map[string]string)
	for _, entry := range strings.Fields(runtime.environmentValue("HOST_MOUNTS")) {
		parts := strings.Split(entry, ":")
		if len(parts) != 4 || parts[0] == "" {
			continue
		}
		desired[parts[0]] = map[string]string{
			"source": filepath.Join(runtime.Yard.Paths.HostBase, parts[0]),
			"path":   parts[1], "readonly": fmt.Sprint(parts[2] == "ro"),
		}
	}
	for name, want := range desired {
		device, found := state.Instance.LocalDevices[name]
		actualReadonly := device["readonly"] == "true"
		if !found || device["source"] != want["source"] || device["path"] != want["path"] ||
			fmt.Sprint(actualReadonly) != want["readonly"] {
			return false, nil
		}
	}
	for name := range state.Instance.LocalDevices {
		if strings.HasPrefix(name, "host-") && desired[name] == nil {
			return false, nil
		}
	}
	return true, nil
}

func (runtime Runtime) environmentValue(name string) string {
	prefix := name + "="
	for _, entry := range runtime.Environment {
		if strings.HasPrefix(entry, prefix) {
			return strings.TrimPrefix(entry, prefix)
		}
	}
	return ""
}

func (runtime Runtime) volumeNames() (string, string) {
	pool, volume := runtime.SRVPool, runtime.SRVVolume
	if pool == "" {
		pool = "default"
	}
	if volume == "" {
		volume = "yard-srv"
	}
	return pool, volume
}

func (runtime Runtime) incusReady(ctx context.Context) (bool, error) {
	if runtime.Incus == nil {
		return false, errors.New("Incus reader is required")
	}
	if _, err := runtime.Incus.Server(ctx); err != nil {
		return false, nil
	}
	return true, nil
}

func (runtime Runtime) incusConverged(ctx context.Context) (bool, error) {
	if runtime.Incus == nil {
		return false, errors.New("Incus reader is required")
	}
	server, err := runtime.Incus.Server(ctx)
	if err != nil {
		return false, nil
	}
	if !versionAtLeast(server.Version, runtime.environmentDefault("MIN_INCUS_VER", "6.0.6")) {
		return false, nil
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil {
		return false, err
	}
	return state.HostPoolFound && state.HostNetworkFound, nil
}

func versionAtLeast(current, minimum string) bool {
	parse := func(value string) ([]int, bool) {
		value = strings.TrimPrefix(value, "v")
		parts := strings.Split(value, ".")
		if len(parts) < 2 {
			return nil, false
		}
		result := make([]int, 3)
		for index := range result {
			if index >= len(parts) {
				break
			}
			end := 0
			for end < len(parts[index]) && parts[index][end] >= '0' && parts[index][end] <= '9' {
				end++
			}
			digits := parts[index][:end]
			if digits == "" {
				return nil, false
			}
			number, err := strconv.Atoi(digits)
			if err != nil {
				return nil, false
			}
			result[index] = number
		}
		return result, true
	}
	left, leftOK := parse(current)
	right, rightOK := parse(minimum)
	if !leftOK || !rightOK {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return left[index] > right[index]
		}
	}
	return true
}

func (runtime Runtime) installIncus(ctx context.Context) error {
	if err := runtime.runScript(ctx, runtime.Stderr, "01-install-incus.sh", "--yes"); err != nil {
		return err
	}
	if ready, _ := runtime.incusReady(ctx); ready {
		return nil
	}
	dispatcher := runtime.environmentValue("SUBYARD_DISPATCHER_PATH")
	if dispatcher == "" || runtime.environmentValue("SUBYARD_SG_REEXEC") == "1" {
		return errors.New("open a fresh incus-admin session, then rerun yard init")
	}
	sg, err := runtime.executableFromPath("sg")
	if err != nil {
		return errors.New("open a fresh incus-admin session, then rerun yard init")
	}
	arguments := []string{dispatcher}
	if runtime.Yard.YardName != "" {
		arguments = append(arguments, "-Y", runtime.Yard.YardName)
	}
	arguments = append(arguments, "init", "--yes")
	words := []string{"env", "SUBYARD_SG_REEXEC=1", "ASSUME_YES=1"}
	for _, argument := range arguments {
		words = append(words, shellWord(argument))
	}
	command := strings.Join(words, " ")
	environment := append([]string(nil), runtime.Environment...)
	environment = append(environment, "SUBYARD_SG_REEXEC=1", "ASSUME_YES=1")
	return syscall.Exec(sg, []string{"sg", "incus-admin", "-c", command}, environment)
}

func shellWord(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}

func charDeviceMatches(device map[string]string, path string) bool {
	return device["type"] == "unix-char" && device["source"] == path && device["path"] == path
}

func (runtime Runtime) Preflight(ctx context.Context, fresh bool) error {
	basePresent := "0"
	if !fresh && runtime.Incus != nil {
		if _, err := runtime.Incus.Instance(ctx, runtime.Yard.IncusProject, runtime.Yard.InstanceName); err == nil {
			basePresent = "1"
		}
	}
	return runtime.runScriptEnvironment(ctx, runtime.Stdout, map[string]string{
		"SUBYARD_PREFLIGHT_STRICT":       "1",
		"SUBYARD_PREFLIGHT_BASE_PRESENT": basePresent,
	}, "00-check-host.sh")
}

func (runtime Runtime) RefreshConfigs(ctx context.Context) error {
	return runtime.runScript(ctx, runtime.Stdout, "agent-configs.sh", "--yes")
}

func (runtime Runtime) Teardown(ctx context.Context) error {
	return runtime.runScriptEnvironment(ctx, runtime.Stdout,
		map[string]string{"SUBYARD_TEARDOWN_KEEP_DATA": "0"}, "teardown-physical.sh", "--yes")
}

func (runtime Runtime) powerImportsConverged(ctx context.Context) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	for _, yard := range runtime.powerYards() {
		if yard.YardType == domain.YardRemote {
			continue
		}
		converged, err := runtime.powerService().Converged(ctx, yard)
		if errors.Is(err, ports.ErrInstanceNotFound) {
			continue
		}
		if err != nil || !converged {
			return false, err
		}
	}
	return true, nil
}

func (runtime Runtime) importPowerState(ctx context.Context) error {
	if runtime.ConfigWriter == nil {
		return errors.New("Incus instance config writer is required")
	}
	for _, yard := range runtime.powerYards() {
		if yard.YardType == domain.YardRemote {
			continue
		}
		intent, err := runtime.powerService().Ensure(ctx, yard)
		if errors.Is(err, ports.ErrInstanceNotFound) {
			continue
		}
		if err != nil {
			return err
		}
		if intent.Imported && runtime.Stderr != nil {
			fmt.Fprintf(runtime.Stderr, "  [ ok ] imported %s power state: %s\n",
				yard.YardName, intent.Desired)
		}
	}
	return nil
}

func (runtime Runtime) powerService() application.PowerService {
	return application.PowerService{Instances: runtime.Incus, Config: runtime.ConfigWriter}
}

func (runtime Runtime) applyInstanceStage(ctx context.Context) error {
	desired := application.InitialPower(runtime.Yard)
	_, err := runtime.Incus.Instance(ctx, runtime.Yard.IncusProject, runtime.Yard.InstanceName)
	if err == nil {
		intent, ensureErr := runtime.powerService().Ensure(ctx, runtime.Yard)
		if ensureErr != nil {
			return ensureErr
		}
		desired = intent.Desired
		if err := runtime.powerService().Set(ctx, runtime.Yard, desired, false); err != nil {
			return err
		}
	} else if !errors.Is(err, ports.ErrInstanceNotFound) {
		return err
	}
	if err := runtime.runScriptEnvironment(ctx, runtime.Stderr, map[string]string{
		"SUBYARD_POWER_DESIRED": desired,
	}, "03-create-subyard.sh", "--yes"); err != nil {
		return err
	}
	return runtime.powerService().Set(ctx, runtime.Yard, desired, false)
}

func (runtime Runtime) runPreparedPowerScript(
	ctx context.Context,
	output io.Writer,
	name string,
	arguments ...string,
) error {
	intent, err := runtime.powerService().Ensure(ctx, runtime.Yard)
	if err != nil {
		return err
	}
	return runtime.runScriptEnvironment(ctx, output, map[string]string{
		"SUBYARD_POWER_DESIRED": intent.Desired,
	}, name, arguments...)
}

func (runtime Runtime) runObservedPowerScript(
	ctx context.Context,
	output io.Writer,
	allowUnmanaged bool,
	name string,
	arguments ...string,
) error {
	intent, err := runtime.powerService().Intent(ctx, runtime.Yard)
	if err != nil {
		if allowUnmanaged && (errors.Is(err, ports.ErrInstanceNotFound) ||
			errors.Is(err, application.ErrPowerUnmanaged)) {
			return runtime.runScript(ctx, output, name, arguments...)
		}
		return err
	}
	return runtime.runScriptEnvironment(ctx, output, map[string]string{
		"SUBYARD_POWER_DESIRED": intent.Desired,
	}, name, arguments...)
}

func (runtime Runtime) observedPowerScriptConverged(
	ctx context.Context,
	allowUnmanaged bool,
	name string,
	arguments ...string,
) (bool, error) {
	err := runtime.runObservedPowerScript(ctx, nil, allowUnmanaged, name, arguments...)
	if err == nil {
		return true, nil
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) && exitError.ExitCode() == 1 {
		return false, nil
	}
	return false, err
}

func (runtime Runtime) finalizePowerState(ctx context.Context) error {
	intent, err := runtime.powerService().Ensure(ctx, runtime.Yard)
	if err != nil {
		return err
	}
	action := "stop"
	if intent.Desired == application.PowerRunning {
		action = "start"
	}
	if err := runtime.runScript(
		ctx, runtime.Stderr, "lifecycle-guard.sh", action, "--reconcile",
	); err != nil {
		return err
	}
	return runtime.powerService().Commit(ctx, runtime.Yard, intent.Desired)
}

func (runtime Runtime) powerYards() []domain.Context {
	if len(runtime.PowerYards) != 0 {
		return runtime.PowerYards
	}
	return []domain.Context{runtime.Yard}
}

func (runtime Runtime) keysConverged(ctx context.Context) (bool, error) {
	credentials, err := runtime.credentialRuntime()
	if err != nil || !credentials.Initialized() {
		return false, err
	}
	for _, command := range [][]string{
		{"install-key-tools.sh", "--check"},
		{"install-keys-auto-sync.sh", "--check"},
	} {
		converged, err := runtime.scriptConverged(ctx, command[0], command[1:]...)
		if err != nil || !converged {
			return false, err
		}
	}
	return true, nil
}

func (runtime Runtime) credentialRuntime() (*credentialruntime.Runtime, error) {
	root := runtime.environmentDefault("SUBYARD_KEYS_ROOT", filepath.Join(runtime.Yard.Paths.ConfigHome, "keys"))
	consumerRoot := runtime.environmentDefault("SUBYARD_KEYS_CONSUMER_ROOT", runtime.RepositoryRoot)
	dispatcher := runtime.environmentDefault("SUBYARD_DISPATCHER_PATH", filepath.Join(runtime.RepositoryRoot, "bin", "yard"))
	return credentialruntime.New(credentialruntime.Config{
		RepositoryRoot: runtime.RepositoryRoot,
		Root:           root,
		ConsumerRoot:   consumerRoot,
		ToolsDirectory: runtime.environmentValue("SUBYARD_KEYS_TOOLS_DIR"),
		HostBase:       runtime.Yard.Paths.HostBase,
		Context:        runtime.Yard.YardName,
		Dispatcher:     dispatcher,
		Environment:    runtime.Environment,
		Stdin:          runtime.Stdin,
		Stdout:         runtime.Stdout,
		Stderr:         runtime.Stderr,
	})
}

func (runtime Runtime) gitIdentityConverged(ctx context.Context) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound {
		return false, err
	}
	instance := state.Instance
	if strings.EqualFold(instance.Status, "stopped") {
		return instanceIntentionallyStopped(instance), nil
	}
	if !strings.EqualFold(instance.Status, "running") {
		return false, nil
	}
	if runtime.Executor == nil {
		return false, errors.New("Incus executor is required")
	}
	result, err := runtime.Executor.Exec(ctx, runtime.Yard.IncusProject, runtime.Yard.InstanceName,
		ports.InstanceExecRequest{Command: []string{
			"test", "-s", "/home/" + runtime.environmentDefault("DEV_USER", "dev") + "/.gitconfig",
		}})
	if err == nil {
		return true, nil
	}
	if result.ExitCode != 0 {
		return false, nil
	}
	return false, err
}

func (runtime Runtime) sshConverged(ctx context.Context) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound {
		return false, err
	}
	port := runtime.environmentDefault("SSH_PORT", "2222")
	if runtime.Yard.SSHPort != 0 {
		port = strconv.Itoa(runtime.Yard.SSHPort)
	}
	device := state.Instance.LocalDevices["ssh"]
	if device["type"] != "proxy" || device["listen"] != "tcp:127.0.0.1:"+port ||
		device["connect"] != "tcp:127.0.0.1:22" {
		return false, nil
	}
	home := runtime.Yard.Paths.OperatorHome
	if home == "" {
		home = runtime.environmentValue("HOME")
	}
	yardName := runtime.Yard.YardName
	suffix := ""
	if yardName != "" {
		suffix = "-" + yardName
	}
	snippet := filepath.Join(home, ".ssh", "subyard"+suffix+".config")
	snippetContents, err := os.ReadFile(snippet)
	sshHost := runtime.Yard.SSHHost
	if sshHost == "" {
		sshHost = runtime.environmentDefault("SSH_HOST", "yard")
	}
	if err != nil || !hasLine(string(snippetContents), "Host "+sshHost) ||
		!hasLine(string(snippetContents), "    Port "+port) ||
		!hasLine(string(snippetContents), "    StrictHostKeyChecking yes") {
		return false, nil
	}
	if runtime.Yard.ForwardSSHAgent != hasDirective(string(snippetContents), "ForwardAgent", "yes") {
		return false, nil
	}
	configContents, err := os.ReadFile(filepath.Join(home, ".ssh", "config"))
	if err != nil || !hasLine(string(configContents), "Include "+filepath.Base(snippet)) {
		return false, nil
	}
	subyardHome := runtime.Yard.Paths.DataHome
	if subyardHome == "" {
		subyardHome = runtime.environmentValue("SUBYARD_HOME")
	}
	knownHosts := filepath.Join(subyardHome, "ssh", "known_hosts")
	sshKeygen, err := runtime.executableFromPath("ssh-keygen")
	if err != nil {
		return false, nil
	}
	command := exec.CommandContext(ctx, sshKeygen, "-F", "[127.0.0.1]:"+port, "-f", knownHosts)
	command.Env = runtime.Environment
	if command.Run() != nil {
		return false, nil
	}
	instance := state.Instance
	if strings.EqualFold(instance.Status, "stopped") {
		return instanceIntentionallyStopped(instance), nil
	}
	if !strings.EqualFold(instance.Status, "running") {
		return false, nil
	}
	if runtime.Executor == nil {
		return false, errors.New("Incus executor is required")
	}
	user := runtime.Yard.DevUser
	if user == "" {
		user = runtime.environmentDefault("DEV_USER", "dev")
	}
	request := ports.InstanceExecRequest{Command: []string{
		"test", "-s", "/home/" + user + "/.ssh/authorized_keys",
	}}
	if runtime.Yard.NestedE2EVMs {
		request.Command = []string{"grep", "-q", `^from="127[.]0[.]0[.]1,::1" `,
			"/home/" + user + "/.ssh/authorized_keys"}
	}
	result, err := runtime.Executor.Exec(ctx, runtime.Yard.IncusProject, runtime.Yard.InstanceName, request)
	if err == nil {
		return true, nil
	}
	if result.ExitCode != 0 {
		return false, nil
	}
	return false, err
}

func (runtime Runtime) provisionConverged(ctx context.Context) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	version := runtime.environmentValue("CCUSAGE_VERSION")
	if version == "" || version == "latest" {
		return false, nil
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound {
		return false, err
	}
	instance := state.Instance
	marker := instanceValue(instance, "user.subyard.ccusage_version")
	if strings.EqualFold(instance.Status, "stopped") {
		return instanceIntentionallyStopped(instance) && marker == version, nil
	}
	if !strings.EqualFold(instance.Status, "running") {
		return false, nil
	}
	if runtime.Executor == nil {
		return false, errors.New("Incus executor is required")
	}
	commands, err := runtime.provisionAgentCommands()
	if err != nil {
		return false, err
	}
	commands = append([]string{"docker"}, commands...)
	commandCheck := []string{"sh", "-c", `for command do command -v "$command" >/dev/null || exit 1; done`, "subyard"}
	commandCheck = append(commandCheck, commands...)
	if ok, err := runtime.guestCheck(ctx, commandCheck); err != nil || !ok {
		return false, err
	}
	user := runtime.Yard.DevUser
	if user == "" {
		user = runtime.environmentDefault("DEV_USER", "dev")
	}
	if ok, err := runtime.guestCheck(ctx, []string{"id", user}); err != nil || !ok {
		return false, err
	}
	passwd, ok, err := runtime.guestObserve(ctx, []string{"getent", "passwd", user})
	if err != nil || !ok {
		return false, err
	}
	fields := strings.Split(strings.TrimSpace(string(passwd.Stdout)), ":")
	if len(fields) < 6 || fields[5] == "" {
		return false, nil
	}
	home := fields[5]
	ccusagePath := runtime.environmentDefault("CCUSAGE_INSTALL_PATH", "/usr/local/bin/ccusage")
	status, ok, err := runtime.guestObserve(ctx,
		[]string{"stat", "-c", "%F|%a|%u:%g", ccusagePath})
	if err != nil || !ok || strings.TrimSpace(string(status.Stdout)) !=
		"regular file|755|"+runtime.environmentDefault("CCUSAGE_EXPECTED_OWNER", "0:0") {
		return false, err
	}
	magic, ok, err := runtime.guestObserve(ctx, []string{"od", "-An", "-tx1", "-N4", ccusagePath})
	if err != nil || !ok || strings.Join(strings.Fields(string(magic.Stdout)), "") != "7f454c46" {
		return false, err
	}
	reported, ok, err := runtime.guestObserve(ctx, []string{ccusagePath, "--version"})
	if err != nil || !ok || strings.TrimSpace(string(reported.Stdout)) != "ccusage "+version {
		return false, err
	}
	for _, instruction := range [][2]string{
		{"HOST_CLAUDE_MD", filepath.Join(home, ".claude", "CLAUDE.md")},
		{"HOST_CODEX_AGENTS_MD", filepath.Join(home, ".codex", "AGENTS.md")},
		{"HOST_OPENCODE_AGENTS_MD", filepath.Join(home, ".config", "opencode", "AGENTS.md")},
	} {
		if regularFile(runtime.environmentValue(instruction[0])) {
			if ok, err := runtime.guestCheck(ctx, []string{"test", "-f", instruction[1]}); err != nil || !ok {
				return false, err
			}
		}
	}
	sudoers := "/etc/sudoers.d/90-subyard-" + user
	sudoTest := "-f"
	if !runtime.Yard.DevSudo {
		sudoTest = "!"
	}
	sudoCommand := []string{"test", sudoTest, sudoers}
	if sudoTest == "!" {
		sudoCommand = []string{"sh", "-c", `[ ! -e "$1" ]`, "subyard", sudoers}
	}
	if ok, err := runtime.guestCheck(ctx, sudoCommand); err != nil || !ok {
		return false, err
	}
	linksOK, err := runtime.provisionLinksConverged(ctx, home)
	if err != nil || !linksOK {
		return false, err
	}
	legacy := filepath.Join(home, ".local", "share", "opencode", "storage")
	link, exists, err := runtime.guestObserve(ctx, []string{"readlink", legacy})
	if err != nil {
		return false, err
	}
	if exists && strings.TrimSpace(string(link.Stdout)) == "/mnt/host/agent-sessions/opencode/storage" {
		return false, nil
	}
	return marker == version, nil
}

func (runtime Runtime) provisionAgentCommands() ([]string, error) {
	commands := make([]string, 0)
	for _, agent := range strings.Fields(runtime.environmentValue("AGENTS")) {
		provision := runtime.environmentValue("AGENT_" + agent + "_PROVISION")
		if provision == "" {
			continue
		}
		if !regularFile(provision) {
			return nil, fmt.Errorf("agent %s provision hook is missing", agent)
		}
		command := runtime.environmentValue("AGENT_" + agent + "_COMMAND")
		if !safeCommand(command) {
			return nil, fmt.Errorf("agent %s command is invalid", agent)
		}
		commands = append(commands, command)
	}
	return commands, nil
}

func (runtime Runtime) provisionLinksConverged(ctx context.Context, home string) (bool, error) {
	for _, entry := range strings.Fields(runtime.environmentValue("HOST_LINKS")) {
		parts := strings.Split(entry, ":")
		if len(parts) < 2 || parts[0] == "" || !filepath.IsAbs(parts[1]) {
			continue
		}
		components := strings.Split(strings.TrimPrefix(parts[1], "/"), "/")
		if len(components) < 3 {
			continue
		}
		mountRoot := "/" + filepath.Join(components[:3]...)
		mounted, err := runtime.guestCheck(ctx, []string{"test", "-d", mountRoot})
		if err != nil {
			return false, err
		}
		if !mounted {
			continue
		}
		link := filepath.Join(home, parts[0])
		present, err := runtime.guestCheck(ctx,
			[]string{"sh", "-c", `[ -e "$1" ] || [ -L "$1" ]`, "subyard", link})
		if err != nil || !present {
			return false, err
		}
	}
	return true, nil
}

func (runtime Runtime) guestCheck(ctx context.Context, command []string) (bool, error) {
	_, ok, err := runtime.guestObserve(ctx, command)
	return ok, err
}

func (runtime Runtime) guestObserve(
	ctx context.Context,
	command []string,
) (ports.InstanceExecResult, bool, error) {
	result, err := runtime.Executor.Exec(ctx, runtime.Yard.IncusProject, runtime.Yard.InstanceName,
		ports.InstanceExecRequest{Command: command})
	if err == nil {
		return result, true, nil
	}
	if result.ExitCode != 0 {
		return result, false, nil
	}
	return result, false, err
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func safeCommand(command string) bool {
	if command == "" {
		return false
	}
	for _, character := range command {
		if !((character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') || strings.ContainsRune("._-", character)) {
			return false
		}
	}
	return true
}

func instanceIntentionallyStopped(instance ports.InstanceInfo) bool {
	return strings.EqualFold(instance.Status, "stopped") &&
		instanceValue(instance, "user.subyard.managed") == "true" &&
		instanceValue(instance, "user.subyard.initialized") == "true" &&
		instanceValue(instance, "user.subyard.desired_power") == "stopped"
}

func (runtime Runtime) powerConverged(ctx context.Context, requireMetadata bool) (bool, error) {
	ready, err := runtime.incusReady(ctx)
	if err != nil || !ready {
		return false, err
	}
	state, err := runtime.reconcileState(ctx)
	if err != nil || !state.InstanceFound {
		return false, err
	}
	if requireMetadata {
		instance := state.Instance
		desired := instanceValue(instance, "user.subyard.desired_power")
		bridge := runtime.environmentDefault("INCUS_BRIDGE",
			runtime.environmentDefault("INCUS_NETWORK", "incusbr0"))
		if instanceValue(instance, "user.subyard.managed") != "true" ||
			instanceValue(instance, "user.subyard.initialized") != "true" ||
			(desired != "running" && desired != "stopped") ||
			instanceValue(instance, "user.subyard.bridge") != bridge ||
			instanceValue(instance, "boot.autostart") != "false" {
			return false, nil
		}
	}
	return runtime.powerReconcilerConverged(ctx), nil
}

func (runtime Runtime) powerReconcilerConverged(ctx context.Context) bool {
	reconciler := runtime.environmentDefault("SUBYARD_POWER_RECONCILER_PATH",
		"/usr/local/libexec/subyard/yard-boot-reconcile")
	powerLibrary := runtime.environmentDefault("SUBYARD_POWER_LIB_PATH",
		"/usr/local/libexec/subyard/lib-power.sh")
	unit := runtime.environmentDefault("SUBYARD_POWER_UNIT_PATH",
		"/etc/systemd/system/subyard-power-reconcile.service")
	if !executable(reconciler) || !sameFile(filepath.Join(runtime.RepositoryRoot,
		"scripts", "yard-boot-reconcile.sh"), reconciler) ||
		!sameFile(filepath.Join(runtime.RepositoryRoot, "scripts", "lib-power.sh"), powerLibrary) {
		return false
	}
	contents, err := os.ReadFile(unit)
	if err != nil || !hasLine(string(contents), "ExecStart="+reconciler) {
		return false
	}
	systemctl, err := runtime.executableFromPath("systemctl")
	if err != nil {
		return false
	}
	command := exec.CommandContext(ctx, systemctl, "is-enabled", "--quiet", filepath.Base(unit))
	command.Env = runtime.Environment
	return command.Run() == nil
}

func (runtime Runtime) executableFromPath(name string) (string, error) {
	for _, directory := range filepath.SplitList(runtime.environmentValue("PATH")) {
		candidate := filepath.Join(directory, name)
		if executable(candidate) {
			return candidate, nil
		}
	}
	return exec.LookPath(name)
}

func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

func sameFile(left, right string) bool {
	leftContents, leftError := os.ReadFile(left)
	rightContents, rightError := os.ReadFile(right)
	return leftError == nil && rightError == nil && string(leftContents) == string(rightContents)
}

func hasLine(contents, wanted string) bool {
	for _, line := range strings.Split(contents, "\n") {
		if line == wanted {
			return true
		}
	}
	return false
}

func hasDirective(contents, name, value string) bool {
	for _, line := range strings.Split(contents, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == name && fields[1] == value {
			return true
		}
	}
	return false
}

func instanceValue(instance ports.InstanceInfo, name string) string {
	if value := instance.LocalConfig[name]; value != "" {
		return value
	}
	return instance.Config[name]
}

func (runtime Runtime) environmentDefault(name, fallback string) string {
	if value := runtime.environmentValue(name); value != "" {
		return value
	}
	return fallback
}

func (runtime Runtime) runScript(
	ctx context.Context,
	output io.Writer,
	name string,
	arguments ...string,
) error {
	path := filepath.Join(runtime.RepositoryRoot, "scripts", name)
	return runtime.runPath(ctx, output, path, arguments...)
}

func (runtime Runtime) runScriptEnvironment(
	ctx context.Context,
	output io.Writer,
	overrides map[string]string,
	name string,
	arguments ...string,
) error {
	path := filepath.Join(runtime.RepositoryRoot, "scripts", name)
	environment := append([]string(nil), runtime.Environment...)
	for name, value := range overrides {
		prefix := name + "="
		replaced := false
		for index := range environment {
			if strings.HasPrefix(environment[index], prefix) {
				environment[index] = prefix + value
				replaced = true
			}
		}
		if !replaced {
			environment = append(environment, prefix+value)
		}
	}
	return runtime.runPathEnvironment(ctx, output, environment, path, arguments...)
}

func (runtime Runtime) runPath(
	ctx context.Context,
	output io.Writer,
	path string,
	arguments ...string,
) error {
	return runtime.runPathEnvironment(ctx, output, runtime.Environment, path, arguments...)
}

func (runtime Runtime) runPathEnvironment(
	ctx context.Context,
	output io.Writer,
	environment []string,
	path string,
	arguments ...string,
) error {
	command := exec.CommandContext(ctx, path, arguments...)
	command.Dir = runtime.RepositoryRoot
	command.Env = environment
	command.Stdin = runtime.Stdin
	command.Stdout = output
	command.Stderr = output
	if err := command.Run(); err != nil {
		return fmt.Errorf("reconcile adapter %s: %w", strings.Join(arguments, " "), err)
	}
	return nil
}
