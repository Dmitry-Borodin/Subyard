package config

import (
	"bufio"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestPublicSettingsExampleCoversStaticCatalog(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
	examplePath := filepath.Join(root, "config", "settings.env.example")
	content, err := os.ReadFile(examplePath)
	if err != nil {
		t.Fatal(err)
	}

	assignments := map[string]struct{}{}
	scanner := bufio.NewScanner(strings.NewReader(string(content)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		line = strings.TrimSpace(strings.TrimPrefix(line, "#"))
		name, _, found := strings.Cut(line, "=")
		if found && ValidVariable(name) {
			assignments[name] = struct{}{}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	for _, definition := range SettingCatalog() {
		if _, ok := assignments[definition.Name]; !ok {
			t.Errorf("public settings example is missing %s", definition.Name)
		}
	}
	for _, pattern := range []string{
		"AGENT_<name>_CONFIG", "AGENT_<name>_RULES", "AGENT_<name>_CONFIG_DEST",
		"AGENT_<name>_RULES_DEST", "AGENT_<name>_PROVISION", "AGENT_<name>_COMMAND",
		"AGENT_<name>_CHECK", "AGENT_<name>_PERSIST",
	} {
		if !strings.Contains(string(content), pattern) {
			t.Errorf("public settings example is missing dynamic pattern %s", pattern)
		}
	}
}
