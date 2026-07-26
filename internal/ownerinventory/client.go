package ownerinventory

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"time"

	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/ports"
	"github.com/Subyard/Subyard/internal/rpc"
)

const Capability = "owner-inventory-v1"

var ErrIntegrity = errors.New("owner inventory integrity violation")

type Client struct {
	Transport ports.RemoteTransport
	Target    string
}

func (client Client) Fetch(ctx context.Context, expectedHostID string) (domain.OwnerInventory, error) {
	raw, err := client.call(ctx, "inventory", "owner.inventory", Capability)
	if err != nil {
		return domain.OwnerInventory{}, err
	}
	var inventory domain.OwnerInventory
	if err := json.Unmarshal(raw, &inventory); err != nil {
		return inventory, fmt.Errorf("%w: invalid inventory JSON", ErrIntegrity)
	}
	if err := inventory.Validate(); err != nil {
		return inventory, fmt.Errorf("%w: %v", ErrIntegrity, err)
	}
	if expectedHostID != "" && inventory.HostID != expectedHostID {
		return inventory, fmt.Errorf(
			"%w: owner HostID mismatch: connection is %q, response is %q", ErrIntegrity,
			expectedHostID, inventory.HostID,
		)
	}
	return inventory, nil
}

func (client Client) YardStatus(ctx context.Context) (domain.YardStatus, error) {
	raw, err := client.call(ctx, "status", "yard.status", "yard-status")
	if err != nil {
		return domain.YardStatus{}, err
	}
	var status domain.YardStatus
	if err := json.Unmarshal(raw, &status); err != nil {
		return status, errors.New("owner returned invalid yard status JSON")
	}
	return status, nil
}

func (client Client) call(ctx context.Context, id, method, capability string) (json.RawMessage, error) {
	if client.Transport == nil {
		return nil, errors.New("owner RPC transport is required")
	}
	deadline, hasDeadline := ctx.Deadline()
	var request bytes.Buffer
	codec := rpc.NewCodec(bytes.NewReader(nil), &request)
	if err := codec.Write(rpc.Request{
		Version: rpc.ProtocolVersion, Type: "request", ID: "negotiate", Method: "rpc.negotiate",
	}); err != nil {
		return nil, err
	}
	call := rpc.Request{
		Version: rpc.ProtocolVersion, Type: "request", ID: id, Method: method,
		Params: json.RawMessage(`{}`),
	}
	if hasDeadline {
		call.Deadline = &deadline
	}
	if err := codec.Write(call); err != nil {
		return nil, err
	}
	response, err := client.Transport.Call(ctx, client.Target, request.Bytes())
	if err != nil {
		return nil, err
	}
	return decodeResponse(response, id, capability)
}

func decodeResponse(payload []byte, responseID, capability string) (json.RawMessage, error) {
	codec := rpc.NewCodec(bytes.NewReader(payload), io.Discard)
	var negotiated bool
	for {
		response, err := codec.ReadResponse()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("decode owner RPC: %w", err)
		}
		if response.Error != nil {
			return nil, response.Error
		}
		switch response.ID {
		case "negotiate":
			payload, err := json.Marshal(response.Result)
			if err != nil {
				return nil, err
			}
			var result struct {
				Capabilities []string `json:"capabilities"`
			}
			if err := json.Unmarshal(payload, &result); err != nil {
				return nil, errors.New("owner returned invalid negotiation result")
			}
			if !slices.Contains(result.Capabilities, capability) {
				return nil, fmt.Errorf(
					"owner does not support %s; update Subyard on the owner host", capability,
				)
			}
			negotiated = true
		case responseID:
			if !negotiated {
				return nil, errors.New("owner response arrived before negotiation")
			}
			encoded, err := json.Marshal(response.Result)
			if err != nil {
				return nil, err
			}
			if len(encoded) > rpc.MaxFrameSize {
				return nil, errors.New("owner response exceeds the RPC response limit")
			}
			return encoded, nil
		}
	}
	return nil, errors.New("owner returned no RPC response")
}

type FetchFunc func(context.Context, string) (domain.OwnerInventory, error)

type Clock interface {
	Now() time.Time
}
