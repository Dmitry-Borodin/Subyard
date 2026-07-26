package ownerinventory

import (
	"strings"
	"testing"
)

func TestConnectionsCollapseAliasesAndRejectIdentityCollisions(t *testing.T) {
	store := Connections{Root: t.TempDir()}
	if err := store.Write(Connection{
		HostID: "owner-a", Destination: "dev@owner.example",
		LegacyNames: []string{"two", "one", "one"},
		Yards: map[string]YardRoute{
			"default": {SSHHost: "yard-one"},
			"inner":   {SSHHost: "yard-two"},
		},
	}); err != nil {
		t.Fatal(err)
	}
	records, err := store.List()
	if err != nil || len(records) != 1 ||
		strings.Join(records[0].LegacyNames, ",") != "one,two" ||
		records[0].Yards["inner"].SSHHost != "yard-two" {
		t.Fatalf("connection migration drifted: records=%#v err=%v", records, err)
	}
	if err := store.Write(Connection{
		HostID: "owner-a", Destination: "dev@other.example",
	}); err == nil || !strings.Contains(err.Error(), "already registered") {
		t.Fatalf("HostID collision was accepted: %v", err)
	}
	if err := store.Write(Connection{
		HostID: "owner-b", Destination: "dev@owner.example",
	}); err == nil || !strings.Contains(err.Error(), "already registered") {
		t.Fatalf("destination collision was accepted: %v", err)
	}
}
