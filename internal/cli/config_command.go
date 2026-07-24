package cli

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type configTarget struct {
	Name   string
	Loaded config.Loaded
}

type configAsset struct {
	Name        string
	Source      string
	Destination string
}

func (cli *CLI) runConfig(ctx context.Context, loaded config.Loaded, arguments []string) int {
	if len(arguments) == 0 || commandHelpRequested(arguments) {
		fmt.Fprintf(cli.options.Stdout,
			"Usage: %s config paths | status [--all-local] | apply [--all-local] [--yes]\n",
			cli.options.Program)
		return 0
	}
	action := arguments[0]
	allLocal, assumeYes := false, cli.env["ASSUME_YES"] == "1"
	for _, argument := range arguments[1:] {
		switch argument {
		case "--all-local":
			allLocal = true
		case "-y", "--yes":
			assumeYes = true
		default:
			cli.errorf("config %s: unknown argument %q", action, argument)
			return 2
		}
	}
	switch action {
	case "paths":
		if len(arguments) != 1 {
			cli.errorf("config paths accepts no options")
			return 2
		}
		return cli.writeConfigPaths(loaded)
	case "status", "apply":
	default:
		cli.errorf("config expects paths, status or apply")
		return 2
	}
	targets, err := cli.localConfigTargets(loaded, allLocal)
	if err != nil {
		cli.errorf("config %s: %v", action, err)
		return 1
	}
	if action == "status" {
		if err := cli.configStatus(ctx, targets, true); err != nil {
			cli.errorf("config status: %v", err)
			return 1
		}
		return 0
	}
	return cli.applyConfig(ctx, targets, assumeYes)
}

func (cli *CLI) writeConfigPaths(loaded config.Loaded) int {
	values := loaded.Environment
	fmt.Fprintf(cli.options.Stdout, "runtime-defaults: %s\n", loaded.Context.Paths.ConfigDir)
	fmt.Fprintf(cli.options.Stdout, "config-root: %s\n", loaded.Context.Paths.ConfigHome)
	for _, layer := range []struct {
		name, key string
	}{
		{"shared-overrides", "SUBYARD_CONFIG_SHARED_DIR"},
		{"host-overrides", "SUBYARD_CONFIG_HOST_DIR"},
		{"yard-overrides", "SUBYARD_CONFIG_YARD_DIR"},
		{"secrets", "SUBYARD_CONFIG_SECRETS_DIR"},
		{"generated", "SUBYARD_CONFIG_GENERATED_DIR"},
	} {
		value := values[layer.key]
		if value == "" {
			value = "-"
		}
		fmt.Fprintf(cli.options.Stdout, "%s: %s\n", layer.name, value)
	}
	assets, err := effectiveConfigAssets(loaded)
	if err != nil {
		cli.errorf("config paths: %v", err)
		return 1
	}
	for _, asset := range assets {
		fmt.Fprintf(cli.options.Stdout, "asset %s: %s (%s)\n",
			asset.Name, asset.Source, configPathScope(asset.Source, values))
	}
	return 0
}

func configPathScope(path string, values map[string]string) string {
	for _, layer := range []struct {
		key, name string
	}{
		{"SUBYARD_CONFIG_YARD_DIR", "yard"},
		{"SUBYARD_CONFIG_HOST_DIR", "host"},
		{"SUBYARD_CONFIG_SHARED_DIR", "shared"},
		{"SUBYARD_CONFIG_GENERATED_DIR", "generated"},
		{"SUBYARD_CONFIG_SECRETS_DIR", "secret"},
		{"SUBYARD_CONFIG_DIR", "runtime-default"},
	} {
		if root := values[layer.key]; root != "" && pathWithinCLI(path, root) {
			return layer.name
		}
	}
	return "environment-or-external"
}

func (cli *CLI) localConfigTargets(loaded config.Loaded, allLocal bool) ([]configTarget, error) {
	if !allLocal {
		return []configTarget{{Name: loaded.Context.YardName, Loaded: loaded}}, nil
	}
	names := map[string]struct{}{"default": {}}
	yardsRoot := filepath.Join(loaded.Context.Paths.ConfigHome, "yards")
	entries, err := os.ReadDir(yardsRoot)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() {
			if domain.SafeName(name) {
				if info, statErr := os.Lstat(filepath.Join(yardsRoot, name, "config.env")); statErr == nil && info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 {
					names[name] = struct{}{}
				}
			}
			continue
		}
		if filepath.Ext(name) == ".env" {
			legacy := strings.TrimSuffix(name, ".env")
			if domain.SafeName(legacy) {
				names[legacy] = struct{}{}
			}
		}
	}
	sorted := make([]string, 0, len(names))
	for name := range names {
		sorted = append(sorted, name)
	}
	sort.Strings(sorted)
	targets := make([]configTarget, 0, len(sorted))
	for _, name := range sorted {
		targetLoaded, err := cli.loadInventoryLoaded(name, loaded)
		if err != nil {
			return nil, fmt.Errorf("yard %s: %w", name, err)
		}
		if targetLoaded.Context.YardType == domain.YardRemote {
			continue
		}
		targets = append(targets, configTarget{Name: name, Loaded: targetLoaded})
	}
	return targets, nil
}

func (cli *CLI) configStatus(
	ctx context.Context,
	targets []configTarget,
	checkDrift bool,
) error {
	if len(targets) == 0 {
		return errors.New("no local yards selected")
	}
	configHome := targets[0].Loaded.Context.Paths.ConfigHome
	if err := validateManagedConfigTree(configHome); err != nil {
		return err
	}
	legacy, err := legacyConfigInputs(targets[0].Loaded)
	if err != nil {
		return err
	}
	for _, path := range legacy {
		fmt.Fprintf(cli.options.Stdout, "attention: legacy input requires review/import: %s\n", path)
	}
	var drifted []string
	for _, target := range targets {
		state, drift, err := cli.configTargetDrift(ctx, target, checkDrift)
		if err != nil {
			return fmt.Errorf("yard %s: %w", target.Name, err)
		}
		fmt.Fprintf(cli.options.Stdout, "yard %s: %s\n", target.Name, state)
		if drift {
			drifted = append(drifted, target.Name)
		}
	}
	if len(drifted) != 0 {
		return fmt.Errorf("agent config drift in yards: %s", strings.Join(drifted, ", "))
	}
	return nil
}

func (cli *CLI) applyConfig(ctx context.Context, targets []configTarget, assumeYes bool) int {
	if len(targets) == 0 {
		cli.errorf("config apply: no local yards selected")
		return 1
	}
	if err := validateManagedConfigTree(targets[0].Loaded.Context.Paths.ConfigHome); err != nil {
		cli.errorf("config apply: %v", err)
		return 1
	}
	running := make([]configTarget, 0, len(targets))
	for _, target := range targets {
		if target.Loaded.Context.YardType == domain.YardRemote {
			cli.errorf("config apply does not implicitly operate on remote yard %s", target.Name)
			return 1
		}
		state, _, err := cli.configTargetDrift(ctx, target, false)
		if err != nil {
			cli.errorf("config apply: yard %s: %v", target.Name, err)
			return 1
		}
		if state == "running" || state == "drift" {
			running = append(running, target)
		} else {
			fmt.Fprintf(cli.options.Stdout, "yard %s: %s; skipped\n", target.Name, state)
		}
	}
	if len(running) == 0 {
		fmt.Fprintln(cli.options.Stdout, "config apply: no running local yards")
		return 0
	}
	if !assumeYes {
		prompt := cli.options.Prompt
		if prompt == nil {
			prompt = streamPrompt{input: cli.options.Stdin, output: cli.options.Stderr}
		}
		names := make([]string, 0, len(running))
		for _, target := range running {
			names = append(names, target.Name)
		}
		accepted, err := prompt.Confirm(ctx, "Apply operator config",
			[]string{"refresh agent configs in local running yards: " + strings.Join(names, ", ")})
		if err != nil {
			cli.errorf("config apply: %v", err)
			return 1
		}
		if !accepted {
			cli.errorf("config apply: operation declined")
			return 1
		}
	}
	applier := cli.options.Config
	if applier == nil {
		applier = dispatcherConfigApplier{
			path: cli.options.DispatcherPath, environment: cli.baseEnv,
			stdout: cli.options.Stdout, stderr: cli.options.Stderr,
		}
	}
	for _, target := range running {
		if err := applier.ApplyConfig(ctx, target.Name); err != nil {
			cli.errorf("config apply: yard %s: %v", target.Name, err)
			return 1
		}
	}
	if err := cli.configStatus(ctx, running, true); err != nil {
		cli.errorf("config apply verification: %v", err)
		return 1
	}
	return 0
}

type dispatcherConfigApplier struct {
	path        string
	environment map[string]string
	stdout      io.Writer
	stderr      io.Writer
}

func (applier dispatcherConfigApplier) ApplyConfig(ctx context.Context, yard string) error {
	arguments := []string{}
	if yard != "" && yard != "default" {
		arguments = append(arguments, "-Y", yard)
	}
	arguments = append(arguments, "init", "--configs", "--yes")
	command := exec.CommandContext(ctx, applier.path, arguments...)
	command.Env = environmentList(applier.environment, map[string]string{"ASSUME_YES": "1"})
	command.Stdin = strings.NewReader("")
	command.Stdout = applier.stdout
	command.Stderr = applier.stderr
	return command.Run()
}

func (cli *CLI) configTargetDrift(
	ctx context.Context,
	target configTarget,
	check bool,
) (string, bool, error) {
	if target.Loaded.Context.YardType == domain.YardRemote {
		return "remote (host config only)", false, nil
	}
	incus, executor := cli.statusPorts()
	info, err := incus.Instance(ctx, target.Loaded.Context.IncusProject,
		target.Loaded.Context.InstanceName)
	if errors.Is(err, ports.ErrInstanceNotFound) {
		return "absent", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if !strings.EqualFold(info.Status, "running") {
		return "stopped", false, nil
	}
	if !check {
		return "running", false, nil
	}
	assets, err := effectiveConfigAssets(target.Loaded)
	if err != nil {
		return "", false, err
	}
	for _, asset := range assets {
		hostHash, err := hashRegularFile(asset.Source)
		if err != nil {
			return "", false, fmt.Errorf("%s: %w", asset.Name, err)
		}
		result, err := executor.Exec(ctx, target.Loaded.Context.IncusProject,
			target.Loaded.Context.InstanceName, ports.InstanceExecRequest{
				Command: []string{"sha256sum", "--", asset.Destination},
				User:    uint32(target.Loaded.Context.DevUID),
				Group:   uint32(target.Loaded.Context.DevUID),
			})
		if err != nil || result.ExitCode != 0 {
			return "drift", true, nil
		}
		fields := strings.Fields(string(result.Stdout))
		if len(fields) == 0 || fields[0] != hostHash {
			return "drift", true, nil
		}
	}
	return "converged", false, nil
}

func effectiveConfigAssets(loaded config.Loaded) ([]configAsset, error) {
	values := loaded.Environment
	var result []configAsset
	for _, agent := range strings.Fields(values["AGENTS"]) {
		if !domain.SafeName(agent) {
			return nil, fmt.Errorf("invalid agent name %q", agent)
		}
		for _, kind := range []string{"CONFIG", "RULES"} {
			source := values["AGENT_"+agent+"_"+kind]
			destination := values["AGENT_"+agent+"_"+kind+"_DEST"]
			if source == "" || destination == "" {
				continue
			}
			if filepath.IsAbs(destination) || destination == ".." ||
				strings.HasPrefix(filepath.Clean(destination), ".."+string(filepath.Separator)) {
				return nil, fmt.Errorf("invalid %s %s destination", agent, kind)
			}
			result = append(result, configAsset{
				Name: agent + "." + strings.ToLower(kind), Source: source,
				Destination: filepath.Join("/home", loaded.Context.DevUser, destination),
			})
		}
	}
	sort.Slice(result, func(left, right int) bool { return result[left].Name < result[right].Name })
	return result, nil
}

func hashRegularFile(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", errors.New("source is not a regular non-symlink file")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", hash.Sum(nil)), nil
}

func validateManagedConfigTree(root string) error {
	info, err := os.Lstat(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return errors.New("config root must be a real directory")
	}
	uid := uint32(os.Getuid())
	if err := validateConfigOwnerMode(root, info, true, uid); err != nil {
		return err
	}
	for _, relative := range []string{"config.env", "overrides", "yards", "secrets", "generated"} {
		path := filepath.Join(root, relative)
		if err := filepath.WalkDir(path, func(path string, entry os.DirEntry, walkErr error) error {
			if errors.Is(walkErr, os.ErrNotExist) {
				return filepath.SkipDir
			}
			if walkErr != nil {
				return walkErr
			}
			info, err := os.Lstat(path)
			if err != nil {
				return err
			}
			return validateConfigOwnerMode(path, info, entry.IsDir(), uid)
		}); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func validateConfigOwnerMode(path string, info os.FileInfo, directory bool, uid uint32) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uid {
		return fmt.Errorf("config path is not operator-owned: %s", path)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("config path is a symlink: %s", path)
	}
	if directory {
		if !info.IsDir() {
			return fmt.Errorf("config path is not a directory: %s", path)
		}
		if info.Mode().Perm()&0o022 != 0 {
			return fmt.Errorf("config directory is group/world writable: %s", path)
		}
		return nil
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("config path is not a regular file: %s", path)
	}
	sensitive := filepath.Base(path) == "config.env" ||
		strings.Contains(path, string(filepath.Separator)+"secrets"+string(filepath.Separator)) ||
		strings.Contains(path, string(filepath.Separator)+"generated"+string(filepath.Separator))
	if sensitive && info.Mode().Perm() != 0o600 {
		return fmt.Errorf("sensitive config file mode must be 0600: %s", path)
	}
	if !sensitive && info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("config file is group/world writable: %s", path)
	}
	return nil
}

func legacyConfigInputs(loaded config.Loaded) ([]string, error) {
	var result []string
	legacyRoot := filepath.Join(loaded.Context.Paths.ConfigHome, "secrets", "legacy")
	if err := filepath.WalkDir(legacyRoot, func(path string, entry os.DirEntry, err error) error {
		if errors.Is(err, os.ErrNotExist) {
			return filepath.SkipDir
		}
		if err != nil {
			return err
		}
		if !entry.IsDir() {
			relative, _ := filepath.Rel(loaded.Context.Paths.ConfigHome, path)
			result = append(result, relative)
		}
		return nil
	}); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	flat, _ := filepath.Glob(filepath.Join(loaded.Context.Paths.ConfigHome, "yards", "*.env"))
	for _, path := range flat {
		relative, _ := filepath.Rel(loaded.Context.Paths.ConfigHome, path)
		result = append(result, relative)
	}
	if info, err := os.Lstat(filepath.Join(loaded.Context.Paths.DataHome, "operator-overlay")); err == nil && info.IsDir() {
		result = append(result, "legacy-data:operator-overlay (ignored)")
	}
	sort.Strings(result)
	return result, nil
}

func pathWithinCLI(path, root string) bool {
	path, root = filepath.Clean(path), filepath.Clean(root)
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != ".." &&
		!strings.HasPrefix(relative, ".."+string(filepath.Separator))
}
