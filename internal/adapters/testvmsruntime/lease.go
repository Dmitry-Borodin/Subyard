package testvmsruntime

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	LeaseSchemaVersion = 1
	LeaseTTL           = 10 * time.Minute
)

var (
	ErrCorruptLeaseState     = errors.New("corrupt lease state")
	ErrUnsupportedLeaseState = errors.New("unsupported lease state")
)

type SlotState string

const (
	SlotAvailable    SlotState = "available"
	SlotProvisioning SlotState = "provisioning"
	SlotHeld         SlotState = "held"
	SlotDraining     SlotState = "draining"
	SlotQuarantined  SlotState = "quarantined"
	SlotUnavailable  SlotState = "unavailable"
)

type LeaseSlot struct {
	SlotID                string    `json:"slot_id"`
	ResourceGeneration    uint64    `json:"resource_generation"`
	LeaseEpoch            uint64    `json:"lease_epoch"`
	State                 SlotState `json:"state"`
	ClientID              string    `json:"client_id,omitempty"`
	ControllerFingerprint string    `json:"controller_fingerprint,omitempty"`
	DisplayLabel          string    `json:"display_label,omitempty"`
	Purpose               string    `json:"purpose,omitempty"`
	LeaseID               string    `json:"lease_id,omitempty"`
	CapabilityHash        string    `json:"capability_hash,omitempty"`
	AcquiredAt            time.Time `json:"acquired_at,omitempty"`
	ProvisioningStartedAt time.Time `json:"provisioning_started_at,omitempty"`
	ReadyAt               time.Time `json:"ready_at,omitempty"`
	LastHeartbeatAt       time.Time `json:"last_heartbeat_at,omitempty"`
	ExpiresAt             time.Time `json:"expires_at,omitempty"`
	FailureReason         string    `json:"failure_reason,omitempty"`
}

type LeasePool struct {
	SchemaVersion int         `json:"schema_version"`
	ResourceType  string      `json:"resource_type"`
	ResourceID    string      `json:"resource_id"`
	Slots         []LeaseSlot `json:"slots"`
}

type LeaseGrant struct {
	SlotID     string        `json:"slot_id"`
	LeaseID    string        `json:"lease_id"`
	Capability string        `json:"capability"`
	LeaseEpoch uint64        `json:"lease_epoch"`
	ExpiresAt  time.Time     `json:"expires_at"`
	DataUser   string        `json:"data_user,omitempty"`
	Targets    []LeaseTarget `json:"targets,omitempty"`
}

type LeaseTarget struct {
	Selector    int    `json:"selector"`
	Name        string `json:"name"`
	Address     string `json:"address"`
	HostKeyType string `json:"host_key_type"`
	HostKeyBlob string `json:"host_key_blob"`
}

type LeaseStore struct {
	Path      string
	SlotCount int
	Now       func() time.Time
}

func (store LeaseStore) now() time.Time {
	if store.Now != nil {
		return store.Now().UTC()
	}
	return time.Now().UTC()
}

func (store LeaseStore) Status() (LeasePool, error) {
	var result LeasePool
	err := store.withLock(true, func(pool *LeasePool) error {
		result = *pool
		result.Slots = append([]LeaseSlot(nil), pool.Slots...)
		return nil
	})
	return result, err
}

func (store LeaseStore) Acquire(clientID, fingerprint, label, purpose string) (LeaseGrant, error) {
	if !safeLeaseText(clientID, 96) || clientID == "" {
		return LeaseGrant{}, errors.New("invalid client_id")
	}
	if !safeLeaseText(fingerprint, 128) || fingerprint == "" {
		return LeaseGrant{}, errors.New("invalid controller fingerprint")
	}
	if !safeLeaseText(label, 80) || !safeLeaseText(purpose, 160) {
		return LeaseGrant{}, errors.New("invalid display metadata")
	}
	var grant LeaseGrant
	err := store.withLock(true, func(pool *LeasePool) error {
		now := store.now()
		expireStale(pool, now)
		for index := range pool.Slots {
			slot := &pool.Slots[index]
			if slot.State != SlotAvailable {
				continue
			}
			leaseID, err := randomToken(16)
			if err != nil {
				return err
			}
			capability, err := randomToken(32)
			if err != nil {
				return err
			}
			slot.LeaseEpoch++
			slot.State = SlotProvisioning
			slot.ClientID = clientID
			slot.ControllerFingerprint = fingerprint
			slot.DisplayLabel = label
			slot.Purpose = purpose
			slot.LeaseID = leaseID
			slot.CapabilityHash = capabilityDigest(capability)
			slot.AcquiredAt = now
			slot.ProvisioningStartedAt = now
			slot.LastHeartbeatAt = now
			slot.ExpiresAt = now.Add(LeaseTTL)
			slot.FailureReason = ""
			grant = LeaseGrant{
				SlotID: slot.SlotID, LeaseID: leaseID, Capability: capability,
				LeaseEpoch: slot.LeaseEpoch, ExpiresAt: slot.ExpiresAt,
			}
			return nil
		}
		return errors.New("busy")
	})
	return grant, err
}

func (store LeaseStore) MarkHeld(grant LeaseGrant) error {
	return store.mutateOwned(grant, func(slot *LeaseSlot, now time.Time) error {
		if slot.State != SlotProvisioning {
			return fmt.Errorf("slot is %s, not provisioning", slot.State)
		}
		slot.State = SlotHeld
		slot.ReadyAt = now
		slot.LastHeartbeatAt = now
		slot.ExpiresAt = now.Add(LeaseTTL)
		return nil
	})
}

func (store LeaseStore) Renew(grant LeaseGrant) (time.Time, error) {
	var expires time.Time
	err := store.mutateOwned(grant, func(slot *LeaseSlot, now time.Time) error {
		if slot.State != SlotHeld && slot.State != SlotProvisioning {
			return errors.New("lease lost")
		}
		slot.LastHeartbeatAt = now
		slot.ExpiresAt = now.Add(LeaseTTL)
		expires = slot.ExpiresAt
		return nil
	})
	return expires, err
}

func (store LeaseStore) BeginDrain(grant LeaseGrant) error {
	return store.mutateOwned(grant, func(slot *LeaseSlot, _ time.Time) error {
		if slot.State == SlotDraining {
			return nil
		}
		if slot.State != SlotHeld && slot.State != SlotProvisioning {
			return errors.New("lease lost")
		}
		slot.State = SlotDraining
		return nil
	})
}

func (store LeaseStore) FinishDrain(slotID string, stopErr error) error {
	return store.withLock(true, func(pool *LeasePool) error {
		slot, err := findSlot(pool, slotID)
		if err != nil {
			return err
		}
		if slot.State == SlotAvailable && stopErr == nil {
			// A concurrent release/revoke may have completed the same fencing sequence first.
			return nil
		}
		if slot.State != SlotDraining {
			return fmt.Errorf("slot %s is not draining", slotID)
		}
		if stopErr != nil {
			slot.State = SlotQuarantined
			slot.FailureReason = boundedReason(stopErr.Error())
			return nil
		}
		clearLease(slot)
		slot.State = SlotAvailable
		return nil
	})
}

func (store LeaseStore) BeginDrainAll(reason string) error {
	return store.withLock(true, func(pool *LeasePool) error {
		for index := range pool.Slots {
			slot := &pool.Slots[index]
			if slot.State != SlotHeld && slot.State != SlotProvisioning {
				continue
			}
			slot.State = SlotDraining
			slot.FailureReason = boundedReason(reason)
		}
		return nil
	})
}

func (store LeaseStore) BeginDrainSlot(slotID, reason string) error {
	return store.withLock(true, func(pool *LeasePool) error {
		slot, err := findSlot(pool, slotID)
		if err != nil {
			return err
		}
		switch slot.State {
		case SlotAvailable:
			return nil
		case SlotHeld, SlotProvisioning:
			slot.State = SlotDraining
			slot.FailureReason = boundedReason(reason)
			return nil
		case SlotDraining:
			return nil
		default:
			return fmt.Errorf("slot %s is %s", slotID, slot.State)
		}
	})
}

func (store LeaseStore) BeginRecovery(slotID string) error {
	err := store.withLock(true, func(pool *LeasePool) error {
		slot, err := findSlot(pool, slotID)
		if err != nil {
			return err
		}
		if slot.State != SlotQuarantined {
			return fmt.Errorf("slot %s is %s, not quarantined", slotID, slot.State)
		}
		slot.State = SlotDraining
		slot.FailureReason = "operator recovery"
		return nil
	})
	if !errors.Is(err, ErrCorruptLeaseState) && !errors.Is(err, ErrUnsupportedLeaseState) {
		return err
	}
	return store.rebuildCorruptPoolForRecovery(slotID)
}

func (store LeaseStore) Quarantine(grant LeaseGrant, cause error) error {
	return store.mutateOwned(grant, func(slot *LeaseSlot, _ time.Time) error {
		slot.State = SlotQuarantined
		slot.FailureReason = boundedReason(cause.Error())
		return nil
	})
}

func (store LeaseStore) mutateOwned(
	grant LeaseGrant, mutate func(*LeaseSlot, time.Time) error,
) error {
	return store.withLock(true, func(pool *LeasePool) error {
		slot, err := findSlot(pool, grant.SlotID)
		if err != nil {
			return err
		}
		if slot.LeaseID != grant.LeaseID || slot.LeaseEpoch != grant.LeaseEpoch ||
			slot.CapabilityHash == "" || slot.CapabilityHash != capabilityDigest(grant.Capability) {
			return errors.New("lease lost")
		}
		return mutate(slot, store.now())
	})
}

func (store LeaseStore) withLock(write bool, operation func(*LeasePool) error) error {
	if store.SlotCount < 1 {
		return errors.New("slot count must be positive")
	}
	return store.withPoolLock(func(pool *LeasePool) error {
		if err := reconcileSlotCount(pool, store.SlotCount); err != nil {
			return err
		}
		before, _ := json.Marshal(*pool)
		expireStale(pool, store.now())
		if err := operation(pool); err != nil {
			return err
		}
		after, _ := json.Marshal(*pool)
		if write || string(before) != string(after) {
			return writeJSONAtomic(store.Path, *pool)
		}
		return nil
	})
}

func (store LeaseStore) withPoolLock(operation func(*LeasePool) error) error {
	if err := os.MkdirAll(filepath.Dir(store.Path), 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(store.Path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN) //nolint:errcheck
	pool, err := store.load()
	if err != nil {
		return err
	}
	return operation(&pool)
}

func (store LeaseStore) load() (LeasePool, error) {
	pool := LeasePool{
		SchemaVersion: LeaseSchemaVersion, ResourceType: "agent-e2e",
		ResourceID: "test-vms",
	}
	payload, err := os.ReadFile(store.Path)
	if os.IsNotExist(err) {
		return pool, nil
	}
	if err != nil {
		return pool, err
	}
	if err := json.Unmarshal(payload, &pool); err != nil {
		return pool, fmt.Errorf("%w: %v", ErrCorruptLeaseState, err)
	}
	if pool.SchemaVersion != LeaseSchemaVersion || pool.ResourceType != "agent-e2e" ||
		pool.ResourceID != "test-vms" {
		return pool, ErrUnsupportedLeaseState
	}
	return pool, nil
}

func (store LeaseStore) rebuildCorruptPoolForRecovery(slotID string) error {
	number, err := slotNumber(slotID, store.SlotCount)
	if err != nil {
		return err
	}
	return store.withRawLock(func() error {
		if _, loadErr := store.load(); !errors.Is(loadErr, ErrCorruptLeaseState) &&
			!errors.Is(loadErr, ErrUnsupportedLeaseState) {
			if loadErr == nil {
				return errors.New("lease state changed while preparing recovery")
			}
			return loadErr
		}
		backup := fmt.Sprintf("%s.corrupt-%d", store.Path, store.now().UnixNano())
		if err := os.Rename(store.Path, backup); err != nil {
			return fmt.Errorf("preserve corrupt lease state: %w", err)
		}
		pool := LeasePool{
			SchemaVersion: LeaseSchemaVersion, ResourceType: "agent-e2e",
			ResourceID: "test-vms",
		}
		for index := 1; index <= store.SlotCount; index++ {
			state := SlotQuarantined
			reason := "lease state recovery required"
			if index == number {
				state = SlotDraining
				reason = "operator recovery"
			}
			pool.Slots = append(pool.Slots, LeaseSlot{
				SlotID: fmt.Sprintf("slot-%03d", index), ResourceGeneration: 1,
				State: state, FailureReason: reason,
			})
		}
		return writeJSONAtomic(store.Path, pool)
	})
}

func (store LeaseStore) withRawLock(operation func() error) error {
	if err := os.MkdirAll(filepath.Dir(store.Path), 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(store.Path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN) //nolint:errcheck
	return operation()
}

func reconcileSlotCount(pool *LeasePool, count int) error {
	sort.Slice(pool.Slots, func(i, j int) bool { return pool.Slots[i].SlotID < pool.Slots[j].SlotID })
	for len(pool.Slots) < count {
		index := len(pool.Slots) + 1
		pool.Slots = append(pool.Slots, LeaseSlot{
			SlotID: fmt.Sprintf("slot-%03d", index), ResourceGeneration: 1,
			State: SlotAvailable,
		})
	}
	if len(pool.Slots) > count {
		for _, slot := range pool.Slots[count:] {
			if slot.State != SlotAvailable {
				return fmt.Errorf("cannot shrink pool: retiring %s is %s", slot.SlotID, slot.State)
			}
		}
		return errors.New("pool shrink requires physical reconciliation")
	}
	return nil
}

func (store LeaseStore) PrepareResize() ([]LeaseSlot, error) {
	var retiring []LeaseSlot
	err := store.withPoolLock(func(pool *LeasePool) error {
		if len(pool.Slots) < store.SlotCount {
			if err := reconcileSlotCount(pool, store.SlotCount); err != nil {
				return err
			}
			return writeJSONAtomic(store.Path, *pool)
		}
		if len(pool.Slots) == store.SlotCount {
			return nil
		}
		for index := store.SlotCount; index < len(pool.Slots); index++ {
			slot := &pool.Slots[index]
			if slot.State == SlotDraining && slot.FailureReason == "pool resize" {
				continue
			}
			if slot.State != SlotAvailable {
				return fmt.Errorf("cannot shrink pool: retiring %s is %s", slot.SlotID, slot.State)
			}
		}
		for index := store.SlotCount; index < len(pool.Slots); index++ {
			slot := &pool.Slots[index]
			slot.State = SlotDraining
			slot.FailureReason = "pool resize"
			retiring = append(retiring, *slot)
		}
		return writeJSONAtomic(store.Path, *pool)
	})
	return retiring, err
}

func (store LeaseStore) ResizePlan() (int, []LeaseSlot, error) {
	current := 0
	var retiring []LeaseSlot
	err := store.withPoolLock(func(pool *LeasePool) error {
		current = len(pool.Slots)
		if current <= store.SlotCount {
			return nil
		}
		for index := store.SlotCount; index < current; index++ {
			slot := pool.Slots[index]
			if slot.State != SlotAvailable &&
				(slot.State != SlotDraining || slot.FailureReason != "pool resize") {
				return fmt.Errorf("cannot shrink pool: retiring %s is %s",
					slot.SlotID, slot.State)
			}
			retiring = append(retiring, slot)
		}
		return nil
	})
	return current, retiring, err
}

func (store LeaseStore) CommitResize() error {
	return store.withPoolLock(func(pool *LeasePool) error {
		if len(pool.Slots) < store.SlotCount {
			return errors.New("pool resize was not prepared")
		}
		for index := store.SlotCount; index < len(pool.Slots); index++ {
			slot := pool.Slots[index]
			if slot.State != SlotDraining || slot.FailureReason != "pool resize" {
				return fmt.Errorf("retiring %s is not fenced for pool resize", slot.SlotID)
			}
		}
		pool.Slots = pool.Slots[:store.SlotCount]
		return writeJSONAtomic(store.Path, *pool)
	})
}

func expireStale(pool *LeasePool, now time.Time) {
	for index := range pool.Slots {
		slot := &pool.Slots[index]
		if (slot.State == SlotHeld || slot.State == SlotProvisioning) &&
			!slot.ExpiresAt.IsZero() && !now.Before(slot.ExpiresAt) {
			slot.State = SlotDraining
			slot.FailureReason = "heartbeat expired; cleanup required"
		}
	}
}

func findSlot(pool *LeasePool, id string) (*LeaseSlot, error) {
	for index := range pool.Slots {
		if pool.Slots[index].SlotID == id {
			return &pool.Slots[index], nil
		}
	}
	return nil, fmt.Errorf("unknown slot %q", id)
}

func clearLease(slot *LeaseSlot) {
	slot.ClientID = ""
	slot.ControllerFingerprint = ""
	slot.DisplayLabel = ""
	slot.Purpose = ""
	slot.LeaseID = ""
	slot.CapabilityHash = ""
	slot.AcquiredAt = time.Time{}
	slot.ProvisioningStartedAt = time.Time{}
	slot.ReadyAt = time.Time{}
	slot.LastHeartbeatAt = time.Time{}
	slot.ExpiresAt = time.Time{}
	slot.FailureReason = ""
}

func randomToken(bytes int) (string, error) {
	payload := make([]byte, bytes)
	if _, err := rand.Read(payload); err != nil {
		return "", err
	}
	return hex.EncodeToString(payload), nil
}

func capabilityDigest(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

func safeLeaseText(value string, maximum int) bool {
	return len(value) <= maximum && !strings.ContainsAny(value, "\x00\r\n\t")
}

func boundedReason(value string) string {
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	if len(value) > 240 {
		value = value[:240]
	}
	return value
}

func writeJSONAtomic(path string, value any) error {
	payload, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	temp, err := os.CreateTemp(filepath.Dir(path), ".lease-state.*")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(payload); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
