package domain

import (
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

type YardType string

const (
	YardLocal  YardType = "local"
	YardRemote YardType = "remote"
)

type InstanceType string

const (
	InstanceContainer InstanceType = "container"
	InstanceVM        InstanceType = "vm"
)

type RuntimePaths struct {
	RepositoryRoot string `json:"repositoryRoot"`
	ConfigDir      string `json:"configDir"`
	OperatorHome   string `json:"operatorHome"`
	ConfigHome     string `json:"configHome"`
	DataHome       string `json:"dataHome"`
	StoragePath    string `json:"storagePath"`
	HostBase       string `json:"hostBase"`
	StateDir       string `json:"stateDir"`
}

type Context struct {
	YardName        string       `json:"yardName"`
	YardType        YardType     `json:"yardType"`
	InstanceType    InstanceType `json:"instanceType"`
	InstanceName    string       `json:"instanceName"`
	IncusProject    string       `json:"incusProject"`
	IncusBridge     string       `json:"incusBridge"`
	SSHHost         string       `json:"sshHost"`
	SSHPort         int          `json:"sshPort"`
	RemoteDest      string       `json:"remoteDest,omitempty"`
	RemoteYard      string       `json:"remoteYard,omitempty"`
	ShiftMode       string       `json:"shiftMode"`
	ForwardSSHAgent bool         `json:"forwardSshAgent"`
	DevSudo         bool         `json:"devSudo"`
	DevUID          int          `json:"devUid"`
	Paths           RuntimePaths `json:"paths"`
}

func NormalizeContext(ctx Context) (Context, error) {
	clean := func(name, value string) (string, error) {
		if !filepath.IsAbs(value) {
			return "", fmt.Errorf("%s must be an absolute path", name)
		}
		return filepath.Clean(value), nil
	}

	fields := []struct {
		name  string
		value *string
	}{
		{"repository root", &ctx.Paths.RepositoryRoot},
		{"config dir", &ctx.Paths.ConfigDir},
		{"operator home", &ctx.Paths.OperatorHome},
		{"config home", &ctx.Paths.ConfigHome},
		{"data home", &ctx.Paths.DataHome},
		{"storage path", &ctx.Paths.StoragePath},
		{"host base", &ctx.Paths.HostBase},
		{"state dir", &ctx.Paths.StateDir},
	}
	for _, field := range fields {
		value, err := clean(field.name, *field.value)
		if err != nil {
			return Context{}, err
		}
		*field.value = value
	}
	if err := ctx.Validate(); err != nil {
		return Context{}, err
	}
	return ctx, nil
}

func (ctx Context) Validate() error {
	if ctx.YardName == "" {
		return errors.New("yard name is required")
	}
	if ctx.YardType != YardLocal && ctx.YardType != YardRemote {
		return fmt.Errorf("yard type must be %q or %q", YardLocal, YardRemote)
	}
	if ctx.InstanceType != InstanceContainer && ctx.InstanceType != InstanceVM {
		return fmt.Errorf("instance type must be %q or %q", InstanceContainer, InstanceVM)
	}
	if ctx.InstanceName == "" || ctx.IncusProject == "" || ctx.SSHHost == "" {
		return errors.New("instance name, Incus project and SSH host are required")
	}
	if ctx.ShiftMode != "shift" && ctx.ShiftMode != "acl" {
		return errors.New("shift mode must be shift or acl")
	}
	if ctx.DevUID < 0 {
		return errors.New("dev UID must be non-negative")
	}
	if ctx.Paths.HostBase != filepath.Clean(ctx.Paths.HostBase) {
		return errors.New("host base must be normalized")
	}
	if broadHostPath(ctx.Paths.HostBase, ctx.Paths.OperatorHome) {
		return fmt.Errorf("host base is too broad: %s", ctx.Paths.HostBase)
	}
	if ctx.YardType == YardLocal && (ctx.SSHPort < 1 || ctx.SSHPort > 65535) {
		return errors.New("SSH port must be an integer from 1 to 65535")
	}
	if ctx.YardType == YardRemote && ctx.RemoteDest == "" {
		return errors.New("remote yard context requires a remote destination")
	}
	return nil
}

func broadHostPath(path, operatorHome string) bool {
	broad := []string{"/", "/boot", "/dev", "/etc", "/home", "/opt", "/proc", "/root", "/run", "/srv", "/sys", "/usr", "/var"}
	return slices.Contains(broad, path) || path == operatorHome
}

type ProjectMode string

const (
	ProjectSync ProjectMode = "sync"
	ProjectGit  ProjectMode = "git"
	ProjectBind ProjectMode = "bind"
)

type ProjectRecord struct {
	Schema         int         `json:"schema"`
	ProjectID      string      `json:"projectId"`
	Name           string      `json:"name"`
	HostPath       string      `json:"hostPath"`
	YardPath       string      `json:"yardPath"`
	Mode           ProjectMode `json:"mode"`
	SSHHost        string      `json:"sshHost"`
	ImportedAt     string      `json:"importedAt,omitempty"`
	Target         string      `json:"target,omitempty"`
	Profile        string      `json:"profile,omitempty"`
	RegistrySource string      `json:"registrySource,omitempty"`
}

func (record ProjectRecord) Validate(expectedID string) error {
	if record.Schema != 1 {
		return fmt.Errorf("unsupported project state schema %d", record.Schema)
	}
	if !SafeID(record.ProjectID) {
		return fmt.Errorf("invalid project ID %q", record.ProjectID)
	}
	if expectedID != "" && record.ProjectID != expectedID {
		return fmt.Errorf("project ID %q does not match filename %q", record.ProjectID, expectedID)
	}
	if record.Name == "" || record.YardPath == "" || record.SSHHost == "" {
		return errors.New("project name, yard path and SSH host are required")
	}
	if record.Mode != ProjectSync && record.Mode != ProjectGit && record.Mode != ProjectBind {
		return fmt.Errorf("invalid project mode %q", record.Mode)
	}
	if record.Target != "" && record.Target != "yard" && !SafeName(record.Target) {
		return fmt.Errorf("invalid project target %q", record.Target)
	}
	if record.Profile != "" && !SafeName(record.Profile) {
		return fmt.Errorf("invalid project profile %q", record.Profile)
	}
	if record.RegistrySource != "" && record.RegistrySource != "yard" {
		return fmt.Errorf("invalid registry source %q", record.RegistrySource)
	}
	return nil
}

func SafeID(value string) bool {
	if value == "" || strings.HasPrefix(value, "-") {
		return false
	}
	for _, char := range value {
		if !(char >= 'a' && char <= 'z') && !(char >= 'A' && char <= 'Z') &&
			!(char >= '0' && char <= '9') && char != '.' && char != '_' && char != '-' {
			return false
		}
	}
	return true
}

func SafeName(value string) bool {
	if value == "" || !((value[0] >= 'a' && value[0] <= 'z') || (value[0] >= '0' && value[0] <= '9')) {
		return false
	}
	for _, char := range value {
		if !(char >= 'a' && char <= 'z') && !(char >= '0' && char <= '9') && char != '_' && char != '-' {
			return false
		}
	}
	return true
}

type CredentialMetadata struct {
	SchemaVersion   int       `json:"schemaVersion"`
	CredentialID    string    `json:"credentialId"`
	RevisionID      string    `json:"revisionId"`
	Parents         []string  `json:"parents"`
	Label           string    `json:"label"`
	Kind            string    `json:"kind"`
	Zone            string    `json:"zone"`
	Scope           string    `json:"scope"`
	Consumer        string    `json:"consumer"`
	State           string    `json:"state"`
	RecipientActors []string  `json:"recipientActors"`
	Exclusive       bool      `json:"exclusive"`
	Syncable        bool      `json:"syncable"`
	AuthorityHost   string    `json:"authorityHost,omitempty"`
	AssignedYard    string    `json:"assignedYard,omitempty"`
	AssignmentEpoch int64     `json:"assignmentEpoch"`
	ActorID         string    `json:"actorId"`
	ActorCounter    int64     `json:"actorCounter"`
	Timestamp       time.Time `json:"timestamp"`
}

type OperationEvent struct {
	OperationID string         `json:"operationId"`
	Sequence    uint64         `json:"sequence"`
	Revision    uint64         `json:"revision"`
	Kind        string         `json:"kind"`
	At          time.Time      `json:"at"`
	Data        map[string]any `json:"data,omitempty"`
}

type AdapterRequest struct {
	Schema      int               `json:"schema"`
	OperationID string            `json:"operationId"`
	Adapter     string            `json:"adapter"`
	Action      string            `json:"action"`
	Context     map[string]string `json:"context"`
	Input       map[string]any    `json:"input,omitempty"`
}

type AdapterResult struct {
	Schema      int            `json:"schema"`
	OperationID string         `json:"operationId"`
	Status      string         `json:"status"`
	Output      map[string]any `json:"output,omitempty"`
	ErrorCode   string         `json:"errorCode,omitempty"`
}

type CommandEffect string

const (
	CommandRead   CommandEffect = "read"
	CommandMutate CommandEffect = "mutate"
)

type RemotePolicy string

const (
	RemoteOnController RemotePolicy = "local"
	RemoteOnOwner      RemotePolicy = "forward"
	RemoteDenied       RemotePolicy = "deny"
)

type ExecutionTarget string

const (
	TargetLocalController ExecutionTarget = "local-controller"
	TargetLocalOwner      ExecutionTarget = "local-owner"
	TargetRemoteOwner     ExecutionTarget = "remote-owner"
)

type CommandPolicy struct {
	Name         string
	Effect       CommandEffect
	RemotePolicy RemotePolicy
	Consequences []string
}

type OperationPlan struct {
	OperationID string          `json:"operationId"`
	Command     string          `json:"command"`
	Target      ExecutionTarget `json:"target"`
	Confirmed   bool            `json:"confirmed"`
	CreatedAt   time.Time       `json:"createdAt"`
}
