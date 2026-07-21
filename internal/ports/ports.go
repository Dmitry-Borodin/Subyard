package ports

import (
	"context"
	"io"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type ServerInfo struct {
	Environment   string   `json:"environment"`
	Version       string   `json:"version"`
	APIExtensions []string `json:"apiExtensions"`
}

type InstanceInfo struct {
	Name    string                       `json:"name"`
	Project string                       `json:"project"`
	Type    domain.InstanceType          `json:"type"`
	Status  string                       `json:"status"`
	Config  map[string]string            `json:"config"`
	Devices map[string]map[string]string `json:"devices"`
}

type Incus interface {
	Server(context.Context) (ServerInfo, error)
	Instance(context.Context, string, string) (InstanceInfo, error)
	Events(context.Context, []string) (<-chan domain.OperationEvent, <-chan error)
}

type ProjectStore interface {
	List(context.Context) ([]domain.ProjectRecord, error)
	Get(context.Context, string) (domain.ProjectRecord, error)
	Put(context.Context, domain.ProjectRecord) error
	Delete(context.Context, string) error
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

type AdapterRunner interface {
	Run(context.Context, domain.AdapterRequest, io.Reader) (domain.AdapterResult, string, error)
}

type RemoteTransport interface {
	Call(context.Context, string, []byte) ([]byte, error)
}

type AuditSink interface {
	WriteAudit(context.Context, domain.OperationEvent) error
}

type EventSink interface {
	Publish(context.Context, domain.OperationEvent) error
}
