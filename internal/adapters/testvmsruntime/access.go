package testvmsruntime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func (runtime *Runtime) killAgentSessions(ctx context.Context) {
	if _, err := user.Lookup(runtime.Config.AgentUser); err != nil {
		return
	}
	if _, err := runtime.Runner.LookPath("pkill"); err != nil {
		return
	}
	_, _, _ = runtime.Runner.Run(ctx, "pkill",
		[]string{"-KILL", "-u", runtime.Config.AgentUser}, nil, nil)
}

func (runtime *Runtime) writeAgentAuthorizedKeys(ip1, ip2 string) error {
	cfg := runtime.Config
	if cfg.AgentPublicKey == "" {
		return nil
	}
	if _, err := user.Lookup(cfg.AgentUser); err != nil {
		return errors.New("agent bastion account is missing; re-run yard init")
	}
	key, err := normalizedPublicKey(cfg.AgentPublicKey)
	if err != nil {
		return err
	}
	directory := filepath.Dir(cfg.AgentAuthorizedKeys)
	mode := os.FileMode(0o600)
	if os.Geteuid() == 0 {
		group, err := userGroup(cfg.AgentUser)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(directory, 0o750); err != nil {
			return err
		}
		if err := os.Chmod(directory, 0o750); err != nil {
			return err
		}
		if err := os.Chown(directory, 0, group); err != nil {
			return err
		}
		mode = 0o640
	} else if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	options := `restrict,command="` + cfg.StatusCommand + `"`
	if ip1 != "" || ip2 != "" {
		if !safeIPv4(ip1) || !safeIPv4(ip2) {
			return errors.New("cannot publish non-IPv4 VM targets")
		}
		options = `restrict,port-forwarding,permitopen="` + ip1 +
			`:22",permitopen="` + ip2 + `:22",command="` + cfg.StatusCommand + `"`
	}
	payload := []byte(options + " " + key + " " + agentKeyMarker + "\n")
	if err := writeAtomic(cfg.AgentAuthorizedKeys, payload, mode); err != nil {
		return err
	}
	if os.Geteuid() == 0 {
		group, _ := userGroup(cfg.AgentUser)
		return os.Chown(cfg.AgentAuthorizedKeys, 0, group)
	}
	return nil
}

func (runtime *Runtime) writeManifest(
	state, reason, ip1, host1, ip2, host2 string,
) error {
	cfg := runtime.Config
	if err := os.MkdirAll(cfg.PublicDir, 0o755); err != nil {
		return err
	}
	if err := os.Chmod(cfg.PublicDir, 0o755); err != nil {
		return err
	}
	created := int64(0)
	expires := int64(0)
	if timestamp, ok := readEpoch(cfg.createdAt()); ok {
		created = timestamp.Unix()
		expires = timestamp.Add(cfg.TTL).Unix()
	}
	var payload strings.Builder
	fmt.Fprintln(&payload, "subyard-e2e-allocation-v1")
	fmt.Fprintf(&payload, "state\t%s\nreason\t%s\n", state, reason)
	fmt.Fprintf(&payload, "allocation_id\t%d\nexpires_at_epoch\t%d\n", created, expires)
	if state == "ready" {
		if !safeIPv4(ip1) || !safeIPv4(ip2) {
			return errors.New("cannot publish non-IPv4 VM targets")
		}
		key1, err := validatePublicKey("VM1 host identity", host1)
		if err != nil {
			return err
		}
		key2, err := validatePublicKey("VM2 host identity", host2)
		if err != nil {
			return err
		}
		fmt.Fprintf(&payload, "vm\t1\t%s\t%s\t%s\n", cfg.vm(1), ip1, key1)
		fmt.Fprintf(&payload, "vm\t2\t%s\t%s\t%s\n", cfg.vm(2), ip2, key2)
	}
	if err := writeAtomic(cfg.manifest(), []byte(payload.String()), 0o644); err != nil {
		return err
	}
	if os.Geteuid() == 0 {
		return os.Chown(cfg.manifest(), 0, 0)
	}
	return nil
}

func (runtime *Runtime) restrictAgentAccess(reason string) error {
	runtime.killAgentSessions(context.Background())
	if err := runtime.writeAgentAuthorizedKeys("", ""); err != nil {
		return err
	}
	return runtime.writeManifest("down", reason, "", "", "", "")
}

func (runtime *Runtime) enableAgentAccess(ctx context.Context) error {
	cfg := runtime.Config
	ip1, err := runtime.vmIP(ctx, cfg.vm(1))
	if err != nil {
		return err
	}
	ip2, err := runtime.vmIP(ctx, cfg.vm(2))
	if err != nil {
		return err
	}
	host1, err := runtime.guestHostKey(ctx, cfg.vm(1))
	if err != nil {
		return err
	}
	host2, err := runtime.guestHostKey(ctx, cfg.vm(2))
	if err != nil {
		return err
	}
	runtime.killAgentSessions(ctx)
	if err := runtime.writeAgentAuthorizedKeys(ip1, ip2); err != nil {
		return err
	}
	return runtime.writeManifest("ready", "ready", ip1, host1, ip2, host2)
}

func (runtime *Runtime) reconcileExistingAgentAccess(ctx context.Context) error {
	cfg := runtime.Config
	if err := runtime.restrictAgentAccess("reconciling"); err != nil {
		return err
	}
	if !runtime.projectExists(ctx) {
		return nil
	}
	if err := runtime.requireProjectMarker(ctx); err != nil {
		return fmt.Errorf("%w; agent access remains disabled", err)
	}
	names, err := runtime.projectInstances(ctx)
	if err != nil {
		return err
	}
	if err := cfg.validateManagedNames(names); err != nil {
		return fmt.Errorf("%w; agent access remains disabled", err)
	}
	for index := 1; index <= 2; index++ {
		vm := cfg.vm(index)
		if !runtime.vmExists(ctx, vm) {
			return runtime.writeManifest("down", "incomplete-allocation", "", "", "", "")
		}
		if err := runtime.requireVMMarker(ctx, vm); err != nil {
			return fmt.Errorf("%w; agent access remains disabled", err)
		}
		state, err := runtime.incus(ctx, "list", vm, "--project", cfg.Project,
			"-f", "csv", "-c", "s")
		if err != nil {
			return err
		}
		if strings.TrimSpace(state) != "RUNNING" {
			return runtime.writeManifest("down", "not-running", "", "", "", "")
		}
	}
	if err := runtime.ensureKey(ctx); err != nil {
		return err
	}
	if err := writePrivateFile(cfg.knownHosts(), nil); err != nil {
		return err
	}
	for index := 1; index <= 2; index++ {
		vm := cfg.vm(index)
		if err := runtime.waitAgent(ctx, vm); err != nil {
			return err
		}
		if err := runtime.ensureGuestTools(ctx, vm); err != nil {
			return err
		}
		if err := runtime.installManagedGuestKeys(ctx, vm); err != nil {
			return err
		}
		if err := runtime.recordHostKey(ctx, vm); err != nil {
			return err
		}
	}
	if err := os.Chmod(cfg.knownHosts(), 0o600); err != nil {
		return err
	}
	for index := 1; index <= 2; index++ {
		if err := runtime.sshSmoke(ctx, cfg.vm(index)); err != nil {
			return err
		}
	}
	if err := runtime.enableAgentAccess(ctx); err != nil {
		return err
	}
	_ = os.Remove(cfg.revokedKey())
	return nil
}

func WritePublicStatus(output io.Writer, manifest string) error {
	if manifest == "" {
		manifest = "/var/lib/subyard/test-vms-public/allocation.tsv"
	}
	payload, err := os.ReadFile(manifest)
	if err == nil {
		_, err = output.Write(payload)
		return err
	}
	if !os.IsNotExist(err) {
		return err
	}
	_, err = fmt.Fprint(output, "subyard-e2e-allocation-v1\n"+
		"state\tdown\nreason\tmanifest-missing\n"+
		"allocation_id\t0\nexpires_at_epoch\t0\n")
	return err
}

func (runtime *Runtime) collectFailureDiagnostics(ctx context.Context, cause error) error {
	cfg := runtime.Config
	if err := runtime.ensureStateDir(); err != nil {
		return err
	}
	var payload strings.Builder
	fmt.Fprintf(&payload, "timestamp_utc=%s\n", runtime.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&payload, "worker_error=%s\nproject=%s\n", oneLine(cause.Error()), cfg.Project)
	if runtime.projectExists(ctx) {
		fmt.Fprintln(&payload, "\n== project ==")
		if value, err := runtime.incus(ctx, "project", "show", cfg.Project); err == nil {
			payload.WriteString(value)
		}
		for index := 1; index <= 2; index++ {
			vm := cfg.vm(index)
			if !runtime.vmExists(ctx, vm) {
				continue
			}
			fmt.Fprintf(&payload, "\n== %s info/log ==\n", vm)
			if value, err := runtime.incus(ctx, "info", "--show-log", vm,
				"--project", cfg.Project); err == nil {
				payload.WriteString(value)
			}
		}
	} else {
		fmt.Fprintln(&payload, "project_state=absent")
	}
	if err := writeAtomic(cfg.failureLog(), []byte(payload.String()), 0o640); err != nil {
		return err
	}
	fmt.Fprintf(runtime.Stderr, "test-vms: failure diagnostics saved to %s\n%s",
		cfg.failureLog(), payload.String())
	return nil
}

func (runtime *Runtime) doctor(ctx context.Context, want map[string]string) error {
	cfg := runtime.Config
	wantEnabled := want["WANT_ENABLED"]
	actualEnabled := "0"
	if cfg.Enabled {
		actualEnabled = "1"
	}
	if wantEnabled != actualEnabled {
		return errors.New("backend enabled state differs")
	}
	if _, err := os.Stat(runtime.ConfigPath); err != nil {
		return errors.New("backend config is missing")
	}
	executable := runtime.ExecutablePath
	if executable == "" {
		var err error
		executable, err = os.Executable()
		if err != nil {
			return err
		}
	}
	hash, err := fileSHA256(executable)
	if err != nil {
		return err
	}
	if hash != want["WANT_ENGINE_HASH"] {
		return errors.New("installed test-vms engine hash differs")
	}
	keyHash := sha256.Sum256([]byte(cfg.AgentPublicKey))
	if hex.EncodeToString(keyHash[:]) != want["WANT_AGENT_KEY_HASH"] {
		return errors.New("installed agent key differs")
	}
	if !cfg.Enabled {
		if runtime.commandOK(ctx, "systemctl", "is-active", "--quiet", "subyard-test-vms-gc.timer") {
			return errors.New("TTL timer remains active")
		}
		if runtime.commandOK(ctx, "systemctl", "is-active", "--quiet",
			"subyard-test-vms-firewall.service") {
			return errors.New("firewall remains active")
		}
		for _, path := range []string{
			"/etc/systemd/system/incus.service.d/subyard-nested-e2e.conf",
			"/etc/ssh/sshd_config.d/90-subyard-e2e-agent.conf",
		} {
			if _, err := os.Stat(path); err == nil {
				return fmt.Errorf("disabled backend artifact remains: %s", path)
			}
		}
		if _, err := user.Lookup(cfg.AgentUser); err == nil {
			return errors.New("agent account remains")
		}
		return nil
	}
	for _, command := range []string{cfg.Incus, "qemu-system-x86_64", "nft"} {
		if _, err := runtime.Runner.LookPath(command); err != nil {
			return fmt.Errorf("required command is missing: %s", command)
		}
	}
	version, _, err := runtime.Runner.Run(ctx, cfg.Incus, []string{"--version"}, nil, nil)
	if err != nil {
		return err
	}
	if !runtime.commandOK(ctx, "dpkg", "--compare-versions",
		strings.TrimSpace(string(version)), "ge", "6.0.6") {
		return errors.New("inner Incus is too old")
	}
	if !runtime.commandOK(ctx, "systemctl", "is-active", "--quiet", "incus.service") {
		return errors.New("inner Incus is inactive")
	}
	if !fileContains("/etc/systemd/system/incus.service.d/subyard-nested-e2e.conf",
		"Environment=INCUS_SECURITY_APPARMOR=false") {
		return errors.New("Incus drop-in differs")
	}
	if !runtime.commandOK(ctx, "systemctl", "is-enabled", "--quiet",
		"subyard-test-vms-gc.timer") {
		return errors.New("TTL timer is disabled")
	}
	if !runtime.commandOK(ctx, "systemctl", "is-active", "--quiet",
		"subyard-test-vms-firewall.service") {
		return errors.New("firewall is inactive")
	}
	if !runtime.commandOK(ctx, "nft", "list", "table", "inet", "subyard_e2e") {
		return errors.New("firewall table is missing")
	}
	sshd, _, err := runtime.Runner.Run(ctx, "sshd", []string{"-T"}, nil, nil)
	if err != nil {
		return errors.New("cannot render sshd config")
	}
	if !linePresent(string(sshd), "passwordauthentication no") ||
		!linePresent(string(sshd), "kbdinteractiveauthentication no") {
		return errors.New("SSH password login is enabled")
	}
	for _, node := range []string{"/dev/kvm", "/dev/vsock", "/dev/vhost-vsock", "/dev/net/tun"} {
		info, err := os.Stat(node)
		if err != nil || info.Mode()&os.ModeCharDevice == 0 {
			return fmt.Errorf("required device is missing: %s", node)
		}
	}
	if err := requireRootMode(cfg.StateDir, 0o700); err != nil {
		return err
	}
	devGroups, err := runtime.output(ctx, "id", "-nG", cfg.DevUser)
	if err != nil {
		return errors.New("yard developer account is missing")
	}
	for _, group := range strings.Fields(devGroups) {
		if group == "incus-admin" || group == "yard" {
			return errors.New("yard developer has inner privileges")
		}
	}
	if want["WANT_AGENT_CONFIGURED"] == "0" {
		if _, err := user.Lookup(cfg.AgentUser); err == nil {
			return errors.New("agent account remains without enrollment")
		}
		return nil
	}
	if _, err := user.Lookup(cfg.AgentUser); err != nil {
		return errors.New("agent account is missing")
	}
	account, err := runtime.output(ctx, "passwd", "--status", cfg.AgentUser)
	if err != nil || !strings.HasPrefix(account, cfg.AgentUser+" P ") {
		return errors.New("agent account cannot use key login")
	}
	groups, err := runtime.output(ctx, "id", "-nG", cfg.AgentUser)
	if err != nil || len(strings.Fields(groups)) != 1 {
		return errors.New("agent has supplementary groups")
	}
	groupName, err := runtime.output(ctx, "id", "-gn", cfg.AgentUser)
	if err != nil {
		return errors.New("cannot inspect agent group")
	}
	if err := requireOwnerMode(filepath.Join(cfg.AgentHome, ".ssh"),
		"root", strings.TrimSpace(groupName), 0o750); err != nil {
		return err
	}
	if err := requireOwnerMode(cfg.AgentAuthorizedKeys,
		"root", strings.TrimSpace(groupName), 0o640); err != nil {
		return err
	}
	authorized, err := os.ReadFile(cfg.AgentAuthorizedKeys)
	if err != nil || !strings.HasPrefix(string(authorized), "restrict,") {
		return errors.New("agent key restrictions are missing")
	}
	if !strings.Contains(string(authorized), `command="`+cfg.StatusCommand+`"`) {
		return errors.New("agent forced command differs")
	}
	return nil
}

func (runtime *Runtime) commandOK(ctx context.Context, name string, arguments ...string) bool {
	_, _, err := runtime.Runner.Run(ctx, name, arguments, nil, nil)
	return err == nil
}

func (runtime *Runtime) output(ctx context.Context, name string, arguments ...string) (string, error) {
	stdout, _, err := runtime.Runner.Run(ctx, name, arguments, nil, nil)
	return string(stdout), err
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func fileContains(path, value string) bool {
	payload, err := os.ReadFile(path)
	return err == nil && linePresent(string(payload), value)
}

func requireRootMode(path string, mode os.FileMode) error {
	return requireOwnerMode(path, "root", "root", mode)
}

func requireOwnerMode(path, ownerName, groupName string, mode os.FileMode) error {
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != mode {
		return fmt.Errorf("%s mode differs", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("cannot inspect %s ownership", path)
	}
	owner, ownerErr := user.LookupId(strconv.Itoa(int(stat.Uid)))
	group, groupErr := user.LookupGroupId(strconv.Itoa(int(stat.Gid)))
	if ownerErr != nil || groupErr != nil || owner.Username != ownerName || group.Name != groupName {
		return fmt.Errorf("%s ownership differs", path)
	}
	return nil
}

func safeIPv4(value string) bool {
	ip := netParseIP(value)
	return ip != nil
}

var netParseIP = func(value string) []byte {
	parts := strings.Split(value, ".")
	if len(parts) != 4 {
		return nil
	}
	result := make([]byte, 4)
	for index, part := range parts {
		number, err := strconv.Atoi(part)
		if err != nil || number < 0 || number > 255 || strconv.Itoa(number) != part {
			return nil
		}
		result[index] = byte(number)
	}
	return result
}

func oneLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}
