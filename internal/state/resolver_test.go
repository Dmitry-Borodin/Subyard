package state

import (
	"context"
	"errors"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

func TestResolverQualifiedAndAmbiguous(t *testing.T) {
	left := newTestStore(t)
	right := newTestStore(t)
	for _, item := range []struct {
		store *FileStore
		id    string
	}{
		{left, "left-id"},
		{right, "right-id"},
	} {
		record := fixtureRecord(item.id)
		record.Name = "same"
		if err := item.store.Put(context.Background(), record); err != nil {
			t.Fatal(err)
		}
	}
	resolver := Resolver{Stores: map[string]ports.ProjectStore{"left": left, "right": right}}
	if _, err := resolver.Resolve(context.Background(), "same"); !errors.Is(err, ErrAmbiguous) {
		t.Fatalf("expected ambiguity, got %v", err)
	}
	match, err := resolver.Resolve(context.Background(), "right/same")
	if err != nil {
		t.Fatal(err)
	}
	if match.Yard != "right" || match.Record.ProjectID != "right-id" {
		t.Fatalf("unexpected match: %#v", match)
	}
}
