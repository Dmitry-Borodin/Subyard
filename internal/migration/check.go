package migration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"

	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
)

type Report struct {
	SchemaVersion          int  `json:"schemaVersion"`
	ProjectStateSchema     int  `json:"projectStateSchema"`
	CredentialSchema       int  `json:"credentialSchema"`
	ProjectStoresValidated int  `json:"projectStoresValidated"`
	CredentialRevisions    int  `json:"credentialRevisions"`
	Changed                bool `json:"changed"`
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
// every store. It currently tightens project records created by the legacy
// shell writer to mode 0600; schema and payload compatibility remain fail-closed.
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
