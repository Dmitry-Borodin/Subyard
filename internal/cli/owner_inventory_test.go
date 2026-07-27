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

func TestCompactProjectListOwner(t *testing.T) {
	tests := []struct {
		name  string
		value string
		want  string
	}{
		{name: "empty"},
		{name: "nineteen", value: strings.Repeat("a", 19), want: strings.Repeat("a", 19)},
		{name: "twenty", value: strings.Repeat("b", 20), want: strings.Repeat("b", 20)},
		{name: "twenty-one", value: strings.Repeat("c", 21), want: strings.Repeat("c", 17) + "..."},
		{
			name:  "uuid",
			value: "5034c950-74d0-46c4-9428-b7835e602109",
			want:  "5034c950-74d0-46c...",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := compactProjectListOwner(test.value); got != test.want {
				t.Fatalf("compactProjectListOwner(%q) = %q, want %q", test.value, got, test.want)
			}
		})
	}
}

func TestProjectListOwnerKeepsYardColumnStable(t *testing.T) {
	for _, owner := range []string{
		"owner-a",
		"5034c950-74d0-46c4-9428-b7835e602109",
	} {
		var output bytes.Buffer
		printProjectListRow(&output, "Demo", "sync", "yard", owner, "default")
		line := strings.TrimSuffix(output.String(), "\n")
		if got, want := strings.Index(line, "default"), 64; got != want {
			t.Fatalf("YARD column for owner %q starts at %d, want %d:\n%s", owner, got, want, line)
		}
	}
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

func TestOwnerIdentityOutputsKeepFullHostID(t *testing.T) {
	const ownerA = "5034c950-74d0-46c4-9428-b7835e602109"
	const ownerB = "6034c950-74d0-46c4-9428-b7835e602109"
	results := []ownerInventoryResult{
		inventoryResult(ownerA, "dev", "Demo"),
		inventoryResult(ownerB, "dev", "Other"),
	}
	var completions bytes.Buffer
	printOwnerCompletions(&completions, results[:1], "projects")
	if !strings.Contains(completions.String(), ownerA+"/dev/Demo") ||
		strings.Contains(completions.String(), compactProjectListOwner(ownerA)+"/dev/Demo") {
		t.Fatalf("completion truncated owner identity:\n%s", completions.String())
	}
	if _, _, err := selectOwnerYards(results, "dev"); err == nil ||
		!strings.Contains(err.Error(), ownerA+"/dev") ||
		!strings.Contains(err.Error(), ownerB+"/dev") {
		t.Fatalf("diagnostic truncated owner identity: %v", err)
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
