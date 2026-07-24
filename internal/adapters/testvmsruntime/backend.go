package testvmsruntime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"
)

type Backend struct {
	RepositoryRoot string
	Dispatcher     string
	Project        string
	Instance       string
	YardName       string
	DesiredPower   string
	Environment    map[string]string
	Runner         CommandRunner
	Output         io.Writer
	Start          func(context.Context) error
	Stop           func(context.Context) error
}

type backendState struct {
	enabled         string
	cpu             string
	agentKey        string
	agentConfigured string
	agentKeyHash    string
	engineHash      string
	marker          string
	clientDirectory string
	provision       string
}

func (backend *Backend) Converged(ctx context.Context) (bool, error) {
	state, err := backend.state()
	if err != nil {
		return false, err
	}
	if backend.Runner == nil {
		backend.Runner = ProcessRunner{}
	}
	marker, err := backend.incus(ctx, "config", "get", backend.Instance,
		"user.subyard.test_vms_revision", "--project", backend.Project)
	if err != nil || strings.TrimSpace(marker) != state.marker {
		return false, nil
	}
	if ok, err := backend.routeConverged(state); err != nil || !ok {
		return false, err
	}
	outer, err := backend.outerState(ctx)
	if err != nil {
		return false, nil
	}
	if outer != "RUNNING" {
		return outer == "STOPPED" && backend.DesiredPower == "stopped", nil
	}
	_, err = backend.incus(ctx,
		"exec", backend.Instance, "--project", backend.Project,
		"--env", "WANT_ENABLED="+state.enabled,
		"--env", "WANT_ENGINE_HASH="+state.engineHash,
		"--env", "WANT_AGENT_CONFIGURED="+state.agentConfigured,
		"--env", "WANT_AGENT_KEY_HASH="+state.agentKeyHash,
		"--", DefaultInstalledPath, "_test-vms-worker", "doctor")
	return err == nil, nil
}

func (backend *Backend) Apply(ctx context.Context) (err error) {
	state, err := backend.state()
	if err != nil {
		return err
	}
	if backend.Runner == nil {
		backend.Runner = ProcessRunner{}
	}
	if backend.Output == nil {
		backend.Output = io.Discard
	}
	if backend.DesiredPower != "running" && backend.DesiredPower != "stopped" {
		return errors.New("prepared desired power is required")
	}
	outer, err := backend.outerState(ctx)
	if err != nil {
		return fmt.Errorf("inspect outer yard: %w", err)
	}
	temporaryStart := false
	if outer != "RUNNING" {
		if outer != "STOPPED" {
			return fmt.Errorf("cannot reconcile nested VM backend while yard state is %q", outer)
		}
		if backend.Start == nil || backend.Stop == nil {
			return errors.New("temporary yard power callbacks are required")
		}
		if err := backend.Start(ctx); err != nil {
			return err
		}
		temporaryStart = backend.DesiredPower == "stopped"
	}
	defer func() {
		if !temporaryStart {
			return
		}
		if stopErr := backend.Stop(ctx); stopErr != nil {
			err = errors.Join(err, fmt.Errorf("restore desired stopped state: %w", stopErr))
		}
	}()

	if _, err := backend.incus(ctx, "file", "push", backend.Dispatcher,
		backend.Instance+DefaultInstalledPath, "--project", backend.Project,
		"--create-dirs", "--uid", "0", "--gid", "0", "--mode", "0755"); err != nil {
		return err
	}
	provision, err := os.Open(state.provision)
	if err != nil {
		return err
	}
	defer provision.Close()
	arguments := []string{"exec", backend.Instance, "--project", backend.Project}
	for _, name := range []string{
		"NESTED_E2E_VMS", "DEV_USER", "E2E_VM_IMAGE", "E2E_VM_CPU", "E2E_VM_MEMORY",
		"E2E_VM_DISK", "E2E_VM_TTL_MINUTES", "E2E_VM_BOOT_TIMEOUT",
	} {
		arguments = append(arguments, "--env", name+"="+backend.Environment[name])
	}
	arguments = append(arguments, "--env", "E2E_AGENT_PUBLIC_KEY="+state.agentKey,
		"--", "bash", "-euo", "pipefail", "-s")
	fmt.Fprintln(backend.Output, "  [ .. ] reconciling nested VM physical backend")
	_, stderr, runErr := backend.Runner.Run(ctx, "incus", arguments, nil, provision)
	if runErr != nil {
		if len(stderr) != 0 {
			fmt.Fprint(backend.Output, string(stderr))
		}
		return runErr
	}
	if state.enabled == "1" && state.agentConfigured == "1" {
		if err := backend.publishRoute(ctx, state); err != nil {
			return err
		}
	} else if err := backend.removeRoute(state); err != nil {
		return err
	}
	if _, err := backend.incus(ctx, "config", "set", backend.Instance,
		"user.subyard.test_vms_revision", state.marker, "--project", backend.Project); err != nil {
		return err
	}
	fmt.Fprintf(backend.Output, "  [ ok ] nested E2E VM backend reconciled (enabled=%s)\n",
		state.enabled)
	return nil
}

func (backend *Backend) state() (backendState, error) {
	value := func(name, fallback string) string {
		if backend.Environment[name] != "" {
			return backend.Environment[name]
		}
		return fallback
	}
	state := backendState{
		enabled: value("NESTED_E2E_VMS", "0"), cpu: value("E2E_VM_CPU", "4"),
		provision:       filepath.Join(backend.RepositoryRoot, "scripts", "e2e-lab", "provision.sh"),
		clientDirectory: backend.Environment["SUBYARD_E2E_CLIENT_EXPORT_DIR"],
	}
	if state.enabled != "0" && state.enabled != "1" {
		return state, errors.New("invalid NESTED_E2E_VMS")
	}
	if backend.Dispatcher == "" {
		return state, errors.New("test-vms engine source is required")
	}
	if state.clientDirectory == "" {
		yard := backend.YardName
		if yard == "" {
			yard = "default"
		}
		state.clientDirectory = filepath.Join(backend.RepositoryRoot, "temp", "agent-e2e", yard)
	}
	key, configured, err := readEnrollment(filepath.Join(state.clientDirectory, "agent-access.pub"))
	if err != nil {
		return state, fmt.Errorf("agent enrollment request must be one regular Ed25519 public-key line: %w", err)
	}
	state.agentKey = key
	if configured {
		state.agentConfigured = "1"
	} else {
		state.agentConfigured = "0"
	}
	engineHash, err := fileSHA256(backend.Dispatcher)
	if err != nil {
		return state, err
	}
	provisionHash, err := fileSHA256(state.provision)
	if err != nil {
		return state, err
	}
	state.engineHash = engineHash
	keyHash := sha256.Sum256([]byte(state.agentKey))
	state.agentKeyHash = hex.EncodeToString(keyHash[:])
	revision := sha256.Sum256([]byte(engineHash + "\n" + provisionHash + "\n"))
	state.marker = strings.Join([]string{
		state.enabled, hex.EncodeToString(revision[:]), state.agentKeyHash, state.cpu,
	}, ":")
	return state, nil
}

func readEnrollment(path string) (string, bool, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", false, errors.New("enrollment is not a regular file")
	}
	payload, err := os.ReadFile(path)
	if err != nil {
		return "", false, err
	}
	if len(payload) == 0 || bytesCount(payload, '\n') != 1 || payload[len(payload)-1] != '\n' {
		return "", false, errors.New("enrollment must contain exactly one newline-terminated key")
	}
	key, _, _, _, err := ssh.ParseAuthorizedKey(payload)
	if err != nil || key.Type() != ssh.KeyAlgoED25519 {
		return "", false, errors.New("enrollment is not an Ed25519 public key")
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key))), true, nil
}

func (backend *Backend) routeConverged(state backendState) (bool, error) {
	route := filepath.Join(state.clientDirectory, "route.tsv")
	known := filepath.Join(state.clientDirectory, "known_hosts")
	if state.enabled != "1" || state.agentConfigured != "1" {
		for _, path := range []string{route, known} {
			if _, err := os.Lstat(path); err == nil {
				return false, nil
			} else if !os.IsNotExist(err) {
				return false, err
			}
		}
		return true, nil
	}
	routePayload, err := os.ReadFile(route)
	if err != nil || !strings.HasPrefix(string(routePayload), "subyard-e2e-route-v1\n") {
		return false, nil
	}
	knownPayload, err := os.ReadFile(known)
	if err != nil {
		return false, nil
	}
	fields := strings.Fields(string(knownPayload))
	if len(fields) != 3 || fields[0] != "subyard-e2e-bastion" || fields[1] != ssh.KeyAlgoED25519 {
		return false, nil
	}
	_, _, _, _, err = ssh.ParseAuthorizedKey([]byte(fields[1] + " " + fields[2]))
	return err == nil, nil
}

func (backend *Backend) publishRoute(ctx context.Context, state backendState) error {
	routes, err := backend.incus(ctx, "exec", backend.Instance, "--project", backend.Project,
		"--", "ip", "-4", "-o", "route", "show", "default")
	if err != nil {
		return err
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
		return errors.New("could not resolve the agent route to the outer yard")
	}
	var device string
	for device = range interfaces {
	}
	addresses, err := backend.incus(ctx, "exec", backend.Instance, "--project", backend.Project,
		"--", "ip", "-4", "-o", "address", "show", "dev", device, "scope", "global")
	if err != nil {
		return err
	}
	var addressesFound []string
	for _, line := range strings.Split(addresses, "\n") {
		fields := strings.Fields(line)
		for index := 0; index+1 < len(fields); index++ {
			if fields[index] == "inet" {
				addressesFound = append(addressesFound, strings.SplitN(fields[index+1], "/", 2)[0])
			}
		}
	}
	if len(addressesFound) != 1 || !safeIPv4(addressesFound[0]) {
		return errors.New("unsafe outer-yard IPv4 address")
	}
	hostKeyPayload, err := backend.incus(ctx, "exec", backend.Instance, "--project", backend.Project,
		"--", "cat", "/etc/ssh/ssh_host_ed25519_key.pub")
	if err != nil {
		return err
	}
	hostKey, err := normalizedPublicKey(hostKeyPayload)
	if err != nil {
		return errors.New("invalid outer-yard SSH host key")
	}
	if err := os.MkdirAll(state.clientDirectory, 0o755); err != nil {
		return err
	}
	route := "subyard-e2e-route-v1\n" +
		"hostname\t" + addressesFound[0] + "\nport\t22\nhost_key_alias\tsubyard-e2e-bastion\n"
	if err := writeAtomic(filepath.Join(state.clientDirectory, "route.tsv"), []byte(route), 0o644); err != nil {
		return err
	}
	known := "subyard-e2e-bastion " + hostKey + "\n"
	return writeAtomic(filepath.Join(state.clientDirectory, "known_hosts"), []byte(known), 0o644)
}

func (backend *Backend) removeRoute(state backendState) error {
	var failures []error
	for _, name := range []string{"route.tsv", "known_hosts"} {
		if err := os.Remove(filepath.Join(state.clientDirectory, name)); err != nil && !os.IsNotExist(err) {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

func (backend *Backend) outerState(ctx context.Context) (string, error) {
	state, err := backend.incus(ctx, "list", backend.Instance, "--project", backend.Project,
		"-f", "csv", "-c", "s")
	return strings.TrimSpace(state), err
}

func (backend *Backend) incus(ctx context.Context, arguments ...string) (string, error) {
	environment := make([]string, 0, len(backend.Environment))
	for name, value := range backend.Environment {
		environment = append(environment, name+"="+value)
	}
	stdout, _, err := backend.Runner.Run(ctx, "incus", arguments, environment, nil)
	return string(stdout), err
}

func bytesCount(value []byte, needle byte) int {
	count := 0
	for _, current := range value {
		if current == needle {
			count++
		}
	}
	return count
}
