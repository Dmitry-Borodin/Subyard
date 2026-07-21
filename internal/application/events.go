package application

import (
	"errors"
	"fmt"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

var (
	ErrEventGap       = errors.New("event stream has a gap")
	ErrEventReordered = errors.New("event stream is duplicate or reordered")
)

type EventTracker struct {
	sequence uint64
	revision uint64
}

func NewEventTracker(snapshotRevision uint64) *EventTracker {
	return &EventTracker{revision: snapshotRevision}
}

func (tracker *EventTracker) Accept(event domain.OperationEvent) error {
	if event.Sequence == 0 {
		return errors.New("event sequence must be positive")
	}
	if tracker.sequence != 0 {
		if event.Sequence <= tracker.sequence {
			return fmt.Errorf("%w: got %d after %d", ErrEventReordered, event.Sequence, tracker.sequence)
		}
		if event.Sequence != tracker.sequence+1 {
			return fmt.Errorf("%w: got %d after %d", ErrEventGap, event.Sequence, tracker.sequence)
		}
	}
	if event.Revision < tracker.revision {
		return fmt.Errorf("%w: revision %d after %d", ErrEventReordered, event.Revision, tracker.revision)
	}
	tracker.sequence = event.Sequence
	tracker.revision = event.Revision
	return nil
}

func (tracker *EventTracker) Revision() uint64 { return tracker.revision }
