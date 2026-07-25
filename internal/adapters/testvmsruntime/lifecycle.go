package testvmsruntime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
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
	if err := child.up(ctx); err != nil {
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
	return nil
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
	cfg.PublicDir = filepath.Join(cfg.PublicDir, "slots", suffix)
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
	diskMiB, err := sizeMiB(runtime.Config.Disk)
	if err != nil {
		return err
	}
	available := runtime.AvailableBytes
	if available == nil {
		available = filesystemAvailableBytes
	}
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
	free, err := available(path)
	if err != nil {
		return fmt.Errorf("inspect test-vms pool capacity: %w", err)
	}
	required := uint64(missing) * uint64(diskMiB) * 1024 * 1024
	if free < required {
		return fmt.Errorf(
			"insufficient test-vms pool capacity: slot needs %d MiB for %d missing VM(s), %d MiB available on %s",
			missing*diskMiB, missing, free/(1024*1024), path,
		)
	}
	return nil
}

func filesystemAvailableBytes(path string) (uint64, error) {
	var stats syscall.Statfs_t
	if err := syscall.Statfs(path, &stats); err != nil {
		return 0, err
	}
	return stats.Bavail * uint64(stats.Bsize), nil
}

func slotNumber(slotID string, maximum int) (int, error) {
	const prefix = "slot-"
	if !strings.HasPrefix(slotID, prefix) {
		return 0, fmt.Errorf("invalid slot id %q", slotID)
	}
	value, err := strconv.Atoi(strings.TrimPrefix(slotID, prefix))
	if err != nil || value < 1 || value > maximum {
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
			if _, err := runtime.incus(ctx, "stop", vm, "--project", runtime.Config.Project,
				"--timeout", "60"); err != nil {
				return err
			}
		}
	}
	return nil
}
