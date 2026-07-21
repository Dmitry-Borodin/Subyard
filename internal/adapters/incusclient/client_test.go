package incusclient

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/contracttest"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestOfficialClientMapsServerAndInstance(t *testing.T) {
	server, err := testkit.NewIncusServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	server.SetInstance("subyard", "yard", map[string]any{
		"name": "yard", "project": "subyard", "type": "container", "status": "Running",
		"expanded_config":  map[string]string{"security.nesting": "true"},
		"expanded_devices": map[string]map[string]string{"root": {"type": "disk", "path": "/"}},
	})
	contracttest.IncusRead(t, New(server.SocketPath, "projects"))
}

func TestRequiredExtensionFailsClosed(t *testing.T) {
	server, err := testkit.NewIncusServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	server.SetExtensions()
	client := New(server.SocketPath, "projects")
	if _, err := client.Server(context.Background()); err == nil {
		t.Fatal("missing required extension was accepted")
	}
	if _, err := client.Instance(context.Background(), "subyard", "yard"); err == nil {
		t.Fatal("instance call bypassed required extension validation")
	}
	if _, err := client.Exec(context.Background(), "subyard", "yard", ports.InstanceExecRequest{
		Command: []string{"true"},
	}); err == nil {
		t.Fatal("exec call bypassed required extension validation")
	}
	events, errorsOut := client.Events(context.Background(), []string{"lifecycle"})
	if _, ok := <-events; ok {
		t.Fatal("event stream remained open without required extension")
	}
	if err := <-errorsOut; err == nil {
		t.Fatal("event stream did not report missing required extension")
	}
}

func TestOfficialClientMapsEventsAndDisconnect(t *testing.T) {
	server, err := testkit.NewIncusServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events, errorsOut := New(server.SocketPath).Events(ctx, []string{"lifecycle"})
	waitContext, stopWaiting := context.WithTimeout(context.Background(), time.Second)
	defer stopWaiting()
	if err := server.WaitForEventClient(waitContext); err != nil {
		t.Fatal(err)
	}
	if err := server.Emit(map[string]any{
		"type": "lifecycle", "timestamp": time.Unix(100, 0).UTC(),
		"metadata": map[string]any{"id": "operation-1", "action": "instance-started", "apiToken": "must-not-escape"},
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case event := <-events:
		if event.OperationID != "operation-1" || event.Kind != "lifecycle" || event.Sequence != 1 ||
			event.Data["action"] != "instance-started" {
			t.Fatalf("unexpected event: %#v", event)
		}
		if _, leaked := event.Data["apiToken"]; leaked {
			t.Fatalf("secret-like Incus metadata escaped event projection: %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("Incus event was not delivered")
	}
	server.DisconnectEvents()
	select {
	case disconnect := <-errorsOut:
		if disconnect == nil {
			t.Fatal("event disconnect returned no error")
		}
	case <-time.After(time.Second):
		t.Fatal("Incus event disconnect was not reported")
	}
}

func TestOfficialClientExecUsesAsyncWebsocketsAndFlushesOutput(t *testing.T) {
	server, err := testkit.NewIncusServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	server.QueueExec(testkit.IncusServerExecStep{
		Stdout: []byte("output\n"), Stderr: []byte("diagnostic\n"),
	})
	result, err := New(server.SocketPath).Exec(context.Background(), "subyard", "yard", ports.InstanceExecRequest{
		Command:     []string{"sh", "-c", "read value; printf '%s' \"$value\""},
		Environment: map[string]string{"FIXTURE": "yes"}, Stdin: []byte("input\n"), User: 1000, Group: 1000,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result.Stdout, []byte("output\n")) ||
		!bytes.Equal(result.Stderr, []byte("diagnostic\n")) || result.ExitCode != 0 {
		t.Fatalf("unexpected exec result: %#v", result)
	}
	calls := server.ExecCalls()
	if len(calls) != 1 || calls[0].Project != "subyard" || calls[0].Name != "yard" ||
		calls[0].Environment["FIXTURE"] != "yes" || !bytes.Equal(calls[0].Stdin, []byte("input\n")) ||
		calls[0].User != 1000 || calls[0].Group != 1000 {
		t.Fatalf("structured exec request changed: %#v", calls)
	}
}

func TestOfficialClientExecMapsStartOperationExitAndCancellation(t *testing.T) {
	server, err := testkit.NewIncusServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	server.QueueExec(
		testkit.IncusServerExecStep{StartError: "command rejected"},
		testkit.IncusServerExecStep{OperationError: "runtime disconnected"},
		testkit.IncusServerExecStep{ExitCode: 17, Stderr: []byte("failed\n")},
	)
	client := New(server.SocketPath)
	request := ports.InstanceExecRequest{Command: []string{"false"}}
	if _, err := client.Exec(context.Background(), "subyard", "yard", request); err == nil ||
		!strings.Contains(err.Error(), "command rejected") {
		t.Fatalf("start error was not normalized: %v", err)
	}
	if _, err := client.Exec(context.Background(), "subyard", "yard", request); err == nil ||
		!strings.Contains(err.Error(), "runtime disconnected") {
		t.Fatalf("operation error was not normalized: %v", err)
	}
	result, err := client.Exec(context.Background(), "subyard", "yard", request)
	if err == nil || !strings.Contains(err.Error(), "status 17") || result.ExitCode != 17 ||
		!bytes.Equal(result.Stderr, []byte("failed\n")) {
		t.Fatalf("exit status was not preserved: result=%#v err=%v", result, err)
	}

	release := make(chan struct{})
	server.QueueExec(testkit.IncusServerExecStep{Release: release})
	ctx, cancel := context.WithCancelCause(context.Background())
	finished := make(chan error, 1)
	go func() {
		_, callErr := client.Exec(ctx, "subyard", "yard", request)
		finished <- callErr
	}()
	waitContext, stopWaiting := context.WithTimeout(context.Background(), time.Second)
	defer stopWaiting()
	if err := server.WaitForExecCount(waitContext, 3); err != nil {
		t.Fatal(err)
	}
	cancel(errors.New("test cancellation"))
	select {
	case err := <-finished:
		if err == nil || !strings.Contains(err.Error(), "test cancellation") {
			t.Fatalf("context cancellation was not preserved: %v", err)
		}
	case <-waitContext.Done():
		t.Fatal("cancelled exec did not stop")
	}
}
