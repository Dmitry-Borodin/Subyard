package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/hostruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/incusclient"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/testvmsruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if len(os.Args) > 1 && os.Args[1] == "_test-vms-status" {
		manifest := os.Getenv("SUBYARD_E2E_ALLOCATION_MANIFEST")
		if err := testvmsruntime.WritePublicStatus(os.Stdout, manifest); err != nil {
			fmt.Fprintf(os.Stderr, "test-vms: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "_test-vms-worker" {
		configPath := os.Getenv("SUBYARD_TEST_VMS_CONFIG")
		if configPath == "" {
			configPath = testvmsruntime.DefaultConfigPath
		}
		runtime, err := testvmsruntime.LoadRuntime(configPath, os.Stdout, os.Stderr)
		if err == nil {
			runtime.ExecutablePath, err = os.Executable()
		}
		if err == nil {
			err = runtime.Run(ctx, os.Args[2:], processEnvironment())
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "test-vms: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "_power-reconcile" {
		client := incusclient.New(os.Getenv("SUBYARD_INCUS_SOCKET"), "projects")
		os.Exit(cli.RunBootPower(ctx, os.Args[2:], os.Stdout, os.Stderr,
			application.BootPowerReconciler{
				Inventory: client, Instances: client, Power: client,
				Network: hostruntime.NetworkGuard{},
			}))
	}
	root, err := repositoryRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "yard: %v\n", err)
		os.Exit(2)
	}
	workingDirectory, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "yard: resolve working directory: %v\n", err)
		os.Exit(2)
	}
	dispatcherPath, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "yard: resolve executable: %v\n", err)
		os.Exit(2)
	}
	program, err := cli.New(cli.Options{
		RepositoryRoot: root,
		DispatcherPath: dispatcherPath,
		Program:        filepath.Base(os.Args[0]),
		Arguments:      os.Args[1:],
		Environment:    os.Environ(),
		WorkingDir:     workingDirectory,
		Stdin:          os.Stdin,
		Stdout:         os.Stdout,
		Stderr:         os.Stderr,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "yard: initialize engine: %v\n", err)
		os.Exit(2)
	}
	os.Exit(program.Run(ctx))
}

func processEnvironment() map[string]string {
	result := map[string]string{}
	for _, assignment := range os.Environ() {
		for index := range assignment {
			if assignment[index] == '=' {
				result[assignment[:index]] = assignment[index+1:]
				break
			}
		}
	}
	return result
}

func repositoryRoot() (string, error) {
	if explicit := os.Getenv("SUBYARD_REPOSITORY_ROOT"); explicit != "" {
		return filepath.Abs(explicit)
	}
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return "", err
	}
	directory := filepath.Dir(executable)
	if filepath.Base(directory) == "bin" {
		return filepath.Dir(directory), nil
	}
	if filepath.Base(directory) == ".build" {
		return filepath.Dir(directory), nil
	}
	return "", fmt.Errorf("set SUBYARD_REPOSITORY_ROOT for executable %s", executable)
}
