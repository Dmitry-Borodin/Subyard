package ports

import (
	"context"
	"errors"
	"io"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

var ErrInstanceNotFound = errors.New("instance not found")

type ServerInfo struct {
	Environment   string   `json:"environment"`
	Version       string   `json:"version"`
	APIExtensions []string `json:"apiExtensions"`
}

type InstanceInfo struct {
	Name         string                       `json:"name"`
	Project      string                       `json:"project"`
	Type         domain.InstanceType          `json:"type"`
	Status       string                       `json:"status"`
	Config       map[string]string            `json:"config"`
	Devices      map[string]map[string]string `json:"devices"`
	LocalConfig  map[string]string            `json:"localConfig,omitempty"`
	LocalDevices map[string]map[string]string `json:"localDevices,omitempty"`
}

type ReconcileState struct {
	ProjectConfig    map[string]string
	ProfileDevices   map[string]map[string]string
	Instance         InstanceInfo
	HostPoolFound    bool
	HostNetworkFound bool
	ProjectFound     bool
	ProfileFound     bool
	InstanceFound    bool
	VolumeFound      bool
}

type Incus interface {
	Server(context.Context) (ServerInfo, error)
	Instance(context.Context, string, string) (InstanceInfo, error)
	ReconcileState(context.Context, string, string, string, string, string) (ReconcileState, error)
	Events(context.Context, []string) (<-chan domain.OperationEvent, <-chan error)
}

type InstanceConfigWriter interface {
	SetInstanceConfig(context.Context, string, string, map[string]string) error
}

type InstanceInventory interface {
	ListInstances(context.Context) ([]InstanceInfo, error)
}

type InstancePowerManager interface {
	SetInstancePower(context.Context, string, string, string, bool) error
}

type HostNetworkGuard interface {
	Check(context.Context, []string) error
}

type InstanceExecRequest struct {
	Command     []string
	Environment map[string]string
	Stdin       []byte
	User        uint32
	Group       uint32
}

type InstanceExecResult struct {
	Stdout   []byte `json:"stdout,omitempty"`
	Stderr   []byte `json:"stderr,omitempty"`
	ExitCode int    `json:"exitCode"`
}

type InstanceExecutor interface {
	Exec(context.Context, string, string, InstanceExecRequest) (InstanceExecResult, error)
}

type InstanceStreamExecutor interface {
	StreamExec(context.Context, string, string, InstanceExecRequest, io.Reader) (InstanceExecResult, error)
}

type YardExecutor interface {
	Execute(context.Context, domain.Context, InstanceExecRequest) (InstanceExecResult, error)
	Stream(context.Context, domain.Context, InstanceExecRequest, io.Reader) (InstanceExecResult, error)
}

type InstanceDeviceManager interface {
	EnsureDiskDevice(context.Context, string, string, string, string, string) (bool, error)
	RemoveDevice(context.Context, string, string, string) (bool, error)
}

type DirectoryArchiver interface {
	Open(context.Context, string) (io.ReadCloser, error)
}

type ProjectExportStore interface {
	Publish(context.Context, string, []byte) (string, error)
}

type VSCode interface {
	Run(context.Context, ...string) ([]byte, error)
}

type ProjectStore interface {
	List(context.Context) ([]domain.ProjectRecord, error)
	Get(context.Context, string) (domain.ProjectRecord, error)
	Put(context.Context, domain.ProjectRecord) error
	Delete(context.Context, string) error
}

type ProjectObserver interface {
	Observe(context.Context, domain.Context, []domain.ProjectRecord, bool) (domain.ProjectObservation, error)
}

type StatusFactsReader interface {
	ReadStatusFacts(context.Context, domain.Context, bool) (domain.StatusFacts, error)
}

type SecurityChecker interface {
	CheckSecurity(context.Context, bool, bool) (string, error)
}

type FileSystem interface {
	ReadFile(context.Context, string) ([]byte, error)
	AtomicWrite(context.Context, string, []byte, uint32) error
	Remove(context.Context, string) error
}

type CredentialStore interface {
	ListMetadata(context.Context) ([]domain.CredentialMetadata, error)
	Heads(context.Context, string) ([]domain.CredentialMetadata, error)
	Publish(context.Context, domain.CredentialMetadata, io.Reader) error
}

type CredentialMetadataReader interface {
	ListMetadata(context.Context) ([]domain.CredentialMetadata, error)
}

type CredentialStatusReader interface {
	ReadCredentialStatus(context.Context) (domain.CredentialStatus, error)
}

type CredentialCrypto interface {
	Decrypt(context.Context, domain.CredentialMetadata, io.Writer) error
	Verify(context.Context, domain.CredentialMetadata) error
}

type PeerTransport interface {
	Exchange(context.Context, string, []domain.CredentialMetadata) ([]domain.CredentialMetadata, error)
}

type Materializer interface {
	Materialize(context.Context, domain.CredentialMetadata, io.Reader) error
}

type Clock interface {
	Now() time.Time
	After(time.Duration) <-chan time.Time
}

type IDSource interface {
	NewID() string
}

type Prompter interface {
	Confirm(context.Context, string, []string) (bool, error)
}

type ConfigApplier interface {
	ApplyConfig(context.Context, string) error
}

type AdapterRunner interface {
	Run(context.Context, domain.AdapterRequest, io.Reader) (domain.AdapterResult, string, error)
}

type ReconcileStageRunner interface {
	CheckStage(context.Context, string) (bool, error)
	ApplyStage(context.Context, string) error
	VerifyStage(context.Context, string) (bool, error)
}

type InitPlatform interface {
	ReconcileStageRunner
	Preflight(context.Context, bool) error
	RefreshConfigs(context.Context) error
	Teardown(context.Context) error
}

type RemoteTransport interface {
	Call(context.Context, string, []byte) ([]byte, error)
}

type RemoteControl interface {
	Lookup(context.Context, string) (domain.RemoteRecord, bool, error)
	List(context.Context) ([]domain.RemoteRecord, error)
	ProbeOwner(context.Context, domain.RemoteSpec) (domain.RemoteInfo, error)
	ObserveOwner(context.Context, domain.RemoteSpec) (domain.RemoteInfo, time.Time, error)
	ScanYardKeys(context.Context, domain.RemoteSpec, int) ([]domain.RemoteKey, error)
	RecordedYardKeys(context.Context, string) ([]domain.RemoteKey, error)
	Apply(context.Context, domain.RemotePrepared) (domain.RemoteResult, error)
}

type AuditSink interface {
	WriteAudit(context.Context, domain.OperationEvent) error
}

type EventSink interface {
	Publish(context.Context, domain.OperationEvent) error
}
