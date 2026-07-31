package domain

import (
	"strings"
	"testing"
	"time"
)

func TestOwnerInventoryValidationRejectsIdentityCollisions(t *testing.T) {
	base := OwnerInventory{
		Schema: OwnerInventorySchema, HostID: "owner-a", ObservedAt: time.Now(),
		Yards: []OwnerYard{{
			Name: "one", Kind: "container", Instance: "subyard-one", State: "RUNNING",
			SSHPort: 2222, DevUser: "dev",
			Projects: []OwnerProject{{ProjectID: "p-1", Name: "Demo", Mode: "sync", Target: "yard"}},
		}},
	}
	if err := base.Validate(); err != nil {
		t.Fatal(err)
	}
	duplicateYard := base
	duplicateYard.Yards = append(duplicateYard.Yards, base.Yards[0])
	if err := duplicateYard.Validate(); err == nil || !strings.Contains(err.Error(), "duplicate owner yard") {
		t.Fatalf("duplicate yard accepted: %v", err)
	}
	duplicateProject := base
	duplicateProject.Yards = append([]OwnerYard(nil), base.Yards...)
	duplicateProject.Yards[0].Projects = append(
		duplicateProject.Yards[0].Projects, base.Yards[0].Projects[0],
	)
	if err := duplicateProject.Validate(); err == nil || !strings.Contains(err.Error(), "duplicate project") {
		t.Fatalf("duplicate project accepted: %v", err)
	}
	duplicateName := base
	duplicateName.Yards = append([]OwnerYard(nil), base.Yards...)
	duplicateName.Yards[0].Projects = append(
		append([]OwnerProject(nil), base.Yards[0].Projects...),
		OwnerProject{ProjectID: "p-2", Name: "demo", Mode: "git", Target: "yard"},
	)
	if err := duplicateName.Validate(); err == nil ||
		!strings.Contains(err.Error(), "duplicate project name") {
		t.Fatalf("duplicate project name accepted: %v", err)
	}
	shadowedID := base
	shadowedID.Yards = append([]OwnerYard(nil), base.Yards...)
	shadowedID.Yards[0].Projects = append(
		append([]OwnerProject(nil), base.Yards[0].Projects...),
		OwnerProject{ProjectID: "Demo", Name: "Other", Mode: "git", Target: "yard"},
	)
	if err := shadowedID.Validate(); err == nil || !strings.Contains(err.Error(), "shadows") {
		t.Fatalf("foreign project ID shadow accepted: %v", err)
	}
}
