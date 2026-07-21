package incusclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sync/atomic"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	incus "github.com/lxc/incus/v6/client"
	"github.com/lxc/incus/v6/shared/api"
)

type Client struct {
	socket             string
	requiredExtensions []string
}

func New(socket string, requiredExtensions ...string) *Client {
	return &Client{socket: socket, requiredExtensions: slices.Clone(requiredExtensions)}
}

func (client *Client) Server(ctx context.Context) (ports.ServerInfo, error) {
	server, err := client.connect(ctx, true)
	if err != nil {
		return ports.ServerInfo{}, err
	}
	info, _, err := server.GetServer()
	if err != nil {
		return ports.ServerInfo{}, normalizeError("get server", err)
	}
	for _, extension := range client.requiredExtensions {
		if !slices.Contains(info.APIExtensions, extension) {
			return ports.ServerInfo{}, fmt.Errorf("Incus API extension %q is required", extension)
		}
	}
	return ports.ServerInfo{
		Environment:   info.Environment.Server,
		Version:       info.Environment.ServerVersion,
		APIExtensions: slices.Clone(info.APIExtensions),
	}, nil
}

func (client *Client) Instance(ctx context.Context, project, name string) (ports.InstanceInfo, error) {
	server, err := client.connect(ctx, true)
	if err != nil {
		return ports.InstanceInfo{}, err
	}
	instance, _, err := server.UseProject(project).GetInstance(name)
	if err != nil {
		return ports.InstanceInfo{}, normalizeError("get instance", err)
	}
	instanceType := domain.InstanceType(instance.Type)
	if instanceType == "virtual-machine" {
		instanceType = domain.InstanceVM
	}
	return ports.InstanceInfo{
		Name:    instance.Name,
		Project: project,
		Type:    instanceType,
		Status:  instance.Status,
		Config:  cloneMap(instance.ExpandedConfig),
		Devices: cloneDevices(instance.ExpandedDevices),
	}, nil
}

func (client *Client) Events(ctx context.Context, types []string) (<-chan domain.OperationEvent, <-chan error) {
	events := make(chan domain.OperationEvent, 64)
	errorsOut := make(chan error, 1)
	server, err := client.connect(ctx, false)
	if err != nil {
		close(events)
		errorsOut <- err
		close(errorsOut)
		return events, errorsOut
	}
	listener, err := server.GetEvents()
	if err != nil {
		close(events)
		errorsOut <- normalizeError("open event stream", err)
		close(errorsOut)
		return events, errorsOut
	}
	var sequence atomic.Uint64
	_, err = listener.AddHandler(types, func(event api.Event) {
		data := make(map[string]any)
		if len(event.Metadata) != 0 {
			_ = json.Unmarshal(event.Metadata, &data)
		}
		current := sequence.Add(1)
		operationID, _ := data["id"].(string)
		normalized := domain.OperationEvent{
			OperationID: operationID,
			Sequence:    current,
			Revision:    current,
			Kind:        event.Type,
			At:          event.Timestamp.UTC(),
			Data:        data,
		}
		select {
		case events <- normalized:
		default:
			select {
			case errorsOut <- errors.New("Incus event consumer exceeded bounded buffer"):
			default:
			}
			listener.Disconnect()
		}
	})
	if err != nil {
		listener.Disconnect()
		close(events)
		errorsOut <- fmt.Errorf("register event handler: %w", err)
		close(errorsOut)
		return events, errorsOut
	}
	go func() {
		defer close(events)
		defer close(errorsOut)
		stopped := make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				listener.Disconnect()
			case <-stopped:
			}
		}()
		err := listener.Wait()
		close(stopped)
		if err != nil && ctx.Err() == nil {
			select {
			case errorsOut <- normalizeError("event stream", err):
			default:
			}
		}
	}()
	return events, errorsOut
}

func (client *Client) connect(ctx context.Context, skipEvents bool) (incus.InstanceServer, error) {
	server, err := incus.ConnectIncusUnixWithContext(ctx, client.socket, &incus.ConnectionArgs{
		SkipGetEvents: skipEvents,
		SkipGetServer: true,
		UserAgent:     "subyard-engine",
	})
	if err != nil {
		return nil, normalizeError("connect to Incus", err)
	}
	return server, nil
}

func normalizeError(operation string, err error) error {
	return fmt.Errorf("%s: %w", operation, err)
}

func cloneMap(source map[string]string) map[string]string {
	result := make(map[string]string, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func cloneDevices(source map[string]map[string]string) map[string]map[string]string {
	result := make(map[string]map[string]string, len(source))
	for name, values := range source {
		result[name] = cloneMap(values)
	}
	return result
}
