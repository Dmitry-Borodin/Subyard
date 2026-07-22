package application

import (
	"strings"
	"testing"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

func TestProjectConsequencesOwnSafetyPlan(t *testing.T) {
	record := domain.ProjectRecord{HostPath: "/host/project", YardPath: "/srv/workspaces/id/src"}
	for _, test := range []struct {
		command string
		mode    domain.ProjectMode
		soft    bool
		want    string
	}{
		{"sync", domain.ProjectSync, false, "copy /host/project"},
		{"bind", domain.ProjectBind, false, "expose /host/project"},
		{"remove", domain.ProjectBind, true, "without deleting the host directory"},
		{"remove", domain.ProjectSync, true, "keep the project workspace"},
		{"remove", domain.ProjectSync, false, "delete the project workspace"},
	} {
		record.Mode = test.mode
		got := strings.Join(ProjectConsequences(test.command, record, test.soft), " ")
		if !strings.Contains(got, test.want) {
			t.Fatalf("%s consequence %q does not contain %q", test.command, got, test.want)
		}
	}
}
