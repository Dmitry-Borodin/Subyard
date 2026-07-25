package testvmsruntime

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/crypto/ssh"
)

const enrollmentMarker = ".operator-enrollment-v1"

// EnrollmentDirectory is stable owner-host state. Unlike the legacy client
// directory below RepositoryRoot, it survives immutable runtime replacement.
func EnrollmentDirectory(dataHome, yard string) (string, error) {
	if !safeEnrollmentName(yard) {
		return "", fmt.Errorf("invalid enrollment yard %q", yard)
	}
	if dataHome == "" || !filepath.IsAbs(dataHome) {
		return "", errors.New("absolute Subyard data home is required")
	}
	return filepath.Join(filepath.Clean(dataHome), "e2e", "controllers", yard), nil
}

func CurrentEnrollment(path string) (bool, string, string, error) {
	marker := filepath.Join(path, enrollmentMarker)
	info, err := os.Lstat(marker)
	if os.IsNotExist(err) {
		directory, directoryErr := os.Lstat(path)
		if os.IsNotExist(directoryErr) {
			return false, "", "", nil
		}
		if directoryErr != nil {
			return false, "", "", directoryErr
		}
		if directory.Mode()&os.ModeSymlink != 0 || !directory.IsDir() {
			return false, "", "", errors.New(
				"operator enrollment path is not a real directory",
			)
		}
		if validateErr := validateEnrollmentDirectory(path); validateErr != nil {
			return false, "", "", validateErr
		}
		return false, "", "", nil
	}
	if err != nil {
		return false, "", "", err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() ||
		info.Mode().Perm() != 0o600 || !ok || stat.Nlink != 1 ||
		stat.Uid != uint32(os.Geteuid()) {
		return false, "", "", errors.New("operator enrollment marker is not a regular file")
	}
	if err := validateEnrollmentDirectory(path); err != nil {
		return false, "", "", err
	}
	markerPayload, err := os.ReadFile(marker)
	if err != nil {
		return false, "", "", err
	}
	if string(markerPayload) != "managed\n" {
		return false, "", "", errors.New("operator enrollment marker is invalid")
	}
	key, configured, err := readEnrollment(filepath.Join(path, "agent-access.pub"))
	if err != nil {
		return false, "", "", err
	}
	if !configured {
		return true, "", "", nil
	}
	_, fingerprint, err := ParseEnrollment([]byte(key + "\n"))
	return true, key, fingerprint, err
}

// SetEnrollment atomically selects the persistent single-controller state.
// An empty key is an explicit revoke; the marker remains so a legacy checkout
// request cannot silently become active again.
func SetEnrollment(path, key string) error {
	if err := ensureEnrollmentDirectory(path); err != nil {
		return err
	}
	if key != "" {
		normalized, _, err := ParseEnrollment([]byte(key + "\n"))
		if err != nil {
			return err
		}
		if err := writeAtomic(filepath.Join(path, "agent-access.pub"),
			[]byte(normalized+"\n"), 0o600); err != nil {
			return err
		}
	} else if err := os.Remove(filepath.Join(path, "agent-access.pub")); err != nil &&
		!os.IsNotExist(err) {
		return err
	}
	return writeAtomic(filepath.Join(path, enrollmentMarker), []byte("managed\n"), 0o600)
}

// RemoveManagedEnrollment restores the pre-migration legacy lookup mode. It is
// used only for rollback when a first explicit enrollment did not complete.
func RemoveManagedEnrollment(path string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return errors.New("enrollment rollback target is not a real directory")
	}
	var failures []error
	for _, name := range []string{
		"agent-access.pub", "route.tsv", "known_hosts", enrollmentMarker,
	} {
		if err := os.Remove(filepath.Join(path, name)); err != nil && !os.IsNotExist(err) {
			failures = append(failures, err)
		}
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) &&
		!errors.Is(err, syscall.ENOTEMPTY) {
		failures = append(failures, err)
	}
	return errors.Join(failures...)
}

func ParseEnrollment(payload []byte) (string, string, error) {
	if len(payload) == 0 || len(payload) > 1024 ||
		bytesCount(payload, '\n') != 1 || payload[len(payload)-1] != '\n' {
		return "", "", errors.New(
			"enrollment must contain exactly one newline-terminated key",
		)
	}
	key, _, _, _, err := ssh.ParseAuthorizedKey(payload)
	if err != nil || key.Type() != ssh.KeyAlgoED25519 {
		return "", "", errors.New("enrollment is not an Ed25519 public key")
	}
	normalized := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))
	return normalized, ssh.FingerprintSHA256(key), nil
}

func ReadClientArtifacts(path string) ([]byte, []byte, error) {
	route, err := readRegularBounded(filepath.Join(path, "route.tsv"), 4096)
	if err != nil {
		return nil, nil, fmt.Errorf("read route: %w", err)
	}
	if !strings.HasPrefix(string(route), "subyard-e2e-route-v1\n") {
		return nil, nil, errors.New("route has an unsupported schema")
	}
	known, err := readRegularBounded(filepath.Join(path, "known_hosts"), 4096)
	if err != nil {
		return nil, nil, fmt.Errorf("read known hosts: %w", err)
	}
	fields := strings.Fields(string(known))
	if len(fields) != 3 || fields[0] != "subyard-e2e-bastion" ||
		fields[1] != ssh.KeyAlgoED25519 {
		return nil, nil, errors.New("known hosts has an invalid bastion key")
	}
	if _, _, _, _, err := ssh.ParseAuthorizedKey(
		[]byte(fields[1] + " " + fields[2]),
	); err != nil {
		return nil, nil, errors.New("known hosts has an invalid bastion key")
	}
	return route, known, nil
}

func ensureEnrollmentDirectory(path string) error {
	if path == "" || !filepath.IsAbs(path) || filepath.Clean(path) == string(filepath.Separator) {
		return errors.New("safe absolute enrollment directory is required")
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	return validateEnrollmentDirectory(path)
}

func validateEnrollmentDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() ||
		info.Mode().Perm()&0o077 != 0 || stat.Uid != uint32(os.Geteuid()) {
		return errors.New("enrollment directory must be an operator-owned private real directory")
	}
	return nil
}

func readRegularBounded(path string, maximum int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() ||
		info.Size() <= 0 || info.Size() > maximum {
		return nil, errors.New("artifact must be a bounded regular file")
	}
	return os.ReadFile(path)
}

func safeEnrollmentName(value string) bool {
	if value == "" || value == "." || value == ".." {
		return false
	}
	for _, current := range value {
		if (current >= 'a' && current <= 'z') ||
			(current >= 'A' && current <= 'Z') ||
			(current >= '0' && current <= '9') ||
			current == '-' || current == '_' {
			continue
		}
		return false
	}
	return true
}
