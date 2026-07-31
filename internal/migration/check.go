package migration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"

	"github.com/Subyard/Subyard/internal/ports"
	"github.com/Subyard/Subyard/internal/state"
)

const projectNameMigrationID = "normalize-project-names"

type Report struct {
	SchemaVersion          int      `json:"schemaVersion"`
	ProjectStateSchema     int      `json:"projectStateSchema"`
	CredentialSchema       int      `json:"credentialSchema"`
	Layout                 int      `json:"layout,omitempty"`
	TargetLayout           int      `json:"targetLayout,omitempty"`
	RequiredMigrations     []string `json:"requiredMigrations,omitempty"`
	AffectedResources      []string `json:"affectedResources,omitempty"`
	Phase                  string   `json:"phase,omitempty"`
	ProjectStoresValidated int      `json:"projectStoresValidated"`
	CredentialRevisions    int      `json:"credentialRevisions"`
	Pending                bool     `json:"pending,omitempty"`
	Changed                bool     `json:"changed"`
}

// Check validates every existing store before an engine replacement without
// changing it.
func Check(
	ctx context.Context,
	projectDirectories []string,
	credentials ports.CredentialMetadataReader,
) (Report, error) {
	return run(ctx, projectDirectories, credentials, false)
}

// Apply performs registered, backwards-compatible repairs before validating
// every store.
func Apply(
	ctx context.Context,
	projectDirectories []string,
	credentials ports.CredentialMetadataReader,
) (Report, error) {
	return run(ctx, projectDirectories, credentials, true)
}

func run(
	ctx context.Context,
	projectDirectories []string,
	credentials ports.CredentialMetadataReader,
	apply bool,
) (Report, error) {
	report := Report{SchemaVersion: 1, ProjectStateSchema: 1, CredentialSchema: 1}
	directories := uniquePaths(projectDirectories)
	for _, directory := range directories {
		info, err := os.Lstat(directory)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return Report{}, err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return Report{}, errors.New("project state path is not a real directory")
		}
		store, err := state.NewFileStore(directory)
		if err != nil {
			return Report{}, err
		}
		if apply {
			changed, err := store.RepairLegacyPermissions(ctx)
			if err != nil {
				return Report{}, err
			}
			report.Changed = report.Changed || changed
			changed, err = store.MigrateLegacyNames(ctx)
			if err != nil {
				return Report{}, err
			}
			report.Changed = report.Changed || changed
		} else {
			pending, err := store.LegacyNameMigrationPending(ctx)
			if err != nil {
				return Report{}, err
			}
			if pending {
				report.Pending = true
				if !contains(report.RequiredMigrations, projectNameMigrationID) {
					report.RequiredMigrations = append(
						report.RequiredMigrations, projectNameMigrationID,
					)
				}
				report.AffectedResources = append(report.AffectedResources, directory)
			}
		}
		if _, err := store.List(ctx); err != nil {
			return Report{}, err
		}
		report.ProjectStoresValidated++
	}
	if credentials != nil {
		metadata, err := credentials.ListMetadata(ctx)
		if err != nil {
			return Report{}, err
		}
		report.CredentialRevisions = len(metadata)
	}
	return report, nil
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func uniquePaths(paths []string) []string {
	set := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		if filepath.IsAbs(path) {
			set[filepath.Clean(path)] = struct{}{}
		}
	}
	result := make([]string, 0, len(set))
	for path := range set {
		result = append(result, path)
	}
	sort.Strings(result)
	return result
}
