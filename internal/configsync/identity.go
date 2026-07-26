package configsync

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/Subyard/Subyard/internal/domain"
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
	info, err := os.Lstat(path)
	if err == nil {
		if err := validateConfigurationAncestors(configHome, path); err != nil {
			return "", false, err
		}
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

func EnsureHostID(configHome string, environment map[string]string) (string, error) {
	hostID, pending, err := ResolveHostID(configHome, environment)
	if err != nil || !pending {
		return hostID, err
	}
	if err := os.MkdirAll(configHome, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(configHome, 0o700); err != nil {
		return "", err
	}
	path := HostIDPath(configHome)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		resolved, stillPending, resolveErr := ResolveHostID(configHome, environment)
		if resolveErr != nil {
			return "", resolveErr
		}
		if stillPending {
			return "", errors.New("owner HostID initialization did not converge")
		}
		return resolved, nil
	}
	if err != nil {
		return "", err
	}
	if _, err := file.WriteString(hostID + "\n"); err != nil {
		file.Close()
		_ = os.Remove(path)
		return "", err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		_ = os.Remove(path)
		return "", err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return "", err
	}
	return hostID, nil
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
