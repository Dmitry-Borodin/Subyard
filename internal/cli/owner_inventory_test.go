package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/Subyard/Subyard/internal/domain"
)

func inventoryResult(hostID, yard, project string) ownerInventoryResult {
	projects := []domain.OwnerProject{}
	if project != "" {
		projects = append(projects, domain.OwnerProject{
			ProjectID: strings.ToLower(project) + "-id", Name: project, Mode: "sync", Target: "yard",
		})
	}
	return ownerInventoryResult{inventory: domain.OwnerInventory{
		Schema: domain.OwnerInventorySchema, HostID: hostID, ObservedAt: time.Now(),
		Yards: []domain.OwnerYard{{
			Name: yard, Kind: "container", Instance: "subyard-" + yard, State: "RUNNING",
			SSHPort: 2222, DevUser: "dev", Projects: projects,
		}},
	}}
}

func TestOwnerYardSelectorRequiresCanonicalPathWhenAmbiguous(t *testing.T) {
	results := []ownerInventoryResult{
		inventoryResult("owner-a", "dev", "Demo"),
		inventoryResult("owner-b", "dev", "Other"),
	}
	if _, _, err := selectOwnerYards(results, "dev"); err == nil ||
		!strings.Contains(err.Error(), "owner-a/dev") ||
		!strings.Contains(err.Error(), "owner-b/dev") {
		t.Fatalf("ambiguous short selector diagnostic drifted: %v", err)
	}
	selected, _, err := selectOwnerYards(results, "owner-b/dev")
	if err != nil || len(selected) != 1 || selected[0].inventory.HostID != "owner-b" {
		t.Fatalf("canonical selector failed: selected=%#v err=%v", selected, err)
	}
}

func TestOwnerCompletionPrintsFullAndOnlyUniqueShortSelectors(t *testing.T) {
	results := []ownerInventoryResult{
		inventoryResult("owner-a", "dev", "Demo"),
		inventoryResult("owner-b", "dev", "Demo"),
		inventoryResult("owner-b", "ops", "Unique"),
	}
	var yards bytes.Buffer
	printOwnerCompletions(&yards, results, "yards")
	yardLines := "\n" + yards.String()
	if strings.Contains(yardLines, "\ndev\n") ||
		!strings.Contains(yards.String(), "owner-a/dev") ||
		!strings.Contains(yardLines, "\nops\n") {
		t.Fatalf("yard completion drifted:\n%s", yards.String())
	}
	var projects bytes.Buffer
	printOwnerCompletions(&projects, results, "projects")
	projectLines := "\n" + projects.String()
	if strings.Contains(projectLines, "\nDemo\n") ||
		!strings.Contains(projects.String(), "owner-a/dev/Demo") ||
		!strings.Contains(projectLines, "\nUnique\n") {
		t.Fatalf("project completion drifted:\n%s", projects.String())
	}
}
