package testkit

import (
	"context"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

func TestManualClockAndMemoryState(t *testing.T) {
	clock := NewManualClock(time.Unix(100, 0))
	alarm := clock.After(time.Minute)
	clock.Advance(time.Minute)
	if got := <-alarm; !got.Equal(time.Unix(160, 0)) {
		t.Fatalf("unexpected manual time: %s", got)
	}
	state := NewMemoryState(domain.ProjectRecord{ProjectID: "one"})
	records, err := state.List(context.Background())
	if err != nil || len(records) != 1 {
		t.Fatalf("unexpected state: %#v, %v", records, err)
	}
}
