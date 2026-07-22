package application

import (
	"context"
	"errors"
	"fmt"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
)

type ProjectInventory struct {
	Store    ports.ProjectStore
	Observer ports.ProjectObserver
}

func (inventory ProjectInventory) Read(
	ctx context.Context,
	yard domain.Context,
	live bool,
) ([]domain.ProjectRecord, domain.ProjectObservation, error) {
	if inventory.Store == nil {
		return nil, domain.ProjectObservation{}, errors.New("project store is required")
	}
	records, err := inventory.Store.List(ctx)
	if err != nil {
		return nil, domain.ProjectObservation{}, err
	}
	observation := domain.ProjectObservation{
		Presence: make(map[string]domain.ProjectPresence), Boxes: make(map[string]domain.ProjectBoxState),
	}
	if inventory.Observer != nil {
		observation, err = inventory.Observer.Observe(ctx, yard, records, live)
		if err != nil {
			return nil, domain.ProjectObservation{}, err
		}
	}
	if live {
		service := state.Service{Store: inventory.Store}
		for _, discovered := range observation.Live {
			if err := service.UpsertYard(ctx, discovered.ProjectID, discovered.Name, discovered.Mode,
				discovered.Target, yard.SSHHost); err != nil {
				observation.Warnings = append(observation.Warnings,
					fmt.Sprintf("ignored invalid yard project metadata: %v", err))
			}
		}
		records, err = inventory.Store.List(ctx)
		if err != nil {
			return nil, domain.ProjectObservation{}, err
		}
	}
	return records, observation, nil
}

func ProjectConsequences(command string, record domain.ProjectRecord, soft bool) []string {
	switch command {
	case "sync":
		return []string{fmt.Sprintf("copy %s to %s", record.HostPath, record.YardPath)}
	case "bind":
		return []string{fmt.Sprintf("expose %s at %s through an Incus disk", record.HostPath, record.YardPath)}
	case "clone":
		return []string{fmt.Sprintf("clone the repository inside the yard at %s", record.YardPath)}
	case "remove":
		if record.Mode == domain.ProjectBind {
			return []string{"detach the Incus disk without deleting the host directory"}
		}
		if soft {
			return []string{"keep the project workspace in the yard"}
		}
		return []string{"delete the project workspace from the yard"}
	case "up":
		return []string{fmt.Sprintf("build or start the %s project environment", record.Target)}
	default:
		return nil
	}
}
