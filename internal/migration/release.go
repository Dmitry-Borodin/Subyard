package migration

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"github.com/Subyard/Subyard/internal/config"
	"github.com/Subyard/Subyard/internal/ports"
)

const (
	migrationStateSchema = 1
	maximumMigratedFile  = 64 * 1024 * 1024
)

// ReleaseOptions binds a release-owned registry to stable operator-owned roots.
type ReleaseOptions struct {
	RegistryPath       string
	RepositoryRoot     string
	RuntimeRoot        string
	ConfigHome         string
	DataHome           string
	Version            string
	ProjectDirectories []string
	Credentials        ports.CredentialMetadataReader
}

type appliedState struct {
	SchemaVersion  int      `json:"schemaVersion"`
	Layout         int      `json:"layout"`
	Applied        []string `json:"applied,omitempty"`
	CurrentRelease string   `json:"currentRelease,omitempty"`
}

type transaction struct {
	SchemaVersion int                `json:"schemaVersion"`
	FromLayout    int                `json:"fromLayout"`
	ToLayout      int                `json:"toLayout"`
	FromRuntime   string             `json:"fromRuntime,omitempty"`
	ToRelease     string             `json:"toRelease"`
	ToRuntime     string             `json:"toRuntime,omitempty"`
	Phase         string             `json:"phase"`
	Migrations    []string           `json:"migrations"`
	Entries       []transactionEntry `json:"entries"`
}

type transactionEntry struct {
	MigrationID string `json:"migrationId"`
	Scope       string `json:"scope"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Consumer    string `json:"consumer"`
	Recovery    string `json:"recovery"`
	Digest      string `json:"sha256,omitempty"`
	Mode        uint32 `json:"mode,omitempty"`
}

// CheckRelease validates the migration path and all existing consumers without
// creating migration metadata or changing operator data.
func CheckRelease(ctx context.Context, options ReleaseOptions) (Report, error) {
	registry, state, path, tx, err := inspectRelease(options)
	if err != nil {
		return Report{}, err
	}
	if err := validatePathInputs(options, path, tx); err != nil {
		return Report{}, err
	}
	report, err := Check(ctx, options.ProjectDirectories, options.Credentials)
	if err != nil {
		return Report{}, err
	}
	enrichReport(&report, registry, state, path, tx)
	return report, nil
}

// ApplyRelease performs legacy repairs and durably prepares every registered
// relocation. Sources are retained until the candidate is the active runtime.
func ApplyRelease(ctx context.Context, options ReleaseOptions) (Report, error) {
	registry, state, path, _, err := inspectRelease(options)
	if err != nil {
		return Report{}, err
	}
	if err := validatePathInputs(options, path, nil); err != nil {
		return Report{}, err
	}
	legacyReport, err := Apply(ctx, options.ProjectDirectories, options.Credentials)
	if err != nil {
		return Report{}, err
	}

	unlock, err := lockMigrationRoot(options.ConfigHome)
	if err != nil {
		return Report{}, err
	}
	defer unlock()

	// Re-read under the stable lock.
	state, err = readAppliedState(options.ConfigHome, registry.MinimumLayout)
	if err != nil {
		return Report{}, err
	}
	if err := validateAppliedState(registry, state); err != nil {
		return Report{}, err
	}
	path, err = registry.Path(state.Layout)
	if err != nil {
		return Report{}, err
	}
	if len(path) == 0 {
		if state.CurrentRelease == "" {
			state.CurrentRelease = options.Version
			if err := writeAppliedState(options.ConfigHome, state); err != nil {
				return Report{}, err
			}
			legacyReport.Changed = true
		}
		enrichReport(&legacyReport, registry, state, nil, nil)
		return legacyReport, nil
	}

	tx, err := prepareTransaction(options, state, path)
	if err != nil {
		return Report{}, err
	}
	legacyReport.Changed = true
	enrichReport(&legacyReport, registry, state, path, &tx)
	return legacyReport, nil
}

// FinalizeActive commits a prepared transition only after the candidate
// repository is the target of the stable runtime current link.
func FinalizeActive(options ReleaseOptions) (bool, error) {
	tx, exists, err := readTransaction(options.ConfigHome, options.Version)
	if err != nil || !exists {
		return false, err
	}
	if tx.Phase == "committed" {
		return false, nil
	}
	active, err := candidateIsActive(options)
	if err != nil || !active {
		return false, err
	}
	if tx.Phase != "prepared" && tx.Phase != "committing" {
		return false, fmt.Errorf("migration transaction for %s is in phase %q", options.Version, tx.Phase)
	}
	registry, err := LoadRegistry(options.RegistryPath)
	if err != nil {
		return false, err
	}
	if err := validateTransaction(options, registry, tx); err != nil {
		return false, err
	}

	unlock, err := lockMigrationRoot(options.ConfigHome)
	if err != nil {
		return false, err
	}
	defer unlock()
	tx, exists, err = readTransaction(options.ConfigHome, options.Version)
	if err != nil || !exists {
		return false, err
	}
	if tx.Phase == "committed" {
		return false, nil
	}
	activeTarget := currentRuntimeTarget(options.RuntimeRoot)
	if activeTarget == "" {
		return false, errors.New("active runtime target is unavailable")
	}
	if tx.ToRuntime != "" && tx.ToRuntime != activeTarget {
		return false, errors.New("migration transaction is bound to another runtime target")
	}
	tx.ToRuntime = activeTarget
	tx.Phase = "committing"
	if err := writeTransaction(options.ConfigHome, tx); err != nil {
		return false, err
	}
	for _, entry := range tx.Entries {
		destination := movePath(options, entry.Scope, entry.Destination)
		if err := validateMoveParent(options, entry.Scope, entry.Destination); err != nil {
			return false, err
		}
		if err := validateConsumer(destination, entry.Consumer, entry.Digest); err != nil {
			return false, fmt.Errorf("verify migration %q destination: %w", entry.MigrationID, err)
		}
	}
	for _, entry := range tx.Entries {
		source := movePath(options, entry.Scope, entry.Source)
		if err := validateMoveParent(options, entry.Scope, entry.Source); err != nil {
			return false, err
		}
		if err := removeMatchingFile(source, entry.Digest); err != nil {
			return false, fmt.Errorf("retire migration %q source: %w", entry.MigrationID, err)
		}
	}
	state, err := readAppliedState(options.ConfigHome, registry.MinimumLayout)
	if err != nil {
		return false, err
	}
	if err := validateAppliedState(registry, state); err != nil {
		return false, err
	}
	state.Layout = tx.ToLayout
	state.CurrentRelease = tx.ToRuntime
	for _, id := range tx.Migrations {
		if !slices.Contains(state.Applied, id) {
			state.Applied = append(state.Applied, id)
		}
	}
	if err := writeAppliedState(options.ConfigHome, state); err != nil {
		return false, err
	}
	tx.Phase = "committed"
	if err := writeTransaction(options.ConfigHome, tx); err != nil {
		return false, err
	}
	return true, nil
}

// RollbackRelease restores the previous layout before the runtime current link
// is switched back. It is idempotent across interrupted rollback attempts.
func RollbackRelease(options ReleaseOptions) (Report, error) {
	registry, err := LoadRegistry(options.RegistryPath)
	if err != nil {
		return Report{}, err
	}
	tx, exists, err := readTransaction(options.ConfigHome, options.Version)
	if err != nil {
		return Report{}, err
	}
	state, err := readAppliedState(options.ConfigHome, registry.MinimumLayout)
	if err != nil {
		return Report{}, err
	}
	if err := validateAppliedState(registry, state); err != nil {
		return Report{}, err
	}
	if !exists || tx.Phase == "rolled-back" {
		report := Report{}
		enrichReport(&report, registry, state, nil, nil)
		return report, nil
	}
	if tx.Phase != "prepared" && tx.Phase != "committing" &&
		tx.Phase != "committed" && tx.Phase != "rolling-back" {
		return Report{}, fmt.Errorf("cannot roll back migration transaction in phase %q", tx.Phase)
	}
	if tx.Phase == "committed" || tx.Phase == "rolling-back" {
		currentTarget := currentRuntimeTarget(options.RuntimeRoot)
		previousTarget := runtimeLinkTarget(options.RuntimeRoot, "previous")
		if tx.ToRuntime == "" || tx.ToRuntime != currentTarget || tx.FromRuntime != previousTarget {
			report := Report{}
			enrichReport(&report, registry, state, nil, &tx)
			return report, nil
		}
	}
	if err := validateTransaction(options, registry, tx); err != nil {
		return Report{}, err
	}

	unlock, err := lockMigrationRoot(options.ConfigHome)
	if err != nil {
		return Report{}, err
	}
	defer unlock()
	tx, exists, err = readTransaction(options.ConfigHome, options.Version)
	if err != nil || !exists {
		return Report{}, err
	}
	if err := preflightRollback(options, tx); err != nil {
		return Report{}, err
	}
	tx.Phase = "rolling-back"
	if err := writeTransaction(options.ConfigHome, tx); err != nil {
		return Report{}, err
	}
	for index := len(tx.Entries) - 1; index >= 0; index-- {
		entry := tx.Entries[index]
		recovery := filepath.Join(transactionDirectory(options.ConfigHome, options.Version), entry.Recovery)
		source := movePath(options, entry.Scope, entry.Source)
		root := moveRoot(options, entry.Scope)
		if err := validateMoveParent(options, entry.Scope, entry.Source); err != nil {
			return Report{}, err
		}
		if err := publishMatchingFile(root, recovery, source, os.FileMode(entry.Mode), entry.Digest); err != nil {
			return Report{}, fmt.Errorf("restore migration %q source: %w", entry.MigrationID, err)
		}
		destination := movePath(options, entry.Scope, entry.Destination)
		if err := validateMoveParent(options, entry.Scope, entry.Destination); err != nil {
			return Report{}, err
		}
		if err := removeMatchingFile(destination, entry.Digest); err != nil {
			return Report{}, fmt.Errorf("remove migration %q destination: %w", entry.MigrationID, err)
		}
	}
	state.Layout = tx.FromLayout
	state.CurrentRelease = tx.FromRuntime
	for _, id := range tx.Migrations {
		state.Applied = removeString(state.Applied, id)
	}
	if err := writeAppliedState(options.ConfigHome, state); err != nil {
		return Report{}, err
	}
	tx.Phase = "rolled-back"
	if err := writeTransaction(options.ConfigHome, tx); err != nil {
		return Report{}, err
	}
	report := Report{Changed: true}
	enrichReport(&report, registry, state, nil, &tx)
	return report, nil
}

func preflightRollback(options ReleaseOptions, tx transaction) error {
	for _, entry := range tx.Entries {
		recovery := filepath.Join(
			transactionDirectory(options.ConfigHome, options.Version),
			entry.Recovery,
		)
		recoveryInfo, recoveryExists, err := inspectMigratedFile(recovery)
		if err != nil || !recoveryExists || recoveryInfo.Digest != entry.Digest ||
			recoveryInfo.Mode.Perm() != os.FileMode(entry.Mode).Perm() {
			return errors.Join(
				fmt.Errorf("migration %q recovery is unavailable or changed", entry.MigrationID),
				err,
			)
		}
		sourceInfo, sourceExists, err := inspectMoveFile(options, entry.Scope, entry.Source)
		if err != nil {
			return err
		}
		destinationInfo, destinationExists, err := inspectMoveFile(
			options, entry.Scope, entry.Destination,
		)
		if err != nil {
			return err
		}
		if sourceExists && (sourceInfo.Digest != entry.Digest ||
			sourceInfo.Mode.Perm() != os.FileMode(entry.Mode).Perm()) {
			return fmt.Errorf("migration %q rollback source conflicts", entry.MigrationID)
		}
		if destinationExists && (destinationInfo.Digest != entry.Digest ||
			destinationInfo.Mode.Perm() != os.FileMode(entry.Mode).Perm()) {
			return fmt.Errorf("migration %q rollback destination conflicts", entry.MigrationID)
		}
		if !sourceExists && !destinationExists {
			return fmt.Errorf("migration %q rollback has no authoritative copy", entry.MigrationID)
		}
	}
	return nil
}

// CleanupRelease removes recovery payloads whose exact runtime pair is no
// longer current/previous. It runs only after both stable links were updated.
func CleanupRelease(options ReleaseOptions) (int, error) {
	registry, err := LoadRegistry(options.RegistryPath)
	if err != nil {
		return 0, err
	}
	currentTarget := currentRuntimeTarget(options.RuntimeRoot)
	previousTarget := runtimeLinkTarget(options.RuntimeRoot, "previous")
	if currentTarget == "" {
		return 0, errors.New("current runtime target is unavailable")
	}
	unlock, err := lockMigrationRoot(options.ConfigHome)
	if err != nil {
		return 0, err
	}
	defer unlock()

	root := filepath.Join(migrationRoot(options.ConfigHome), "transactions")
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, entry := range entries {
		path := filepath.Join(root, entry.Name())
		info, err := entry.Info()
		if err != nil {
			return removed, err
		}
		if entry.Type()&os.ModeSymlink != 0 || !info.IsDir() {
			return removed, errors.New("migration transaction root contains an unsafe entry")
		}
		if err := validateOwnedSafeMode(path, info); err != nil {
			return removed, err
		}
		var old transaction
		exists, err := readProtectedJSON(filepath.Join(path, "transaction.json"), &old)
		if err != nil || !exists {
			return removed, errors.Join(errors.New("invalid retained migration transaction"), err)
		}
		oldOptions := options
		oldOptions.Version = old.ToRelease
		if transactionDirectory(options.ConfigHome, old.ToRelease) != path {
			return removed, errors.New("retained migration transaction directory has an invalid identity")
		}
		if err := validateTransaction(oldOptions, registry, old); err != nil {
			return removed, err
		}
		if old.ToRuntime == currentTarget && old.FromRuntime == previousTarget {
			continue
		}
		if old.Phase != "committed" && old.Phase != "rolled-back" {
			continue
		}
		if err := removeTransactionDirectory(path); err != nil {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

func inspectRelease(
	options ReleaseOptions,
) (Registry, appliedState, []Definition, *transaction, error) {
	if err := validateReleaseOptions(options); err != nil {
		return Registry{}, appliedState{}, nil, nil, err
	}
	registry, err := LoadRegistry(options.RegistryPath)
	if err != nil {
		return Registry{}, appliedState{}, nil, nil, err
	}
	state, err := readAppliedState(options.ConfigHome, registry.MinimumLayout)
	if err != nil {
		return Registry{}, appliedState{}, nil, nil, err
	}
	if err := validateAppliedState(registry, state); err != nil {
		return Registry{}, appliedState{}, nil, nil, err
	}
	path, err := registry.Path(state.Layout)
	if err != nil {
		return Registry{}, appliedState{}, nil, nil, err
	}
	tx, exists, err := readTransaction(options.ConfigHome, options.Version)
	if err != nil {
		return Registry{}, appliedState{}, nil, nil, err
	}
	if exists {
		if err := validateTransaction(options, registry, tx); err != nil {
			return Registry{}, appliedState{}, nil, nil, err
		}
		if tx.Phase == "rolled-back" {
			return registry, state, path, nil, nil
		}
		return registry, state, path, &tx, nil
	}
	return registry, state, path, nil, nil
}

func validateReleaseOptions(options ReleaseOptions) error {
	if options.Version == "" || options.RegistryPath == "" {
		return errors.New("migration release version and registry are required")
	}
	for name, root := range map[string]string{
		"config home": options.ConfigHome,
		"data home":   options.DataHome,
	} {
		if root == "" || !filepath.IsAbs(root) || filepath.Clean(root) == string(filepath.Separator) {
			return fmt.Errorf("migration %s must be an absolute non-root path", name)
		}
	}
	return nil
}

func enrichReport(
	report *Report,
	registry Registry,
	state appliedState,
	path []Definition,
	tx *transaction,
) {
	report.Layout = state.Layout
	report.TargetLayout = registry.CurrentLayout
	report.RequiredMigrations = report.RequiredMigrations[:0]
	report.AffectedResources = report.AffectedResources[:0]
	for _, definition := range path {
		report.RequiredMigrations = append(report.RequiredMigrations, definition.ID)
		for _, resource := range definition.Resources {
			if !slices.Contains(report.AffectedResources, resource) {
				report.AffectedResources = append(report.AffectedResources, resource)
			}
		}
	}
	if tx != nil {
		report.Phase = tx.Phase
		report.Pending = tx.Phase == "preparing" || tx.Phase == "prepared" || tx.Phase == "committing"
	}
}

func validatePathInputs(options ReleaseOptions, path []Definition, tx *transaction) error {
	for _, definition := range path {
		for _, move := range definition.Moves {
			source := movePath(options, move.Scope, move.Source)
			destination := movePath(options, move.Scope, move.Destination)
			sourceDigest, sourceExists, err := inspectMoveFile(options, move.Scope, move.Source)
			if err != nil {
				return fmt.Errorf("migration %q source: %w", definition.ID, err)
			}
			destinationDigest, destinationExists, err := inspectMoveFile(options, move.Scope, move.Destination)
			if err != nil {
				return fmt.Errorf("migration %q destination: %w", definition.ID, err)
			}
			if !sourceExists && !destinationExists {
				return fmt.Errorf("migration %q has neither source nor destination", definition.ID)
			}
			if sourceExists && destinationExists && sourceDigest.Digest != destinationDigest.Digest {
				return fmt.Errorf("migration %q source and destination differ", definition.ID)
			}
			active := source
			digest := sourceDigest.Digest
			if !sourceExists {
				active = destination
				digest = destinationDigest.Digest
			}
			if err := validateConsumer(active, move.Consumer, digest); err != nil {
				return fmt.Errorf("migration %q consumer: %w", definition.ID, err)
			}
		}
	}
	if tx != nil {
		for _, entry := range tx.Entries {
			destination := movePath(options, entry.Scope, entry.Destination)
			if err := validateMoveParent(options, entry.Scope, entry.Destination); err != nil {
				return err
			}
			if err := validateConsumer(destination, entry.Consumer, entry.Digest); err != nil {
				return fmt.Errorf("prepared migration %q: %w", entry.MigrationID, err)
			}
		}
	}
	return nil
}

func prepareTransaction(
	options ReleaseOptions,
	state appliedState,
	path []Definition,
) (transaction, error) {
	tx, exists, err := readTransaction(options.ConfigHome, options.Version)
	if err != nil {
		return transaction{}, err
	}
	expectedEntries := flattenEntries(path)
	expectedIDs := make([]string, 0, len(path))
	for _, definition := range path {
		expectedIDs = append(expectedIDs, definition.ID)
	}
	if exists && tx.Phase != "rolled-back" {
		if tx.FromLayout != state.Layout || tx.ToLayout != path[len(path)-1].ToLayout ||
			!slices.Equal(tx.Migrations, expectedIDs) {
			return transaction{}, errors.New("existing migration transaction does not match release registry")
		}
		if tx.Phase == "prepared" || tx.Phase == "committing" || tx.Phase == "committed" {
			return tx, nil
		}
	} else {
		tx = transaction{
			SchemaVersion: migrationStateSchema,
			FromLayout:    state.Layout,
			ToLayout:      path[len(path)-1].ToLayout,
			FromRuntime:   preparationFromRuntime(options),
			ToRelease:     options.Version,
			Phase:         "preparing",
			Migrations:    expectedIDs,
			Entries:       expectedEntries,
		}
		if err := writeTransaction(options.ConfigHome, tx); err != nil {
			return transaction{}, err
		}
	}
	if len(tx.Entries) != len(expectedEntries) {
		return transaction{}, errors.New("existing migration transaction entry count does not match registry")
	}
	for index := range tx.Entries {
		entry := &tx.Entries[index]
		expected := expectedEntries[index]
		if entry.MigrationID != expected.MigrationID || entry.Scope != expected.Scope ||
			entry.Source != expected.Source || entry.Destination != expected.Destination ||
			entry.Consumer != expected.Consumer || entry.Recovery != expected.Recovery {
			return transaction{}, errors.New("existing migration transaction entries do not match registry")
		}
		source := movePath(options, entry.Scope, entry.Source)
		destination := movePath(options, entry.Scope, entry.Destination)
		sourceInfo, sourceExists, err := inspectMoveFile(options, entry.Scope, entry.Source)
		if err != nil {
			return transaction{}, err
		}
		destinationInfo, destinationExists, err := inspectMoveFile(options, entry.Scope, entry.Destination)
		if err != nil {
			return transaction{}, err
		}
		if !sourceExists && !destinationExists {
			return transaction{}, fmt.Errorf("migration %q has neither source nor destination", entry.MigrationID)
		}
		observed := sourceInfo
		if !sourceExists {
			observed = destinationInfo
		}
		if entry.Digest == "" {
			entry.Digest = observed.Digest
			entry.Mode = uint32(observed.Mode.Perm())
			if err := writeTransaction(options.ConfigHome, tx); err != nil {
				return transaction{}, err
			}
		} else if entry.Digest != observed.Digest || entry.Mode != uint32(observed.Mode.Perm()) {
			return transaction{}, fmt.Errorf("migration %q input changed during preparation", entry.MigrationID)
		}
		if destinationExists && destinationInfo.Digest != entry.Digest {
			return transaction{}, fmt.Errorf("migration %q destination conflicts", entry.MigrationID)
		}
		input := source
		if !sourceExists {
			input = destination
		}
		recovery := filepath.Join(transactionDirectory(options.ConfigHome, options.Version), entry.Recovery)
		if err := publishMatchingFile(
			options.ConfigHome, input, recovery, os.FileMode(entry.Mode), entry.Digest,
		); err != nil {
			return transaction{}, fmt.Errorf("preserve migration %q recovery: %w", entry.MigrationID, err)
		}
		if err := publishMatchingFile(
			moveRoot(options, entry.Scope), input, destination, os.FileMode(entry.Mode), entry.Digest,
		); err != nil {
			return transaction{}, fmt.Errorf("publish migration %q destination: %w", entry.MigrationID, err)
		}
		if err := validateConsumer(destination, entry.Consumer, entry.Digest); err != nil {
			return transaction{}, fmt.Errorf("verify migration %q destination: %w", entry.MigrationID, err)
		}
	}
	tx.Phase = "prepared"
	if err := writeTransaction(options.ConfigHome, tx); err != nil {
		return transaction{}, err
	}
	return tx, nil
}

func flattenEntries(path []Definition) []transactionEntry {
	var entries []transactionEntry
	for _, definition := range path {
		for _, move := range definition.Moves {
			entries = append(entries, transactionEntry{
				MigrationID: definition.ID,
				Scope:       move.Scope,
				Source:      move.Source,
				Destination: move.Destination,
				Consumer:    move.Consumer,
				Recovery:    filepath.ToSlash(filepath.Join("recovery", fmt.Sprintf("%04d", len(entries)))),
			})
		}
	}
	return entries
}

func validateTransaction(options ReleaseOptions, registry Registry, tx transaction) error {
	if tx.SchemaVersion != migrationStateSchema || tx.ToRelease != options.Version {
		return errors.New("migration transaction identity does not match active release")
	}
	switch tx.Phase {
	case "preparing", "prepared", "committing", "committed", "rolling-back", "rolled-back":
	default:
		return fmt.Errorf("unknown migration transaction phase %q", tx.Phase)
	}
	if (tx.FromRuntime != "" && !safeReleaseIdentity(tx.FromRuntime)) ||
		(tx.ToRuntime != "" && !safeReleaseIdentity(tx.ToRuntime)) {
		return errors.New("migration transaction contains an unsafe runtime identity")
	}
	path, err := registry.Path(tx.FromLayout)
	if err != nil {
		return err
	}
	for index, definition := range path {
		if definition.ToLayout == tx.ToLayout {
			path = path[:index+1]
			break
		}
	}
	if len(path) == 0 || path[len(path)-1].ToLayout != tx.ToLayout {
		return errors.New("migration transaction layout does not match release registry")
	}
	expected := flattenEntries(path)
	if len(expected) != len(tx.Entries) {
		return errors.New("migration transaction entry count does not match release registry")
	}
	for index, entry := range tx.Entries {
		if entry.MigrationID != expected[index].MigrationID ||
			entry.Scope != expected[index].Scope ||
			entry.Source != expected[index].Source ||
			entry.Destination != expected[index].Destination ||
			entry.Consumer != expected[index].Consumer ||
			entry.Recovery != expected[index].Recovery ||
			(tx.Phase != "preparing" && entry.Digest == "") ||
			entry.Mode&0o022 != 0 {
			return errors.New("migration transaction entry does not match release registry")
		}
	}
	return nil
}

func validateAppliedState(registry Registry, state appliedState) error {
	var expected []string
	for _, definition := range registry.Migrations {
		if definition.ToLayout <= state.Layout {
			expected = append(expected, definition.ID)
		}
	}
	if !slices.Equal(state.Applied, expected) {
		return errors.New("migration applied-state IDs do not match its layout")
	}
	if state.CurrentRelease != "" && !safeReleaseIdentity(state.CurrentRelease) {
		return errors.New("migration applied-state has an unsafe release identity")
	}
	return nil
}

func safeReleaseIdentity(value string) bool {
	if value == "" || strings.ContainsAny(value, "\x00\n\r\t") ||
		filepath.IsAbs(value) || strings.Contains(value, "..") {
		return false
	}
	if strings.Contains(value, "/") {
		releaseID, ok := strings.CutPrefix(value, "releases/")
		if !ok || releaseID == "" || strings.Contains(releaseID, "/") {
			return false
		}
	}
	for _, character := range value {
		if character == '/' || character == '.' || character == '_' ||
			character == '+' || character == '-' ||
			character >= '0' && character <= '9' ||
			character >= 'A' && character <= 'Z' ||
			character >= 'a' && character <= 'z' {
			continue
		}
		return false
	}
	return true
}

func removeTransactionDirectory(path string) error {
	if err := filepath.WalkDir(path, func(candidate string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("retained migration transaction contains a symlink")
		}
		if info.IsDir() {
			return validateOwnedSafeMode(candidate, info)
		}
		if !info.Mode().IsRegular() {
			return errors.New("retained migration transaction contains a non-regular file")
		}
		return validateOwnedSafeMode(candidate, info)
	}); err != nil {
		return err
	}
	parent := filepath.Dir(path)
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	return syncMigrationDirectory(parent)
}

type migratedFile struct {
	Digest string
	Mode   os.FileMode
}

func inspectMigratedFile(path string) (migratedFile, bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return migratedFile{}, false, nil
	}
	if err != nil {
		return migratedFile{}, false, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return migratedFile{}, false, errors.New("path is not a regular non-symlink file")
	}
	if err := validateOwnedSafeMode(path, info); err != nil {
		return migratedFile{}, false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Nlink != 1 {
		return migratedFile{}, false, errors.New("migrated file must have exactly one hard link")
	}
	if info.Size() > maximumMigratedFile {
		return migratedFile{}, false, errors.New("migrated file exceeds size limit")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return migratedFile{}, false, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return migratedFile{}, false, err
	}
	if !os.SameFile(info, opened) {
		return migratedFile{}, false, errors.New("migrated file changed while opening")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, io.LimitReader(file, maximumMigratedFile+1)); err != nil {
		return migratedFile{}, false, err
	}
	return migratedFile{Digest: hex.EncodeToString(hash.Sum(nil)), Mode: info.Mode()}, true, nil
}

func publishMatchingFile(root, source, destination string, mode os.FileMode, digest string) error {
	if existing, exists, err := inspectMigratedFile(destination); err != nil {
		return err
	} else if exists {
		if existing.Digest != digest || existing.Mode.Perm() != mode.Perm() {
			return errors.New("existing destination differs")
		}
		return nil
	}
	sourceInfo, exists, err := inspectMigratedFile(source)
	if err != nil {
		return err
	}
	if !exists || sourceInfo.Digest != digest {
		return errors.New("copy source is unavailable or changed")
	}
	parent := filepath.Dir(destination)
	if err := ensureProtectedDirectoryUnder(root, parent); err != nil {
		return err
	}
	file, err := os.CreateTemp(parent, ".subyard-migrate-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	remove := true
	defer func() {
		if remove {
			_ = os.Remove(temporary)
		}
	}()
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	input, err := os.OpenFile(source, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		file.Close()
		return err
	}
	_, copyErr := io.Copy(file, io.LimitReader(input, maximumMigratedFile+1))
	closeInputErr := input.Close()
	if copyErr != nil || closeInputErr != nil {
		file.Close()
		return errors.Join(copyErr, closeInputErr)
	}
	if err := file.Chmod(mode.Perm()); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary, destination); err != nil {
		return err
	}
	remove = false
	return syncMigrationDirectory(parent)
}

func removeMatchingFile(path, digest string) error {
	info, exists, err := inspectMigratedFile(path)
	if err != nil || !exists {
		return err
	}
	if info.Digest != digest {
		return errors.New("refusing to remove changed migration file")
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	return syncMigrationDirectory(filepath.Dir(path))
}

func validateConsumer(path, consumer, digest string) error {
	info, exists, err := inspectMigratedFile(path)
	if err != nil {
		return err
	}
	if !exists || (digest != "" && info.Digest != digest) {
		return errors.New("consumer input is unavailable or changed")
	}
	switch consumer {
	case "regular-file":
		return nil
	case "assignments":
		_, err := config.ReadAssignments(path)
		return err
	case "json":
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		defer file.Close()
		decoder := json.NewDecoder(io.LimitReader(file, maximumMigratedFile+1))
		var value any
		if err := decoder.Decode(&value); err != nil {
			return err
		}
		return requireJSONEOF(decoder)
	default:
		return fmt.Errorf("unsupported migration consumer %q", consumer)
	}
}

func movePath(options ReleaseOptions, scope, relative string) string {
	return filepath.Join(moveRoot(options, scope), filepath.FromSlash(relative))
}

func moveRoot(options ReleaseOptions, scope string) string {
	if scope == "data-home" {
		return options.DataHome
	}
	return options.ConfigHome
}

func inspectMoveFile(options ReleaseOptions, scope, relative string) (migratedFile, bool, error) {
	if err := validateMoveParent(options, scope, relative); err != nil {
		return migratedFile{}, false, err
	}
	return inspectMigratedFile(movePath(options, scope, relative))
}

func validateMoveParent(options ReleaseOptions, scope, relative string) error {
	root := moveRoot(options, scope)
	parent := filepath.Dir(movePath(options, scope, relative))
	return validateDirectoryUnder(root, parent)
}

func migrationRoot(configHome string) string {
	return filepath.Join(configHome, "migrations")
}

func transactionDirectory(configHome, version string) string {
	sum := sha256.Sum256([]byte(version))
	return filepath.Join(migrationRoot(configHome), "transactions", hex.EncodeToString(sum[:16]))
}

func statePath(configHome string) string {
	return filepath.Join(migrationRoot(configHome), "state.json")
}

func transactionPath(configHome, version string) string {
	return filepath.Join(transactionDirectory(configHome, version), "transaction.json")
}

func readAppliedState(configHome string, minimumLayout int) (appliedState, error) {
	state := appliedState{SchemaVersion: migrationStateSchema, Layout: minimumLayout}
	exists, err := readProtectedJSON(statePath(configHome), &state)
	if err != nil {
		return appliedState{}, fmt.Errorf("read migration state: %w", err)
	}
	if !exists {
		return state, nil
	}
	if state.SchemaVersion != migrationStateSchema || state.Layout < 1 {
		return appliedState{}, errors.New("invalid migration state")
	}
	return state, nil
}

func writeAppliedState(configHome string, state appliedState) error {
	state.SchemaVersion = migrationStateSchema
	return writeProtectedJSON(statePath(configHome), state)
}

func readTransaction(configHome, version string) (transaction, bool, error) {
	var tx transaction
	exists, err := readProtectedJSON(transactionPath(configHome, version), &tx)
	if err != nil {
		return transaction{}, false, fmt.Errorf("read migration transaction: %w", err)
	}
	return tx, exists, nil
}

func writeTransaction(configHome string, tx transaction) error {
	tx.SchemaVersion = migrationStateSchema
	return writeProtectedJSON(transactionPath(configHome, tx.ToRelease), tx)
}

func readProtectedJSON(path string, target any) (bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() ||
		info.Mode().Perm() != 0o600 {
		return false, errors.New("migration metadata must be a protected regular file")
	}
	if err := validateOwnedSafeMode(path, info); err != nil {
		return false, err
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return false, err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, maximumMigratedFile+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return false, err
	}
	if err := requireJSONEOF(decoder); err != nil {
		return false, err
	}
	return true, nil
}

func writeProtectedJSON(path string, value any) error {
	payload, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() ||
			info.Mode().Perm() != 0o600 {
			return errors.New("migration metadata destination is unsafe")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	parent := filepath.Dir(path)
	if err := ensureProtectedDirectory(parent); err != nil {
		return err
	}
	file, err := os.CreateTemp(parent, ".subyard-metadata-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(payload); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	return syncMigrationDirectory(parent)
}

func ensureProtectedDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return errors.New("migration directory must be a real directory")
	}
	if err := validateOwnedSafeMode(path, info); err != nil {
		return err
	}
	if info.Mode().Perm() != 0o700 {
		if err := os.Chmod(path, 0o700); err != nil {
			return err
		}
	}
	return nil
}

func ensureProtectedDirectoryUnder(root, path string) error {
	if err := ensureProtectedDirectory(root); err != nil {
		return err
	}
	relative, err := filepath.Rel(root, path)
	if err != nil || relative == ".." ||
		filepath.IsAbs(relative) || (!safeRelativePath(relative) && relative != ".") {
		return errors.New("migration directory escapes its allowlisted root")
	}
	current := filepath.Clean(root)
	if relative == "." {
		return nil
	}
	for _, component := range splitPath(relative) {
		current = filepath.Join(current, component)
		if err := os.Mkdir(current, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return errors.New("migration directory contains a symlink or non-directory")
		}
		if err := validateOwnedSafeMode(current, info); err != nil {
			return err
		}
	}
	return nil
}

func validateDirectoryUnder(root, path string) error {
	relative, err := filepath.Rel(root, path)
	if err != nil || relative == ".." ||
		filepath.IsAbs(relative) || (!safeRelativePath(relative) && relative != ".") {
		return errors.New("migration path escapes its allowlisted root")
	}
	current := filepath.Clean(root)
	for _, component := range append([]string{""}, splitPath(relative)...) {
		if component != "" {
			current = filepath.Join(current, component)
		}
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return errors.New("migration path contains a symlink or non-directory")
		}
		if err := validateOwnedSafeMode(current, info); err != nil {
			return err
		}
	}
	return nil
}

func splitPath(path string) []string {
	if path == "." {
		return nil
	}
	var components []string
	for path != "." {
		directory, base := filepath.Split(path)
		components = append([]string{base}, components...)
		path = filepath.Clean(directory)
	}
	return components
}

func lockMigrationRoot(configHome string) (func(), error) {
	root := migrationRoot(configHome)
	if err := ensureProtectedDirectory(root); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(root, "update.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		lock.Close()
		return nil, err
	}
	return func() {
		_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		_ = lock.Close()
	}, nil
}

func syncMigrationDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func candidateIsActive(options ReleaseOptions) (bool, error) {
	current := filepath.Join(options.RuntimeRoot, "current")
	active, err := filepath.EvalSymlinks(current)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	repository, err := filepath.EvalSymlinks(options.RepositoryRoot)
	if err != nil {
		return false, err
	}
	return filepath.Clean(active) == filepath.Clean(repository), nil
}

func currentRuntimeTarget(runtimeRoot string) string {
	return runtimeLinkTarget(runtimeRoot, "current")
}

func preparationFromRuntime(options ReleaseOptions) string {
	active, err := candidateIsActive(options)
	if err == nil && active {
		return runtimeLinkTarget(options.RuntimeRoot, "previous")
	}
	return currentRuntimeTarget(options.RuntimeRoot)
}

func runtimeLinkTarget(runtimeRoot, name string) string {
	target, err := os.Readlink(filepath.Join(runtimeRoot, name))
	if err != nil {
		return ""
	}
	return target
}

func removeString(values []string, target string) []string {
	result := values[:0]
	for _, value := range values {
		if value != target {
			result = append(result, value)
		}
	}
	return result
}
