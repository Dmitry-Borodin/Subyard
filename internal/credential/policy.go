package credential

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

type Decision struct {
	RequiresMerge bool
	Conflict      bool
	Reason        string
	State         string
	Parents       []string
	Recipients    []string
	Exclusive     bool
	Template      domain.CredentialMetadata
}

func ValidateRevisions(revisions []domain.CredentialMetadata) error {
	byID := make(map[string]domain.CredentialMetadata, len(revisions))
	for _, revision := range revisions {
		if err := validateMetadata(revision); err != nil {
			return err
		}
		if _, duplicate := byID[revision.RevisionID]; duplicate {
			return fmt.Errorf("duplicate credential revision %q", revision.RevisionID)
		}
		byID[revision.RevisionID] = revision
	}
	for _, revision := range revisions {
		seenParents := make(map[string]struct{})
		for _, parentID := range revision.Parents {
			if _, duplicate := seenParents[parentID]; duplicate {
				return fmt.Errorf("revision %q has duplicate parent %q", revision.RevisionID, parentID)
			}
			seenParents[parentID] = struct{}{}
			parent, ok := byID[parentID]
			if !ok {
				return fmt.Errorf("revision %q has unknown parent %q", revision.RevisionID, parentID)
			}
			if parent.CredentialID != revision.CredentialID {
				return fmt.Errorf("revision %q crosses credential histories", revision.RevisionID)
			}
		}
	}
	visiting := make(map[string]bool)
	visited := make(map[string]bool)
	var visit func(string) error
	visit = func(id string) error {
		if visiting[id] {
			return fmt.Errorf("credential revision cycle at %q", id)
		}
		if visited[id] {
			return nil
		}
		visiting[id] = true
		for _, parent := range byID[id].Parents {
			if err := visit(parent); err != nil {
				return err
			}
		}
		delete(visiting, id)
		visited[id] = true
		return nil
	}
	for id := range byID {
		if err := visit(id); err != nil {
			return err
		}
	}
	return nil
}

func Heads(revisions []domain.CredentialMetadata, credentialID string) []domain.CredentialMetadata {
	parents := make(map[string]struct{})
	for _, revision := range revisions {
		if revision.CredentialID != credentialID {
			continue
		}
		for _, parent := range revision.Parents {
			parents[parent] = struct{}{}
		}
	}
	heads := make([]domain.CredentialMetadata, 0)
	for _, revision := range revisions {
		if revision.CredentialID != credentialID {
			continue
		}
		if _, hasChild := parents[revision.RevisionID]; !hasChild {
			heads = append(heads, revision)
		}
	}
	sort.Slice(heads, func(left, right int) bool {
		if heads[left].ActorID != heads[right].ActorID {
			return heads[left].ActorID < heads[right].ActorID
		}
		if heads[left].ActorCounter != heads[right].ActorCounter {
			return heads[left].ActorCounter < heads[right].ActorCounter
		}
		return heads[left].RevisionID < heads[right].RevisionID
	})
	return heads
}

func AnalyzeHeads(ctx context.Context, heads []domain.CredentialMetadata, crypto ports.CredentialCrypto) (Decision, error) {
	if len(heads) == 0 {
		return Decision{}, errors.New("credential has no heads")
	}
	credentialID := heads[0].CredentialID
	for _, head := range heads {
		if err := validateMetadata(head); err != nil {
			return Decision{}, err
		}
		if head.CredentialID != credentialID {
			return Decision{}, errors.New("heads belong to different credentials")
		}
		if crypto != nil {
			if err := crypto.Verify(ctx, head); err != nil {
				return Decision{}, fmt.Errorf("verify revision %s: %w", head.RevisionID, err)
			}
		}
	}
	decision := Decision{
		RequiresMerge: len(heads) > 1,
		State:         heads[0].State,
		Parents:       make([]string, 0, len(heads)),
		Recipients:    recipientIntersection(heads),
		Template:      heads[0],
	}
	for _, head := range heads {
		decision.Parents = append(decision.Parents, head.RevisionID)
		decision.Exclusive = decision.Exclusive || head.Exclusive
		if head.State == "tombstone" || (head.State == "revoked" && decision.State != "tombstone") {
			decision.State = head.State
		}
	}
	sort.Strings(decision.Parents)
	if len(heads) == 1 {
		return decision, nil
	}
	if len(decision.Recipients) == 0 {
		return conflict(decision, "heads have no common recipient"), nil
	}
	if decision.State == "revoked" || decision.State == "tombstone" {
		return decision, nil
	}
	if !compatibleMetadata(heads) {
		return conflict(decision, "head metadata differs"), nil
	}
	if crypto == nil {
		return Decision{}, errors.New("active multi-head analysis requires credential crypto")
	}
	var expected []byte
	for _, head := range heads {
		var payload bytes.Buffer
		if err := crypto.Decrypt(ctx, head, &payload); err != nil {
			clear(expected)
			return conflict(decision, "a head could not be decrypted"), nil
		}
		current := payload.Bytes()
		if expected == nil {
			expected = append([]byte(nil), current...)
		} else if !bytes.Equal(expected, current) {
			clear(expected)
			clear(current)
			return conflict(decision, "active head payloads differ"), nil
		}
		clear(current)
	}
	clear(expected)
	return decision, nil
}

func RekeyRecipients(current []string, actor string, trust bool) ([]string, error) {
	if !domain.SafeID(actor) {
		return nil, fmt.Errorf("invalid actor ID %q", actor)
	}
	set := make(map[string]struct{}, len(current)+1)
	for _, existing := range current {
		if !domain.SafeID(existing) {
			return nil, fmt.Errorf("invalid actor ID %q", existing)
		}
		set[existing] = struct{}{}
	}
	if trust {
		set[actor] = struct{}{}
	} else {
		delete(set, actor)
	}
	if len(set) == 0 {
		return nil, errors.New("credential must retain at least one recipient")
	}
	result := make([]string, 0, len(set))
	for existing := range set {
		result = append(result, existing)
	}
	sort.Strings(result)
	return result, nil
}

func MoveAssignment(head domain.CredentialMetadata, authorityHost, assignedYard string, expectedEpoch int64) (domain.CredentialMetadata, error) {
	if !head.Exclusive {
		return domain.CredentialMetadata{}, errors.New("only exclusive credentials have assignments")
	}
	if head.AssignmentEpoch != expectedEpoch {
		return domain.CredentialMetadata{}, fmt.Errorf("assignment epoch changed: expected %d, current %d", expectedEpoch, head.AssignmentEpoch)
	}
	if !domain.SafeID(authorityHost) {
		return domain.CredentialMetadata{}, errors.New("invalid authority host")
	}
	owner, yard, ok := strings.Cut(assignedYard, "/")
	if !ok || !domain.SafeID(owner) || !domain.SafeName(yard) {
		return domain.CredentialMetadata{}, errors.New("assigned yard must be <actor>/<yard>")
	}
	updated := head
	updated.AuthorityHost = authorityHost
	updated.AssignedYard = assignedYard
	updated.AssignmentEpoch++
	return updated, nil
}

func RetryDelay(consecutiveFailures int) time.Duration {
	if consecutiveFailures <= 0 {
		return 6 * time.Hour
	}
	exponent := consecutiveFailures - 1
	if exponent > 6 {
		exponent = 6
	}
	delay := 5 * time.Minute * time.Duration(1<<exponent)
	if delay > 6*time.Hour {
		return 6 * time.Hour
	}
	return delay
}

func validateMetadata(metadata domain.CredentialMetadata) error {
	if metadata.SchemaVersion != 1 {
		return fmt.Errorf("unsupported credential schema %d", metadata.SchemaVersion)
	}
	if !domain.SafeID(metadata.CredentialID) || !domain.SafeID(metadata.RevisionID) ||
		!domain.SafeID(metadata.ActorID) || metadata.ActorCounter < 1 {
		return errors.New("invalid credential or revision identity")
	}
	if metadata.Label == "" || !domain.SafeID(metadata.Kind) || !domain.SafeID(metadata.Zone) || metadata.Scope != "staging" {
		return errors.New("invalid credential classification")
	}
	if !slices.Contains([]string{"none", "staging-env", "qa-secrets", "qa-pool"}, metadata.Consumer) {
		return errors.New("invalid credential consumer")
	}
	if !slices.Contains([]string{"active", "revoked", "tombstone"}, metadata.State) {
		return errors.New("invalid credential state")
	}
	if len(metadata.RecipientActors) == 0 || metadata.AssignmentEpoch < 0 || metadata.Timestamp.IsZero() {
		return errors.New("credential recipients, epoch and timestamp are required")
	}
	seen := make(map[string]struct{}, len(metadata.RecipientActors))
	for _, actor := range metadata.RecipientActors {
		if !domain.SafeID(actor) {
			return fmt.Errorf("invalid recipient actor %q", actor)
		}
		if _, duplicate := seen[actor]; duplicate {
			return fmt.Errorf("duplicate recipient actor %q", actor)
		}
		seen[actor] = struct{}{}
	}
	return nil
}

func recipientIntersection(heads []domain.CredentialMetadata) []string {
	counts := make(map[string]int)
	for _, head := range heads {
		seen := make(map[string]struct{})
		for _, actor := range head.RecipientActors {
			if _, duplicate := seen[actor]; !duplicate {
				counts[actor]++
				seen[actor] = struct{}{}
			}
		}
	}
	result := make([]string, 0)
	for actor, count := range counts {
		if count == len(heads) {
			result = append(result, actor)
		}
	}
	sort.Strings(result)
	return result
}

func compatibleMetadata(heads []domain.CredentialMetadata) bool {
	first := heads[0]
	for _, head := range heads[1:] {
		if head.Label != first.Label || head.Kind != first.Kind || head.Zone != first.Zone ||
			head.Consumer != first.Consumer || head.AuthorityHost != first.AuthorityHost ||
			head.AssignedYard != first.AssignedYard || head.AssignmentEpoch != first.AssignmentEpoch {
			return false
		}
	}
	return true
}

func conflict(decision Decision, reason string) Decision {
	decision.Conflict = true
	decision.Reason = reason
	return decision
}
