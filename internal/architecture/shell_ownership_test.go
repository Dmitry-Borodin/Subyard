package architecture

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/command"
)

func TestProductionShellIsReachableAndLeafOnly(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	for _, retired := range []string{"scripts/lib/cache.sh", "scripts/state/transport.sh"} {
		if _, err := os.Lstat(filepath.Join(root, retired)); err == nil {
			t.Errorf("retired shell path returned: %s", retired)
		} else if !os.IsNotExist(err) {
			t.Fatal(err)
		}
	}
	manifestFile, err := os.Open(filepath.Join(root, "config", "commands.registry"))
	if err != nil {
		t.Fatal(err)
	}
	manifest, parseErr := command.Parse(manifestFile)
	closeErr := manifestFile.Close()
	if parseErr != nil {
		t.Fatal(parseErr)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}
	definitions := manifest.Commands()
	allowedHandlers := map[string]bool{
		"00-check-host.sh": true, "security-lint.sh": true,
	}
	handlers := make(map[string]bool)
	for _, definition := range definitions {
		if strings.HasPrefix(definition.Handler, "@") {
			for _, candidate := range []string{
				definition.Name + ".sh", "yard-" + definition.Name + ".sh",
				strings.TrimPrefix(definition.Handler, "@") + ".sh",
				"yard-" + strings.TrimPrefix(definition.Handler, "@") + ".sh",
			} {
				if _, err := os.Lstat(filepath.Join(root, "scripts", candidate)); err == nil {
					t.Errorf("native command keeps a replaced shell path: scripts/%s", candidate)
				}
			}
			continue
		}
		handlers[definition.Handler] = true
		path := filepath.Join(root, "scripts", definition.Handler)
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
			t.Errorf("manifest handler is unavailable: scripts/%s", definition.Handler)
		}
		if !allowedHandlers[definition.Handler] {
			t.Errorf("core registry uses a non-leaf shell handler: scripts/%s", definition.Handler)
		}
	}

	productionShell := shellFiles(t, filepath.Join(root, "scripts"))
	goSources := sourceFiles(t, []string{filepath.Join(root, "internal")}, func(path string) bool {
		return strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go")
	})
	externalSources := sourceFiles(t, []string{
		filepath.Join(root, "internal"), filepath.Join(root, "config"), filepath.Join(root, "bin"),
		filepath.Join(root, "dev"), filepath.Join(root, ".github"),
	}, func(path string) bool { return !strings.HasSuffix(path, "_test.go") })
	shellSources := append(shellFiles(t, filepath.Join(root, "scripts")),
		shellFiles(t, filepath.Join(root, "config", "profiles"))...)
	for _, script := range productionShell {
		path, err := filepath.Rel(filepath.Join(root, "scripts"), script)
		if err != nil {
			t.Fatal(err)
		}
		if path == "install-cli.sh" || handlers[filepath.ToSlash(path)] ||
			containsSource(t, externalSources, "scripts/"+filepath.ToSlash(path)) ||
			containsSource(t, goSources, `"`+filepath.ToSlash(path)+`"`) ||
			hasShellCaller(t, script, filepath.ToSlash(path), shellSources) {
			continue
		}
		t.Errorf("unreferenced production shell file: scripts/%s", filepath.ToSlash(path))
	}
}

func hasShellCaller(t *testing.T, target, path string, sources []string) bool {
	t.Helper()
	for _, source := range sources {
		if source == target {
			continue
		}
		relative, err := filepath.Rel(filepath.Dir(source), target)
		if err != nil {
			t.Fatal(err)
		}
		contents, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		text := string(contents)
		for _, reference := range []string{
			"$SCRIPT_DIR/" + filepath.ToSlash(relative),
			"${SCRIPT_DIR}/" + filepath.ToSlash(relative),
			"$SCRIPT_DIR/" + path,
			"$ROOT/" + path,
		} {
			if strings.Contains(text, reference) {
				return true
			}
		}
	}
	return false
}

func containsSource(t *testing.T, sources []string, needle string) bool {
	t.Helper()
	for _, source := range sources {
		contents, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(contents), needle) {
			return true
		}
	}
	return false
}

func shellFiles(t *testing.T, root string) []string {
	t.Helper()
	return sourceFiles(t, []string{root}, func(path string) bool { return strings.HasSuffix(path, ".sh") })
}

func sourceFiles(t *testing.T, roots []string, include func(string) bool) []string {
	t.Helper()
	var result []string
	for _, root := range roots {
		err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
			if os.IsNotExist(err) {
				return nil
			}
			if err != nil {
				return err
			}
			if !entry.IsDir() && entry.Type().IsRegular() && include(path) {
				result = append(result, path)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return result
}
