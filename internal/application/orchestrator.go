package application

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

var ErrDeclined = errors.New("operation declined")

type Orchestrator struct {
	Clock    ports.Clock
	IDs      ports.IDSource
	Prompt   ports.Prompter
	Runner   ports.AdapterRunner
	Audit    ports.AuditSink
	Events   ports.EventSink
	mu       sync.Mutex
	revision uint64
}

func (orchestrator *Orchestrator) Plan(ctx context.Context, yard domain.Context, policy domain.CommandPolicy, assumeYes bool) (domain.OperationPlan, error) {
	plan, err := orchestrator.Prepare(yard, policy)
	if err != nil {
		return domain.OperationPlan{}, err
	}
	return orchestrator.Confirm(ctx, plan, assumeYes)
}

func (orchestrator *Orchestrator) Prepare(yard domain.Context, policy domain.CommandPolicy) (domain.OperationPlan, error) {
	if orchestrator.Clock == nil || orchestrator.IDs == nil {
		return domain.OperationPlan{}, errors.New("clock and ID source are required")
	}
	if policy.Name == "" || (policy.Effect != domain.CommandRead && policy.Effect != domain.CommandMutate) {
		return domain.OperationPlan{}, errors.New("invalid command policy")
	}
	if policy.RemotePolicy != domain.RemoteOnController && policy.RemotePolicy != domain.RemoteOnOwner &&
		policy.RemotePolicy != domain.RemoteDenied {
		return domain.OperationPlan{}, errors.New("invalid remote command policy")
	}
	target, err := Route(yard, policy.RemotePolicy)
	if err != nil {
		return domain.OperationPlan{}, fmt.Errorf("command %q: %w", policy.Name, err)
	}
	operationID := orchestrator.IDs.NewID()
	if !domain.SafeID(operationID) {
		return domain.OperationPlan{}, errors.New("ID source returned an invalid operation ID")
	}
	return domain.OperationPlan{
		OperationID: operationID, Command: policy.Name, Effect: policy.Effect, Target: target,
		Consequences: append([]string(nil), policy.Consequences...),
		Confirmed:    policy.Effect == domain.CommandRead, CreatedAt: orchestrator.Clock.Now().UTC(),
	}, nil
}

func (orchestrator *Orchestrator) Confirm(ctx context.Context, plan domain.OperationPlan, assumeYes bool) (domain.OperationPlan, error) {
	if !domain.SafeID(plan.OperationID) || plan.Command == "" ||
		(plan.Effect != domain.CommandRead && plan.Effect != domain.CommandMutate) {
		return domain.OperationPlan{}, errors.New("invalid operation plan")
	}
	if plan.Effect == domain.CommandRead || plan.Confirmed || assumeYes {
		plan.Confirmed = true
		return plan, nil
	}
	if !plan.Confirmed {
		if orchestrator.Prompt == nil {
			return domain.OperationPlan{}, errors.New("mutating operation requires a prompt port")
		}
		accepted, err := orchestrator.Prompt.Confirm(ctx, plan.Command, plan.Consequences)
		if err != nil {
			return domain.OperationPlan{}, err
		}
		if !accepted {
			return domain.OperationPlan{}, ErrDeclined
		}
		plan.Confirmed = true
	}
	return plan, nil
}

func Route(yard domain.Context, policy domain.RemotePolicy) (domain.ExecutionTarget, error) {
	if policy != domain.RemoteOnController && policy != domain.RemoteOnOwner && policy != domain.RemoteDenied {
		return "", errors.New("invalid remote command policy")
	}
	if yard.YardType != domain.YardRemote {
		return domain.TargetLocalOwner, nil
	}
	switch policy {
	case domain.RemoteOnController:
		return domain.TargetLocalController, nil
	case domain.RemoteOnOwner:
		return domain.TargetRemoteOwner, nil
	case domain.RemoteDenied:
		return "", errors.New("host-local command is denied for a remote yard")
	default:
		return "", errors.New("invalid remote command policy")
	}
}

func (orchestrator *Orchestrator) RunAdapter(
	ctx context.Context,
	plan domain.OperationPlan,
	request domain.AdapterRequest,
	protectedInput io.Reader,
) (domain.AdapterResult, string, error) {
	if orchestrator.Runner == nil {
		return domain.AdapterResult{}, "", errors.New("adapter runner is required")
	}
	if request.OperationID != plan.OperationID {
		return domain.AdapterResult{}, "", errors.New("adapter request does not belong to the operation plan")
	}
	if !plan.Confirmed {
		return domain.AdapterResult{}, "", errors.New("adapter request belongs to an unconfirmed operation plan")
	}
	if err := orchestrator.record(ctx, plan, "operation.started", nil); err != nil {
		return domain.AdapterResult{}, "", err
	}
	result, stderr, runErr := orchestrator.Runner.Run(ctx, request, protectedInput)
	data := map[string]any{"status": result.Status}
	if runErr != nil {
		data["status"] = "error"
		data["error"] = runErr.Error()
	}
	recordErr := orchestrator.record(ctx, plan, "operation.finished", data)
	if runErr != nil {
		return result, stderr, runErr
	}
	if recordErr != nil {
		return result, stderr, recordErr
	}
	return result, stderr, nil
}

func (orchestrator *Orchestrator) record(ctx context.Context, plan domain.OperationPlan, kind string, data map[string]any) error {
	orchestrator.mu.Lock()
	orchestrator.revision++
	revision := orchestrator.revision
	orchestrator.mu.Unlock()
	event := domain.OperationEvent{
		OperationID: plan.OperationID, Sequence: revision, Revision: revision,
		Kind: kind, At: orchestrator.Clock.Now().UTC(), Data: data,
	}
	if orchestrator.Audit != nil {
		if err := orchestrator.Audit.WriteAudit(ctx, event); err != nil {
			return fmt.Errorf("write operation audit: %w", err)
		}
	}
	if orchestrator.Events != nil {
		if err := orchestrator.Events.Publish(ctx, event); err != nil {
			return fmt.Errorf("publish operation event: %w", err)
		}
	}
	return nil
}
