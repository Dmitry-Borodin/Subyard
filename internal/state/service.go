package state

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type Service struct {
	Store ports.ProjectStore
}

func (service Service) Validate(ctx context.Context) error {
	if service.Store == nil {
		return errors.New("project store is required")
	}
	_, err := service.Store.List(ctx)
	return err
}

func (service Service) Write(
	ctx context.Context,
	id string,
	name string,
	hostPath string,
	yardPath string,
	mode domain.ProjectMode,
	sshHost string,
	importedAt string,
) error {
	record := domain.ProjectRecord{
		Schema: 1, ProjectID: id, Name: name, HostPath: hostPath, YardPath: yardPath,
		Mode: mode, SSHHost: sshHost, ImportedAt: importedAt,
	}
	return service.Store.Put(ctx, record)
}

func (service Service) Set(ctx context.Context, id, field, value string) error {
	record, err := service.Store.Get(ctx, id)
	if err != nil {
		return err
	}
	switch field {
	case "target":
		record.Target = value
	case "profile":
		record.Profile = value
	case "registrySource":
		record.RegistrySource = value
	default:
		return fmt.Errorf("unsupported project state field %q", field)
	}
	return service.Store.Put(ctx, record)
}

func (service Service) UpsertYard(
	ctx context.Context,
	id string,
	name string,
	mode domain.ProjectMode,
	target string,
	sshHost string,
) error {
	if strings.ContainsAny(name, "\n\t") || name == "" {
		return errors.New("invalid project name")
	}
	record, err := service.Store.Get(ctx, id)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return err
	}
	if errors.Is(err, ErrNotFound) {
		record = domain.ProjectRecord{
			Schema: 1, ProjectID: id, HostPath: "", RegistrySource: "yard",
		}
	}
	record.Name = name
	record.Mode = mode
	record.Target = target
	record.YardPath = YardPath(id)
	record.SSHHost = sshHost
	if record.HostPath == "" {
		record.RegistrySource = "yard"
	} else {
		record.RegistrySource = ""
	}
	return service.Store.Put(ctx, record)
}

func (service Service) UnregisterYard(ctx context.Context, id string) error {
	record, err := service.Store.Get(ctx, id)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if record.HostPath != "" {
		return nil
	}
	return service.Store.Delete(ctx, id)
}

func Field(record domain.ProjectRecord, name string) (string, error) {
	switch name {
	case "projectId":
		return record.ProjectID, nil
	case "name":
		return record.Name, nil
	case "hostPath":
		return record.HostPath, nil
	case "yardPath":
		return record.YardPath, nil
	case "mode":
		return string(record.Mode), nil
	case "sshHost":
		return record.SSHHost, nil
	case "importedAt":
		return record.ImportedAt, nil
	case "target":
		return record.Target, nil
	case "profile":
		return record.Profile, nil
	case "registrySource":
		return record.RegistrySource, nil
	default:
		return "", fmt.Errorf("unknown project state field %q", name)
	}
}

func YardPath(id string) string { return filepath.Join("/srv/workspaces", id, "src") }

func ProjectID(path string) (string, error) {
	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	realPath, err = filepath.Abs(realPath)
	if err != nil {
		return "", err
	}
	base := strings.Map(func(char rune) rune {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '.' || char == '_' || char == '-' {
			return char
		}
		return '-'
	}, filepath.Base(realPath))
	digest := sha256.Sum256([]byte(realPath))
	return fmt.Sprintf("%s-%x", base, digest[:4]), nil
}

func WorkspaceDevice(id string) string {
	return "ws-" + strings.Map(func(char rune) rune {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') {
			return char
		}
		return '-'
	}, id)
}
