package migration

import (
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
		filepath.Join(fixture.data, "config.env"))
	assertSameFile(t, filepath.Join(fixture.source, "private/yards/named.env"),
		filepath.Join(fixture.config, "yards/named.env"))
	assertSameFile(t, filepath.Join(fixture.source, "private/agents/codex/repo.rules"),
		filepath.Join(fixture.data, "operator-overlay/private/agents/codex/repo.rules"))
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
	for _, path := range []string{
		filepath.Join(fixture.data, "config.env"),
		filepath.Join(fixture.config, "yards/named.env"),
		filepath.Join(fixture.data, "operator-overlay/private/agents/codex/repo.rules"),
	} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("recovery retained imported file %s: %v", path, err)
		}
	}
	if info, err := os.Stat(runtimeLauncher); err != nil || info.Mode()&0o111 == 0 {
		t.Fatalf("recovery damaged verified runtime: %v", err)
	}
}

func TestSourceInstallDetectorIsExact(t *testing.T) {
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
		fixture.bin,
		filepath.Join(fixture.data, "runtime/current/bin"),
		filepath.Join(fixture.data, "runtime/current/scripts"),
		filepath.Join(fixture.data, "runtime/current/completions"),
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
	writeTestFile(t, filepath.Join(fixture.source, "private/config.env"), 0o600, "DEV_SUDO=1\n")
	writeTestFile(t, filepath.Join(fixture.source, "private/yards/named.env"), 0o600,
		"SSH_PORT=3333\n")
	writeTestFile(t, filepath.Join(fixture.source, "private/agents/codex/repo.rules"), 0o600,
		"fixture rule\n")
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
	)
	return command.CombinedOutput()
}

func writeTestFile(t *testing.T, path string, mode os.FileMode, contents string) {
	t.Helper()
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
