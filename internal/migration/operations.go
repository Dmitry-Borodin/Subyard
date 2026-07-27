package migration

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/Subyard/Subyard/internal/testyardmigration"
)

const (
	operationPrepared    = "prepared"
	operationCommitting  = "committing"
	operationCommitted   = "committed"
	operationRollingBack = "rolling-back"
	operationRolledBack  = "rolled-back"
)

func prepareTypedOperation(
	ctx context.Context,
	options ReleaseOptions,
	operation Operation,
) (string, error) {
	switch operation.Kind {
	case OperationKindTestYardOwnerV1:
		state, err := testyardmigration.Prepare(ctx, testYardOptions(options))
		return string(state), err
	case OperationKindTestYardRouteConsumersV1:
		return testyardmigration.PrepareRouteConsumers(ctx, testYardOptions(options))
	default:
		return "", fmt.Errorf("unsupported migration operation kind %q", operation.Kind)
	}
}

func commitTypedOperation(
	ctx context.Context,
	options ReleaseOptions,
	operation Operation,
	before string,
) error {
	switch operation.Kind {
	case OperationKindTestYardOwnerV1:
		state := testyardmigration.State(before)
		if err := testyardmigration.Commit(ctx, testYardOptions(options), state); err != nil {
			return err
		}
		return testyardmigration.Verify(testYardOptions(options), state)
	case OperationKindTestYardRouteConsumersV1:
		return testyardmigration.CommitRouteConsumers(
			ctx,
			testYardOptions(options),
			before,
		)
	default:
		return fmt.Errorf("unsupported migration operation kind %q", operation.Kind)
	}
}

func verifyTypedOperation(
	ctx context.Context,
	options ReleaseOptions,
	operation Operation,
	before string,
) error {
	switch operation.Kind {
	case OperationKindTestYardOwnerV1:
		return testyardmigration.Verify(
			testYardOptions(options),
			testyardmigration.State(before),
		)
	case OperationKindTestYardRouteConsumersV1:
		return testyardmigration.VerifyRouteConsumers(
			ctx,
			testYardOptions(options),
			before,
		)
	default:
		return fmt.Errorf("unsupported migration operation kind %q", operation.Kind)
	}
}

func rollbackTypedOperation(
	ctx context.Context,
	options ReleaseOptions,
	operation Operation,
	before string,
) error {
	switch operation.Kind {
	case OperationKindTestYardOwnerV1:
		state := testyardmigration.State(before)
		if err := testyardmigration.Rollback(ctx, testYardOptions(options), state); err != nil {
			return err
		}
		return testyardmigration.VerifyRollback(testYardOptions(options), state)
	case OperationKindTestYardRouteConsumersV1:
		if err := testyardmigration.RollbackRouteConsumers(
			ctx,
			testYardOptions(options),
			before,
		); err != nil {
			return err
		}
		return testyardmigration.VerifyRouteConsumersRollback(
			ctx,
			testYardOptions(options),
			before,
		)
	default:
		return fmt.Errorf("unsupported migration operation kind %q", operation.Kind)
	}
}

func reprepareTypedOperation(
	ctx context.Context,
	options ReleaseOptions,
	operation Operation,
	before string,
) (string, bool, error) {
	if err := verifyTypedOperation(ctx, options, operation, before); err == nil {
		return before, false, nil
	}
	switch operation.Kind {
	case OperationKindTestYardOwnerV1:
		previous := testyardmigration.State(before)
		current, err := testyardmigration.Prepare(ctx, testYardOptions(options))
		if err != nil {
			return "", false, err
		}
		switch current {
		case testyardmigration.StateAbsent:
			return string(current), false, nil
		case testyardmigration.StateLegacyDirectory,
			testyardmigration.StateLegacyDirectoryProjects,
			testyardmigration.StateLegacyDirectoryOverrides,
			testyardmigration.StateLegacyDirectoryState,
			testyardmigration.StateLegacyFlat,
			testyardmigration.StateLegacyDirectoryAdoptCurrent,
			testyardmigration.StateLegacyFlatAdoptCurrent,
			testyardmigration.StateCurrent:
			if current == testyardmigration.StateCurrent {
				return "", false, fmt.Errorf(
					"typed migration postcondition changed after commit from %q",
					before,
				)
			}
			if previous != testyardmigration.StateAbsent &&
				previous != testyardmigration.StateCurrent &&
				current != previous {
				return "", false, fmt.Errorf(
					"typed migration postcondition changed from %q to %q",
					before,
					current,
				)
			}
			return string(current), true, nil
		default:
			return "", false, fmt.Errorf(
				"typed migration postcondition changed from %q to %q",
				before,
				current,
			)
		}
	case OperationKindTestYardRouteConsumersV1:
		current, err := testyardmigration.PrepareRouteConsumers(
			ctx,
			testYardOptions(options),
		)
		if err != nil {
			return "", false, err
		}
		return current, true, nil
	default:
		return "", false, fmt.Errorf("unsupported migration operation kind %q", operation.Kind)
	}
}

func testYardOptions(options ReleaseOptions) testyardmigration.Options {
	executable := options.Executable
	if executable == "" {
		executable = filepath.Join(options.RepositoryRoot, "bin", "yard-engine")
	}
	environment := options.Environment
	if environment == nil {
		environment = os.Environ()
	}
	diagnostics := options.Diagnostics
	if diagnostics == nil {
		diagnostics = io.Discard
	}
	stderr := options.Stderr
	if stderr == nil {
		stderr = io.Discard
	}
	return testyardmigration.Options{
		Executable:  executable,
		Incus:       options.Incus,
		ConfigHome:  options.ConfigHome,
		DataHome:    options.DataHome,
		Environment: environment,
		Stdout:      diagnostics,
		Stderr:      stderr,
	}
}

func validateOperationState(operation transactionOperation) error {
	if operation.Before == "" {
		return errors.New("typed migration operation has no prepared state")
	}
	switch operation.Kind {
	case OperationKindTestYardOwnerV1:
		switch testyardmigration.State(operation.Before) {
		case testyardmigration.StateAbsent,
			testyardmigration.StateLegacyDirectory,
			testyardmigration.StateLegacyDirectoryProjects,
			testyardmigration.StateLegacyDirectoryOverrides,
			testyardmigration.StateLegacyDirectoryState,
			testyardmigration.StateLegacyFlat,
			testyardmigration.StateLegacyDirectoryAdoptCurrent,
			testyardmigration.StateLegacyFlatAdoptCurrent,
			testyardmigration.StateCurrent:
		default:
			return fmt.Errorf(
				"typed migration operation has invalid prepared state %q",
				operation.Before,
			)
		}
	case OperationKindTestYardRouteConsumersV1:
		if err := testyardmigration.ValidateRouteConsumersState(operation.Before); err != nil {
			return fmt.Errorf(
				"typed migration operation has invalid prepared state: %w",
				err,
			)
		}
	default:
		return fmt.Errorf("unsupported migration operation kind %q", operation.Kind)
	}
	switch operation.Phase {
	case operationPrepared, operationCommitting, operationCommitted,
		operationRollingBack, operationRolledBack:
		return nil
	default:
		return fmt.Errorf("typed migration operation has unknown phase %q", operation.Phase)
	}
}
