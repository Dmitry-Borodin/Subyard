package rpc

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSessionNegotiationEventsAndCancellation(t *testing.T) {
	started := make(chan struct{})
	handler := HandlerFunc(func(ctx context.Context, call Call, emit Emit) (any, error) {
		switch call.Method {
		case "events":
			if err := emit("started", 7, map[string]any{"ok": true}); err != nil {
				return nil, err
			}
			if err := emit("finished", 8, nil); err != nil {
				return nil, err
			}
			return map[string]any{"done": true}, nil
		case "slow":
			close(started)
			<-ctx.Done()
			return nil, ctx.Err()
		default:
			return nil, &Error{Code: "method_not_found", Message: call.Method}
		}
	})
	client, server := net.Pipe()
	done := make(chan error, 1)
	go func() {
		done <- (Session{Handler: handler, Capabilities: []string{"events"}}).Serve(context.Background(), server, server)
	}()
	codec := NewCodec(client, client)
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "n", Method: "rpc.negotiate"})
	if response := readResponse(t, codec); response.Error != nil {
		t.Fatal(response.Error)
	}
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "e", Method: "events"})
	first := readResponse(t, codec)
	second := readResponse(t, codec)
	third := readResponse(t, codec)
	if first.Type != "event" || second.Type != "event" || third.Type != "response" ||
		first.Sequence+1 != second.Sequence {
		t.Fatalf("unexpected event flow: %#v %#v %#v", first, second, third)
	}
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "slow", Method: "slow"})
	<-started
	writeRequest(t, codec, Request{Version: 1, Type: "cancel", ID: "cancel", OperationID: "slow"})
	responses := []Response{readResponse(t, codec), readResponse(t, codec)}
	var cancelled bool
	for _, response := range responses {
		if response.ID == "slow" && response.Error != nil && response.Error.Code == "cancelled" {
			cancelled = true
		}
	}
	if !cancelled {
		t.Fatalf("slow operation was not cancelled: %#v", responses)
	}
	_ = client.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestSessionRejectsUnnegotiatedVersionAndSecrets(t *testing.T) {
	handlerCalls := atomic.Int32{}
	handler := HandlerFunc(func(context.Context, Call, Emit) (any, error) {
		handlerCalls.Add(1)
		return nil, nil
	})
	client, server := net.Pipe()
	go func() { _ = (Session{Handler: handler}).Serve(context.Background(), server, server) }()
	codec := NewCodec(client, client)
	writeRequest(t, codec, Request{Version: 2, Type: "request", ID: "version", Method: "rpc.negotiate"})
	if response := readResponse(t, codec); response.Error == nil || response.Error.Code != "incompatible_version" {
		t.Fatalf("version accepted: %#v", response)
	}
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "early", Method: "read"})
	if response := readResponse(t, codec); response.Error == nil || response.Error.Code != "negotiation_required" {
		t.Fatalf("unnegotiated call accepted: %#v", response)
	}
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "n", Method: "rpc.negotiate"})
	_ = readResponse(t, codec)
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "secret", Method: "read", Params: json.RawMessage(`{"apiToken":"x"}`)})
	if response := readResponse(t, codec); response.Error == nil || response.Error.Code != "secret_forbidden" {
		t.Fatalf("secret-bearing call accepted: %#v", response)
	}
	if handlerCalls.Load() != 0 {
		t.Fatal("rejected calls reached handler")
	}
	_ = client.Close()
}

func TestCodecHandlesPartialIOAndOversize(t *testing.T) {
	writer := &oneByteWriter{}
	codec := NewCodec(strings.NewReader(""), writer)
	if err := codec.Write(Response{Version: 1, Type: "response", ID: "one"}); err != nil {
		t.Fatal(err)
	}
	reader := NewCodec(&oneByteReader{value: writer.value}, io.Discard)
	response, err := reader.ReadResponse()
	if err != nil || response.ID != "one" {
		t.Fatalf("partial frame failed: %#v, %v", response, err)
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, MaxFrameSize+1)
	if _, err := NewCodec(strings.NewReader(string(header)), io.Discard).ReadRequest(); err == nil {
		t.Fatal("oversized frame was accepted")
	}
}

func TestDisconnectCancelsOperation(t *testing.T) {
	cancelled := make(chan struct{})
	handler := HandlerFunc(func(ctx context.Context, _ Call, _ Emit) (any, error) {
		<-ctx.Done()
		close(cancelled)
		return nil, ctx.Err()
	})
	client, server := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- (Session{Handler: handler}).Serve(context.Background(), server, server) }()
	codec := NewCodec(client, client)
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "n", Method: "rpc.negotiate"})
	_ = readResponse(t, codec)
	writeRequest(t, codec, Request{Version: 1, Type: "request", ID: "work", Method: "slow"})
	_ = client.Close()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("disconnect did not cancel operation")
	}
	if err := <-done; err != nil && !errors.Is(err, io.ErrClosedPipe) {
		t.Fatal(err)
	}
}

func writeRequest(t *testing.T, codec *Codec, request Request) {
	t.Helper()
	if err := codec.Write(request); err != nil {
		t.Fatal(err)
	}
}

func readResponse(t *testing.T, codec *Codec) Response {
	t.Helper()
	response, err := codec.ReadResponse()
	if err != nil {
		t.Fatal(err)
	}
	return response
}

type oneByteWriter struct{ value []byte }

func (writer *oneByteWriter) Write(value []byte) (int, error) {
	writer.value = append(writer.value, value[0])
	return 1, nil
}

type oneByteReader struct{ value []byte }

func (reader *oneByteReader) Read(target []byte) (int, error) {
	if len(reader.value) == 0 {
		return 0, io.EOF
	}
	target[0] = reader.value[0]
	reader.value = reader.value[1:]
	return 1, nil
}
