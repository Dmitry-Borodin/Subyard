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
