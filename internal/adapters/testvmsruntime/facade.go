package testvmsruntime

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

type Facade struct {
	Store     LeaseStore
	Output    io.Writer
	OnAcquire func(LeaseGrant, string) (LeaseGrant, error)
	OnRelease func(LeaseGrant) error
}

type facadeResponse struct {
	SchemaVersion int         `json:"schema_version"`
	Status        string      `json:"status"`
	Code          string      `json:"code,omitempty"`
	Message       string      `json:"message,omitempty"`
	Pool          *LeasePool  `json:"pool,omitempty"`
	Grant         *LeaseGrant `json:"grant,omitempty"`
	ExpiresAt     *time.Time  `json:"expires_at,omitempty"`
}

func (facade Facade) Run(originalCommand string) error {
	if facade.Output == nil {
		facade.Output = io.Discard
	}
	fields := strings.Fields(originalCommand)
	if len(fields) == 0 {
		fields = []string{"status"}
	}
	switch fields[0] {
	case "status":
		if len(fields) != 1 {
			return facade.writeError("invalid_request", "status accepts no arguments")
		}
		pool, err := facade.Store.Status()
		if err != nil {
			return facade.writeError("unavailable", err.Error())
		}
		redactPool(&pool)
		return facade.write(facadeResponse{
			SchemaVersion: LeaseSchemaVersion, Status: "ok", Pool: &pool,
		})
	case "acquire":
		if len(fields) != 7 {
			return facade.writeError("invalid_request",
				"acquire requires client_id fingerprint label purpose key_type key_blob")
		}
		publicKey := fields[5] + " " + fields[6]
		if _, err := normalizedPublicKey(publicKey); err != nil || fields[5] != "ssh-ed25519" {
			return facade.writeError("invalid_request", "lease key must be Ed25519")
		}
		grant, err := facade.Store.Acquire(fields[1], fields[2], fields[3], fields[4])
		if err != nil {
			if err.Error() == "busy" {
				return facade.writeError("busy", "all configured slots are busy or unavailable")
			}
			return facade.writeError("invalid_request", err.Error())
		}
		if facade.OnAcquire != nil {
			grant, err = facade.OnAcquire(grant, publicKey)
			if err != nil {
				_ = facade.Store.Quarantine(grant, err)
				return facade.writeError("quarantined", "slot provisioning failed")
			}
		}
		return facade.write(facadeResponse{
			SchemaVersion: LeaseSchemaVersion, Status: "ok", Grant: &grant,
		})
	case "renew":
		grant, err := parseGrant(fields)
		if err != nil {
			return facade.writeError("invalid_request", err.Error())
		}
		expires, err := facade.Store.Renew(grant)
		if err != nil {
			return facade.writeError("lease_lost", "lease is no longer current")
		}
		return facade.write(facadeResponse{
			SchemaVersion: LeaseSchemaVersion, Status: "ok", ExpiresAt: &expires,
		})
	case "release":
		grant, err := parseGrant(fields)
		if err != nil {
			return facade.writeError("invalid_request", err.Error())
		}
		if err := facade.Store.BeginDrain(grant); err != nil {
			return facade.writeError("lease_lost", "lease is no longer current")
		}
		if facade.OnRelease == nil {
			return facade.writeError("unavailable", "physical lease lifecycle is unavailable")
		}
		if err := facade.OnRelease(grant); err != nil {
			_ = facade.Store.FinishDrain(grant.SlotID, err)
			return facade.writeError("quarantined", "slot fencing or stop failed")
		}
		if err := facade.Store.FinishDrain(grant.SlotID, nil); err != nil {
			return facade.writeError("unavailable", err.Error())
		}
		return facade.write(facadeResponse{
			SchemaVersion: LeaseSchemaVersion, Status: "ok", Message: "released",
		})
	default:
		return facade.writeError("invalid_request", "unknown facade operation")
	}
}

func parseGrant(fields []string) (LeaseGrant, error) {
	if len(fields) != 5 {
		return LeaseGrant{}, errors.New("operation requires slot_id lease_id lease_epoch capability")
	}
	epoch, err := strconv.ParseUint(fields[3], 10, 64)
	if err != nil || epoch == 0 {
		return LeaseGrant{}, errors.New("invalid lease_epoch")
	}
	for _, value := range []string{fields[1], fields[2], fields[4]} {
		if !safeLeaseText(value, 128) || value == "" {
			return LeaseGrant{}, errors.New("invalid lease credential")
		}
	}
	return LeaseGrant{
		SlotID: fields[1], LeaseID: fields[2], LeaseEpoch: epoch, Capability: fields[4],
	}, nil
}

func redactPool(pool *LeasePool) {
	for index := range pool.Slots {
		slot := &pool.Slots[index]
		slot.CapabilityHash = ""
		slot.LeaseID = ""
		slot.ClientID = ""
	}
}

func (facade Facade) writeError(code, message string) error {
	return facade.write(facadeResponse{
		SchemaVersion: LeaseSchemaVersion, Status: "error", Code: code,
		Message: boundedReason(message),
	})
}

func (facade Facade) write(response facadeResponse) error {
	encoder := json.NewEncoder(facade.Output)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(response); err != nil {
		return fmt.Errorf("write facade response: %w", err)
	}
	return nil
}
