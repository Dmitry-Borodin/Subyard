package configsync

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/Dmitry-Borodin/Subyard/internal/config"
)

const sourceRecordSchema = 1

type SourceRecord struct {
	SchemaVersion int    `json:"schemaVersion"`
	Checkout      string `json:"checkout"`
}

func SourceRecordPath(configHome string) string {
	return filepath.Join(configHome, ".sync", "source.json")
}

func ReadSourceRecord(configHome string) (SourceRecord, bool, error) {
	unlock, err := config.LockRoot(configHome, false)
	if err != nil {
		return SourceRecord{}, false, err
	}
	defer unlock()
	return readSourceRecord(configHome)
}

func RegisterSource(configHome, checkout string) error {
	clean, err := validateRecordedCheckout(checkout)
	if err != nil {
		return err
	}
	if err := ensureConfigurationRoot(configHome); err != nil {
		return err
	}
	unlock, err := config.LockRoot(configHome, true)
	if err != nil {
		return err
	}
	defer unlock()
	current, exists, err := readSourceRecord(configHome)
	if err != nil {
		return err
	}
	if exists {
		if current.Checkout != clean {
			return fmt.Errorf(
				"configuration source is already registered at %s", current.Checkout,
			)
		}
		return nil
	}
	content, err := json.MarshalIndent(SourceRecord{
		SchemaVersion: sourceRecordSchema,
		Checkout:      clean,
	}, "", "  ")
	if err != nil {
		return err
	}
	return writeFileDurable(
		configHome, SourceRecordPath(configHome), append(content, '\n'), 0o600,
	)
}

func readSourceRecord(configHome string) (SourceRecord, bool, error) {
	path := SourceRecordPath(configHome)
	if err := validateConfigurationAncestors(configHome, path); err != nil {
		return SourceRecord{}, false, err
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return SourceRecord{}, false, nil
	}
	if err != nil {
		return SourceRecord{}, false, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() ||
		info.Mode().Perm() != 0o600 {
		return SourceRecord{}, false, errors.New(
			"configuration source record must be a regular 0600 file",
		)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) || stat.Nlink != 1 {
		return SourceRecord{}, false, errors.New(
			"configuration source record has unsafe ownership or hard links",
		)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return SourceRecord{}, false, err
	}
	var record SourceRecord
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return SourceRecord{}, false, err
	}
	if err := requireJSONEOF(decoder); err != nil {
		return SourceRecord{}, false, err
	}
	if record.SchemaVersion != sourceRecordSchema {
		return SourceRecord{}, false, fmt.Errorf(
			"unsupported configuration source record schema %d", record.SchemaVersion,
		)
	}
	record.Checkout, err = validateRecordedCheckout(record.Checkout)
	if err != nil {
		return SourceRecord{}, false, fmt.Errorf(
			"invalid configuration source record: %w", err,
		)
	}
	return record, true, nil
}

func validateRecordedCheckout(checkout string) (string, error) {
	if checkout == "" || !filepath.IsAbs(checkout) {
		return "", errors.New("configuration source checkout must be an absolute path")
	}
	clean := filepath.Clean(checkout)
	if clean == string(filepath.Separator) {
		return "", errors.New("configuration source checkout cannot be the filesystem root")
	}
	return clean, nil
}
