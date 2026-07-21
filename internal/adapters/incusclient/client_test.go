package incusclient

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestOfficialClientMapsServerAndInstance(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "incus.socket")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/1.0":
			writeSync(t, writer, map[string]any{
				"api_extensions": []string{"projects", "instances"},
				"environment":    map[string]any{"server": "incus", "server_version": "6.23"},
			})
		case "/1.0/instances/yard":
			if request.URL.Query().Get("project") != "subyard" {
				t.Errorf("missing project query: %s", request.URL.RawQuery)
			}
			writeSync(t, writer, map[string]any{
				"name": "yard", "project": "subyard", "type": "container", "status": "Running",
				"expanded_config":  map[string]string{"security.nesting": "true"},
				"expanded_devices": map[string]map[string]string{"root": {"type": "disk", "path": "/"}},
			})
		default:
			http.NotFound(writer, request)
		}
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		_ = server.Close()
		_ = os.Remove(socket)
	})

	client := New(socket, "projects")
	info, err := client.Server(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if info.Environment != "incus" || info.Version != "6.23" {
		t.Fatalf("unexpected server info: %#v", info)
	}
	instance, err := client.Instance(context.Background(), "subyard", "yard")
	if err != nil {
		t.Fatal(err)
	}
	if instance.Status != "Running" || instance.Config["security.nesting"] != "true" {
		t.Fatalf("unexpected instance: %#v", instance)
	}
}

func TestRequiredExtensionFailsClosed(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "incus.socket")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writeSync(t, writer, map[string]any{"api_extensions": []string{}, "environment": map[string]any{}})
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	if _, err := New(socket, "projects").Server(context.Background()); err == nil {
		t.Fatal("missing required extension was accepted")
	}
}

func writeSync(t *testing.T, writer http.ResponseWriter, metadata any) {
	t.Helper()
	if err := json.NewEncoder(writer).Encode(map[string]any{
		"type": "sync", "status": "Success", "status_code": 200, "metadata": metadata,
	}); err != nil {
		t.Error(err)
	}
}
