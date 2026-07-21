package resource

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type Definition struct {
	Profile  string
	Name     string
	Command  string
	Handler  string
	BringUp  string
	Shutdown string
	Verbs    []string
	Title    string
	path     string
}

func (definition Definition) HandlerPath() string { return definition.path }

type Registry struct {
	definitions []Definition
	byCommand   map[string]int
	byName      map[string]int
}

func Load(root string) (Registry, error) {
	pattern := filepath.Join(root, "config", "profiles", "*", "resources", "*.res")
	files, err := filepath.Glob(pattern)
	if err != nil {
		return Registry{}, err
	}
	registry := Registry{byCommand: make(map[string]int), byName: make(map[string]int)}
	for _, file := range files {
		definition, err := loadDefinition(root, file)
		if err != nil {
			return Registry{}, err
		}
		if _, duplicate := registry.byCommand[definition.Command]; duplicate {
			return Registry{}, fmt.Errorf("duplicate resource command %q", definition.Command)
		}
		if _, duplicate := registry.byName[definition.Name]; duplicate {
			return Registry{}, fmt.Errorf("duplicate resource name %q", definition.Name)
		}
		index := len(registry.definitions)
		registry.byCommand[definition.Command] = index
		registry.byName[definition.Name] = index
		registry.definitions = append(registry.definitions, definition)
	}
	return registry, nil
}

func (registry Registry) Definitions() []Definition { return slices.Clone(registry.definitions) }

func (registry Registry) Lookup(value string) (Definition, bool) {
	if index, ok := registry.byCommand[value]; ok {
		return registry.definitions[index], true
	}
	if index, ok := registry.byName[value]; ok {
		return registry.definitions[index], true
	}
	return Definition{}, false
}

func loadDefinition(root, path string) (Definition, error) {
	profile := filepath.Base(filepath.Dir(filepath.Dir(path)))
	name := strings.TrimSuffix(filepath.Base(path), ".res")
	if !domain.SafeName(profile) || !domain.SafeName(name) {
		return Definition{}, fmt.Errorf("invalid resource identity in %s", path)
	}
	values, err := readDescriptor(path)
	if err != nil {
		return Definition{}, err
	}
	command := defaultValue(values["COMMAND"], name)
	bringUp := defaultValue(values["BRINGUP"], "up")
	shutdown := defaultValue(values["SHUTDOWN"], "down")
	handler := values["HANDLER"]
	verbs := strings.Fields(values["VERBS"])
	if !domain.SafeName(command) || !domain.SafeName(bringUp) || !domain.SafeName(shutdown) ||
		handler == "" || values["TITLE"] == "" || len(verbs) == 0 {
		return Definition{}, fmt.Errorf("resource descriptor is incomplete: %s", path)
	}
	for _, verb := range verbs {
		if !domain.SafeName(verb) {
			return Definition{}, fmt.Errorf("invalid resource verb %q in %s", verb, path)
		}
	}
	if !slices.Contains(verbs, bringUp) || !slices.Contains(verbs, shutdown) {
		return Definition{}, fmt.Errorf("resource lifecycle verbs are missing in %s", path)
	}
	profileRoot := filepath.Join(root, "config", "profiles", profile)
	handlerPath := filepath.Clean(filepath.Join(profileRoot, handler))
	relative, err := filepath.Rel(profileRoot, handlerPath)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return Definition{}, fmt.Errorf("resource handler escapes profile: %s", path)
	}
	info, err := os.Lstat(handlerPath)
	if err != nil {
		return Definition{}, fmt.Errorf("inspect resource handler %s: %w", handlerPath, err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0o111 == 0 {
		return Definition{}, fmt.Errorf("resource handler is not an executable regular file: %s", handlerPath)
	}
	return Definition{
		Profile: profile, Name: name, Command: command, Handler: handler,
		BringUp: bringUp, Shutdown: shutdown, Verbs: verbs, Title: values["TITLE"], path: handlerPath,
	}, nil
}

func readDescriptor(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	allowed := map[string]struct{}{
		"COMMAND": {}, "HANDLER": {}, "TITLE": {}, "VERBS": {}, "BRINGUP": {}, "SHUTDOWN": {},
	}
	values := make(map[string]string)
	scanner := bufio.NewScanner(file)
	line := 0
	for scanner.Scan() {
		line++
		record := strings.TrimSpace(scanner.Text())
		if record == "" || strings.HasPrefix(record, "#") {
			continue
		}
		name, value, ok := strings.Cut(record, "=")
		if !ok {
			return nil, fmt.Errorf("%s:%d: descriptor assignments only", path, line)
		}
		if _, ok := allowed[name]; !ok {
			return nil, fmt.Errorf("%s:%d: unknown descriptor field %q", path, line, name)
		}
		if _, duplicate := values[name]; duplicate {
			return nil, fmt.Errorf("%s:%d: duplicate descriptor field %q", path, line, name)
		}
		value = strings.TrimSpace(value)
		if len(value) >= 2 && ((value[0] == '"' && value[len(value)-1] == '"') ||
			(value[0] == '\'' && value[len(value)-1] == '\'')) {
			value = value[1 : len(value)-1]
		}
		if strings.Contains(value, "$(") || strings.ContainsRune(value, '`') || strings.ContainsRune(value, 0) {
			return nil, fmt.Errorf("%s:%d: unsafe descriptor value", path, line)
		}
		values[name] = value
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return values, nil
}

func defaultValue(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
