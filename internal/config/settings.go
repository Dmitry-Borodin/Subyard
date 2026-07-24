package config

import (
	"sort"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type SettingApplication string

const (
	SettingNextCommand SettingApplication = "next command"
	SettingYardInit    SettingApplication = "yard init"
	SettingConfigApply SettingApplication = "config apply"
)

type SettingResolution struct {
	Scope  string
	Role   string
	Path   string
	Line   int
	Value  string
	Status string
	Detail string
}

type SettingTrace struct {
	Name           string
	EffectiveValue string
	Application    SettingApplication
	Sensitive      bool
	Resolutions    []SettingResolution
}

type ConfigurationLayer struct {
	Scope   string
	Role    string
	Path    string
	Present bool
}

type settingKind uint8

const (
	settingScalar settingKind = iota
	settingFile
	settingAny
)

type settingDefinition struct {
	Application SettingApplication
	Sensitive   bool
	Kind        settingKind
}

var scalarSettingApplications = map[string]SettingApplication{
	"ADB_CONSOLE_EMULATOR_PORT": SettingNextCommand,
	"ADB_CONSOLE_PROXY_PORT":    SettingNextCommand,
	"ADB_EMULATOR_PORT":         SettingNextCommand,
	"ADB_PROXY_PORT":            SettingNextCommand,
	"AGENTS":                    SettingYardInit,
	"BASE_IMAGE":                SettingYardInit,
	"BASE_IMAGE_FALLBACK":       SettingYardInit,
	"DEV_SUDO":                  SettingYardInit,
	"DEV_UID":                   SettingYardInit,
	"DEV_USER":                  SettingYardInit,
	"E2E_VM_BOOT_TIMEOUT":       SettingNextCommand,
	"E2E_VM_CPU":                SettingNextCommand,
	"E2E_VM_DISK":               SettingNextCommand,
	"E2E_VM_IMAGE":              SettingNextCommand,
	"E2E_VM_MEMORY":             SettingNextCommand,
	"E2E_VM_TTL_MINUTES":        SettingNextCommand,
	"FORWARD_SSH_AGENT":         SettingYardInit,
	"HOST_BASE":                 SettingNextCommand,
	"HOST_CLAUDE_MD":            SettingYardInit,
	"HOST_CODEX_AGENTS_MD":      SettingYardInit,
	"HOST_LINKS":                SettingYardInit,
	"HOST_MOUNTS":               SettingYardInit,
	"HOST_OPENCODE_AGENTS_MD":   SettingYardInit,
	"INCUS_BRIDGE":              SettingYardInit,
	"INCUS_PROJECT":             SettingNextCommand,
	"INSTANCE_NAME":             SettingNextCommand,
	"INSTANCE_TYPE":             SettingYardInit,
	"LIMITS_CPU":                SettingYardInit,
	"LIMITS_MEMORY":             SettingYardInit,
	"NESTED_E2E_VMS":            SettingYardInit,
	"REMOTE_DEST":               SettingNextCommand,
	"REMOTE_DEV_USER":           SettingNextCommand,
	"REMOTE_SSH_PORT":           SettingNextCommand,
	"REMOTE_YARD":               SettingNextCommand,
	"RESTRICTED_DISK_PATHS":     SettingYardInit,
	"SHIFT_MODE":                SettingYardInit,
	"SRV_POOL":                  SettingYardInit,
	"SRV_VOLUME":                SettingYardInit,
	"SSH_HOST":                  SettingNextCommand,
	"SSH_PORT":                  SettingNextCommand,
	"STORAGE_PATH":              SettingYardInit,
	"YARD_CAPABILITIES":         SettingYardInit,
	"YARD_CAPS":                 SettingYardInit,
	"YARD_DEVICES":              SettingYardInit,
	"YARD_MOUNTS":               SettingYardInit,
	"YARD_PROFILES":             SettingYardInit,
	"YARD_TEMPLATE":             SettingYardInit,
	"YARD_TYPE":                 SettingNextCommand,
}

func settingDefinitionFor(name string) (settingDefinition, bool) {
	if application, ok := scalarSettingApplications[name]; ok {
		return settingDefinition{Application: application, Kind: settingScalar}, true
	}
	if !strings.HasPrefix(name, "AGENT_") {
		return settingDefinition{}, false
	}
	for _, suffix := range []string{
		"_CONFIG_DEST", "_RULES_DEST", "_COMMAND", "_CONFIG", "_PERSIST", "_PROVISION", "_RULES",
	} {
		agent, found := strings.CutSuffix(strings.TrimPrefix(name, "AGENT_"), suffix)
		if !found || !domain.SafeName(agent) {
			continue
		}
		switch suffix {
		case "_CONFIG", "_RULES":
			return settingDefinition{Application: SettingConfigApply, Kind: settingFile}, true
		case "_CONFIG_DEST", "_RULES_DEST":
			return settingDefinition{Application: SettingConfigApply, Kind: settingScalar}, true
		case "_PROVISION":
			return settingDefinition{Application: SettingYardInit, Kind: settingFile}, true
		default:
			return settingDefinition{Application: SettingYardInit, Kind: settingScalar}, true
		}
	}
	return settingDefinition{}, false
}

type settingLayerID int

type settingLayer struct {
	ID      settingLayerID
	Scope   string
	Role    string
	Path    string
	Present bool
	Kind    settingKind
	Names   map[string]struct{}
}

type settingAssignment struct {
	Layer  settingLayerID
	Path   string
	Line   int
	Value  string
	Detail string
	Order  int
}

type settingTracker struct {
	layers      []settingLayer
	assignments map[string][]settingAssignment
	order       int
}

func newSettingTracker() *settingTracker {
	return &settingTracker{assignments: map[string][]settingAssignment{}}
}

func (tracker *settingTracker) addLayer(
	scope, role, path string,
	present bool,
	kind settingKind,
	names ...string,
) settingLayerID {
	id := settingLayerID(len(tracker.layers))
	applicableNames := make(map[string]struct{}, len(names))
	for _, name := range names {
		applicableNames[name] = struct{}{}
	}
	tracker.layers = append(tracker.layers, settingLayer{
		ID: id, Scope: scope, Role: role, Path: path, Present: present, Kind: kind,
		Names: applicableNames,
	})
	return id
}

func (tracker *settingTracker) record(
	layer settingLayerID,
	name, value, path string,
	line int,
	detail string,
) {
	if _, ok := settingDefinitionFor(name); !ok {
		return
	}
	tracker.order++
	tracker.assignments[name] = append(tracker.assignments[name], settingAssignment{
		Layer: layer, Path: path, Line: line, Value: value, Detail: detail, Order: tracker.order,
	})
}

func (tracker *settingTracker) normalize(name, value, detail string) {
	assignments := tracker.assignments[name]
	if len(assignments) == 0 {
		return
	}
	index := len(assignments) - 1
	assignments[index].Value = value
	if assignments[index].Detail == "" {
		assignments[index].Detail = detail
	} else {
		assignments[index].Detail += "; " + detail
	}
	tracker.assignments[name] = assignments
}

func (tracker *settingTracker) configurationLayers() []ConfigurationLayer {
	result := make([]ConfigurationLayer, 0, len(tracker.layers))
	for _, layer := range tracker.layers {
		if layer.Role == "command override" || layer.Role == "derived" {
			continue
		}
		result = append(result, ConfigurationLayer{
			Scope: layer.Scope, Role: layer.Role, Path: layer.Path, Present: layer.Present,
		})
	}
	return result
}

func (tracker *settingTracker) traces(values environment) map[string]SettingTrace {
	names := make(map[string]struct{}, len(scalarSettingApplications)+len(tracker.assignments))
	for name := range scalarSettingApplications {
		names[name] = struct{}{}
	}
	for name := range tracker.assignments {
		names[name] = struct{}{}
	}
	for name := range values {
		if _, ok := settingDefinitionFor(name); ok {
			names[name] = struct{}{}
		}
	}

	result := make(map[string]SettingTrace, len(names))
	for name := range names {
		definition, ok := settingDefinitionFor(name)
		if !ok {
			continue
		}
		assignments := tracker.assignments[name]
		effectiveOrder := 0
		for _, assignment := range assignments {
			if assignment.Order > effectiveOrder {
				effectiveOrder = assignment.Order
			}
		}
		trace := SettingTrace{
			Name: name, EffectiveValue: values[name],
			Application: definition.Application, Sensitive: definition.Sensitive,
		}
		for _, layer := range tracker.layers {
			if layer.Kind != settingAny && layer.Kind != definition.Kind {
				continue
			}
			if len(layer.Names) != 0 {
				if _, ok := layer.Names[name]; !ok {
					continue
				}
			}
			found := false
			for _, assignment := range assignments {
				if assignment.Layer != layer.ID {
					continue
				}
				found = true
				status := "overridden"
				if assignment.Order == effectiveOrder {
					status = "effective"
				}
				path := assignment.Path
				if path == "" {
					path = layer.Path
				}
				trace.Resolutions = append(trace.Resolutions, SettingResolution{
					Scope: layer.Scope, Role: layer.Role, Path: path, Line: assignment.Line,
					Value: assignment.Value, Status: status, Detail: assignment.Detail,
				})
			}
			if !found {
				trace.Resolutions = append(trace.Resolutions, SettingResolution{
					Scope: layer.Scope, Role: layer.Role, Path: layer.Path, Status: "unset",
				})
			}
		}
		result[name] = trace
	}
	return result
}

func SettingNames(settings map[string]SettingTrace) []string {
	names := make([]string, 0, len(settings))
	for name := range settings {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
