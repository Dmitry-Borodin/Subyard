package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

func TestLoadNamedContext(t *testing.T) {
	root := t.TempDir()
	operatorHome := filepath.Join(root, "home")
	configHome := filepath.Join(root, "config-home")
	shipped := filepath.Join(root, "config")
	yardDir := filepath.Join(configHome, "yards")
	for _, directory := range []string{operatorHome, shipped, yardDir} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeFixture(t, filepath.Join(shipped, "incus.project.env"), `: "${INCUS_PROJECT:=subyard}"
: "${RESTRICTED_DISK_PATHS:=/srv/subyard}"`)
	writeFixture(t, filepath.Join(shipped, "subyard.env"), `: "${INSTANCE_NAME:=yard}"
: "${INSTANCE_TYPE:=container}"
: "${SHIFT_MODE:=shift}"
: "${FORWARD_SSH_AGENT:=0}"
: "${DEV_SUDO:=0}"
: "${DEV_UID:=1000}"
: "${SSH_HOST:=yard}"
: "${SSH_PORT:=2222}"`)
	writeFixture(t, filepath.Join(shipped, "host.env"), `: "${SUBYARD_CONFIG_HOME:=$SUBYARD_OPERATOR_HOME/.config/subyard}"
: "${SUBYARD_HOME:=$SUBYARD_OPERATOR_HOME/.subyard}"
: "${STORAGE_PATH:=$SUBYARD_HOME/incus/storage}"
: "${HOST_BASE:=${RESTRICTED_DISK_PATHS:-/srv/subyard}}"`)
	writeFixture(t, filepath.Join(shipped, "yards", "profiles", "test-vms.env"), "NESTED_E2E_VMS=1\nE2E_VM_CPU=2\nFORWARD_SSH_AGENT=0\n")
	writeFixture(t, filepath.Join(yardDir, "named.env"), "YARD_TEMPLATE=test-vms\nSSH_PORT=3333\nINSTANCE_NAME=fixture-yard\nE2E_VM_CPU=1\nHOST_BASE="+root+"/host/../host\nRESTRICTED_DISK_PATHS="+root+"/host\n")

	loaded, err := Load(LoadOptions{
		RepositoryRoot: root,
		OperatorHome:   operatorHome,
		YardName:       "named",
		DisablePrivate: true,
		Environment: map[string]string{
			"SUBYARD_OPERATOR_HOME": operatorHome,
			"SUBYARD_CONFIG_HOME":   configHome,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := loaded.Context
	if ctx.InstanceName != "fixture-yard" || ctx.IncusProject != "subyard-named" || ctx.SSHPort != 3333 {
		t.Fatalf("named context mismatch: %#v", ctx)
	}
	if !ctx.NestedE2EVMs || ctx.ForwardSSHAgent {
		t.Fatalf("public yard template was not applied: %#v", ctx)
	}
	if loaded.Environment["E2E_VM_CPU"] != "1" {
		t.Fatalf("machine yard file did not override its template: %#v", loaded.Environment)
	}
	if ctx.Paths.HostBase != filepath.Join(root, "host") {
		t.Fatalf("host base was not normalized: %s", ctx.Paths.HostBase)
	}
	if ctx.YardType != domain.YardLocal {
		t.Fatalf("unexpected yard type: %s", ctx.YardType)
	}
}

func TestRetiredE2EVMTemplateReportsMigrationAndTeardown(t *testing.T) {
	root := t.TempDir()
	configDir := filepath.Join(root, "config")
	yardFile := filepath.Join(root, "yards", "e2e-yard.env")
	writeFixture(t, yardFile, "YARD_TEMPLATE=e2e-vms\nSSH_PORT=3333\n")
	// Even if a stale file is present, the retired name must never act as an alias.
	writeFixture(t, filepath.Join(configDir, "yards", "profiles", "e2e-vms.env"), "NESTED_E2E_VMS=1\n")

	err := applyYardConfig(configDir, "e2e-yard", yardFile, environment{})
	if err == nil {
		t.Fatal("retired e2e-vms template was accepted")
	}
	diagnostic := err.Error()
	for _, expected := range []string{
		yardFile,
		"YARD_TEMPLATE=test-vms",
		"yard -Y e2e-yard check",
		"yard -Y e2e-yard status",
		"yard -Y e2e-yard test-vms status",
		"yard -Y e2e-yard test-vms down",
		"yard -Y e2e-yard teardown",
	} {
		if !strings.Contains(diagnostic, expected) {
			t.Fatalf("retired-template diagnostic omitted %q: %s", expected, diagnostic)
		}
	}
}

func TestLoadMachineConfigAndMigratedPrivateAssets(t *testing.T) {
	root := t.TempDir()
	operatorHome := filepath.Join(root, "home")
	configHome := filepath.Join(operatorHome, ".config", "subyard")
	shipped := filepath.Join(root, "config")
	hostAgents := filepath.Join(configHome, "overrides", "host", "agents")
	for _, directory := range []string{
		operatorHome, shipped, filepath.Join(configHome, "yards", "named"),
		filepath.Join(hostAgents, "codex"),
	} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeFixture(t, filepath.Join(shipped, "incus.project.env"), `: "${INCUS_PROJECT:=subyard}"
: "${RESTRICTED_DISK_PATHS:=/srv/subyard}"`)
	writeFixture(t, filepath.Join(shipped, "subyard.env"), `: "${INSTANCE_NAME:=yard}"
: "${INSTANCE_TYPE:=container}"
: "${SHIFT_MODE:=shift}"
: "${FORWARD_SSH_AGENT:=0}"
: "${DEV_SUDO:=0}"
: "${DEV_UID:=1000}"
: "${SSH_HOST:=yard}"
: "${SSH_PORT:=2222}"`)
	writeFixture(t, filepath.Join(shipped, "host.env"), `: "${SUBYARD_CONFIG_HOME:=$SUBYARD_OPERATOR_HOME/.config/subyard}"
: "${SUBYARD_HOME:=$SUBYARD_OPERATOR_HOME/.subyard}"
: "${STORAGE_PATH:=$SUBYARD_HOME/incus/storage}"
: "${HOST_BASE:=${RESTRICTED_DISK_PATHS:-/srv/subyard}}"`)
	writeFixture(t, filepath.Join(shipped, "agents.env"),
		`AGENT_codex_RULES="$SUBYARD_CONFIG_DIR/agents/codex/rules/repo.rules"`)
	writeFixture(t, filepath.Join(configHome, "config.env"),
		"DEV_SUDO=1\nAGENT_codex_RULES=\"$SUBYARD_CONFIG_DIR/../private/agents/codex/repo.rules\"\n")
	writeFixture(t, filepath.Join(hostAgents, "codex", "repo.rules"), "fixture\n")
	writeFixture(t, filepath.Join(configHome, "yards", "named", "config.env"), "SSH_PORT=3333\n")

	loaded, err := Load(LoadOptions{
		RepositoryRoot: root,
		OperatorHome:   operatorHome,
		YardName:       "named",
		DisablePrivate: true,
		Environment: map[string]string{
			"SUBYARD_OPERATOR_HOME": operatorHome,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.Context.DevSudo {
		t.Fatal("machine-local global overlay was not loaded")
	}
	wantRules := filepath.Join(hostAgents, "codex", "repo.rules")
	if loaded.Environment["AGENT_codex_RULES"] != wantRules {
		t.Fatalf("migrated private asset path = %q, want %q",
			loaded.Environment["AGENT_codex_RULES"], wantRules)
	}
	file, err := os.Open(loaded.Environment["AGENT_codex_RULES"])
	if err != nil {
		t.Fatalf("production agent asset path is not openable: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(loaded.Environment["AGENT_codex_RULES"]); err != nil ||
		!info.Mode().IsRegular() {
		t.Fatalf("production agent asset path is not a regular file: %v", err)
	}
	if loaded.Environment["SUBYARD_CONFIG_HOME"] != configHome ||
		loaded.Environment["SUBYARD_CONFIG_HOST_DIR"] != filepath.Join(configHome, "overrides", "host") ||
		loaded.Environment["SUBYARD_CONFIG_GENERATED_DIR"] != filepath.Join(configHome, "generated") ||
		loaded.Environment["SUBYARD_KEYS_CONSUMER_ROOT"] != filepath.Join(configHome, "generated") {
		t.Fatalf("persistent operator config root is not canonical: %#v", loaded.Environment)
	}
	if loaded.Environment["SUBYARD_CONFIG_DIR"] != shipped {
		t.Fatalf("runtime config root leaked from migration overlay: %q", loaded.Environment["SUBYARD_CONFIG_DIR"])
	}
}

func TestOperatorConfigPrecedenceAndYardAssetOverride(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	temp := t.TempDir()
	home := filepath.Join(temp, "home")
	configHome := filepath.Join(home, ".config", "subyard")
	shared := filepath.Join(configHome, "overrides", "shared", "agents", "codex", "rules", "repo.rules")
	host := filepath.Join(configHome, "overrides", "host", "agents", "codex", "rules", "repo.rules")
	yard := filepath.Join(configHome, "yards", "named", "overrides", "agents", "codex", "rules", "repo.rules")
	external := filepath.Join(temp, "external.rules")
	for path, value := range map[string]string{
		shared: "shared\n", host: "host\n", yard: "yard\n", external: "external\n",
		filepath.Join(configHome, "config.env"):                   "DEV_SUDO=1\nAGENT_codex_RULES=" + external + "\n",
		filepath.Join(configHome, "yards", "named", "config.env"): "DEV_SUDO=0\nSSH_PORT=3333\n",
	} {
		writeFixture(t, path, value)
	}
	base := map[string]string{
		"HOME": home, "SUBYARD_OPERATOR_HOME": home,
		"SUBYARD_CONFIG_HOME": configHome, "SUBYARD_HOME": filepath.Join(home, ".subyard"),
	}
	defaultLoaded, err := Load(LoadOptions{
		RepositoryRoot: root, OperatorHome: home, Environment: base, DisablePrivate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if defaultLoaded.Environment["AGENT_codex_RULES"] != host {
		t.Fatalf("host asset did not override shared/config.env: %s",
			defaultLoaded.Environment["AGENT_codex_RULES"])
	}
	namedLoaded, err := Load(LoadOptions{
		RepositoryRoot: root, OperatorHome: home, YardName: "named",
		Environment: base, DisablePrivate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if namedLoaded.Environment["AGENT_codex_RULES"] != yard || namedLoaded.Context.DevSudo {
		t.Fatalf("yard layer did not win: asset=%s sudo=%v",
			namedLoaded.Environment["AGENT_codex_RULES"], namedLoaded.Context.DevSudo)
	}
	withEnvironment := cloneStringMap(base)
	withEnvironment["AGENT_codex_RULES"] = external
	withEnvironment["DEV_SUDO"] = "1"
	environmentLoaded, err := Load(LoadOptions{
		RepositoryRoot: root, OperatorHome: home, YardName: "named",
		Environment: withEnvironment, DisablePrivate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if environmentLoaded.Environment["AGENT_codex_RULES"] != external ||
		!environmentLoaded.Context.DevSudo {
		t.Fatalf("command environment did not win: asset=%s sudo=%v",
			environmentLoaded.Environment["AGENT_codex_RULES"], environmentLoaded.Context.DevSudo)
	}
}

func cloneStringMap(values map[string]string) map[string]string {
	result := make(map[string]string, len(values))
	for name, value := range values {
		result[name] = value
	}
	return result
}

func TestResolveE2EVMCPU(t *testing.T) {
	for _, test := range []struct {
		value    string
		hostCPUs int
		want     string
	}{
		{value: "auto", hostCPUs: 1, want: "1"},
		{value: "auto", hostCPUs: 2, want: "1"},
		{value: "auto", hostCPUs: 3, want: "2"},
		{value: "auto", hostCPUs: 4, want: "2"},
		{value: "auto", hostCPUs: 5, want: "3"},
		{value: "auto", hostCPUs: 6, want: "4"},
		{value: "auto", hostCPUs: 64, want: "4"},
		{value: "7", hostCPUs: 3, want: "7"},
	} {
		got, err := resolveE2EVMCPU(test.value, test.hostCPUs)
		if err != nil || got != test.want {
			t.Fatalf("resolveE2EVMCPU(%q, %d) = %q, %v; want %q",
				test.value, test.hostCPUs, got, err, test.want)
		}
	}
	for _, value := range []string{"0", "-1", "invalid"} {
		if _, err := resolveE2EVMCPU(value, 8); err == nil {
			t.Fatalf("invalid E2E_VM_CPU %q was accepted", value)
		}
	}
	if _, err := resolveE2EVMCPU("auto", 0); err == nil {
		t.Fatal("automatic E2E_VM_CPU accepted an unavailable host CPU count")
	}
}

func TestEnvFileRejectsCommands(t *testing.T) {
	file := filepath.Join(t.TempDir(), "unsafe.env")
	writeFixture(t, file, "VALUE=$(id)\n")
	if err := applyEnvFile(file, environment{}); err == nil {
		t.Fatal("command substitution was accepted")
	}
}

func TestSingleQuotedValueIsLiteral(t *testing.T) {
	file := filepath.Join(t.TempDir(), "literal.env")
	writeFixture(t, file, "VALUE='$HOME'\n")
	values := environment{"HOME": "/operator"}
	if err := applyEnvFile(file, values); err != nil {
		t.Fatal(err)
	}
	if values["VALUE"] != "$HOME" {
		t.Fatalf("single-quoted value expanded: %q", values["VALUE"])
	}
}

func TestReadAssignmentsOverPreservesExplicitProfileOverrides(t *testing.T) {
	file := filepath.Join(t.TempDir(), "profile.conf")
	writeFixture(t, file, "IMAGE_DOCKERFILE=\"${IMAGE_DOCKERFILE:-}\"\nBASE_IMAGE=ubuntu:24.04\n")
	values, err := ReadAssignmentsOver(file, map[string]string{"IMAGE_DOCKERFILE": "docker/dev.Dockerfile"})
	if err != nil {
		t.Fatal(err)
	}
	if values["IMAGE_DOCKERFILE"] != "docker/dev.Dockerfile" || values["BASE_IMAGE"] != "ubuntu:24.04" {
		t.Fatalf("profile overlay changed precedence: %#v", values)
	}
}

func TestE2EConfigValidation(t *testing.T) {
	valid := environment{
		"E2E_VM_IMAGE": "images:debian/13/cloud", "E2E_VM_CPU": "2",
		"E2E_VM_MEMORY": "4GiB", "E2E_VM_DISK": "10GiB",
		"E2E_VM_TTL_MINUTES": "1200", "E2E_VM_BOOT_TIMEOUT": "300",
	}
	if err := validateE2EConfig(valid); err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{
		"E2E_VM_IMAGE": "-unsafe", "E2E_VM_CPU": "0", "E2E_VM_MEMORY": "4GB",
		"E2E_VM_DISK": "9GiB", "E2E_VM_TTL_MINUTES": "1441", "E2E_VM_BOOT_TIMEOUT": "29",
	} {
		values := make(environment, len(valid))
		for key, current := range valid {
			values[key] = current
		}
		values[name] = value
		if err := validateE2EConfig(values); err == nil {
			t.Errorf("%s=%q was accepted", name, value)
		}
	}
}

func TestEngineReexecDoesNotLeakPriorYardContext(t *testing.T) {
	root := t.TempDir()
	operatorHome := filepath.Join(root, "home")
	configHome := filepath.Join(root, "config-home")
	for _, directory := range []string{filepath.Join(root, "config"), filepath.Join(configHome, "yards")} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeFixture(t, filepath.Join(root, "config", "incus.project.env"), `: "${INCUS_PROJECT:=subyard}"
: "${RESTRICTED_DISK_PATHS:=/srv/subyard}"`)
	writeFixture(t, filepath.Join(root, "config", "subyard.env"), `: "${INSTANCE_NAME:=yard}"
: "${INSTANCE_TYPE:=container}"
: "${SHIFT_MODE:=shift}"
: "${FORWARD_SSH_AGENT:=0}"
: "${DEV_SUDO:=0}"
: "${DEV_UID:=1000}"
: "${SSH_HOST:=yard}"
: "${SSH_PORT:=2222}"`)
	writeFixture(t, filepath.Join(root, "config", "host.env"), `: "${SUBYARD_CONFIG_HOME:=$SUBYARD_OPERATOR_HOME/.config/subyard}"
: "${SUBYARD_HOME:=$SUBYARD_OPERATOR_HOME/.subyard}"
: "${STORAGE_PATH:=$SUBYARD_HOME/incus/storage}"
: "${HOST_BASE:=${RESTRICTED_DISK_PATHS:-/srv/subyard}}"`)
	writeFixture(t, filepath.Join(configHome, "yards", "named.env"), "SSH_PORT=3333\n")

	loaded, err := Load(LoadOptions{
		RepositoryRoot: root, OperatorHome: operatorHome, YardName: "named", DisablePrivate: true,
		Environment: map[string]string{
			"SUBYARD_OPERATOR_HOME": operatorHome, "SUBYARD_CONFIG_HOME": configHome,
			"SUBYARD_ENGINE_CONTEXT": "1", "INSTANCE_NAME": "yard", "INCUS_PROJECT": "subyard",
			"SSH_HOST": "yard", "SSH_PORT": "2222", "RESTRICTED_DISK_PATHS": "/srv/subyard",
			"HOST_BASE": "/srv/subyard", "INSTANCE_TYPE": "container", "SHIFT_MODE": "shift",
			"FORWARD_SSH_AGENT": "0", "DEV_SUDO": "0", "DEV_UID": "1000",
			"YARD_TEMPLATE": "stale", "NESTED_E2E_VMS": "1",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := loaded.Context
	if ctx.InstanceName != "yard-named" || ctx.IncusProject != "subyard-named" || ctx.SSHHost != "yard-named" {
		t.Fatalf("prior context leaked into named reload: %#v", ctx)
	}
	if ctx.NestedE2EVMs || loaded.Environment["YARD_TEMPLATE"] != "" {
		t.Fatalf("prior E2E context leaked into named reload: %#v", loaded.Environment)
	}
}

func TestMultilineAndNestedDefaults(t *testing.T) {
	file := filepath.Join(t.TempDir(), "config.env")
	writeFixture(t, file, `ROOT=/srv/test
A="${A:-
one
two
}"
B="${B:-${A}/three}"
`)
	values := environment{}
	if err := applyEnvFile(file, values); err != nil {
		t.Fatal(err)
	}
	if values["A"] != "\none\ntwo\n" || values["B"] != "\none\ntwo\n/three" {
		t.Fatalf("unexpected expansion: A=%q B=%q", values["A"], values["B"])
	}
}

func writeFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}
