package migration

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestReleaseMigrationPrepareCommitRollbackAndRollForward(t *testing.T) {
	options, source, destination := releaseMigrationFixture(t)

	report, err := CheckRelease(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if report.Layout != 1 || report.TargetLayout != 2 ||
		len(report.RequiredMigrations) != 1 || report.Changed {
		t.Fatalf("unexpected check report: %#v", report)
	}
	if _, err := os.Lstat(migrationRoot(options.ConfigHome)); !os.IsNotExist(err) {
		t.Fatal("migration check changed the config home")
	}

	report, err = ApplyRelease(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Pending || report.Phase != "prepared" {
		t.Fatalf("unexpected apply report: %#v", report)
	}
	assertFileContents(t, source, "TOKEN=legacy\n")
	assertFileContents(t, destination, "TOKEN=legacy\n")
	repeated, err := ApplyRelease(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if !repeated.Pending || repeated.Phase != "prepared" {
		t.Fatalf("repeated apply did not resume prepared work: %#v", repeated)
	}
	state, err := readAppliedState(options.ConfigHome, 1)
	if err != nil {
		t.Fatal(err)
	}
	if state.Layout != 1 {
		t.Fatalf("prepared state layout = %d, want 1", state.Layout)
	}
	if changed, err := FinalizeActive(options); err != nil || changed {
		t.Fatalf("inactive candidate finalized: changed=%v err=%v", changed, err)
	}

	activateFixtureRelease(t, options)
	if changed, err := FinalizeActive(options); err != nil || !changed {
		t.Fatalf("active candidate did not finalize: changed=%v err=%v", changed, err)
	}
	if _, err := os.Lstat(source); !os.IsNotExist(err) {
		t.Fatal("finalize retained the legacy source")
	}
	assertFileContents(t, destination, "TOKEN=legacy\n")
	state, err = readAppliedState(options.ConfigHome, 1)
	if err != nil {
		t.Fatal(err)
	}
	if state.Layout != 2 ||
		state.CurrentRelease != filepath.Join("releases", filepath.Base(options.RepositoryRoot)) {
		t.Fatalf("committed state = %#v", state)
	}

	report, err = RollbackRelease(options)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Changed || report.Layout != 1 {
		t.Fatalf("unexpected rollback report: %#v", report)
	}
	assertFileContents(t, source, "TOKEN=legacy\n")
	if _, err := os.Lstat(destination); !os.IsNotExist(err) {
		t.Fatal("rollback retained the new destination")
	}
	swapFixtureRuntimeLinks(t, options.RuntimeRoot)

	if _, err := ApplyRelease(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	activateFixtureRelease(t, options)
	if changed, err := FinalizeActive(options); err != nil || !changed {
		t.Fatalf("roll-forward did not finalize: changed=%v err=%v", changed, err)
	}
	if _, err := os.Lstat(source); !os.IsNotExist(err) {
		t.Fatal("roll-forward retained the legacy source")
	}
	assertFileContents(t, destination, "TOKEN=legacy\n")
}

func TestReleaseMigrationResumesInterruptedPrepare(t *testing.T) {
	options, source, destination := releaseMigrationFixture(t)
	registry, err := LoadRegistry(options.RegistryPath)
	if err != nil {
		t.Fatal(err)
	}
	path, err := registry.Path(1)
	if err != nil {
		t.Fatal(err)
	}
	tx := transaction{
		SchemaVersion: migrationStateSchema,
		FromLayout:    1,
		ToLayout:      2,
		ToRelease:     options.Version,
		Phase:         "preparing",
		Migrations:    []string{path[0].ID},
		Entries:       flattenEntries(path),
	}
	if err := writeTransaction(options.ConfigHome, tx); err != nil {
		t.Fatal(err)
	}
	report, err := ApplyRelease(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if report.Phase != "prepared" || !report.Pending {
		t.Fatalf("interrupted preparation did not resume: %#v", report)
	}
	assertFileContents(t, source, "TOKEN=legacy\n")
	assertFileContents(t, destination, "TOKEN=legacy\n")
}

func TestReleaseMigrationResumesInterruptedFinalize(t *testing.T) {
	options, source, destination := releaseMigrationFixture(t)
	if _, err := ApplyRelease(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	activateFixtureRelease(t, options)

	tx, exists, err := readTransaction(options.ConfigHome, options.Version)
	if err != nil || !exists {
		t.Fatalf("read prepared transaction: exists=%v err=%v", exists, err)
	}
	tx.Phase = "committing"
	if err := writeTransaction(options.ConfigHome, tx); err != nil {
		t.Fatal(err)
	}
	if err := removeMatchingFile(source, tx.Entries[0].Digest); err != nil {
		t.Fatal(err)
	}
	if changed, err := FinalizeActive(options); err != nil || !changed {
		t.Fatalf("interrupted finalize did not resume: changed=%v err=%v", changed, err)
	}
	if _, err := os.Lstat(source); !os.IsNotExist(err) {
		t.Fatal("resumed finalize restored the retired source")
	}
	assertFileContents(t, destination, "TOKEN=legacy\n")
}

func TestReleaseMigrationResumesAfterStateCommitAndDuringRollback(t *testing.T) {
	t.Run("state-committed", func(t *testing.T) {
		options, source, _ := releaseMigrationFixture(t)
		if _, err := ApplyRelease(context.Background(), options); err != nil {
			t.Fatal(err)
		}
		activateFixtureRelease(t, options)
		tx, exists, err := readTransaction(options.ConfigHome, options.Version)
		if err != nil || !exists {
			t.Fatalf("read transaction: exists=%v err=%v", exists, err)
		}
		tx.ToRuntime = currentRuntimeTarget(options.RuntimeRoot)
		tx.Phase = "committing"
		if err := writeTransaction(options.ConfigHome, tx); err != nil {
			t.Fatal(err)
		}
		if err := removeMatchingFile(source, tx.Entries[0].Digest); err != nil {
			t.Fatal(err)
		}
		if err := writeAppliedState(options.ConfigHome, appliedState{
			SchemaVersion:  migrationStateSchema,
			Layout:         2,
			Applied:        tx.Migrations,
			CurrentRelease: tx.ToRuntime,
		}); err != nil {
			t.Fatal(err)
		}
		if changed, err := FinalizeActive(options); err != nil || !changed {
			t.Fatalf("state-committed finalize did not resume: changed=%v err=%v", changed, err)
		}
	})

	t.Run("rolling-back", func(t *testing.T) {
		options, source, destination := releaseMigrationFixture(t)
		if _, err := ApplyRelease(context.Background(), options); err != nil {
			t.Fatal(err)
		}
		activateFixtureRelease(t, options)
		if _, err := FinalizeActive(options); err != nil {
			t.Fatal(err)
		}
		tx, exists, err := readTransaction(options.ConfigHome, options.Version)
		if err != nil || !exists {
			t.Fatalf("read transaction: exists=%v err=%v", exists, err)
		}
		tx.Phase = "rolling-back"
		if err := writeTransaction(options.ConfigHome, tx); err != nil {
			t.Fatal(err)
		}
		recovery := filepath.Join(
			transactionDirectory(options.ConfigHome, options.Version),
			tx.Entries[0].Recovery,
		)
		if err := publishMatchingFile(
			options.ConfigHome, recovery, source,
			os.FileMode(tx.Entries[0].Mode), tx.Entries[0].Digest,
		); err != nil {
			t.Fatal(err)
		}
		if err := removeMatchingFile(destination, tx.Entries[0].Digest); err != nil {
			t.Fatal(err)
		}
		report, err := RollbackRelease(options)
		if err != nil {
			t.Fatal(err)
		}
		if report.Layout != 1 {
			t.Fatalf("resumed rollback report: %#v", report)
		}
		assertFileContents(t, source, "TOKEN=legacy\n")
	})
}

func TestReleaseMigrationFailedRollbackDoesNotCreateMixedLayout(t *testing.T) {
	options, source, destination := releaseMigrationFixture(t)
	if _, err := ApplyRelease(context.Background(), options); err != nil {
		t.Fatal(err)
	}
	activateFixtureRelease(t, options)
	if _, err := FinalizeActive(options); err != nil {
		t.Fatal(err)
	}
	writeMigrationFixture(t, destination, "TOKEN=changed\n")
	if _, err := RollbackRelease(options); err == nil {
		t.Fatal("rollback accepted a changed destination")
	}
	if _, err := os.Lstat(source); !os.IsNotExist(err) {
		t.Fatal("failed rollback restored the old source before preflight completed")
	}
	assertFileContents(t, destination, "TOKEN=changed\n")
	state, err := readAppliedState(options.ConfigHome, 1)
	if err != nil {
		t.Fatal(err)
	}
	if state.Layout != 2 {
		t.Fatalf("failed rollback changed applied layout to %d", state.Layout)
	}
	tx, exists, err := readTransaction(options.ConfigHome, options.Version)
	if err != nil || !exists || tx.Phase != "committed" {
		t.Fatalf("failed rollback changed transaction authority: exists=%v phase=%q err=%v", exists, tx.Phase, err)
	}
}

func TestReleaseMigrationRejectsChangedDestinationAndHardLinks(t *testing.T) {
	t.Run("destination-conflict", func(t *testing.T) {
		options, _, destination := releaseMigrationFixture(t)
		writeMigrationFixture(t, destination, "TOKEN=conflict\n")
		if _, err := CheckRelease(context.Background(), options); err == nil {
			t.Fatal("check accepted a conflicting destination")
		}
	})
	t.Run("hard-link", func(t *testing.T) {
		options, source, _ := releaseMigrationFixture(t)
		if err := os.Link(source, source+".link"); err != nil {
			t.Fatal(err)
		}
		if _, err := CheckRelease(context.Background(), options); err == nil {
			t.Fatal("check accepted a multiply linked source")
		}
	})
	t.Run("intermediate-symlink", func(t *testing.T) {
		options, source, _ := releaseMigrationFixture(t)
		outside := filepath.Join(t.TempDir(), "outside")
		if err := os.Rename(filepath.Dir(source), outside); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(outside, filepath.Dir(source)); err != nil {
			t.Fatal(err)
		}
		if _, err := CheckRelease(context.Background(), options); err == nil {
			t.Fatal("check accepted an intermediate symlink")
		}
	})
}

func TestRegistryRejectsNonContiguousAndUnsafeDefinitions(t *testing.T) {
	registry := Registry{
		SchemaVersion: 1,
		MinimumLayout: 1,
		CurrentLayout: 2,
		Migrations: []Definition{{
			ID:             "unsafe",
			FromLayout:     1,
			ToLayout:       2,
			Resources:      []string{"unsafe-resource"},
			FinalizePolicy: "remove-source-after-active-verify",
			RollbackPolicy: "restore-recovery-before-runtime-swap",
			Moves: []Move{{
				Scope: "config-home", Source: "../escape",
				Destination: "current/config.env", Consumer: "assignments",
			}},
		}},
	}
	if err := registry.Validate(); err == nil {
		t.Fatal("registry accepted an escaping source")
	}
	registry.Migrations[0].Moves[0].Source = "legacy/config.env"
	registry.Migrations[0].ToLayout = 3
	if err := registry.Validate(); err == nil {
		t.Fatal("registry accepted a skipped layout")
	}
}

func TestReleaseMigrationRejectsCorruptDurableState(t *testing.T) {
	t.Run("applied-ids", func(t *testing.T) {
		options, _, _ := releaseMigrationFixture(t)
		if err := writeAppliedState(options.ConfigHome, appliedState{
			SchemaVersion: migrationStateSchema,
			Layout:        1,
			Applied:       []string{"unknown-migration"},
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := CheckRelease(context.Background(), options); err == nil {
			t.Fatal("check accepted applied IDs inconsistent with layout")
		}
	})
	t.Run("transaction-phase", func(t *testing.T) {
		options, _, _ := releaseMigrationFixture(t)
		registry, err := LoadRegistry(options.RegistryPath)
		if err != nil {
			t.Fatal(err)
		}
		path, err := registry.Path(1)
		if err != nil {
			t.Fatal(err)
		}
		tx := transaction{
			SchemaVersion: migrationStateSchema,
			FromLayout:    1,
			ToLayout:      2,
			ToRelease:     options.Version,
			Phase:         "unknown",
			Migrations:    []string{path[0].ID},
			Entries:       flattenEntries(path),
		}
		if err := writeTransaction(options.ConfigHome, tx); err != nil {
			t.Fatal(err)
		}
		if _, err := CheckRelease(context.Background(), options); err == nil {
			t.Fatal("check accepted an unknown transaction phase")
		}
	})
}

func releaseMigrationFixture(t *testing.T) (ReleaseOptions, string, string) {
	t.Helper()
	root := t.TempDir()
	configHome := filepath.Join(root, "config-home")
	dataHome := filepath.Join(root, "data-home")
	runtimeRoot := filepath.Join(root, "runtime")
	repositoryRoot := filepath.Join(runtimeRoot, "releases", "2.0.0-test-release")
	for _, directory := range []string{
		configHome, dataHome, filepath.Join(repositoryRoot, "config"),
		filepath.Join(runtimeRoot, "releases", "1.0.0-test-release"),
	} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	registry := Registry{
		SchemaVersion: 1,
		MinimumLayout: 1,
		CurrentLayout: 2,
		Migrations: []Definition{{
			ID:             "move-legacy-assignments",
			FromLayout:     1,
			ToLayout:       2,
			Resources:      []string{"fixture-assignments"},
			FinalizePolicy: "remove-source-after-active-verify",
			RollbackPolicy: "restore-recovery-before-runtime-swap",
			Moves: []Move{{
				Scope: "config-home", Source: "legacy/config.env",
				Destination: "current/config.env", Consumer: "assignments",
			}},
		}},
	}
	payload, err := json.Marshal(registry)
	if err != nil {
		t.Fatal(err)
	}
	registryPath := filepath.Join(repositoryRoot, "config", "migrations.json")
	if err := os.WriteFile(registryPath, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(
		filepath.Join("releases", "1.0.0-test-release"),
		filepath.Join(runtimeRoot, "current"),
	); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(configHome, "legacy", "config.env")
	destination := filepath.Join(configHome, "current", "config.env")
	writeMigrationFixture(t, source, "TOKEN=legacy\n")
	return ReleaseOptions{
		RegistryPath:   registryPath,
		RepositoryRoot: repositoryRoot,
		RuntimeRoot:    runtimeRoot,
		ConfigHome:     configHome,
		DataHome:       dataHome,
		Version:        "2.0.0-test",
	}, source, destination
}

func activateFixtureRelease(t *testing.T, options ReleaseOptions) {
	t.Helper()
	if err := os.MkdirAll(options.RuntimeRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	oldTarget, err := os.Readlink(filepath.Join(options.RuntimeRoot, "current"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(options.RuntimeRoot, "current")); err != nil {
		t.Fatal(err)
	}
	_ = os.Remove(filepath.Join(options.RuntimeRoot, "previous"))
	if err := os.Symlink(
		filepath.Join("releases", filepath.Base(options.RepositoryRoot)),
		filepath.Join(options.RuntimeRoot, "current"),
	); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(oldTarget, filepath.Join(options.RuntimeRoot, "previous")); err != nil {
		t.Fatal(err)
	}
}

func swapFixtureRuntimeLinks(t *testing.T, runtimeRoot string) {
	t.Helper()
	current := filepath.Join(runtimeRoot, "current")
	previous := filepath.Join(runtimeRoot, "previous")
	currentTarget, err := os.Readlink(current)
	if err != nil {
		t.Fatal(err)
	}
	previousTarget, err := os.Readlink(previous)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(current); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(previous); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(previousTarget, current); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(currentTarget, previous); err != nil {
		t.Fatal(err)
	}
}

func writeMigrationFixture(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assertFileContents(t *testing.T, path, want string) {
	t.Helper()
	payload, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != want {
		t.Fatalf("%s = %q, want %q", path, payload, want)
	}
}
