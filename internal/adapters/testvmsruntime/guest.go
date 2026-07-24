package testvmsruntime

import (
	"context"
	"fmt"
	"os"
	"strings"
)

func (runtime *Runtime) cloudConfig() string {
	publicKey, _ := os.ReadFile(runtime.Config.keyPath() + ".pub")
	workerKey, _ := normalizedPublicKey(string(publicKey))
	var agentLine string
	if runtime.Config.AgentPublicKey != "" {
		agentKey, _ := normalizedPublicKey(runtime.Config.AgentPublicKey)
		agentLine = "      - " + agentKey + " " + agentKeyMarker + "\n"
	}
	return `#cloud-config
users:
  - default
  - name: dev
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: x
    ssh_authorized_keys:
      - ` + workerKey + "\n" + agentLine + `ssh_pwauth: false
package_update: true
packages: [openssh-server, sudo, git, curl, jq, ripgrep, golang-go, shellcheck]
runcmd:
  - [systemctl, enable, --now, ssh]
`
}

func (runtime *Runtime) waitAgent(ctx context.Context, vm string) error {
	if err := runtime.waitFor(ctx, "waiting for "+vm+" Incus agent", func() error {
		_, err := runtime.guest(ctx, vm, nil, "true")
		return err
	}); err != nil {
		return err
	}
	fmt.Fprintf(runtime.Stdout, "  [ ok ] %s Incus agent is ready\n", vm)
	if err := runtime.progress(ctx, "waiting for "+vm+" cloud-init", func() error {
		_, err := runtime.guest(ctx, vm, nil, "timeout",
			fmt.Sprintf("%d", int(runtime.Config.BootTimeout.Seconds())),
			"cloud-init", "status", "--wait")
		return err
	}); err != nil {
		return err
	}
	if _, err := runtime.guest(ctx, vm, nil, "usermod", "--password", "x", "dev"); err != nil {
		return err
	}
	account, err := runtime.guest(ctx, vm, nil, "passwd", "--status", "dev")
	if err != nil {
		return err
	}
	if !strings.HasPrefix(account, "dev P ") {
		return fmt.Errorf("%s dev account did not become key-login capable", vm)
	}
	const sshPolicy = `directory=/etc/ssh/sshd_config.d
target="$directory/00-subyard-e2e.conf"
install -d -m 0755 "$directory"
temp="$(mktemp "$directory/.subyard-e2e.XXXXXX")"
trap 'rm -f "$temp"' EXIT
printf "PasswordAuthentication no\nKbdInteractiveAuthentication no\n" > "$temp"
chmod 0644 "$temp"
mv -f "$temp" "$target"
trap - EXIT
sshd -t
systemctl reload ssh`
	if _, err := runtime.guest(ctx, vm, nil, "sh", "-eu", "-c", sshPolicy); err != nil {
		return err
	}
	sshdConfig, err := runtime.guest(ctx, vm, nil, "sshd", "-T")
	if err != nil {
		return err
	}
	if !linePresent(sshdConfig, "passwordauthentication no") {
		return fmt.Errorf("%s SSH password authentication is not disabled", vm)
	}
	if _, err := runtime.guest(ctx, vm, nil, "systemctl", "is-active", "--quiet", "ssh"); err != nil {
		return err
	}
	fmt.Fprintf(runtime.Stdout, "  [ ok ] %s cloud-init and SSH service are ready\n", vm)
	return nil
}

func (runtime *Runtime) ensureGuestTools(ctx context.Context, vm string) error {
	const check = `command -v git >/dev/null &&
command -v curl >/dev/null &&
command -v jq >/dev/null &&
command -v rg >/dev/null &&
command -v go >/dev/null &&
command -v shellcheck >/dev/null`
	if _, err := runtime.guest(ctx, vm, nil, "sh", "-c", check); err == nil {
		return nil
	}
	if err := runtime.progress(ctx, "installing test toolchain in "+vm, func() error {
		const install = `export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl jq ripgrep golang-go shellcheck`
		_, err := runtime.guest(ctx, vm, nil, "sh", "-eu", "-c", install)
		return err
	}); err != nil {
		return err
	}
	fmt.Fprintf(runtime.Stdout, "  [ ok ] %s test toolchain is ready\n", vm)
	return nil
}

func (runtime *Runtime) installManagedGuestKeys(ctx context.Context, vm string) error {
	workerPayload, err := os.ReadFile(runtime.Config.keyPath() + ".pub")
	if err != nil {
		return err
	}
	workerKey, err := normalizedPublicKey(string(workerPayload))
	if err != nil {
		return fmt.Errorf("%s worker identity is invalid", vm)
	}
	agentKey := ""
	if runtime.Config.AgentPublicKey != "" {
		agentKey, err = normalizedPublicKey(runtime.Config.AgentPublicKey)
		if err != nil {
			return err
		}
	}
	revokedKey := ""
	if payload, readErr := os.ReadFile(runtime.Config.revokedKey()); readErr == nil {
		revokedKey, _ = normalizedPublicKey(string(payload))
	}
	const reconcile = `home=/home/dev
ssh_dir="$home/.ssh"
authorized="$ssh_dir/authorized_keys"
install -d -m 0700 -o dev -g dev "$ssh_dir"
touch "$authorized"
temp="$(mktemp "$ssh_dir/.authorized-keys.XXXXXX")"
revoked_type="${REVOKED_WORKER_KEY%% *}"
revoked_blob="${REVOKED_WORKER_KEY#* }"
awk -v agent_marker="$AGENT_KEY_MARKER" \
    -v revoked_type="$revoked_type" -v revoked_blob="$revoked_blob" '
  $NF == "subyard-test-vms" || $NF == "subyard-managed-e2e-worker" || $NF == agent_marker { next }
  {
    drop = 0
    if (revoked_type != "" && revoked_blob != "") {
      for (i = 1; i < NF; i++) {
        if ($i == revoked_type && $(i + 1) == revoked_blob) drop = 1
      }
    }
    if (!drop) print
  }
' "$authorized" > "$temp"
printf "%s subyard-managed-e2e-worker\n" "$WORKER_KEY" >> "$temp"
[ -z "$AGENT_KEY" ] || printf "%s %s\n" "$AGENT_KEY" "$AGENT_KEY_MARKER" >> "$temp"
chmod 0600 "$temp"
chown dev:dev "$temp"
mv -f "$temp" "$authorized"`
	_, err = runtime.guest(ctx, vm, []string{
		"WORKER_KEY=" + workerKey,
		"AGENT_KEY=" + agentKey,
		"REVOKED_WORKER_KEY=" + revokedKey,
		"AGENT_KEY_MARKER=" + agentKeyMarker,
	}, "sh", "-eu", "-c", reconcile)
	return err
}

func (runtime *Runtime) recordHostKey(ctx context.Context, vm string) error {
	address, err := runtime.vmIP(ctx, vm)
	if err != nil {
		return fmt.Errorf("%s has no IPv4 address on its default-route interface: %w", vm, err)
	}
	var scanned string
	if err := runtime.waitFor(ctx, "waiting for "+vm+" SSH host key ("+address+")", func() error {
		stdout, _, runErr := runtime.Runner.Run(ctx, "ssh-keyscan",
			[]string{"-T", "3", address}, nil, nil)
		if runErr == nil && len(strings.TrimSpace(string(stdout))) == 0 {
			runErr = fmt.Errorf("empty host key")
		}
		if runErr == nil {
			scanned = string(stdout)
		}
		return runErr
	}); err != nil {
		return err
	}
	file, err := os.OpenFile(runtime.Config.knownHosts(), os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, writeErr := fmt.Fprintln(file, strings.TrimSpace(scanned))
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	fmt.Fprintf(runtime.Stdout, "  [ ok ] %s SSH host key recorded\n", vm)
	return nil
}

func (runtime *Runtime) sshSmoke(ctx context.Context, vm string) error {
	address, err := runtime.vmIP(ctx, vm)
	if err != nil {
		return err
	}
	arguments := []string{
		"-i", runtime.Config.keyPath(), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + runtime.Config.knownHosts(),
		"-o", "ConnectTimeout=8", "dev@" + address, "--", "sudo", "-n", "true",
	}
	if err := runtime.waitFor(ctx, "verifying "+vm+" SSH and passwordless sudo", func() error {
		_, _, runErr := runtime.Runner.Run(ctx, "ssh", arguments, nil, nil)
		return runErr
	}); err != nil {
		return err
	}
	fmt.Fprintf(runtime.Stdout, "  [ ok ] %s SSH and passwordless sudo verified\n", vm)
	return nil
}

func (runtime *Runtime) guestPeerKey(ctx context.Context, vm string) (string, error) {
	const ensure = `install -d -m 0700 -o dev -g dev /home/dev/.ssh
if [ ! -s /home/dev/.ssh/id_ed25519 ] || [ ! -s /home/dev/.ssh/id_ed25519.pub ]; then
  rm -f /home/dev/.ssh/id_ed25519 /home/dev/.ssh/id_ed25519.pub
  runuser -u dev -- ssh-keygen -q -t ed25519 -N "" -C subyard-e2e-peer \
    -f /home/dev/.ssh/id_ed25519
fi
awk '$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }' \
  /home/dev/.ssh/id_ed25519.pub`
	value, err := runtime.guest(ctx, vm, nil, "sh", "-eu", "-c", ensure)
	if err != nil {
		return "", err
	}
	return validatePublicKey(vm+" peer identity", value)
}

func (runtime *Runtime) guestHostKey(ctx context.Context, vm string) (string, error) {
	value, err := runtime.guest(ctx, vm, nil, "awk",
		`$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2; exit }`,
		"/etc/ssh/ssh_host_ed25519_key.pub")
	if err != nil {
		return "", err
	}
	return validatePublicKey(vm+" host identity", value)
}

func (runtime *Runtime) installGuestPeerTrust(
	ctx context.Context,
	target, peerIP, peerKey, peerHostKey string,
) error {
	const install = `home=/home/dev
ssh_dir="$home/.ssh"
authorized="$ssh_dir/authorized_keys"
known="$ssh_dir/known_hosts"
temp="$(mktemp "$ssh_dir/.known-hosts.XXXXXX")"
install -d -m 0700 -o dev -g dev "$ssh_dir"
touch "$authorized" "$known"
grep -qxF "$PEER_PUBLIC_KEY" "$authorized" || printf "%s\n" "$PEER_PUBLIC_KEY" >> "$authorized"
awk -v ip="$PEER_IP" '$1 != ip { print }' "$known" > "$temp"
printf "%s %s\n" "$PEER_IP" "$PEER_HOST_KEY" >> "$temp"
chmod 0600 "$authorized" "$temp"
chown dev:dev "$authorized" "$temp"
mv -f "$temp" "$known"`
	_, err := runtime.guest(ctx, target, []string{
		"PEER_IP=" + peerIP, "PEER_PUBLIC_KEY=" + peerKey, "PEER_HOST_KEY=" + peerHostKey,
	}, "sh", "-eu", "-c", install)
	return err
}

func (runtime *Runtime) peerSSHSmoke(ctx context.Context, source, peerIP string) error {
	_, err := runtime.guest(ctx, source, nil, "runuser", "-u", "dev", "--",
		"ssh", "-n", "-i", "/home/dev/.ssh/id_ed25519",
		"-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=yes",
		"-o", "UserKnownHostsFile=/home/dev/.ssh/known_hosts",
		"-o", "ConnectTimeout=8", "dev@"+peerIP, "--", "sudo", "-n", "true")
	return err
}

func (runtime *Runtime) ensurePeerTrust(ctx context.Context) error {
	cfg := runtime.Config
	vm1, vm2 := cfg.vm(1), cfg.vm(2)
	ip1, err := runtime.vmIP(ctx, vm1)
	if err != nil {
		return err
	}
	ip2, err := runtime.vmIP(ctx, vm2)
	if err != nil {
		return err
	}
	key1, err := runtime.guestPeerKey(ctx, vm1)
	if err != nil {
		return err
	}
	key2, err := runtime.guestPeerKey(ctx, vm2)
	if err != nil {
		return err
	}
	host1, err := runtime.guestHostKey(ctx, vm1)
	if err != nil {
		return err
	}
	host2, err := runtime.guestHostKey(ctx, vm2)
	if err != nil {
		return err
	}
	if err := runtime.installGuestPeerTrust(ctx, vm1, ip2, key2, host2); err != nil {
		return err
	}
	if err := runtime.installGuestPeerTrust(ctx, vm2, ip1, key1, host1); err != nil {
		return err
	}
	fmt.Fprintln(runtime.Stdout, "  [ .. ] verifying mutual VM SSH trust")
	if err := runtime.peerSSHSmoke(ctx, vm1, ip2); err != nil {
		return err
	}
	if err := runtime.peerSSHSmoke(ctx, vm2, ip1); err != nil {
		return err
	}
	fmt.Fprintln(runtime.Stdout,
		"  [ ok ] both VMs trust each other's synthetic identity and pinned host key")
	return nil
}

func validatePublicKey(label, value string) (string, error) {
	key, err := normalizedPublicKey(value)
	if err != nil || !strings.HasPrefix(key, "ssh-ed25519 ") {
		return "", fmt.Errorf("%s did not expose one valid Ed25519 public key", label)
	}
	return key, nil
}
