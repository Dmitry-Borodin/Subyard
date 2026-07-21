package shelladapter

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

func TestRunnerPreservesQuotingAndSeparatesSecret(t *testing.T) {
	runner := fixtureRunner(t, `#!/bin/sh
set -eu
metadata="$(cat <&3)"
secret="$(cat)"
printf '%s' "$metadata" | grep -F '"value":"a b;$(nope)"' >/dev/null
printf '%s' "$secret" >&2
printf '%s' '{"schema":1,"operationId":"operation-1","status":"ok","output":{"seen":"a b;$(nope)"}}'
`)
	request := fixtureRequest()
	request.Input = map[string]any{"value": "a b;$(nope)"}
	result, stderr, err := runner.Run(context.Background(), request, strings.NewReader("owner-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if result.Output["seen"] != "a b;$(nope)" {
		t.Fatalf("quoting changed: %#v", result.Output)
	}
	if stderr != "[REDACTED]" {
		t.Fatalf("secret leaked through stderr: %q", stderr)
	}
}

func TestRunnerKillsProcessGroupOnTimeoutAndRejectsPartialOutput(t *testing.T) {
	runner := fixtureRunner(t, `#!/bin/sh
printf '{"schema":1'
sleep 30 &
wait
`)
	runner.Timeout = 50 * time.Millisecond
	started := time.Now()
	_, _, err := runner.Run(context.Background(), fixtureRequest(), nil)
	if err == nil || !strings.Contains(err.Error(), "deadline exceeded") {
		t.Fatalf("expected deadline, got %v", err)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("adapter process group was not killed promptly")
	}
}

func TestRunnerRejectsSecretMetadataAndOversizedOutput(t *testing.T) {
	runner := fixtureRunner(t, `#!/bin/sh
head -c 100 /dev/zero
`)
	request := fixtureRequest()
	request.Input = map[string]any{"api_token": "do-not-pass"}
	if _, _, err := runner.Run(context.Background(), request, nil); err == nil {
		t.Fatal("secret metadata was accepted")
	}
	request.Input = nil
	runner.MaxOutput = 10
	if _, _, err := runner.Run(context.Background(), request, nil); err == nil {
		t.Fatal("oversized output was accepted")
	}
}

func TestRunnerRejectsSecretLikeContextKey(t *testing.T) {
	runner := fixtureRunner(t, "#!/bin/sh\nexit 0\n")
	runner.ContextKeys["api_token"] = struct{}{}
	request := fixtureRequest()
	request.Context["api_token"] = "do-not-pass"
	if _, _, err := runner.Run(context.Background(), request, nil); err == nil {
		t.Fatal("secret-like context key was accepted")
	}
}

func TestRunnerRedactsNestedOutput(t *testing.T) {
	runner := fixtureRunner(t, `#!/bin/sh
printf '%s' '{"schema":1,"operationId":"operation-1","status":"ok","output":{"items":[{"api_token":"owner-secret"},{"url":"https://user:pass@example.test"}]}}'
`)
	result, _, err := runner.Run(context.Background(), fixtureRequest(), strings.NewReader("owner-secret"))
	if err != nil {
		t.Fatal(err)
	}
	items, ok := result.Output["items"].([]any)
	if !ok || len(items) != 2 {
		t.Fatalf("unexpected nested output: %#v", result.Output)
	}
	first, firstOK := items[0].(map[string]any)
	second, secondOK := items[1].(map[string]any)
	if !firstOK || !secondOK || first["api_token"] != "[REDACTED]" ||
		second["url"] != "https://user:***@example.test" {
		t.Fatalf("nested output was not redacted: %#v", items)
	}
}

func TestRunnerHonorsParentCancellation(t *testing.T) {
	runner := fixtureRunner(t, "#!/bin/sh\nsleep 30\n")
	ctx, cancel := context.WithCancelCause(context.Background())
	cancel(errors.New("operator cancelled"))
	_, _, err := runner.Run(ctx, fixtureRequest(), bytes.NewReader(nil))
	if err == nil {
		t.Fatal("cancelled request ran")
	}
}

func fixtureRunner(t *testing.T, script string) Runner {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "adapter.sh")
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return Runner{
		RepositoryRoot: root,
		Allow:          map[string]map[string]string{"fixture": {"run": path}},
		ContextKeys:    map[string]struct{}{"yard": {}},
		Timeout:        time.Second,
	}
}

func fixtureRequest() domain.AdapterRequest {
	return domain.AdapterRequest{
		Schema:      1,
		OperationID: "operation-1",
		Adapter:     "fixture",
		Action:      "run",
		Context:     map[string]string{"yard": "default"},
	}
}
