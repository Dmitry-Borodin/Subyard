package state

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

var ErrAmbiguous = errors.New("project selector is ambiguous")

type Match struct {
	Yard   string
	Record domain.ProjectRecord
}

type Resolver struct {
	Stores map[string]ports.ProjectStore
}

func (resolver Resolver) Resolve(ctx context.Context, selector string) (Match, error) {
	if selector == "" {
		return Match{}, errors.New("project selector is required")
	}
	if yard, rest, qualified := strings.Cut(selector, "/"); qualified {
		if store, ok := resolver.Stores[yard]; ok && rest != "" {
			return resolveOne(ctx, yard, store, rest)
		}
	}
	return resolver.resolveAcross(ctx, selector)
}

func (resolver Resolver) resolveAcross(ctx context.Context, selector string) (Match, error) {
	exact := make([]Match, 0)
	named := make([]Match, 0)
	for yard, store := range resolver.Stores {
		records, err := store.List(ctx)
		if err != nil {
			return Match{}, fmt.Errorf("list projects in yard %s: %w", yard, err)
		}
		for _, record := range records {
			match := Match{Yard: yard, Record: record}
			if record.ProjectID == selector {
				exact = append(exact, match)
			}
			if strings.EqualFold(record.Name, selector) {
				named = append(named, match)
			}
		}
	}
	if len(exact) != 0 {
		return unique(selector, exact)
	}
	return unique(selector, named)
}

func resolveOne(ctx context.Context, yard string, store ports.ProjectStore, selector string) (Match, error) {
	if domain.SafeID(selector) {
		if record, err := store.Get(ctx, selector); err == nil {
			return Match{Yard: yard, Record: record}, nil
		} else if !errors.Is(err, ErrNotFound) {
			return Match{}, err
		}
	}
	records, err := store.List(ctx)
	if err != nil {
		return Match{}, err
	}
	matches := make([]Match, 0)
	for _, record := range records {
		if strings.EqualFold(record.Name, selector) {
			matches = append(matches, Match{Yard: yard, Record: record})
		}
	}
	return unique(selector, matches)
}

func unique(selector string, matches []Match) (Match, error) {
	switch len(matches) {
	case 0:
		return Match{}, fmt.Errorf("project %q was not found", selector)
	case 1:
		return matches[0], nil
	default:
		return Match{}, fmt.Errorf("%w: %q has %d matches", ErrAmbiguous, selector, len(matches))
	}
}
