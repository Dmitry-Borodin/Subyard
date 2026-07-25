package testvmsruntime

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestFacadeContractAndRedaction(t *testing.T) {
	store := LeaseStore{Path: filepath.Join(t.TempDir(), "leases.json"), SlotCount: 1}
	var output bytes.Buffer
	facade := Facade{Store: store, Output: &output}
	key := strings.Fields(fixturePublicKey(t))
	if err := facade.Run("acquire client SHA256:key checkout tests " + key[0] + " " + key[1]); err != nil {
		t.Fatal(err)
	}
	var acquired facadeResponse
	if err := json.Unmarshal(output.Bytes(), &acquired); err != nil {
		t.Fatal(err)
	}
	if acquired.Grant == nil || acquired.Grant.Capability == "" {
		t.Fatalf("missing grant: %#v", acquired)
	}
	output.Reset()
	if err := facade.Run("status"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), acquired.Grant.Capability) ||
		strings.Contains(output.String(), acquired.Grant.LeaseID) {
		t.Fatal("status disclosed lease credentials")
	}
	output.Reset()
	if err := facade.Run("acquire second SHA256:key checkout tests " + key[0] + " " + key[1]); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"code":"busy"`) {
		t.Fatalf("busy response=%s", output.String())
	}
}

func TestFacadeRejectsUnboundedInput(t *testing.T) {
	var output bytes.Buffer
	facade := Facade{
		Store:  LeaseStore{Path: filepath.Join(t.TempDir(), "leases.json"), SlotCount: 1},
		Output: &output,
	}
	if err := facade.Run("status arbitrary"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"code":"invalid_request"`) {
		t.Fatalf("response=%s", output.String())
	}
}
