package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/Dmitry-Borodin/Subyard/internal/cli"
)

func main() {
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
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(program.Run(ctx))
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
