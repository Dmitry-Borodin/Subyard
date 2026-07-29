package ownerinventory

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"sync"

	"github.com/Subyard/Subyard/internal/domain"
)

type Connection struct {
	HostID      string               `json:"hostId"`
	Destination string               `json:"destination"`
	LegacyNames []string             `json:"legacyNames,omitempty"`
	Yards       map[string]YardRoute `json:"yards,omitempty"`
}

type YardRoute struct {
	SSHHost string `json:"sshHost"`
}

func (connection Connection) Validate() error {
	if err := validateHostID(connection.HostID); err != nil {
		return err
	}
	if !domain.SafeSSHTarget(connection.Destination) {
		return fmt.Errorf("invalid owner destination %q", connection.Destination)
	}
	for _, name := range connection.LegacyNames {
		if !domain.SafeName(name) {
			return fmt.Errorf("invalid legacy remote name %q", name)
		}
	}
	for yard, route := range connection.Yards {
		if !domain.SafeName(yard) || !domain.SafeSSHTarget(route.SSHHost) {
			return fmt.Errorf("invalid transport route for owner yard %q", yard)
		}
	}
	return nil
}

type Connections struct {
	Root string
}

var connectionsMu sync.Mutex

func (store Connections) List() ([]Connection, error) {
	connectionsMu.Lock()
	defer connectionsMu.Unlock()
	return store.list()
}

func (store Connections) list() ([]Connection, error) {
	directory := filepath.Join(store.Root, "connections")
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	result := make([]Connection, 0, len(entries))
	destinations := make(map[string]string)
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		payload, err := os.ReadFile(filepath.Join(directory, entry.Name()))
		if err != nil {
			return nil, err
		}
		var connection Connection
		if err := json.Unmarshal(payload, &connection); err != nil {
			return nil, fmt.Errorf("decode owner connection %q: %w", entry.Name(), err)
		}
		if err := connection.Validate(); err != nil {
			return nil, err
		}
		if entry.Name() != connection.HostID+".json" {
			return nil, errors.New("owner connection filename does not match HostID")
		}
		if other, duplicate := destinations[connection.Destination]; duplicate && other != connection.HostID {
			return nil, fmt.Errorf(
				"owner destination %q is registered for HostID %q and %q",
				connection.Destination, other, connection.HostID,
			)
		}
		destinations[connection.Destination] = connection.HostID
		result = append(result, connection)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].HostID < result[j].HostID })
	return result, nil
}

func (store Connections) Write(connection Connection) error {
	connectionsMu.Lock()
	defer connectionsMu.Unlock()
	if err := connection.Validate(); err != nil {
		return err
	}
	existing, err := store.list()
	if err != nil {
		return err
	}
	for _, current := range existing {
		if current.HostID == connection.HostID && current.Destination != connection.Destination {
			return fmt.Errorf(
				"HostID %q is already registered at %q, refusing %q",
				connection.HostID, current.Destination, connection.Destination,
			)
		}
		if current.HostID != connection.HostID && current.Destination == connection.Destination {
			return fmt.Errorf(
				"destination %q is already registered as HostID %q",
				connection.Destination, current.HostID,
			)
		}
	}
	slices.Sort(connection.LegacyNames)
	connection.LegacyNames = slices.Compact(connection.LegacyNames)
	payload, err := json.Marshal(connection)
	if err != nil {
		return err
	}
	directory := filepath.Join(store.Root, "connections")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	path := filepath.Join(directory, connection.HostID+".json")
	temporary, err := os.CreateTemp(directory, ".connection-*")
	if err != nil {
		return err
	}
	tempPath := temporary.Name()
	defer os.Remove(tempPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(payload); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}
