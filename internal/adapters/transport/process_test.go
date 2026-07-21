package transport

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/contracttest"
	"github.com/Dmitry-Borodin/Subyard/internal/rpc"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestRPCProcessHelper(t *testing.T) {
	if os.Getenv("SUBYARD_RPC_PROCESS_HELPER") != "1" {
		return
	}
	handler := rpc.HandlerFunc(func(_ context.Context, call rpc.Call, _ rpc.Emit) (any, error) {
		return map[string]any{"method": call.Method}, nil
	})
	err := (rpc.Session{
		Handler: handler, Capabilities: []string{"snapshot"}, DrainOnEOF: true,
	}).Serve(context.Background(), os.Stdin, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

func TestSSHTransportUsesFixedArgumentsAndPreservesFrames(t *testing.T) {
	root := t.TempDir()
	program := filepath.Join(root, "ssh")
	log := filepath.Join(root, "arguments")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$SSH_ARGUMENT_LOG\"\n" +
		"exec \"$SUBYARD_RPC_HELPER_BINARY\" -test.run=^TestRPCProcessHelper$\n"
	if err := os.WriteFile(program, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	transport, err := SSH(program, "owner@example.test", 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	helper, err := filepath.Abs(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	transport.Env = append(os.Environ(), "SSH_ARGUMENT_LOG="+log,
		"SUBYARD_RPC_HELPER_BINARY="+helper, "SUBYARD_RPC_PROCESS_HELPER=1")
	request := rpcFrames(t,
		rpc.Request{Version: 1, Type: "request", ID: "n", Method: "rpc.negotiate"},
		rpc.Request{Version: 1, Type: "request", ID: "ping", OperationID: "operation-ping", Method: "system.ping"},
	)
	response, err := transport.Call(context.Background(), "owner", request)
	if err != nil {
		t.Fatal(err)
	}
	codec := rpc.NewCodec(bytes.NewReader(response), io.Discard)
	negotiated, err := codec.ReadResponse()
	if err != nil || negotiated.ID != "n" || negotiated.Error != nil {
		t.Fatalf("negotiation frame changed: %#v err=%v", negotiated, err)
	}
	ping, err := codec.ReadResponse()
	if err != nil || ping.ID != "ping" || ping.OperationID != "operation-ping" || ping.Error != nil {
		t.Fatalf("call frame changed: %#v err=%v", ping, err)
	}
	arguments, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(arguments), "BatchMode=yes\n") ||
		!strings.HasSuffix(string(arguments), "yard\nrpc\n--stdio\n") {
		t.Fatalf("unsafe or incomplete SSH arguments: %q", arguments)
	}
}

func rpcFrames(t *testing.T, requests ...rpc.Request) []byte {
	t.Helper()
	var framed bytes.Buffer
	codec := rpc.NewCodec(bytes.NewReader(nil), &framed)
	for _, request := range requests {
		if err := codec.Write(request); err != nil {
			t.Fatal(err)
		}
	}
	return framed.Bytes()
}

func TestScriptedTransportReconnectsWithFullResync(t *testing.T) {
	remote := &testkit.ScriptedRemote{Steps: []testkit.RemoteStep{
		{Err: errors.New("connection lost")},
		{Response: []byte("full snapshot revision 12")},
	}}
	if _, err := remote.Call(context.Background(), "owner", []byte("incremental revision 11")); err == nil {
		t.Fatal("disconnect was not reported")
	}
	response, err := remote.Call(context.Background(), "owner", []byte("system.snapshot"))
	if err != nil || string(response) != "full snapshot revision 12" {
		t.Fatalf("reconnect did not resync: response=%q err=%v", response, err)
	}
	if len(remote.Calls) != 2 || string(remote.Calls[1].Request) != "system.snapshot" {
		t.Fatalf("reconnect reused stale incremental request: %#v", remote.Calls)
	}
}

func TestTransportTimeoutAndTargetValidation(t *testing.T) {
	if _, err := SSH("ssh", "-oProxyCommand=bad", time.Second); err == nil {
		t.Fatal("unsafe SSH target was accepted")
	}
	root := t.TempDir()
	program := filepath.Join(root, "slow")
	if err := os.WriteFile(program, []byte("#!/bin/sh\nsleep 30\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	transport := Process{Program: program, Timeout: 50 * time.Millisecond}
	started := time.Now()
	if _, err := transport.Call(context.Background(), "", nil); err == nil {
		t.Fatal("timeout was ignored")
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("timed-out transport was not killed")
	}
}

func TestRemoteTransportConformance(t *testing.T) {
	root := t.TempDir()
	program := filepath.Join(root, "echo")
	if err := os.WriteFile(program, []byte("#!/bin/sh\ncat\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Run("process", func(t *testing.T) {
		contracttest.RemoteTransport(t, Process{Program: program}, "owner")
	})
	t.Run("scripted", func(t *testing.T) {
		contracttest.RemoteTransport(t, &testkit.ScriptedRemote{Steps: []testkit.RemoteStep{{Response: []byte("framed request")}}}, "owner")
	})
}
