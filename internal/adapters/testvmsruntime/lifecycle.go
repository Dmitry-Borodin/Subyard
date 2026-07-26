package testvmsruntime

import (
	"context"
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

const (
	// VM disks are thin-provisioned; preserve real host headroom instead of summing virtual maxima.
	HostReserveBytes       = uint64(5 * 1024 * 1024 * 1024)
	InitialVMHeadroomBytes = uint64(1024 * 1024 * 1024)
)

func (runtime *Runtime) AcquireSlot(
	ctx context.Context, store LeaseStore, grant LeaseGrant, publicKey string,
) (LeaseGrant, error) {
	runtime.prepareDefaults()
	slot, err := slotNumber(grant.SlotID, runtime.Config.SlotCount)
	if err != nil {
		return grant, err
	}
	child := runtime.slotRuntime(slot, publicKey)
	if err := child.preflightSlotCapacity(ctx); err != nil {
		return grant, err
	}
	if err := child.ensureSlotNetwork(ctx); err != nil {
		return grant, err
	}
	if err := child.provisionPair(ctx); err != nil {
		return grant, err
	}
	if err := store.MarkHeld(grant); err != nil {
		_ = child.stopRetained(ctx)
		return grant, err
	}
	grant.DataUser = child.Config.AgentUser
	for selector := 1; selector <= 2; selector++ {
		vm := child.Config.vm(selector)
		address, err := child.vmIP(ctx, vm)
		if err != nil {
			return grant, err
		}
		key, err := child.guestHostKey(ctx, vm)
		if err != nil {
			return grant, err
		}
		keyType, keyBlob, ok := strings.Cut(key, " ")
		if !ok {
			return grant, errors.New("invalid guest host key")
		}
		grant.Targets = append(grant.Targets, LeaseTarget{
			Selector: selector, Name: vm, Address: address,
			HostKeyType: keyType, HostKeyBlob: keyBlob,
		})
	}
	return grant, nil
}

func (runtime *Runtime) ensureSlotNetwork(ctx context.Context) error {
	cfg := runtime.Config
	if _, err := runtime.incus(ctx, "network", "show", cfg.Network, "--project", "default"); err != nil {
		if _, createErr := runtime.incus(ctx, "network", "create", cfg.Network,
			"ipv4.address=auto", "ipv6.address=none",
			"user.subyard.managed="+managedMarker, "--project", "default"); createErr != nil {
			return createErr
		}
	}
	marker, err := runtime.incus(ctx, "network", "get", cfg.Network,
		"user.subyard.managed", "--project", "default")
	if err != nil {
		return err
	}
	if strings.TrimSpace(marker) != managedMarker {
		return fmt.Errorf("network %q exists without the Subyard marker", cfg.Network)
	}
	return nil
}

func (runtime *Runtime) ReleaseSlot(ctx context.Context, grant LeaseGrant) error {
	runtime.prepareDefaults()
	slot, err := slotNumber(grant.SlotID, runtime.Config.SlotCount)
	if err != nil {
		return err
	}
	return runtime.slotRuntime(slot, "").stopRetained(ctx)
}

func (runtime *Runtime) ReapExpired(ctx context.Context, store LeaseStore) error {
	runtime.prepareDefaults()
	pool, err := store.Status()
	if err != nil {
		return err
	}
	var result error
	for _, slot := range pool.Slots {
		if slot.State != SlotDraining {
			continue
		}
		number, parseErr := slotNumber(slot.SlotID, runtime.Config.SlotCount)
		if parseErr != nil {
			result = errors.Join(result, parseErr)
			continue
		}
		stopErr := runtime.slotRuntime(number, "").stopRetained(ctx)
		if finishErr := store.FinishDrain(slot.SlotID, stopErr); finishErr != nil {
			result = errors.Join(result, finishErr)
		}
		if stopErr != nil {
			result = errors.Join(result, stopErr)
		}
	}
	return result
}

func (runtime *Runtime) DrainAll(ctx context.Context, store LeaseStore, reason string) error {
	if err := store.BeginDrainAll(reason); err != nil {
		return err
	}
	return runtime.ReapExpired(ctx, store)
}

func (runtime *Runtime) RevokeSlot(ctx context.Context, store LeaseStore, slotID string) error {
	if err := store.BeginDrainSlot(slotID, "operator revoke"); err != nil {
		return err
	}
	return runtime.ReapExpired(ctx, store)
}

func (runtime *Runtime) RecoverSlot(ctx context.Context, store LeaseStore, slotID string) error {
	if err := store.BeginRecovery(slotID); err != nil {
		return err
	}
	number, err := slotNumber(slotID, runtime.Config.SlotCount)
	if err != nil {
		return err
	}
	child := runtime.slotRuntime(number, "")
	child.prepareDefaults()
	recoverErr := child.recoverErrored(ctx)
	return store.FinishDrain(slotID, recoverErr)
}

func (runtime *Runtime) ReconcilePool(ctx context.Context, store LeaseStore) error {
	runtime.prepareDefaults()
	current, plannedRetiring, err := store.ResizePlan()
	if err != nil {
		return err
	}
	path := runtime.capacityPath()
	available := runtime.AvailableBytes
	if available == nil {
		available = filesystemAvailableBytes
	}
	free, capacityErr := available(path)
	if capacityErr != nil {
		return fmt.Errorf("inspect test-vms pool capacity: %w", capacityErr)
	}
	fmt.Fprintf(runtime.Stdout,
		"Reconcile test-vms pool: slots %d -> %d, maximum VMs %d, per-VM cpu=%d memory=%s disk=%s, available=%d MiB, host reserve=%d MiB.\n",
		current, runtime.Config.SlotCount, runtime.Config.SlotCount*2,
		runtime.Config.CPU, runtime.Config.Memory, runtime.Config.Disk,
		free/(1024*1024), HostReserveBytes/(1024*1024))
	for _, slot := range plannedRetiring {
		fmt.Fprintf(runtime.Stdout, "  retire %s: delete only its marker-owned stopped pair, project, network, data account and state\n",
			slot.SlotID)
	}
	retiring, err := store.PrepareResize()
	if err != nil {
		return err
	}
	for _, slot := range retiring {
		number, err := slotNumberUnbounded(slot.SlotID)
		if err != nil {
			return err
		}
		if err := runtime.cleanupRetiringSlot(ctx, number); err != nil {
			return fmt.Errorf("cleanup retiring %s: %w", slot.SlotID, err)
		}
	}
	return store.CommitResize()
}

func (runtime *Runtime) cleanupRetiringSlot(ctx context.Context, slot int) error {
	child := runtime.slotRuntime(slot, "")
	child.prepareDefaults()
	if err := child.cleanupManaged(ctx, true); err != nil {
		return err
	}
	if _, err := child.incus(ctx, "network", "show", child.Config.Network,
		"--project", "default"); err == nil {
		marker, err := child.incus(ctx, "network", "get", child.Config.Network,
			"user.subyard.managed", "--project", "default")
		if err != nil {
			return err
		}
		if strings.TrimSpace(marker) != managedMarker {
			return fmt.Errorf("network %q is not Subyard-managed", child.Config.Network)
		}
		if _, err := child.incus(ctx, "network", "delete", child.Config.Network,
			"--project", "default"); err != nil {
			return err
		}
	}
	if _, err := os.Stat(child.Config.StateDir); err == nil {
		marker, err := os.ReadFile(child.Config.stateMarker())
		if err != nil || strings.TrimSpace(string(marker)) != managedMarker {
			return fmt.Errorf("slot state %q is not exactly Subyard-managed",
				child.Config.StateDir)
		}
		if err := os.RemoveAll(child.Config.StateDir); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if _, err := user.Lookup(child.Config.AgentUser); err == nil {
		child.killAgentSessions(ctx)
		if _, _, err := child.Runner.Run(ctx, "userdel",
			[]string{"--remove", child.Config.AgentUser}, nil, nil); err != nil {
			return err
		}
	}
	return nil
}

func (runtime *Runtime) recoverErrored(ctx context.Context) error {
	if err := runtime.restrictAgentAccess("operator-recovery"); err != nil {
		return err
	}
	if !runtime.projectExists(ctx) {
		return nil
	}
	if err := runtime.requireProjectMarker(ctx); err != nil {
		return err
	}
	for selector := 1; selector <= 2; selector++ {
		vm := runtime.Config.vm(selector)
		if !runtime.vmExists(ctx, vm) {
			continue
		}
		if err := runtime.requireVMMarker(ctx, vm); err != nil {
			return err
		}
		state, err := runtime.incus(ctx, "list", vm, "--project", runtime.Config.Project,
			"-f", "csv", "-c", "s")
		if err != nil {
			return err
		}
		if strings.TrimSpace(state) == "ERROR" {
			if _, err := runtime.incus(ctx, "delete", "--force", vm,
				"--project", runtime.Config.Project); err != nil {
				return err
			}
		}
	}
	// Recovery is complete only after the same fencing and stop sequence used by release. A
	// transient guest-agent or stop failure therefore keeps the slot quarantined and retryable.
	return runtime.stopRetained(ctx)
}

func (runtime *Runtime) prepareDefaults() {
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
}

func (runtime *Runtime) slotRuntime(slot int, publicKey string) *Runtime {
	cfg := runtime.Config
	suffix := strconv.Itoa(slot)
	cfg.Project = cfg.Project + "-slot-" + suffix
	cfg.Network = cfg.Prefix + "-net-" + suffix
	cfg.StateDir = filepath.Join(cfg.StateDir, "slots", suffix)
	cfg.AgentUser = "subyard-e2e-slot-" + suffix
	cfg.AgentHome = filepath.Join("/var/lib/subyard/e2e-slots", suffix)
	cfg.AgentAuthorizedKeys = filepath.Join(cfg.AgentHome, ".ssh", "authorized_keys")
	cfg.AgentPublicKey = publicKey
	return &Runtime{
		Config: cfg, ConfigPath: runtime.ConfigPath, Runner: runtime.Runner,
		Stdout: runtime.Stdout, Stderr: runtime.Stderr, Now: runtime.Now, Sleep: runtime.Sleep,
		AvailableBytes: runtime.AvailableBytes, ExecutablePath: runtime.ExecutablePath,
	}
}

func (runtime *Runtime) preflightSlotCapacity(ctx context.Context) error {
	missing := 0
	for selector := 1; selector <= 2; selector++ {
		if !runtime.vmExists(ctx, runtime.Config.vm(selector)) {
			missing++
		}
	}
	if missing == 0 {
		return nil
	}
	available := runtime.AvailableBytes
	if available == nil {
		available = filesystemAvailableBytes
	}
	path := runtime.capacityPath()
	free, err := available(path)
	if err != nil {
		return fmt.Errorf("inspect test-vms pool capacity: %w", err)
	}
	required := HostReserveBytes + uint64(missing)*InitialVMHeadroomBytes
	if free < required {
		return fmt.Errorf(
			"insufficient test-vms pool capacity: %d missing VM(s) need %d MiB initial headroom plus %d MiB host reserve, %d MiB available on %s",
			missing, missing*int(InitialVMHeadroomBytes/(1024*1024)),
			HostReserveBytes/(1024*1024), free/(1024*1024), path,
		)
	}
	return nil
}

func (runtime *Runtime) capacityPath() string {
	path := runtime.Config.StateDir
	for {
		if _, err := os.Stat(path); err == nil {
			break
		}
		parent := filepath.Dir(path)
		if parent == path {
			path = "/"
			break
		}
		path = parent
	}
	return path
}

func filesystemAvailableBytes(path string) (uint64, error) {
	var stats syscall.Statfs_t
	if err := syscall.Statfs(path, &stats); err != nil {
		return 0, err
	}
	return stats.Bavail * uint64(stats.Bsize), nil
}

func slotNumber(slotID string, maximum int) (int, error) {
	value, err := slotNumberUnbounded(slotID)
	if err != nil || value > maximum {
		return 0, fmt.Errorf("invalid slot id %q", slotID)
	}
	return value, nil
}

func slotNumberUnbounded(slotID string) (int, error) {
	const prefix = "slot-"
	if !strings.HasPrefix(slotID, prefix) {
		return 0, fmt.Errorf("invalid slot id %q", slotID)
	}
	value, err := strconv.Atoi(strings.TrimPrefix(slotID, prefix))
	if err != nil || value < 1 {
		return 0, fmt.Errorf("invalid slot id %q", slotID)
	}
	return value, nil
}

func (runtime *Runtime) stopRetained(ctx context.Context) error {
	if err := runtime.restrictAgentAccess("released"); err != nil {
		return err
	}
	if !runtime.projectExists(ctx) {
		return nil
	}
	if err := runtime.requireProjectMarker(ctx); err != nil {
		return err
	}
	for selector := 1; selector <= 2; selector++ {
		vm := runtime.Config.vm(selector)
		if !runtime.vmExists(ctx, vm) {
			continue
		}
		state, err := runtime.incus(ctx, "list", vm, "--project", runtime.Config.Project,
			"-f", "csv", "-c", "s")
		if err != nil {
			return err
		}
		if strings.TrimSpace(state) == "RUNNING" {
			if err := runtime.installManagedGuestKeys(ctx, vm); err != nil {
				return err
			}
			if err := runtime.stopRunningVM(ctx, vm); err != nil {
				return err
			}
		} else if strings.TrimSpace(state) != "STOPPED" {
			return fmt.Errorf("%s cannot be fenced from state %q", vm, strings.TrimSpace(state))
		}
	}
	return nil
}

func (runtime *Runtime) stopRunningVM(ctx context.Context, vm string) error {
	_, stopErr := runtime.incus(ctx, "stop", vm, "--project", runtime.Config.Project,
		"--timeout", "60")
	state, stateErr := runtime.incus(ctx, "list", vm, "--project",
		runtime.Config.Project, "-f", "csv", "-c", "s")
	if stateErr != nil {
		return errors.Join(stopErr, stateErr)
	}
	if strings.TrimSpace(state) != "STOPPED" {
		return errors.Join(stopErr,
			fmt.Errorf("%s remained in state %q after stop", vm, strings.TrimSpace(state)))
	}
	return nil
}
