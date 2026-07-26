package testyardmigration

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const (
	LegacyYard  = "e2e-yard"
	CurrentYard = "test-yard"
)

type Options struct {
	Executable  string
	ConfigHome  string
	DataHome    string
	Environment []string
	Stdout      io.Writer
	Stderr      io.Writer
}

// Apply replaces the retired e2e-yard test-vms owner with test-yard. It is a
// no-op on hosts without the canonical legacy registration.
func Apply(ctx context.Context, options Options) error {
	if options.Executable == "" || !filepath.IsAbs(options.Executable) {
		return errors.New("absolute migration executable is required")
	}
	if options.ConfigHome == "" || !filepath.IsAbs(options.ConfigHome) {
		return errors.New("absolute configuration home is required")
	}
	if options.DataHome == "" || !filepath.IsAbs(options.DataHome) {
		return errors.New("absolute data home is required")
	}
	if options.Stdout == nil {
		options.Stdout = io.Discard
	}
	if options.Stderr == nil {
		options.Stderr = io.Discard
	}
	yardsRoot := filepath.Join(options.ConfigHome, "yards")
	if exists, err := pathExists(yardsRoot); err != nil {
		return err
	} else if !exists {
		return nil
	}
	if err := ownedDirectory(yardsRoot); err != nil {
		return err
	}
	oldRegistration, newRegistration := "", ""
	for _, pair := range [][2]string{
		{filepath.Join(yardsRoot, LegacyYard, "config.env"), filepath.Join(yardsRoot, CurrentYard, "config.env")},
		{filepath.Join(yardsRoot, LegacyYard+".env"), filepath.Join(yardsRoot, CurrentYard+".env")},
	} {
		exists, err := ownedRegular(pair[0])
		if err != nil {
			return err
		}
		if exists {
			if oldRegistration != "" {
				return errors.New("multiple e2e-yard registrations exist")
			}
			oldRegistration, newRegistration = pair[0], pair[1]
		}
	}
	if oldRegistration == "" {
		return nil
	}
	if exists, err := pathExists(newRegistration); err != nil {
		return err
	} else if exists {
		return errors.New("test-yard already exists; refusing to replace either yard")
	}
	if filepath.Base(newRegistration) == "config.env" {
		if exists, err := pathExists(filepath.Dir(newRegistration)); err != nil {
			return err
		} else if exists {
			return errors.New("test-yard directory already exists; refusing to replace it")
		}
	}
	payload, err := os.ReadFile(oldRegistration)
	if err != nil {
		return err
	}
	if !selectsTestVMs(string(payload)) {
		return errors.New("e2e-yard does not select YARD_TEMPLATE=test-vms")
	}

	run := func(yard string, arguments ...string) error {
		commandArguments := append([]string{"-Y", yard}, arguments...)
		command := exec.CommandContext(ctx, options.Executable, commandArguments...)
		command.Env = options.Environment
		command.Stdin = strings.NewReader("")
		command.Stdout, command.Stderr = options.Stdout, options.Stderr
		return command.Run()
	}
	if err := run(LegacyYard, "check"); err != nil {
		return fmt.Errorf("validate legacy test yard: %w", err)
	}
	if err := run(LegacyYard, "teardown", "--yes"); err != nil {
		return fmt.Errorf("teardown legacy test yard: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(newRegistration), 0o700); err != nil {
		return recoverLegacy(run, oldRegistration, newRegistration, false, err)
	}
	if err := os.Rename(oldRegistration, newRegistration); err != nil {
		return recoverLegacy(run, oldRegistration, newRegistration, false, err)
	}
	registrationMoved := true
	if filepath.Base(oldRegistration) == "config.env" {
		err = removeEmptyDirectory(filepath.Dir(oldRegistration))
	}
	if err != nil {
		return recoverLegacy(run, oldRegistration, newRegistration, registrationMoved, err)
	}
	if err := run(CurrentYard, "init", "--yes"); err != nil {
		return recoverLegacy(run, oldRegistration, newRegistration, registrationMoved,
			fmt.Errorf("initialize test-yard: %w", err))
	}
	if err := run(CurrentYard, "check"); err != nil {
		return recoverLegacy(run, oldRegistration, newRegistration, registrationMoved,
			fmt.Errorf("validate test-yard: %w", err))
	}
	legacyController := filepath.Join(options.DataHome, "e2e", "controllers", LegacyYard)
	if err := removeManagedLegacyController(legacyController); err != nil {
		return recoverLegacy(run, oldRegistration, newRegistration, registrationMoved,
			fmt.Errorf("remove legacy controller state: %w", err))
	}
	fmt.Fprintln(options.Stdout, "migrated test VM yard e2e-yard -> test-yard")
	return nil
}

func recoverLegacy(
	run func(string, ...string) error,
	oldRegistration, newRegistration string,
	registrationMoved bool,
	cause error,
) error {
	var recovery []error
	if registrationMoved {
		if err := run(CurrentYard, "teardown", "--yes"); err != nil {
			recovery = append(recovery, fmt.Errorf("teardown failed test-yard: %w", err))
		}
		if err := os.MkdirAll(filepath.Dir(oldRegistration), 0o700); err != nil {
			recovery = append(recovery, err)
		} else if err := os.Rename(newRegistration, oldRegistration); err != nil {
			recovery = append(recovery, err)
		}
	}
	if err := run(LegacyYard, "init", "--yes"); err != nil {
		recovery = append(recovery, fmt.Errorf("recreate legacy test yard: %w", err))
	}
	if len(recovery) > 0 {
		return errors.Join(cause, fmt.Errorf("test-yard migration recovery failed: %w", errors.Join(recovery...)))
	}
	return cause
}

func removeManagedLegacyController(path string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() ||
		info.Mode().Perm()&0o077 != 0 || stat.Uid != uint32(os.Geteuid()) {
		return errors.New("legacy controller path is not an owned private directory")
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	allowed := map[string]bool{
		".operator-enrollment-v1": true,
		"agent-access.pub":        true,
		"route.tsv":               true,
		"known_hosts":             true,
	}
	markerFound := false
	for _, entry := range entries {
		if !allowed[entry.Name()] {
			return fmt.Errorf("unexpected legacy controller artifact %q", entry.Name())
		}
		artifact := filepath.Join(path, entry.Name())
		artifactInfo, err := os.Lstat(artifact)
		if err != nil {
			return err
		}
		artifactStat, ok := artifactInfo.Sys().(*syscall.Stat_t)
		if !ok || artifactInfo.Mode()&os.ModeSymlink != 0 ||
			!artifactInfo.Mode().IsRegular() || artifactStat.Nlink != 1 ||
			artifactStat.Uid != uint32(os.Geteuid()) {
			return fmt.Errorf("legacy controller artifact %q is unsafe", entry.Name())
		}
		if entry.Name() == ".operator-enrollment-v1" {
			payload, err := os.ReadFile(artifact)
			if err != nil || string(payload) != "managed\n" ||
				artifactInfo.Mode().Perm() != 0o600 {
				return errors.New("legacy controller marker is invalid")
			}
			markerFound = true
		}
	}
	if !markerFound {
		return errors.New("legacy controller marker is missing")
	}
	for _, entry := range entries {
		if err := os.Remove(filepath.Join(path, entry.Name())); err != nil {
			return err
		}
	}
	return os.Remove(path)
}

func ownedRegular(path string) (bool, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || !ok ||
		stat.Nlink != 1 || stat.Uid != uint32(os.Geteuid()) {
		return false, errors.New("legacy test-yard registration is not an owned regular file")
	}
	return true, nil
}

func ownedDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || !ok ||
		stat.Uid != uint32(os.Geteuid()) || info.Mode().Perm()&0o022 != 0 {
		return errors.New("test-yard registration root is not a private owned directory")
	}
	return nil
}

func pathExists(path string) (bool, error) {
	_, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	return err == nil, err
}

func selectsTestVMs(payload string) bool {
	for _, line := range strings.Split(payload, "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "export "))
		if line == "YARD_TEMPLATE=test-vms" ||
			line == `YARD_TEMPLATE="test-vms"` || line == "YARD_TEMPLATE='test-vms'" {
			return true
		}
	}
	return false
}

func removeEmptyDirectory(path string) error {
	err := os.Remove(path)
	if os.IsNotExist(err) || errors.Is(err, syscall.ENOTEMPTY) {
		return nil
	}
	return err
}
