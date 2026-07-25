package testvmsruntime

import (
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

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
	if _, err := shrunk.Status(); err != nil {
		t.Fatalf("available higher slots should shrink: %v", err)
	}
	if err := store.FinishDrain(grant.SlotID, errors.New("stop failed")); err != nil {
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
