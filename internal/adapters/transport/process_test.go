package transport

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSSHTransportUsesFixedArgumentsAndPreservesFrames(t *testing.T) {
	root := t.TempDir()
	program := filepath.Join(root, "ssh")
	log := filepath.Join(root, "arguments")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$SSH_ARGUMENT_LOG\"\ncat\n"
	if err := os.WriteFile(program, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	transport, err := SSH(program, "owner@example.test", 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	transport.Env = append(os.Environ(), "SSH_ARGUMENT_LOG="+log)
	response, err := transport.Call(context.Background(), "owner", []byte("framed request"))
	if err != nil {
		t.Fatal(err)
	}
	if string(response) != "framed request" {
		t.Fatalf("frame changed: %q", response)
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
