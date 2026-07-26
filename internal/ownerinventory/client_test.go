package ownerinventory

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Subyard/Subyard/internal/rpc"
)

type errorTransport struct{ err error }

func (transport errorTransport) Call(context.Context, string, []byte) ([]byte, error) {
	return nil, transport.err
}

type responseTransport struct {
	payload []byte
	calls   int
}

func (transport *responseTransport) Call(context.Context, string, []byte) ([]byte, error) {
	transport.calls++
	return transport.payload, nil
}

func framedResponses(t *testing.T, capabilities []string, result any) []byte {
	t.Helper()
	var output bytes.Buffer
	codec := rpc.NewCodec(bytes.NewReader(nil), &output)
	if err := codec.Write(rpc.Response{
		Version: rpc.ProtocolVersion, Type: "response", ID: "negotiate",
		Result: map[string]any{"capabilities": capabilities},
	}); err != nil {
		t.Fatal(err)
	}
	if err := codec.Write(rpc.Response{
		Version: rpc.ProtocolVersion, Type: "response", ID: "inventory", Result: result,
	}); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func TestClientValidatesCapabilityAndExpectedHostID(t *testing.T) {
	inventory := fixtureInventory("owner-a", time.Now())
	transport := &responseTransport{payload: framedResponses(t, []string{Capability}, inventory)}
	result, err := (Client{Transport: transport}).Fetch(context.Background(), "owner-a")
	if err != nil || result.HostID != "owner-a" || transport.calls != 1 {
		t.Fatalf("valid fetch failed: result=%#v err=%v calls=%d", result, err, transport.calls)
	}
	if _, err := (Client{Transport: transport}).Fetch(context.Background(), "owner-b"); err == nil || !strings.Contains(err.Error(), "HostID mismatch") {
		t.Fatalf("HostID mismatch was accepted: %v", err)
	}
}

func TestClientRejectsMissingCapabilityAndMalformedInventory(t *testing.T) {
	inventory := fixtureInventory("owner-a", time.Now())
	missing := &responseTransport{payload: framedResponses(t, []string{"yard-status"}, inventory)}
	if _, err := (Client{Transport: missing}).Fetch(context.Background(), ""); err == nil || !strings.Contains(err.Error(), "update Subyard") {
		t.Fatalf("missing capability was accepted: %v", err)
	}
	malformed := map[string]any{}
	encoded, err := json.Marshal(inventory)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &malformed); err != nil {
		t.Fatal(err)
	}
	malformed["hostId"] = "../escape"
	bad := &responseTransport{payload: framedResponses(t, []string{Capability}, malformed)}
	if _, err := (Client{Transport: bad}).Fetch(context.Background(), ""); err == nil {
		t.Fatal("malformed owner inventory was accepted")
	}
}

func TestClientRejectsTimeoutAndOversizedResponse(t *testing.T) {
	if _, err := (Client{Transport: errorTransport{err: context.DeadlineExceeded}}).
		Fetch(context.Background(), "owner-a"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("transport timeout was not preserved: %v", err)
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, rpc.MaxFrameSize+1)
	if _, err := (Client{Transport: &responseTransport{payload: header}}).
		Fetch(context.Background(), "owner-a"); err == nil ||
		!strings.Contains(err.Error(), "outside the allowed range") {
		t.Fatalf("oversized RPC response was accepted: %v", err)
	}
}
