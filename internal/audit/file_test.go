package audit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWriteInvocationRedactsAndRotates(t *testing.T) {
	home := t.TempDir()
	invocation := Invocation{
		Home: home, Command: "clone", Arguments: []string{"https://user:password@example.test/repo", "--", "secret"},
		WorkingDir: "/workspace", Yard: "named", Remote: "owner", Side: "host",
		OperationID: "op-fixture",
		Now:         time.Date(2026, 7, 20, 0, 0, 0, 0, time.UTC), PID: 42, Maximum: 1,
	}
	if err := WriteInvocation(invocation); err != nil {
		t.Fatal(err)
	}
	if err := WriteInvocation(invocation); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"yard.log", "yard.log.1"} {
		data, err := os.ReadFile(filepath.Join(home, "logs", name))
		if err != nil {
			t.Fatal(err)
		}
		text := string(data)
		if strings.Contains(text, "password") || strings.Contains(text, " secret") || !strings.Contains(text, "***") {
			t.Fatalf("audit redaction failed in %s: %q", name, text)
		}
		if !strings.Contains(text, " op=op-fixture ") {
			t.Fatalf("operation correlation missing in %s: %q", name, text)
		}
	}
}
