//go:build realincus

package incusclient

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/projectruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

func TestRealIncusServerContract(t *testing.T) {
	socket := os.Getenv("SUBYARD_REAL_INCUS_SOCKET")
	if socket == "" {
		t.Skip("set SUBYARD_REAL_INCUS_SOCKET")
	}
	if !filepath.IsAbs(socket) {
		t.Fatal("real Incus socket must be absolute")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	server, err := New(socket, "projects").Server(ctx)
	if err != nil || server.Environment == "" || server.Version == "" {
		t.Fatalf("server/extensions contract: %#v err=%v", server, err)
	}
}

// TestRealIncusConformance is opt-in and read-only apart from executing printf
// inside a dedicated acceptance instance. Run it once for a container and once
// for a VM; the ordinary yard-safe gate uses the fake Unix/WebSocket server.
func TestRealIncusConformance(t *testing.T) {
	socket := os.Getenv("SUBYARD_REAL_INCUS_SOCKET")
	project := os.Getenv("SUBYARD_REAL_INCUS_PROJECT")
	instanceName := os.Getenv("SUBYARD_REAL_INCUS_INSTANCE")
	expectedType := domain.InstanceType(os.Getenv("SUBYARD_REAL_INCUS_TYPE"))
	if socket == "" || project == "" || instanceName == "" || expectedType == "" {
		t.Skip("set SUBYARD_REAL_INCUS_SOCKET, SUBYARD_REAL_INCUS_PROJECT, " +
			"SUBYARD_REAL_INCUS_INSTANCE and SUBYARD_REAL_INCUS_TYPE")
	}
	if !filepath.IsAbs(socket) || !domain.SafeName(project) || !domain.SafeName(instanceName) ||
		(expectedType != domain.InstanceContainer && expectedType != domain.InstanceVM) {
		t.Fatal("real Incus acceptance inputs are invalid")
	}
	client := New(socket, "projects")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	server, err := client.Server(ctx)
	if err != nil || server.Environment == "" || server.Version == "" {
		t.Fatalf("server contract: %#v err=%v", server, err)
	}
	instance, err := client.Instance(ctx, project, instanceName)
	if err != nil || instance.Name != instanceName || instance.Type != expectedType ||
		!strings.EqualFold(instance.Status, "running") {
		t.Fatalf("running instance contract: %#v err=%v", instance, err)
	}
	eventContext, stopEvents := context.WithCancel(context.Background())
	events, errorsOut := client.Events(eventContext, []string{"lifecycle", "operation"})
	result, err := client.Exec(ctx, project, instanceName, ports.InstanceExecRequest{
		Command: []string{"sh", "-c", "printf subyard-real-incus"},
	})
	if err != nil || result.ExitCode != 0 || string(result.Stdout) != "subyard-real-incus" {
		stopEvents()
		t.Fatalf("exec contract: %#v err=%v", result, err)
	}
	result, err = client.StreamExec(ctx, project, instanceName, ports.InstanceExecRequest{
		Command: []string{"cat"},
	}, strings.NewReader("subyard-stream"))
	if err != nil || string(result.Stdout) != "subyard-stream" {
		stopEvents()
		t.Fatalf("stream exec contract: %#v err=%v", result, err)
	}
	source := t.TempDir()
	if err := os.WriteFile(filepath.Join(source, "payload"), []byte("archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	archive, err := (projectruntime.TarArchiver{}).Open(ctx, source)
	if err != nil {
		t.Fatal(err)
	}
	destination := "/tmp/subyard-real-archive"
	if _, err := client.Exec(ctx, project, instanceName, ports.InstanceExecRequest{
		Command: []string{"install", "-d", destination},
	}); err != nil {
		t.Fatal(err)
	}
	result, err = client.StreamExec(ctx, project, instanceName, ports.InstanceExecRequest{
		Command: []string{"tar", "-C", destination, "-xf", "-"},
	}, archive)
	archiveErr := archive.Close()
	if err != nil || archiveErr != nil {
		stopEvents()
		t.Fatalf("archive stream contract: %#v stream=%v archive=%v", result, err, archiveErr)
	}
	result, err = client.Exec(ctx, project, instanceName, ports.InstanceExecRequest{
		Command: []string{"cat", filepath.Join(destination, "payload")},
	})
	if err != nil || string(result.Stdout) != "archive" {
		stopEvents()
		t.Fatalf("archive payload contract: %#v err=%v", result, err)
	}
	select {
	case event, ok := <-events:
		if !ok || event.Sequence == 0 || event.Revision == 0 ||
			(event.Kind != "operation" && event.Kind != "lifecycle") {
			stopEvents()
			t.Fatalf("event delivery contract: %#v", event)
		}
	case streamErr, ok := <-errorsOut:
		stopEvents()
		if !ok {
			t.Fatal("event stream closed before the exec event")
		}
		t.Fatalf("event delivery contract: %v", streamErr)
	case <-time.After(5 * time.Second):
		stopEvents()
		t.Fatal("event stream did not observe the exec operation")
	}
	stopEvents()
	for events != nil || errorsOut != nil {
		select {
		case _, ok := <-events:
			if !ok {
				events = nil
			}
		case streamErr, ok := <-errorsOut:
			if !ok {
				errorsOut = nil
			} else if streamErr != nil {
				t.Fatalf("event cancellation contract: %v", streamErr)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("event stream did not close after cancellation")
		}
	}
}
