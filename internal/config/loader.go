package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type LoadOptions struct {
	RepositoryRoot string
	OperatorHome   string
	YardName       string
	Environment    map[string]string
	DisablePrivate bool
	YardDirs       []string
}

type Loaded struct {
	Context     domain.Context
	Environment map[string]string
}

func LoadContext(options LoadOptions) (domain.Context, error) {
	loaded, err := Load(options)
	return loaded.Context, err
}

func Load(options LoadOptions) (Loaded, error) {
	ctx, values, err := load(options)
	if err != nil {
		return Loaded{}, err
	}
	environment := make(map[string]string, len(values))
	for name, value := range values {
		environment[name] = value
	}
	return Loaded{Context: ctx, Environment: environment}, nil
}

func load(options LoadOptions) (domain.Context, environment, error) {
	root, err := filepath.Abs(options.RepositoryRoot)
	if err != nil {
		return domain.Context{}, nil, fmt.Errorf("resolve repository root: %w", err)
	}
	values := environmentFrom(options.Environment)
	if values["SUBYARD_ENGINE_CONTEXT"] == "1" {
		resetInheritedContext(values)
	}
	if values["SUBYARD_CONFIG_DIR"] == "" {
		values["SUBYARD_CONFIG_DIR"] = filepath.Join(root, "config")
	}
	configDir := filepath.Clean(values["SUBYARD_CONFIG_DIR"])
	if options.OperatorHome != "" {
		values["SUBYARD_OPERATOR_HOME"] = options.OperatorHome
	}
	if values["SUBYARD_OPERATOR_HOME"] == "" {
		return domain.Context{}, nil, errors.New("operator home is required")
	}

	if !options.DisablePrivate {
		privateConfig := filepath.Join(configDir, "..", "private", "config.env")
		if err := applyOptional(privateConfig, values); err != nil {
			return domain.Context{}, nil, err
		}
	}

	yardName := options.YardName
	if yardName == "" {
		yardName = values["SUBYARD_YARD"]
	}
	if yardName == "" || yardName == "default" {
		yardName = "default"
	} else {
		if !domain.SafeName(yardName) {
			return domain.Context{}, nil, fmt.Errorf("invalid yard name %q", yardName)
		}
		yardFile, err := findYardFile(root, yardName, values, options.YardDirs)
		if err != nil {
			return domain.Context{}, nil, err
		}
		if err := applyEnvFile(yardFile, values); err != nil {
			return domain.Context{}, nil, err
		}
		applyYardDerivations(yardName, values)
	}

	for _, name := range []string{"incus.project.env", "subyard.env", "host.env", "agents.env", "ports.env"} {
		if err := applyOptional(filepath.Join(configDir, name), values); err != nil {
			return domain.Context{}, nil, err
		}
	}
	ctx, err := contextFrom(root, yardName, values)
	return ctx, values, err
}

func resetInheritedContext(values environment) {
	for _, name := range []string{
		"YARD_NAME", "YARD_TYPE", "YARD_PROFILES", "INSTANCE_TYPE", "INSTANCE_NAME", "INCUS_PROJECT",
		"INCUS_BRIDGE", "SSH_HOST", "SSH_PORT", "REMOTE_DEST", "REMOTE_YARD", "SHIFT_MODE",
		"FORWARD_SSH_AGENT", "DEV_SUDO", "DEV_UID", "DEV_USER", "NESTED_E2E_VMS",
		"E2E_VM_IMAGE", "E2E_VM_CPU", "E2E_VM_MEMORY", "E2E_VM_TTL_MINUTES", "E2E_VM_BOOT_TIMEOUT",
		"SUBYARD_STATE_DIR", "RESTRICTED_DISK_PATHS",
		"HOST_BASE", "SRV_VOLUME",
	} {
		delete(values, name)
	}
}

func environmentFrom(explicit map[string]string) environment {
	values := make(environment)
	if explicit == nil {
		for _, pair := range os.Environ() {
			name, value, ok := strings.Cut(pair, "=")
			if ok {
				values[name] = value
			}
		}
		return values
	}
	for name, value := range explicit {
		values[name] = value
	}
	return values
}

func applyOptional(path string, values environment) error {
	if _, err := os.Stat(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	return applyEnvFile(path, values)
}

func findYardFile(root, name string, values environment, explicit []string) (string, error) {
	directories := explicit
	if len(directories) == 0 {
		configHome := values["SUBYARD_CONFIG_HOME"]
		if configHome == "" {
			configHome = filepath.Join(values["SUBYARD_OPERATOR_HOME"], ".config", "subyard")
		}
		privateYards := filepath.Join(values["SUBYARD_CONFIG_DIR"], "..", "private", "yards")
		directories = []string{privateYards, filepath.Join(configHome, "yards")}
	}
	for _, directory := range directories {
		candidate := filepath.Join(directory, name+".env")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("unknown yard %q", name)
}

func applyYardDerivations(name string, values environment) {
	values["YARD_NAME"] = name
	setDefault(values, "INSTANCE_NAME", "yard-"+name)
	setDefault(values, "INCUS_PROJECT", "subyard-"+name)
	setDefault(values, "SSH_HOST", "yard-"+name)
	setDefault(values, "SRV_VOLUME", "yard-srv-"+name)
	setDefault(values, "RESTRICTED_DISK_PATHS", "/srv/subyard-"+name)
	configHome := values["SUBYARD_CONFIG_HOME"]
	if configHome == "" {
		configHome = filepath.Join(values["SUBYARD_OPERATOR_HOME"], ".config", "subyard")
	}
	setDefault(values, "SUBYARD_STATE_DIR", filepath.Join(configHome, "yards", name, "projects"))
}

func setDefault(values environment, name, value string) {
	if values[name] == "" {
		values[name] = value
	}
}

func contextFrom(root, yardName string, values environment) (domain.Context, error) {
	setDefault(values, "YARD_TYPE", "local")
	setDefault(values, "INSTANCE_TYPE", "container")
	setDefault(values, "INSTANCE_NAME", "yard")
	setDefault(values, "INCUS_PROJECT", "subyard")
	setDefault(values, "INCUS_BRIDGE", "incusbr0")
	setDefault(values, "SSH_HOST", "yard")
	setDefault(values, "DEV_USER", "dev")
	setDefault(values, "NESTED_E2E_VMS", "0")
	configHome := values["SUBYARD_CONFIG_HOME"]
	dataHome := values["SUBYARD_HOME"]
	hostBase := filepath.Clean(values["HOST_BASE"])
	restrictedBase := filepath.Clean(values["RESTRICTED_DISK_PATHS"])
	if hostBase != restrictedBase {
		return domain.Context{}, errors.New("HOST_BASE must equal RESTRICTED_DISK_PATHS")
	}
	stateDir := values["SUBYARD_STATE_DIR"]
	if stateDir == "" {
		stateDir = filepath.Join(configHome, "projects")
	}
	sshPort, err := optionalInt(values["SSH_PORT"])
	if err != nil {
		return domain.Context{}, fmt.Errorf("SSH_PORT: %w", err)
	}
	devUID, err := strconv.Atoi(values["DEV_UID"])
	if err != nil {
		return domain.Context{}, fmt.Errorf("DEV_UID must be numeric")
	}
	forwardAgent, err := zeroOne(values["FORWARD_SSH_AGENT"], "FORWARD_SSH_AGENT")
	if err != nil {
		return domain.Context{}, err
	}
	devSudo, err := zeroOne(values["DEV_SUDO"], "DEV_SUDO")
	if err != nil {
		return domain.Context{}, err
	}
	nestedE2EVMs, err := zeroOne(values["NESTED_E2E_VMS"], "NESTED_E2E_VMS")
	if err != nil {
		return domain.Context{}, err
	}
	ctx := domain.Context{
		YardName:        yardName,
		YardType:        domain.YardType(values["YARD_TYPE"]),
		InstanceType:    domain.InstanceType(values["INSTANCE_TYPE"]),
		InstanceName:    values["INSTANCE_NAME"],
		IncusProject:    values["INCUS_PROJECT"],
		IncusBridge:     values["INCUS_BRIDGE"],
		SSHHost:         values["SSH_HOST"],
		DevUser:         values["DEV_USER"],
		SSHPort:         sshPort,
		RemoteDest:      values["REMOTE_DEST"],
		RemoteYard:      values["REMOTE_YARD"],
		ShiftMode:       values["SHIFT_MODE"],
		ForwardSSHAgent: forwardAgent,
		DevSudo:         devSudo,
		NestedE2EVMs:    nestedE2EVMs,
		DevUID:          devUID,
		Paths: domain.RuntimePaths{
			RepositoryRoot: root,
			ConfigDir:      filepath.Clean(values["SUBYARD_CONFIG_DIR"]),
			OperatorHome:   values["SUBYARD_OPERATOR_HOME"],
			ConfigHome:     configHome,
			DataHome:       dataHome,
			StoragePath:    values["STORAGE_PATH"],
			HostBase:       hostBase,
			StateDir:       stateDir,
		},
	}
	return domain.NormalizeContext(ctx)
}

func optionalInt(value string) (int, error) {
	if value == "" {
		return 0, nil
	}
	return strconv.Atoi(value)
}

func zeroOne(value, name string) (bool, error) {
	switch value {
	case "0":
		return false, nil
	case "1":
		return true, nil
	default:
		return false, fmt.Errorf("%s must be 0 or 1", name)
	}
}
