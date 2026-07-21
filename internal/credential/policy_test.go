package credential

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

func TestAnalyzeHeadsSafeMergeAndPayloadConflict(t *testing.T) {
	left := metadata("revision-left", "actor-a", 1)
	right := metadata("revision-right", "actor-b", 1)
	crypto := &testkit.CredentialCrypto{Payloads: map[string][]byte{
		left.RevisionID: []byte("same"), right.RevisionID: []byte("same"),
	}}
	decision, err := AnalyzeHeads(context.Background(), []domain.CredentialMetadata{left, right}, crypto)
	if err != nil {
		t.Fatal(err)
	}
	if decision.Conflict || !decision.RequiresMerge || len(decision.Parents) != 2 {
		t.Fatalf("safe merge rejected: %#v", decision)
	}
	crypto.Payloads[right.RevisionID] = []byte("different")
	decision, err = AnalyzeHeads(context.Background(), []domain.CredentialMetadata{left, right}, crypto)
	if err != nil || !decision.Conflict {
		t.Fatalf("payload conflict accepted: %#v, %v", decision, err)
	}
}

func TestAnalyzeHeadsFailsOnTamperingAndTerminalWins(t *testing.T) {
	left := metadata("revision-left", "actor-a", 1)
	right := metadata("revision-right", "actor-b", 1)
	crypto := &testkit.CredentialCrypto{Err: errors.New("MAC mismatch")}
	if _, err := AnalyzeHeads(context.Background(), []domain.CredentialMetadata{left}, crypto); err == nil {
		t.Fatal("tampered head was accepted")
	}
	left.State = "tombstone"
	decision, err := AnalyzeHeads(context.Background(), []domain.CredentialMetadata{left, right}, nil)
	if err != nil || decision.Conflict || decision.State != "tombstone" {
		t.Fatalf("terminal convergence failed: %#v, %v", decision, err)
	}
}

func TestValidateGraphTrustAssignmentAndBackoff(t *testing.T) {
	parent := metadata("revision-parent", "actor-a", 1)
	child := metadata("revision-child", "actor-a", 2)
	child.Parents = []string{parent.RevisionID}
	if err := ValidateRevisions([]domain.CredentialMetadata{child, parent}); err != nil {
		t.Fatal(err)
	}
	parent.Parents = []string{child.RevisionID}
	if err := ValidateRevisions([]domain.CredentialMetadata{child, parent}); err == nil {
		t.Fatal("revision cycle was accepted")
	}
	recipients, err := RekeyRecipients([]string{"actor-a"}, "actor-b", true)
	if err != nil || len(recipients) != 2 {
		t.Fatalf("trust add failed: %#v, %v", recipients, err)
	}
	exclusive := metadata("revision-exclusive", "actor-a", 3)
	exclusive.Exclusive = true
	updated, err := MoveAssignment(exclusive, "actor-a", "actor-a/yard", 0)
	if err != nil || updated.AssignmentEpoch != 1 {
		t.Fatalf("assignment move failed: %#v, %v", updated, err)
	}
	if RetryDelay(1) != 5*time.Minute || RetryDelay(100) != 5*time.Hour+20*time.Minute {
		t.Fatalf("unexpected retry delays: %s %s", RetryDelay(1), RetryDelay(100))
	}
}

func metadata(revision, actor string, counter int64) domain.CredentialMetadata {
	return domain.CredentialMetadata{
		SchemaVersion: 1, CredentialID: "cred-0123456789abcdef0123456789abcdef", RevisionID: revision,
		Label: "fixture", Kind: "token", Zone: "fixture", Scope: "staging", Consumer: "staging-env",
		State: "active", RecipientActors: []string{"actor-a"}, Syncable: true,
		ActorID: actor, ActorCounter: counter, Timestamp: time.Unix(100, 0),
	}
}
