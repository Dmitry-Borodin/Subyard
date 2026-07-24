package migration

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type sourceInstallFixture struct {
	home, source, bin, data, config, rc, login string
}

func TestSourceInstallMigrationAndRecovery(t *testing.T) {
	requireJQ(t)
	fixture := newSourceInstallFixture(t,
		"# Stable launcher for a release-installed native Go control-plane engine.")
	rcBefore := readTestFile(t, fixture.rc)
	loginBefore := readTestFile(t, fixture.login)

	output, err := fixture.migrate()
	if err != nil {
		t.Fatalf("migration failed: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), "migrated source installation") {
		t.Fatalf("migration result is incomplete: %s", output)
	}
	runtimeLauncher := filepath.Join(fixture.data, "runtime/current/bin/yard")
	for _, name := range []string{"yard", "sy"} {
		target, err := os.Readlink(filepath.Join(fixture.bin, name))
		if err != nil || target != runtimeLauncher {
			t.Fatalf("%s did not switch to runtime: target=%q err=%v", name, target, err)
		}
	}
	assertSameFile(t, filepath.Join(fixture.source, "private/config.env"),
		filepath.Join(fixture.config, "config.env"))
	assertSameFile(t, filepath.Join(fixture.config, "yards/named/config.env"),
		filepath.Join(fixture.data, "recovery/pre-go-source/normalized-yard-1.env"))
	if got := string(readTestFile(t,
		filepath.Join(fixture.config, "yards/named/config.env"))); got !=
		"YARD_TEMPLATE=test-vms\nSSH_PORT=3333\n" {
		t.Fatalf("retired yard template was not normalized: %q", got)
	}
	assertSameFile(t, filepath.Join(fixture.source, "private/agents/codex/repo.rules"),
		filepath.Join(fixture.config, "overrides/host/agents/codex/repo.rules"))
	assertSameFile(t, filepath.Join(fixture.data,
		"recovery/pre-go-source/legacy-operator-overlay.before/private/agents/claude/settings.json"),
		filepath.Join(fixture.config, "overrides/host/agents/claude/settings.json"))
	for source, destination := range map[string]string{
		"config/profiles/openclaw/profile.env": "secrets/profiles/openclaw/profile.env",
		"config/staging/canonical.conf":        "overrides/host/staging/canonical.conf",
		"config/staging/canonical.env":         "secrets/legacy/staging/canonical.env",
		"config/prod-fingerprints":             "overrides/host/prod-fingerprints",
		"config/qa-pool/broker.conf":           "overrides/host/qa-pool/broker.conf",
		"config/qa-pool/secrets.env":           "secrets/legacy/qa-pool/secrets.env",
		"config/qa-pool/pool.jsonl":            "secrets/legacy/qa-pool/pool.jsonl",
	} {
		assertSameFile(t, filepath.Join(fixture.source, source),
			filepath.Join(fixture.config, destination))
	}
	for _, path := range []string{
		filepath.Join(fixture.config, "config.env"),
		filepath.Join(fixture.config, "yards/named/config.env"),
		filepath.Join(fixture.config, "overrides/host/agents/codex/repo.rules"),
		filepath.Join(fixture.config, "secrets/legacy/staging/canonical.env"),
	} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("migrated file is not protected: %s mode=%v err=%v", path, info.Mode(), err)
		}
	}
	for _, path := range []string{
		filepath.Join(fixture.data, "config.env"),
		filepath.Join(fixture.data, "operator-overlay"),
	} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("legacy data source remained active after migration: %s", path)
		}
	}
	rcAfter := string(readTestFile(t, fixture.rc))
	if !strings.Contains(rcAfter, filepath.Join(fixture.data, "runtime/current/completions/yard.bash")) ||
		strings.Contains(rcAfter, filepath.Join(fixture.source, "completions/yard.bash")) {
		t.Fatalf("completion was not moved to the stable runtime: %s", rcAfter)
	}

	recovery := filepath.Join(fixture.data, "recovery/pre-go-source/restore.sh")
	command := exec.Command(recovery)
	command.Env = append(os.Environ(), "HOME="+fixture.home, "SUBYARD_HOME="+fixture.data)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("source recovery failed: %v\n%s", err, output)
	}
	for _, name := range []string{"yard", "sy"} {
		target, err := filepath.EvalSymlinks(filepath.Join(fixture.bin, name))
		if err != nil || target != filepath.Join(fixture.source, "bin/yard") {
			t.Fatalf("%s did not recover source launcher: target=%q err=%v", name, target, err)
		}
	}
	if string(readTestFile(t, fixture.rc)) != string(rcBefore) ||
		string(readTestFile(t, fixture.login)) != string(loginBefore) {
		t.Fatal("recovery did not restore exact shell files")
	}
	assertSameFile(t, filepath.Join(fixture.source, "private/config.env"),
		filepath.Join(fixture.data, "config.env"))
	if string(readTestFile(t, filepath.Join(fixture.data,
		"operator-overlay/private/agents/claude/settings.json"))) != "{\"fixture\":true}\n" {
		t.Fatal("recovery did not restore the previous operator overlay")
	}
	for _, path := range []string{
		filepath.Join(fixture.config, "config.env"),
		filepath.Join(fixture.config, "yards/named/config.env"),
		filepath.Join(fixture.config, "overrides/host/agents/codex/repo.rules"),
		filepath.Join(fixture.config, "secrets/legacy/staging/canonical.env"),
	} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("recovery retained imported file %s: %v", path, err)
		}
	}
	if info, err := os.Stat(runtimeLauncher); err != nil || info.Mode()&0o111 == 0 {
		t.Fatalf("recovery damaged verified runtime: %v", err)
	}
}

func TestSourceInstallMigrationConflictAndExistingIdenticalTarget(t *testing.T) {
	requireJQ(t)
	t.Run("conflict", func(t *testing.T) {
		fixture := newSourceInstallFixture(t,
			"# Stable launcher for a release-installed native Go control-plane engine.")
		target := filepath.Join(fixture.config, "secrets/legacy/staging/canonical.env")
		writeTestFile(t, target, 0o600, "different\n")
		output, err := fixture.migrate()
		if err == nil || !strings.Contains(string(output), "different content") {
			t.Fatalf("conflicting destination was not rejected: err=%v output=%s", err, output)
		}
		assertSourceEntrypoints(t, fixture)
		if string(readTestFile(t, target)) != "different\n" {
			t.Fatal("conflicting destination was changed")
		}
		if _, err := os.Lstat(filepath.Join(fixture.config, "config.env")); !os.IsNotExist(err) {
			t.Fatal("failed transaction retained an earlier created file")
		}
	})

	t.Run("identical", func(t *testing.T) {
		fixture := newSourceInstallFixture(t,
			"# Stable launcher for a release-installed native Go control-plane engine.")
		source := filepath.Join(fixture.source, "config/staging/canonical.env")
		target := filepath.Join(fixture.config, "secrets/legacy/staging/canonical.env")
		writeTestFile(t, target, 0o600, string(readTestFile(t, source)))
		if output, err := fixture.migrate(); err != nil {
			t.Fatalf("identical destination was rejected: %v\n%s", err, output)
		}
		if output, err := fixture.migrate(); err == nil || exitStatus(err) != 3 || len(output) != 0 {
			t.Fatalf("repeat migration did not report already-runtime status: status=%d output=%s",
				exitStatus(err), output)
		}
		recovery := filepath.Join(fixture.data, "recovery/pre-go-source/restore.sh")
		command := exec.Command(recovery)
		command.Env = append(os.Environ(), "HOME="+fixture.home, "SUBYARD_HOME="+fixture.data)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("recovery failed: %v\n%s", err, output)
		}
		if _, err := os.Stat(target); err != nil {
			t.Fatalf("recovery removed a pre-existing identical destination: %v", err)
		}
	})
}

func TestSourceInstallMigrationRejectsUnsafeSourceAndDestination(t *testing.T) {
	requireJQ(t)
	for _, test := range []struct {
		name string
		edit func(*testing.T, sourceInstallFixture)
		want string
	}{
		{
			name: "group-writable-source",
			edit: func(t *testing.T, fixture sourceInstallFixture) {
				if err := os.Chmod(filepath.Join(fixture.source, "config/staging/canonical.env"), 0o622); err != nil {
					t.Fatal(err)
				}
			},
			want: "group/world writable",
		},
		{
			name: "unsafe-existing-mode",
			edit: func(t *testing.T, fixture sourceInstallFixture) {
				source := filepath.Join(fixture.source, "config/staging/canonical.env")
				target := filepath.Join(fixture.config, "secrets/legacy/staging/canonical.env")
				writeTestFile(t, target, 0o644, string(readTestFile(t, source)))
			},
			want: "unsafe mode",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newSourceInstallFixture(t,
				"# Stable launcher for a release-installed native Go control-plane engine.")
			test.edit(t, fixture)
			output, err := fixture.migrate()
			if err == nil || !strings.Contains(string(output), test.want) {
				t.Fatalf("unsafe input was not rejected: err=%v output=%s", err, output)
			}
			assertSourceEntrypoints(t, fixture)
		})
	}
}

func TestSourceInstallDetectorIsExact(t *testing.T) {
	requireJQ(t)
	for _, test := range []struct {
		name, marker string
		ok           bool
	}{
		{"historical-bash", "# historical thin dispatcher over scripts/", true},
		{"unknown", "# unknown launcher", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newSourceInstallFixture(t, test.marker)
			output, err := fixture.migrate()
			if test.ok && err != nil {
				t.Fatalf("recognized launcher failed: %v\n%s", err, output)
			}
			if !test.ok {
				if err == nil {
					t.Fatal("unknown launcher was accepted")
				}
				if !strings.Contains(string(output), "not a recognized source-installed Subyard version") {
					t.Fatalf("unknown launcher did not fail at detector: %s", output)
				}
				target, linkErr := filepath.EvalSymlinks(filepath.Join(fixture.bin, "yard"))
				if linkErr != nil || target != filepath.Join(fixture.source, "bin/yard") {
					t.Fatalf("failed detector changed entrypoint: target=%q err=%v", target, linkErr)
				}
			}
		})
	}

	t.Run("ambiguous-entrypoint", func(t *testing.T) {
		fixture := newSourceInstallFixture(t,
			"# Stable launcher for a release-installed native Go control-plane engine.")
		sy := filepath.Join(fixture.bin, "sy")
		if err := os.Remove(sy); err != nil {
			t.Fatal(err)
		}
		writeTestFile(t, sy, 0o600, "ambiguous\n")
		if output, err := fixture.migrate(); err == nil {
			t.Fatalf("regular sy entrypoint was accepted: %s", output)
		}
		target, err := filepath.EvalSymlinks(filepath.Join(fixture.bin, "yard"))
		if err != nil || target != filepath.Join(fixture.source, "bin/yard") {
			t.Fatalf("ambiguous detector changed yard: target=%q err=%v", target, err)
		}
	})
}

func newSourceInstallFixture(t *testing.T, marker string) sourceInstallFixture {
	t.Helper()
	root := filepath.Clean(filepath.Join("..", ".."))
	temp := t.TempDir()
	fixture := sourceInstallFixture{
		home: filepath.Join(temp, "home"),
	}
	fixture.source = filepath.Join(fixture.home, "Subyard")
	fixture.bin = filepath.Join(fixture.home, ".local/bin")
	fixture.data = filepath.Join(fixture.home, ".subyard")
	fixture.config = filepath.Join(fixture.home, ".config/subyard")
	fixture.rc = filepath.Join(fixture.home, ".bashrc")
	fixture.login = filepath.Join(fixture.home, ".profile")
	for _, directory := range []string{
		filepath.Join(fixture.source, "bin"),
		filepath.Join(fixture.source, "scripts"),
		filepath.Join(fixture.source, "config"),
		filepath.Join(fixture.source, "completions"),
		filepath.Join(fixture.source, "private/yards"),
		filepath.Join(fixture.source, "private/agents/codex"),
		filepath.Join(fixture.source, "config/profiles/openclaw"),
		filepath.Join(fixture.source, "config/staging"),
		filepath.Join(fixture.source, "config/qa-pool"),
		filepath.Join(fixture.data, "operator-overlay/private/agents/claude"),
		fixture.bin,
		filepath.Join(fixture.data, "runtime/current/bin"),
		filepath.Join(fixture.data, "runtime/current/scripts"),
		filepath.Join(fixture.data, "runtime/current/completions"),
		fixture.config,
	} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, filepath.Join(fixture.source, "bin/yard"), 0o700,
		"#!/bin/sh\n"+marker+"\nexit 0\n")
	writeTestFile(t, filepath.Join(fixture.source, "scripts/install-cli.sh"), 0o700,
		"#!/bin/sh\nexit 0\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/commands.registry"), 0o600, "fixture\n")
	writeTestFile(t, filepath.Join(fixture.source, "completions/yard.bash"), 0o600, "fixture\n")
	writeTestFile(t, filepath.Join(fixture.source, "private/config.env"), 0o600,
		"DEV_SUDO=1\nAGENT_codex_RULES=\"$SUBYARD_CONFIG_DIR/../private/agents/codex/repo.rules\"\n")
	writeTestFile(t, filepath.Join(fixture.data, "config.env"), 0o600,
		"DEV_SUDO=1\nAGENT_codex_RULES=\"$SUBYARD_CONFIG_DIR/../private/agents/codex/repo.rules\"\n")
	writeTestFile(t, filepath.Join(fixture.data,
		"operator-overlay/private/agents/claude/settings.json"), 0o600,
		"{\"fixture\":true}\n")
	writeTestFile(t, filepath.Join(fixture.source, "private/yards/named.env"), 0o600,
		"YARD_TEMPLATE=e2e-vms\nSSH_PORT=3333\n")
	writeTestFile(t, filepath.Join(fixture.source, "private/agents/codex/repo.rules"), 0o600,
		"fixture rule\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/profiles/openclaw/profile.env"), 0o600,
		"PROFILE_TOKEN=fixture\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/staging/canonical.conf"), 0o600,
		"PROFILE=openclaw\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/staging/canonical.env"), 0o600,
		"STAGING_TOKEN=fixture\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/prod-fingerprints"), 0o600,
		"fixture-hash\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/qa-pool/broker.conf"), 0o600,
		"CLOUD_PORT=3210\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/qa-pool/secrets.env"), 0o600,
		"QA_SECRET=fixture\n")
	writeTestFile(t, filepath.Join(fixture.source, "config/qa-pool/pool.jsonl"), 0o600,
		"{\"fixture\":true}\n")
	writeTestFile(t, fixture.rc, 0o600, fmt.Sprintf(
		"# keep\nexport KEEP_ME=1\n# Subyard CLI completion\n[ -f %q ] && source %q\n",
		filepath.Join(fixture.source, "completions/yard.bash"),
		filepath.Join(fixture.source, "completions/yard.bash")))
	writeTestFile(t, fixture.login, 0o600, "# keep login\n")
	if err := os.Symlink(filepath.Join(fixture.source, "bin/yard"),
		filepath.Join(fixture.bin, "yard")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(fixture.source, "bin/yard"),
		filepath.Join(fixture.bin, "sy")); err != nil {
		t.Fatal(err)
	}

	candidate := filepath.Join(fixture.data, "runtime/current/bin/yard")
	writeTestFile(t, candidate, 0o700, `#!/bin/sh
case "$*" in
  --version) printf 'yard fixture\n' ;;
  '_migrate check'|'_migrate apply'|'-Y named _migrate check'|'-Y named _migrate apply') ;;
	  '_migrate paths') printf '{"dataHome":"%s","configHome":"%s"}\n' "$TEST_DATA_HOME" "$TEST_CONFIG_HOME" ;;
	  _migrate\ overlay-manifest\ *)
	    printf '%s\n' '{"schemaVersion":2,"sourceRoot":"'"$TEST_SOURCE_ROOT"'","dataHome":"'"$TEST_DATA_HOME"'","configHome":"'"$TEST_CONFIG_HOME"'","entries":['\
'{"sourceBase":"source-root","source":"private/config.env","destinationRoot":"config-home","destination":"config.env","kind":"host-config","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"data-home","source":"config.env","destinationRoot":"config-home","destination":"config.env","kind":"previous-host-config","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"private/yards/named.env","destinationRoot":"config-home","destination":"yards/named/config.env","kind":"yard-config","mode":"0600","conflictPolicy":"identical-or-fail","contentTransform":"yard-template-e2e-vms-to-test-vms"},'\
'{"sourceBase":"source-root","source":"private/agents/codex/repo.rules","destinationRoot":"config-home","destination":"overrides/host/agents/codex/repo.rules","kind":"agent-asset","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"data-home","source":"operator-overlay/private/agents/claude/settings.json","destinationRoot":"config-home","destination":"overrides/host/agents/claude/settings.json","kind":"agent-asset","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"config/profiles/openclaw/profile.env","destinationRoot":"config-home","destination":"secrets/profiles/openclaw/profile.env","kind":"profile-secret","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"config/staging/canonical.conf","destinationRoot":"config-home","destination":"overrides/host/staging/canonical.conf","kind":"staging-config","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"config/staging/canonical.env","destinationRoot":"config-home","destination":"secrets/legacy/staging/canonical.env","kind":"legacy-staging-secret","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"config/prod-fingerprints","destinationRoot":"config-home","destination":"overrides/host/prod-fingerprints","kind":"production-fingerprints","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"config/qa-pool/broker.conf","destinationRoot":"config-home","destination":"overrides/host/qa-pool/broker.conf","kind":"qa-broker-config","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"config/qa-pool/secrets.env","destinationRoot":"config-home","destination":"secrets/legacy/qa-pool/secrets.env","kind":"legacy-qa-secrets","mode":"0600","conflictPolicy":"identical-or-fail"},'\
'{"sourceBase":"source-root","source":"config/qa-pool/pool.jsonl","destinationRoot":"config-home","destination":"secrets/legacy/qa-pool/pool.jsonl","kind":"legacy-qa-pool","mode":"0600","conflictPolicy":"identical-or-fail"}'\
']}'
    ;;
  _migrate\ normalize-yard-config\ *)
    sed 's/^YARD_TEMPLATE=e2e-vms$/YARD_TEMPLATE=test-vms/' "$3" > "$4"
    chmod 0600 "$4"
    ;;
  *) exit 64 ;;
esac
`)
	writeTestFile(t, filepath.Join(fixture.data, "runtime/current/bin/yard-engine"), 0o700,
		"#!/bin/sh\nexit 0\n")
	writeTestFile(t, filepath.Join(fixture.data, "runtime/current/completions/yard.bash"), 0o600,
		"fixture\n")
	for _, name := range []string{"migrate-source-install.sh", "restore-source-install.sh"} {
		payload := readTestFile(t, filepath.Join(root, "scripts", name))
		writeTestFile(t, filepath.Join(fixture.data, "runtime/current/scripts", name), 0o700,
			string(payload))
	}
	return fixture
}

func (fixture sourceInstallFixture) migrate() ([]byte, error) {
	command := exec.Command(
		filepath.Join(fixture.data, "runtime/current/scripts/migrate-source-install.sh"),
		"--runtime-root", filepath.Join(fixture.data, "runtime"),
		"--bin-dir", fixture.bin,
		"--rc", fixture.rc,
		"--login-rc", fixture.login,
		"--data-home", fixture.data,
	)
	command.Env = append(os.Environ(),
		"HOME="+fixture.home,
		"TEST_DATA_HOME="+fixture.data,
		"TEST_CONFIG_HOME="+fixture.config,
		"TEST_SOURCE_ROOT="+fixture.source,
	)
	return command.CombinedOutput()
}

func assertSourceEntrypoints(t *testing.T, fixture sourceInstallFixture) {
	t.Helper()
	for _, name := range []string{"yard", "sy"} {
		target, err := filepath.EvalSymlinks(filepath.Join(fixture.bin, name))
		if err != nil || target != filepath.Join(fixture.source, "bin/yard") {
			t.Fatalf("%s source entrypoint changed: target=%q err=%v", name, target, err)
		}
	}
}

func exitStatus(err error) int {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	return -1
}

func requireJQ(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("jq"); err != nil {
		t.Skip("jq is required by the production installer")
	}
}

func writeTestFile(t *testing.T, path string, mode os.FileMode, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
}

func readTestFile(t *testing.T, path string) []byte {
	t.Helper()
	payload, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func assertSameFile(t *testing.T, left, right string) {
	t.Helper()
	if string(readTestFile(t, left)) != string(readTestFile(t, right)) {
		t.Fatalf("files differ: %s %s", left, right)
	}
}
