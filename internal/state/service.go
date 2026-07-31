package state

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/ports"
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
	return service.UpsertProject(ctx, id, name, mode, target, sshHost, "", "", 0)
}

func (service Service) UpsertObserved(
	ctx context.Context,
	record domain.ProjectRecord,
	sshHost string,
) error {
	if store, ok := service.Store.(*FileStore); ok {
		return store.ConvergeObserved(ctx, record, sshHost)
	}
	if _, err := service.Store.Get(ctx, record.ProjectID); err == nil {
		return nil
	} else if !errors.Is(err, ErrNotFound) {
		return err
	}
	return service.UpsertProject(
		ctx, record.ProjectID, record.Name, record.Mode, record.Target,
		sshHost, "", record.ImportedAt, record.IdentityVersion,
	)
}

func (service Service) UpsertProject(
	ctx context.Context,
	id string,
	name string,
	mode domain.ProjectMode,
	target string,
	sshHost string,
	hostPath string,
	importedAt string,
	identityVersion int,
) error {
	if !domain.SafeProjectName(name) {
		return errors.New("invalid project name")
	}
	records, err := service.Store.List(ctx)
	if err != nil {
		return err
	}
	for _, candidate := range records {
		if candidate.ProjectID == id {
			continue
		}
		if domain.ProjectNamesEqual(candidate.Name, name) ||
			domain.ProjectNamesEqual(candidate.ProjectID, name) ||
			domain.ProjectNamesEqual(candidate.Name, id) {
			return fmt.Errorf("project name %q conflicts with project %q", name, candidate.ProjectID)
		}
	}
	record, err := service.Store.Get(ctx, id)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return err
	}
	isNew := errors.Is(err, ErrNotFound)
	if isNew {
		record = domain.ProjectRecord{
			Schema: 1, ProjectID: id, HostPath: "", RegistrySource: "yard",
		}
	} else if record.Name != name {
		return fmt.Errorf(
			"owner project %q is already named %q; refusing stale rename to %q",
			id, record.Name, name,
		)
	}
	record.Name = name
	if identityVersion != 0 {
		record.IdentityVersion = identityVersion
	}
	record.Mode = mode
	record.Target = target
	record.Profile = ""
	if target != "" && target != "yard" {
		record.Profile = target
	}
	record.YardPath = YardPath(id)
	record.SSHHost = sshHost
	if hostPath != "" {
		record.HostPath = hostPath
		record.SourceKey = SourceKey(hostPath)
	}
	if importedAt != "" {
		record.ImportedAt = importedAt
	}
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

func (service Service) RemoveProject(ctx context.Context, id, sourceKey string) error {
	if len(sourceKey) != 64 || strings.Trim(sourceKey, "0123456789abcdef") != "" {
		return errors.New("valid project source key is required")
	}
	record, err := service.Store.Get(ctx, id)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	recordSourceKey := record.SourceKey
	if recordSourceKey == "" && record.HostPath != "" {
		recordSourceKey = SourceKey(record.HostPath)
	}
	if recordSourceKey != sourceKey {
		return errors.New("project source changed before owner removal")
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

func SourceKey(source string) string {
	digest := sha256.Sum256([]byte(source))
	return fmt.Sprintf("%x", digest[:])
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

func TechnicalID(id string) string {
	var result strings.Builder
	for index := 0; index < len(id); index++ {
		value := id[index]
		if value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' ||
			value >= '0' && value <= '9' || value == '-' {
			result.WriteByte(value)
			continue
		}
		fmt.Fprintf(&result, "_%02x", value)
	}
	return result.String()
}

func DockerImageID(id string) string {
	var result strings.Builder
	result.WriteByte('p')
	for index := 0; index < len(id); index++ {
		value := id[index]
		if value >= 'a' && value <= 'z' || value >= '0' && value <= '9' {
			result.WriteByte(value)
			continue
		}
		fmt.Fprintf(&result, "_%02x", value)
	}
	return result.String()
}

func ProjectTechnicalID(record domain.ProjectRecord) string {
	if record.IdentityVersion == 2 {
		return TechnicalID(record.ProjectID)
	}
	return strings.TrimPrefix(WorkspaceDevice(record.ProjectID), "ws-")
}

func ProjectDockerImageID(record domain.ProjectRecord) string {
	if record.IdentityVersion == 2 {
		return DockerImageID(record.ProjectID)
	}
	return record.ProjectID
}

func WorkspaceDeviceFor(record domain.ProjectRecord) string {
	return "ws-" + ProjectTechnicalID(record)
}
