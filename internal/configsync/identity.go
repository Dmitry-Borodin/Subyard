package configsync

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

func HostIDPath(configHome string) string {
	return filepath.Join(configHome, "host-id")
}

func ManifestPath(configHome string) string {
	return filepath.Join(configHome, ".sync", "manifest.json")
}

func TransactionPath(configHome string) string {
	return filepath.Join(configHome, ".sync", "transaction.json")
}

func ResolveHostID(configHome string, environment map[string]string) (string, bool, error) {
	path := HostIDPath(configHome)
	if err := validateConfigurationAncestors(configHome, path); err != nil {
		return "", false, err
	}
	info, err := os.Lstat(path)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return "", false, errors.New("owner host ID must be a regular non-symlink file")
		}
		if info.Mode().Perm() != 0o600 {
			return "", false, errors.New("owner host ID file mode must be 0600")
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return "", false, err
		}
		hostID := strings.TrimSpace(string(content))
		if !safeHostID(hostID) {
			return "", false, fmt.Errorf("invalid owner host ID %q", hostID)
		}
		return hostID, false, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", false, err
	}
	hostID := strings.TrimSpace(environment["SUBYARD_HOST_ID"])
	if hostID == "" {
		hostID, err = os.Hostname()
		if err != nil {
			return "", false, fmt.Errorf("resolve initial owner host ID: %w", err)
		}
		hostID = strings.TrimSuffix(strings.TrimSpace(hostID), ".")
	}
	if !safeHostID(hostID) {
		return "", false, fmt.Errorf(
			"initial owner host ID %q is unsafe; set SUBYARD_HOST_ID to a safe value for the first sync",
			hostID,
		)
	}
	return hostID, true, nil
}

func ReadStatus(configHome string, environment map[string]string) (Status, error) {
	hostID, pending, err := ResolveHostID(configHome, environment)
	if err != nil {
		return Status{}, err
	}
	manifest, err := readManifest(configHome)
	if err != nil {
		return Status{}, err
	}
	if err := validateConfigurationAncestors(configHome, TransactionPath(configHome)); err != nil {
		return Status{}, err
	}
	_, transactionErr := os.Lstat(TransactionPath(configHome))
	recovery := transactionErr == nil
	if transactionErr != nil && !errors.Is(transactionErr, os.ErrNotExist) {
		return Status{}, transactionErr
	}
	return Status{
		HostID: hostID, HostIDPending: pending, ManifestPath: ManifestPath(configHome),
		ManifestPresent: manifest.SchemaVersion != 0, SourceCommit: manifest.SourceCommit,
		Generation: manifest.Generation, RecoveryRequired: recovery,
	}, nil
}

func safeHostID(value string) bool {
	return domain.SafeID(value) && !strings.ContainsAny(value, `/\`)
}
