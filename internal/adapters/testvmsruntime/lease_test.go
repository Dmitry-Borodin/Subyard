package testvmsruntime

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestLeaseStoreConfiguredCapacityMatrix(t *testing.T) {
	for _, count := range []int{1, 2, 3} {
		t.Run(fmt.Sprintf("N=%d", count), func(t *testing.T) {
			store := LeaseStore{
				Path: filepath.Join(t.TempDir(), "leases.json"), SlotCount: count,
			}
			var grants []LeaseGrant
			for index := 0; index < count; index++ {
				grant, err := store.Acquire(
					fmt.Sprintf("client-%d", index), "SHA256:key", "", "",
				)
				if err != nil {
					t.Fatal(err)
				}
				grants = append(grants, grant)
			}
			if _, err := store.Acquire("overflow", "SHA256:key", "", ""); err == nil ||
				err.Error() != "busy" {
				t.Fatalf("N+1 acquire error = %v", err)
			}
			seen := map[string]bool{}
			for _, grant := range grants {
				seen[grant.SlotID] = true
			}
			if len(seen) != count {
				t.Fatalf("distinct winners = %d, want %d", len(seen), count)
			}
		})
	}
}

func TestLeaseStoreAcquireSlotDoesNotFallback(t *testing.T) {
	store := LeaseStore{Path: filepath.Join(t.TempDir(), "leases.json"), SlotCount: 2}
	grant, err := store.AcquireSlot(
		"exact", "SHA256:key", "checkout", "tests", "slot-002",
	)
	if err != nil {
		t.Fatal(err)
	}
	if grant.SlotID != "slot-002" {
		t.Fatalf("exact acquire returned %s", grant.SlotID)
	}
	before, err := store.Status()
	if err != nil {
		t.Fatal(err)
	}
	if before.Slots[0].State != SlotAvailable ||
		before.Slots[1].State != SlotProvisioning {
		t.Fatalf("unexpected exact acquire state: %#v", before.Slots)
	}
	if _, err := store.AcquireSlot(
		"second", "SHA256:key", "", "", "slot-002",
	); !errors.Is(err, ErrLeaseBusy) {
		t.Fatalf("occupied exact acquire error = %v", err)
	}
	after, err := store.Status()
	if err != nil {
		t.Fatal(err)
	}
	if after.Slots[0] != before.Slots[0] {
		t.Fatalf("failed exact acquire mutated neighbor: before=%#v after=%#v",
			before.Slots[0], after.Slots[0])
	}
	if err := store.Quarantine(grant, errors.New("fixture failure")); err != nil {
		t.Fatal(err)
	}
	if _, err := store.AcquireSlot(
		"third", "SHA256:key", "", "", "slot-002",
	); !errors.Is(err, ErrLeaseBusy) {
		t.Fatalf("quarantined exact acquire error = %v", err)
	}
	automatic, err := store.Acquire("automatic", "SHA256:key", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if automatic.SlotID != "slot-001" {
		t.Fatalf("automatic acquire returned %s", automatic.SlotID)
	}
	if _, err := store.AcquireSlot(
		"invalid", "SHA256:key", "", "", "slot-2",
	); err == nil || errors.Is(err, ErrLeaseBusy) {
		t.Fatalf("non-canonical slot error = %v", err)
	}
}

func TestLeaseStoreConcurrentCapacityAndFencing(t *testing.T) {
	now := time.Date(2026, 7, 25, 12, 0, 0, 0, time.UTC)
	store := LeaseStore{Path: filepath.Join(t.TempDir(), "leases.json"), SlotCount: 2, Now: func() time.Time {
		return now
	}}
	var wait sync.WaitGroup
	results := make(chan LeaseGrant, 3)
	failures := make(chan error, 3)
	for index := 0; index < 3; index++ {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			grant, err := store.Acquire(
				string(rune('a'+index)), "SHA256:controller", "checkout", "test",
			)
			if err != nil {
				failures <- err
			} else {
				results <- grant
			}
		}(index)
	}
	wait.Wait()
	close(results)
	close(failures)
	var grants []LeaseGrant
	for grant := range results {
		grants = append(grants, grant)
	}
	if len(grants) != 2 || len(failures) != 1 {
		t.Fatalf("winners=%d losers=%d", len(grants), len(failures))
	}
	if grants[0].SlotID == grants[1].SlotID {
		t.Fatal("concurrent leases received the same slot")
	}
	if err := store.MarkHeld(grants[0]); err != nil {
		t.Fatal(err)
	}
	stale := grants[0]
	stale.Capability = "wrong"
	if _, err := store.Renew(stale); err == nil {
		t.Fatal("wrong capability renewed a lease")
	}
	if err := store.BeginDrain(grants[0]); err != nil {
		t.Fatal(err)
	}
	if err := store.FinishDrain(grants[0].SlotID, nil); err != nil {
		t.Fatal(err)
	}
	if err := store.FinishDrain(grants[0].SlotID, nil); err != nil {
		t.Fatalf("replayed successful fencing was not idempotent: %v", err)
	}
	next, err := store.Acquire("next", "SHA256:controller", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if next.LeaseEpoch <= grants[0].LeaseEpoch {
		t.Fatal("lease epoch did not fence the previous holder")
	}
	if _, err := store.Renew(grants[0]); err == nil {
		t.Fatal("released lease became valid again")
	}
}

func TestLeaseStoreExpiryShrinkAndQuarantine(t *testing.T) {
	now := time.Date(2026, 7, 25, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "leases.json")
	store := LeaseStore{Path: path, SlotCount: 3, Now: func() time.Time { return now }}
	grant, err := store.Acquire("client", "SHA256:key", "", "")
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(LeaseTTL)
	pool, err := store.Status()
	if err != nil {
		t.Fatal(err)
	}
	if pool.Slots[0].State != SlotDraining {
		t.Fatalf("expired state=%s", pool.Slots[0].State)
	}
	shrunk := LeaseStore{Path: path, SlotCount: 1, Now: store.Now}
	retiring, err := shrunk.PrepareResize()
	if err != nil || len(retiring) != 2 {
		t.Fatalf("prepare available higher slots: retiring=%v err=%v", retiring, err)
	}
	if err := shrunk.CommitResize(); err != nil {
		t.Fatalf("commit available higher slots: %v", err)
	}
	if err := shrunk.FinishDrain(grant.SlotID, errors.New("stop failed")); err != nil {
		t.Fatal(err)
	}
	pool, err = shrunk.Status()
	if err != nil {
		t.Fatal(err)
	}
	if pool.Slots[0].State != SlotQuarantined || pool.Slots[0].FailureReason == "" {
		t.Fatalf("quarantine not recorded: %#v", pool.Slots[0])
	}
}

func TestLeaseStoreBlockedShrinkDoesNotMutateState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "leases.json")
	store := LeaseStore{Path: path, SlotCount: 3}
	for index := 0; index < 3; index++ {
		if _, err := store.Acquire(
			fmt.Sprintf("client-%d", index), "SHA256:key", "", "",
		); err != nil {
			t.Fatal(err)
		}
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	shrunk := LeaseStore{Path: path, SlotCount: 1}
	if _, _, err := shrunk.ResizePlan(); err == nil ||
		!strings.Contains(err.Error(), "slot-002 is provisioning") {
		t.Fatalf("blocked shrink error = %v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Fatal("blocked shrink changed lease state")
	}
}

func TestLeaseStoreRedactsCapability(t *testing.T) {
	store := LeaseStore{Path: filepath.Join(t.TempDir(), "leases.json"), SlotCount: 1}
	grant, err := store.Acquire("client", "SHA256:key", "label", "purpose")
	if err != nil {
		t.Fatal(err)
	}
	pool, err := store.Status()
	if err != nil {
		t.Fatal(err)
	}
	if pool.Slots[0].CapabilityHash == "" || pool.Slots[0].CapabilityHash == grant.Capability {
		t.Fatal("capability was not stored in verifier-only form")
	}
}

func TestLeaseStoreCorruptStateRecoveryKeepsOtherSlotsQuarantined(t *testing.T) {
	path := filepath.Join(t.TempDir(), "leases.json")
	if err := os.WriteFile(path, []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := LeaseStore{Path: path, SlotCount: 2}
	if _, err := store.Status(); !errors.Is(err, ErrCorruptLeaseState) {
		t.Fatalf("status error = %v", err)
	}
	if err := store.BeginRecovery("slot-001"); err != nil {
		t.Fatal(err)
	}
	pool, err := store.Status()
	if err != nil {
		t.Fatal(err)
	}
	if pool.Slots[0].State != SlotDraining || pool.Slots[1].State != SlotQuarantined {
		t.Fatalf("recovery pool = %#v", pool.Slots)
	}
	backups, err := filepath.Glob(path + ".corrupt-*")
	if err != nil || len(backups) != 1 {
		t.Fatalf("corrupt-state backups = %v, %v", backups, err)
	}
}
