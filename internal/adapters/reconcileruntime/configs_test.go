package reconcileruntime

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestRefreshConfigsUsesTypedAtomicGuestWrites(t *testing.T) {
	root := t.TempDir()
	source := func(name, payload string) string {
		t.Helper()
		path := filepath.Join(root, name)
		if err := os.WriteFile(path, []byte(payload), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	environment := []string{
		"AGENTS=opencode",
		"HOST_CLAUDE_MD=" + source("CLAUDE.md", "claude\n"),
		"HOST_CODEX_AGENTS_MD=" + source("CODEX.md", "codex\n"),
		"HOST_OPENCODE_AGENTS_MD=" + source("OPENCODE.md", "opencode\n"),
		"AGENT_opencode_CONFIG=" + source("opencode.jsonc", "{}\n"),
		"AGENT_opencode_CONFIG_DEST=.config/opencode/opencode.jsonc",
		"AGENT_opencode_RULES=" + source("repo.rules", "rule\n"),
		"AGENT_opencode_RULES_DEST=.config/opencode/repo.rules",
	}
	incus := runningIncus(10)
	var output bytes.Buffer
	runtime := Runtime{
		Environment: environment, Incus: incus, Executor: incus, Stdout: &output,
		Yard: domain.Context{
			IncusProject: "subyard", InstanceName: "yard", DevUser: "dev", DevUID: 1001,
		},
	}
	if err := runtime.RefreshConfigs(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := runtime.RefreshConfigs(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(incus.ExecCalls) != 10 {
		t.Fatalf("typed config writes = %d, want 10", len(incus.ExecCalls))
	}
	for index, call := range incus.ExecCalls {
		if call.Project != "subyard" || call.Name != "yard" ||
			len(call.Request.Command) != 7 ||
			call.Request.Command[0] != "sh" ||
			!strings.Contains(call.Request.Command[3], "mktemp") ||
			call.Request.Command[6] != "1001" {
			t.Fatalf("config write %d is not the atomic typed contract: %#v", index, call)
		}
		destination := call.Request.Command[5]
		if !strings.HasPrefix(destination, "/home/dev/") ||
			strings.Contains(destination, "auth.json") {
			t.Fatalf("unsafe config destination %q", destination)
		}
		if index >= 5 {
			first := incus.ExecCalls[index-5].Request
			if !slices.Equal(first.Command, call.Request.Command) ||
				!bytes.Equal(first.Stdin, call.Request.Stdin) {
				t.Fatalf("config refresh %d is not idempotent", index-5)
			}
		}
	}
	if !strings.Contains(output.String(), "Agent instructions and configs refreshed") {
		t.Fatalf("refresh output changed: %q", output.String())
	}
}

func TestRefreshConfigsRejectsPathsOutsideDeveloperHome(t *testing.T) {
	root := t.TempDir()
	config := filepath.Join(root, "config")
	if err := os.WriteFile(config, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	incus := runningIncus(0)
	runtime := Runtime{
		Environment: []string{
			"AGENTS=opencode",
			"AGENT_opencode_CONFIG=" + config,
			"AGENT_opencode_CONFIG_DEST=../../root/.config",
		},
		Incus: incus, Executor: incus,
		Yard: domain.Context{
			IncusProject: "subyard", InstanceName: "yard", DevUser: "dev",
		},
	}
	if err := runtime.RefreshConfigs(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "leaves the developer home") {
		t.Fatalf("unsafe config destination error = %v", err)
	}
	if len(incus.ExecCalls) != 0 {
		t.Fatalf("unsafe config caused guest execution: %#v", incus.ExecCalls)
	}
}

func TestApplyGitIdentityUsesTypedDeveloperCommands(t *testing.T) {
	incus := runningIncus(3)
	runtime := Runtime{
		Environment: []string{"GIT_USER_NAME=Developer", "GIT_USER_EMAIL=dev@example.test"},
		Incus:       incus, Executor: incus,
		Yard: domain.Context{
			IncusProject: "subyard", InstanceName: "yard", DevUser: "dev", DevUID: 1001,
			Paths: domain.RuntimePaths{DataHome: t.TempDir()},
		},
	}
	if err := runtime.applyGitIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := [][]string{
		{"git", "config", "--global", "user.name", "Developer"},
		{"git", "config", "--global", "user.email", "dev@example.test"},
		{"git", "config", "--global", "--replace-all", "safe.directory", "*"},
	}
	if len(incus.ExecCalls) != len(want) {
		t.Fatalf("git identity calls = %#v", incus.ExecCalls)
	}
	for index, call := range incus.ExecCalls {
		if !slices.Equal(call.Request.Command, want[index]) ||
			call.Request.User != 1001 || call.Request.Group != 1001 ||
			call.Request.Environment["HOME"] != "/home/dev" {
			t.Fatalf("git identity call %d = %#v", index, call)
		}
	}
}

func TestApplyGitIdentityCopiesOperatorDropin(t *testing.T) {
	dataHome := t.TempDir()
	payload := []byte("[user]\n\tname = Operator\n")
	if err := os.WriteFile(filepath.Join(dataHome, "gitconfig"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	incus := runningIncus(2)
	runtime := Runtime{
		Incus: incus, Executor: incus,
		Yard: domain.Context{
			IncusProject: "subyard", InstanceName: "yard", DevUser: "dev",
			Paths: domain.RuntimePaths{DataHome: dataHome},
		},
	}
	if err := runtime.applyGitIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(incus.ExecCalls) != 2 ||
		incus.ExecCalls[0].Request.Command[5] != "/home/dev/.gitconfig" ||
		!bytes.Equal(incus.ExecCalls[0].Request.Stdin, payload) ||
		!slices.Equal(incus.ExecCalls[1].Request.Command,
			[]string{"git", "config", "--global", "--replace-all", "safe.directory", "*"}) {
		t.Fatalf("operator gitconfig was not copied through typed execution: %#v", incus.ExecCalls)
	}
}

func runningIncus(execCount int) *testkit.Incus {
	steps := make([]testkit.IncusExecStep, execCount)
	for index := range steps {
		steps[index].Result = ports.InstanceExecResult{}
	}
	return &testkit.Incus{
		Reconcile: ports.ReconcileState{
			InstanceFound: true,
			Instance:      ports.InstanceInfo{Status: "Running"},
		},
		ExecSteps: steps,
	}
}
