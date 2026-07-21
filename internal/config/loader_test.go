package config

import (
	"os"
	"path/filepath"
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
	writeFixture(t, filepath.Join(yardDir, "named.env"), "SSH_PORT=3333\nINSTANCE_NAME=fixture-yard\nHOST_BASE="+root+"/host/../host\nRESTRICTED_DISK_PATHS="+root+"/host\n")

	ctx, err := LoadContext(LoadOptions{
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
	if ctx.InstanceName != "fixture-yard" || ctx.IncusProject != "subyard-named" || ctx.SSHPort != 3333 {
		t.Fatalf("named context mismatch: %#v", ctx)
	}
	if ctx.Paths.HostBase != filepath.Join(root, "host") {
		t.Fatalf("host base was not normalized: %s", ctx.Paths.HostBase)
	}
	if ctx.YardType != domain.YardLocal {
		t.Fatalf("unexpected yard type: %s", ctx.YardType)
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

	ctx, err := LoadContext(LoadOptions{
		RepositoryRoot: root, OperatorHome: operatorHome, YardName: "named", DisablePrivate: true,
		Environment: map[string]string{
			"SUBYARD_OPERATOR_HOME": operatorHome, "SUBYARD_CONFIG_HOME": configHome,
			"SUBYARD_ENGINE_CONTEXT": "1", "INSTANCE_NAME": "yard", "INCUS_PROJECT": "subyard",
			"SSH_HOST": "yard", "SSH_PORT": "2222", "RESTRICTED_DISK_PATHS": "/srv/subyard",
			"HOST_BASE": "/srv/subyard", "INSTANCE_TYPE": "container", "SHIFT_MODE": "shift",
			"FORWARD_SSH_AGENT": "0", "DEV_SUDO": "0", "DEV_UID": "1000",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if ctx.InstanceName != "yard-named" || ctx.IncusProject != "subyard-named" || ctx.SSHHost != "yard-named" {
		t.Fatalf("prior context leaked into named reload: %#v", ctx)
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
