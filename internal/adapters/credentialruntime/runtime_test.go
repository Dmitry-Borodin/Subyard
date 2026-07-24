package credentialruntime

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

const credentialFixturePublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture"

func TestNewAndBoundaryKeepCredentialStateHostOnly(t *testing.T) {
	runtime := credentialFixture(t)
	if err := runtime.assertBoundary(); err != nil {
		t.Fatalf("safe sibling roots were rejected: %v", err)
	}
	for name, path := range map[string]string{
		"checkout": filepath.Join(runtime.config.RepositoryRoot, "keys"),
		"host":     filepath.Join(runtime.config.HostBase, "keys"),
	} {
		config := runtime.config
		config.Root = path
		candidate, err := New(config)
		if err != nil {
			t.Fatalf("construct %s boundary fixture: %v", name, err)
		}
		if err := candidate.assertBoundary(); err == nil {
			t.Fatalf("credential root inside %s boundary was accepted", name)
		}
	}
	config := runtime.config
	config.Context = "../unsafe"
	if _, err := New(config); err == nil {
		t.Fatal("unsafe yard context was accepted")
	}
	config = runtime.config
	config.Root = "relative"
	if _, err := New(config); err == nil {
		t.Fatal("relative credential root was accepted")
	}
}

func TestProtectedJSONAtomicWriteAndCounter(t *testing.T) {
	runtime := credentialFixture(t)
	path := filepath.Join(runtime.config.Root, "protected.json")
	type document struct {
		Name string `json:"name"`
	}
	payload, _ := json.Marshal(document{Name: "fixture"})
	if err := atomicWrite(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	var decoded document
	if err := readProtectedJSON(path, &decoded); err != nil || decoded.Name != "fixture" {
		t.Fatalf("protected JSON did not round-trip: %#v err=%v", decoded, err)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("protected JSON mode drifted: info=%v err=%v", info, err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := readProtectedJSON(path, &decoded); err == nil {
		t.Fatal("world-readable protected JSON was accepted")
	}
	if err := atomicWrite(path, append(payload, []byte("\n{}")...), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := readProtectedJSON(path, &decoded); err == nil {
		t.Fatal("protected JSON with trailing data was accepted")
	}

	if err := os.MkdirAll(runtime.stateDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	first, err := runtime.nextCounter()
	if err != nil {
		t.Fatal(err)
	}
	second, err := runtime.nextCounter()
	if err != nil || first != 1 || second != 2 {
		t.Fatalf("counter sequence drifted: first=%d second=%d err=%v", first, second, err)
	}
	writeCredentialFile(t, filepath.Join(runtime.stateDirectory, "counter"), "-1\n", 0o600)
	if _, err := runtime.nextCounter(); err == nil {
		t.Fatal("negative actor counter was accepted")
	}
}

func TestPeerStorePreservesActiveRouteAndRejectsIdentityRotation(t *testing.T) {
	runtime := credentialFixture(t)
	identity := credentialPeerIdentity("actor-peer")
	peer, err := runtime.storePeer("local-peer", identity, "ssh", "owner.example", "inner", false)
	if err != nil {
		t.Fatal(err)
	}
	if peer.Transport != "ssh" || peer.Dest != "owner.example" || peer.RemoteYard != "inner" {
		t.Fatalf("active peer route was not stored: %#v", peer)
	}
	inbound, err := runtime.storePeer("controller-alias", identity, "inbound", "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	if inbound != peer {
		t.Fatalf("reciprocal inbound enrollment demoted the active route: %#v", inbound)
	}
	if _, err := os.Lstat(filepath.Join(runtime.peersDirectory, "controller-alias.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("duplicate actor alias was stored: %v", err)
	}
	rotated := identity
	rotated.SigningPublic = "ssh-ed25519 AAAAchanged"
	if _, err := runtime.storePeer("local-peer", rotated, "ssh", "owner.example", "inner", false); err == nil {
		t.Fatal("known peer rotated its signing identity")
	}
	peers, err := runtime.peers()
	if err != nil || len(peers) != 1 || peers[0] != peer {
		t.Fatalf("stored peers drifted: %#v err=%v", peers, err)
	}
	signerData, err := os.ReadFile(runtime.allowedSigners)
	if err != nil || strings.Count(string(signerData), "actor-peer ") != 1 {
		t.Fatalf("allowed signer was not stored exactly once: %q err=%v", signerData, err)
	}
}

func TestPeerRoutesAssignmentsAndSyncState(t *testing.T) {
	runtime := credentialFixture(t)
	for _, test := range []struct {
		peer       domain.CredentialPeer
		role       string
		assignment string
	}{
		{
			peer: domain.CredentialPeer{
				Name: "local", ActorID: "actor-local", Transport: "local",
			},
			role: "active", assignment: "actor-local/local",
		},
		{
			peer: domain.CredentialPeer{
				Name: "remote", ActorID: "actor-remote", Transport: "ssh", RemoteYard: "inner",
			},
			role: "active", assignment: "actor-remote/inner",
		},
	} {
		role, err := peerRole(test.peer)
		if err != nil || role != test.role {
			t.Fatalf("peer role drifted: peer=%#v role=%q err=%v", test.peer, role, err)
		}
		assignment, err := peerAssignment(test.peer)
		if err != nil || assignment != test.assignment {
			t.Fatalf("peer assignment drifted: peer=%#v assignment=%q err=%v",
				test.peer, assignment, err)
		}
	}
	passive := domain.CredentialPeer{Name: "passive", ActorID: "actor-passive", Transport: "inbound"}
	if role, err := peerRole(passive); err != nil || role != "passive" {
		t.Fatalf("passive role drifted: %q err=%v", role, err)
	}
	if _, err := peerAssignment(passive); err == nil {
		t.Fatal("passive peer received an assignment route")
	}
	if actor, yard, err := splitAssignment("actor-peer/inner"); err != nil ||
		actor != "actor-peer" || yard != "inner" {
		t.Fatalf("assignment parsing drifted: actor=%q yard=%q err=%v", actor, yard, err)
	}
	if _, _, err := splitAssignment("../bad"); err == nil {
		t.Fatal("unsafe assignment was accepted")
	}

	if err := runtime.writeState("remote", false, "offline\nretry", ""); err != nil {
		t.Fatal(err)
	}
	state, err := runtime.readState("remote")
	if err != nil || state.Peer != "remote" || state.ConsecutiveFailures != 1 ||
		state.Error != "offline\nretry" || state.NextRetry <= state.LastAttempt {
		t.Fatalf("failure telemetry drifted: %#v err=%v", state, err)
	}
	if err := runtime.writeState("remote", true, "", strings.Repeat("a", 40)); err != nil {
		t.Fatal(err)
	}
	state, err = runtime.readState("remote")
	if err != nil || state.ConsecutiveFailures != 0 || state.LastSuccess == 0 ||
		state.LastHead != strings.Repeat("a", 40) || state.Error != "" {
		t.Fatalf("success telemetry drifted: %#v err=%v", state, err)
	}
}

func TestRecordParsingOwnsLayoutEncryptionAndGraphValidation(t *testing.T) {
	runtime := credentialFixture(t)
	parent := credentialMetadata("actor-a-000000000001-aaaaaaaa", "actor-a", 1)
	child := credentialMetadata("actor-a-000000000002-bbbbbbbb", "actor-a", 2)
	child.Parents = []string{parent.RevisionID}
	writeCredentialRecord(t, runtime, sharedLedger, child)
	writeCredentialRecord(t, runtime, sharedLedger, parent)

	records, err := runtime.records(context.Background(), sharedLedger)
	if err != nil || len(records) != 2 || records[0].RevisionID != parent.RevisionID ||
		records[1].RevisionID != child.RevisionID {
		t.Fatalf("credential records did not load deterministically: %#v err=%v", records, err)
	}
	scope, err := runtime.findScope(parent.CredentialID)
	if err != nil || scope != sharedLedger {
		t.Fatalf("credential scope was not found: %q err=%v", scope, err)
	}
	if err := os.MkdirAll(filepath.Join(runtime.local, "records", parent.CredentialID), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := runtime.findScope(parent.CredentialID); err == nil {
		t.Fatal("credential present in both ledgers was accepted")
	}

	unknown := filepath.Join(runtime.shared, "records", parent.CredentialID, "unknown.json")
	writeCredentialFile(t, unknown, `{"unknown":true}`, 0o600)
	if _, err := readRecord(unknown); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unknown record field was accepted: %v", err)
	}
	mismatched := filepath.Join(runtime.shared, "records", "cred-ffffffffffffffffffffffffffffffff",
		parent.RevisionID+".json")
	writeCredentialEnvelope(t, mismatched, parent)
	if _, err := runtime.readRecordMetadata(mismatched); err == nil ||
		!strings.Contains(err.Error(), "path does not match") {
		t.Fatalf("mismatched record path was accepted: %v", err)
	}
}

func TestArchiveExtractionAndQuarantineRejectUnsafeTrees(t *testing.T) {
	destination := t.TempDir()
	if err := extractLedgerArchive(credentialTar(t, map[string]string{
		".ledger": "fixture",
		"records/cred-0123456789abcdef0123456789abcdef/revision.json": "ciphertext",
	}), destination); err != nil {
		t.Fatal(err)
	}
	assertCredentialFileContains(t, filepath.Join(destination, ".ledger"), "fixture")
	if err := extractLedgerArchive(credentialTar(t, map[string]string{
		"../escape": "bad",
	}), t.TempDir()); err == nil {
		t.Fatal("archive path traversal was accepted")
	}
	var link bytes.Buffer
	writer := tar.NewWriter(&link)
	if err := writer.WriteHeader(&tar.Header{Name: "link", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd"}); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := extractLedgerArchive(link.Bytes(), t.TempDir()); err == nil {
		t.Fatal("archive symlink was accepted")
	}

	runtime := credentialFixture(t)
	tree := t.TempDir()
	record := filepath.Join(tree, "records", "cred-id", "revision.json")
	writeCredentialFile(t, record, "ciphertext", 0o600)
	writeCredentialFile(t, record+".sig", "signature", 0o600)
	runtime.quarantineTree(tree)
	assertCredentialFileContains(t,
		filepath.Join(runtime.quarantine, "records", "cred-id", "revision.json"), "ciphertext")
	assertCredentialFileContains(t,
		filepath.Join(runtime.quarantine, "records", "cred-id", "revision.json.sig"), "signature")
}

func TestPayloadImportDenylistAndConsumerMapping(t *testing.T) {
	runtime := credentialFixture(t)
	runtime.config.Stdin = strings.NewReader("secret-from-stdin")
	payload, err := runtime.capturePayload("")
	if err != nil || string(payload) != "secret-from-stdin" {
		t.Fatalf("stdin capture failed: %q err=%v", payload, err)
	}
	runtime.config.Stdin = strings.NewReader("")
	if _, err := runtime.capturePayload(""); err == nil {
		t.Fatal("empty secret stdin was accepted")
	}

	source := filepath.Join(t.TempDir(), "credential.env")
	writeCredentialFile(t, source, "TOKEN=fixture", 0o600)
	if resolved, err := runtime.validateImportPath(source); err != nil || resolved != source {
		t.Fatalf("protected source was rejected: %q err=%v", resolved, err)
	}
	if err := os.Chmod(source, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := runtime.validateImportPath(source); err == nil {
		t.Fatal("broad source permissions were accepted")
	}
	oauth := filepath.Join(t.TempDir(), ".codex", "auth.json")
	writeCredentialFile(t, oauth, "{}", 0o600)
	if _, err := runtime.validateImportPath(oauth); err == nil {
		t.Fatal("mutable coding-agent OAuth store was accepted")
	}

	blocked := "production-token"
	digest := sha256.Sum256([]byte(blocked))
	denylist := filepath.Join(t.TempDir(), "fingerprints")
	writeCredentialFile(t, denylist, hex.EncodeToString(digest[:])+" fixture\n", 0o600)
	runtime.env["SUBYARD_KEYS_PROD_FINGERPRINTS"] = denylist
	for _, candidate := range []string{
		blocked,
		"TOKEN='" + blocked + "'\n",
		`{"nested":{"token":"` + blocked + `"}}`,
	} {
		if err := runtime.rejectProductionPayload([]byte(candidate)); err == nil {
			t.Fatalf("production fingerprint was accepted in %q", candidate)
		}
	}
	if err := runtime.rejectProductionPayload([]byte("TOKEN=staging")); err != nil {
		t.Fatalf("unrelated staging payload was rejected: %v", err)
	}

	staging, mapped, err := runtime.consumerPath("staging-env", "demo")
	if err != nil || !mapped ||
		staging != filepath.Join(runtime.config.ConsumerRoot, "staging", "demo.env") {
		t.Fatalf("staging consumer mapping drifted: path=%q mapped=%v err=%v", staging, mapped, err)
	}
	if runtime.detectConsumer(staging) != "staging-env" || runtime.detectZone(staging) != "demo" {
		t.Fatalf("consumer detection drifted for %s", staging)
	}
	if _, _, err := runtime.consumerPath("staging-env", "../prod"); err == nil {
		t.Fatal("consumer zone traversal was accepted")
	}
}

func TestWorkflowArgumentValidationIsDirectAndSideEffectFree(t *testing.T) {
	options, err := parseAdd([]string{
		"API token", "--kind", "token", "--zone", "qa", "--consumer", "staging-env",
		"--exclusive", "--yes",
	})
	if err != nil || options.label != "API token" || options.kind != "token" ||
		options.zone != "qa" || options.consumer != "staging-env" || !options.exclusive {
		t.Fatalf("keys add parse drifted: %#v err=%v", options, err)
	}
	for _, arguments := range [][]string{
		{},
		{"label", "--unknown"},
		{"label", "--zone", "production"},
		{"label", "--consumer", "../unsafe"},
	} {
		if _, err := parseAdd(arguments); err == nil {
			t.Fatalf("invalid keys add arguments were accepted: %#v", arguments)
		}
	}
	credentialID := "cred-0123456789abcdef0123456789abcdef"
	id, source, err := parseCredentialAndFile([]string{credentialID, "--file", "/tmp/source", "--yes"})
	if err != nil || id != credentialID || source != "/tmp/source" {
		t.Fatalf("credential/file parse drifted: id=%q source=%q err=%v", id, source, err)
	}
	if _, _, err := parseCredentialAndFile([]string{"invalid"}); err == nil {
		t.Fatal("invalid credential ID was accepted")
	}
	if got := withoutYes([]string{"one", "-y", "two", "--yes"}); len(got) != 2 ||
		got[0] != "one" || got[1] != "two" {
		t.Fatalf("confirmation filtering drifted: %#v", got)
	}
	if ageHuman(59) != "59s" || ageHuman(60) != "1m" ||
		ageHuman(3600) != "1h" || ageHuman(86400) != "1d" {
		t.Fatal("credential status age formatting drifted")
	}
}

func TestPreparedReadOperationsRenderLedgerStateWithoutMutation(t *testing.T) {
	runtime := credentialFixture(t)
	var output bytes.Buffer
	runtime.config.Stdout = &output

	prepared, err := runtime.Prepare(context.Background(), "", []string{"--help"})
	if err != nil || prepared.Effect != domain.CommandRead {
		t.Fatalf("help preparation drifted: %#v err=%v", prepared, err)
	}
	if err := prepared.Execute(context.Background()); err != nil ||
		!strings.Contains(output.String(), "Host-side encrypted credential ledger") {
		t.Fatalf("help execution drifted: output=%q err=%v", output.String(), err)
	}
	output.Reset()
	prepared, err = runtime.Prepare(context.Background(), "", []string{"status"})
	if err != nil {
		t.Fatal(err)
	}
	if err := prepared.Execute(context.Background()); err != nil ||
		!strings.Contains(output.String(), "not initialized") {
		t.Fatalf("uninitialized status drifted: output=%q err=%v", output.String(), err)
	}

	installCredentialIdentity(t, runtime)
	metadata := credentialMetadata("actor-a-000000000001-aaaaaaaa", "actor-a", 1)
	writeCredentialRecord(t, runtime, sharedLedger, metadata)
	for _, test := range []struct {
		arguments []string
		expected  string
	}{
		{[]string{"list"}, metadata.CredentialID},
		{[]string{"history", metadata.CredentialID}, metadata.RevisionID},
		{[]string{"status"}, "conflicts=0"},
	} {
		output.Reset()
		prepared, err := runtime.Prepare(context.Background(), "", test.arguments)
		if err != nil || prepared.Effect != domain.CommandRead {
			t.Fatalf("prepare %#v: effect=%q err=%v", test.arguments, prepared.Effect, err)
		}
		if err := prepared.Execute(context.Background()); err != nil ||
			!strings.Contains(output.String(), test.expected) {
			t.Fatalf("execute %#v: output=%q err=%v", test.arguments, output.String(), err)
		}
	}
	if _, err := runtime.Prepare(context.Background(), "", []string{"unknown"}); err == nil {
		t.Fatal("unknown public keys command was accepted")
	}
	if err := (Prepared{}).Execute(context.Background()); err == nil {
		t.Fatal("empty prepared operation was executable")
	}
}

func TestPreparedDryRunAndAutoSyncPolicyAreDirectlyTestable(t *testing.T) {
	runtime := credentialFixture(t)
	var output bytes.Buffer
	runtime.config.Stdout = &output
	source := filepath.Join(t.TempDir(), "fixture.env")
	writeCredentialFile(t, source, "TOKEN=fixture\n", 0o600)
	prepared, err := runtime.Prepare(context.Background(), "", []string{
		"import", source, "--dry-run", "--label", "fixture",
	})
	if err != nil || prepared.Effect != domain.CommandRead {
		t.Fatalf("dry-run preparation drifted: %#v err=%v", prepared, err)
	}
	if err := prepared.Execute(context.Background()); err != nil ||
		!strings.Contains(output.String(), "no value was read and no ledger changed") {
		t.Fatalf("dry-run execution drifted: output=%q err=%v", output.String(), err)
	}

	identity := credentialPeerIdentity("actor-active")
	if _, err := runtime.storePeer("active", identity, "local", "", "", false); err != nil {
		t.Fatal(err)
	}
	passiveIdentity := credentialPeerIdentity("actor-passive")
	if _, err := runtime.storePeer("passive", passiveIdentity, "inbound", "", "", true); err != nil {
		t.Fatal(err)
	}
	prepared, err = runtime.Prepare(context.Background(), "", []string{
		"auto-sync", "pause", "@active",
	})
	if err != nil || prepared.Effect != domain.CommandMutate ||
		!strings.Contains(strings.Join(prepared.Consequences, " "), "pause") {
		t.Fatalf("auto-sync pause preparation drifted: %#v err=%v", prepared, err)
	}
	if err := prepared.Execute(context.Background()); err != nil {
		t.Fatal(err)
	}
	peer, err := runtime.peer("active")
	if err != nil || !peer.ManualOnly {
		t.Fatalf("active peer was not paused: %#v err=%v", peer, err)
	}
	prepared, err = runtime.Prepare(context.Background(), "", []string{
		"auto-sync", "resume", "@active",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := prepared.Execute(context.Background()); err != nil {
		t.Fatal(err)
	}
	peer, err = runtime.peer("active")
	if err != nil || peer.ManualOnly {
		t.Fatalf("active peer was not resumed: %#v err=%v", peer, err)
	}
	prepared, err = runtime.Prepare(context.Background(), "", []string{
		"auto-sync", "pause", "@passive",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := prepared.Execute(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "respond-only") {
		t.Fatalf("passive auto-sync policy was mutable: %v", err)
	}

	worker, err := runtime.Prepare(context.Background(), "_auto-worker", []string{"--if-due"})
	if err != nil || worker.Effect != domain.CommandMutate {
		t.Fatalf("automatic worker preparation drifted: %#v err=%v", worker, err)
	}
	uninitialized := credentialFixture(t)
	worker, err = uninitialized.Prepare(context.Background(), "_auto-worker", []string{"--if-due"})
	if err != nil || worker.Execute(context.Background()) != nil {
		t.Fatalf("uninitialized automatic worker was not a no-op: %#v err=%v", worker, err)
	}
}

func TestIdentityAndAllowedSignersAreProtectedAndDeduplicated(t *testing.T) {
	runtime := credentialFixture(t)
	identity := installCredentialIdentity(t, runtime)
	got, err := runtime.Identity()
	if err != nil || got != identity {
		t.Fatalf("host identity did not round-trip: %#v err=%v", got, err)
	}
	if err := runtime.addAllowedSigner(identity.ActorID, identity.SigningPublic); err != nil {
		t.Fatal(err)
	}
	if err := runtime.addAllowedSigner(identity.ActorID, identity.SigningPublic); err != nil {
		t.Fatal(err)
	}
	payload, err := os.ReadFile(runtime.allowedSigners)
	if err != nil || strings.Count(string(payload), identity.ActorID+" ") != 1 {
		t.Fatalf("allowed signer was duplicated: %q err=%v", payload, err)
	}
	if err := runtime.addAllowedSigner("../bad", identity.SigningPublic); err == nil {
		t.Fatal("unsafe signer actor was accepted")
	}
	if err := runtime.addAllowedSigner("actor-two", "ssh-rsa invalid"); err == nil {
		t.Fatal("non-ed25519 signer was accepted")
	}
}

func TestLocalTargetUsesUnresolvedCommandEnvironment(t *testing.T) {
	runtime := credentialFixture(t)
	dispatcher := filepath.Join(runtime.config.RepositoryRoot, "dispatcher")
	writeCredentialFile(t, dispatcher, "#!/bin/sh\nprintf '%s\\n' \"$SUBYARD_KEYS_ROOT\"\n", 0o700)
	runtime.config.Dispatcher = dispatcher
	runtime.config.Environment = []string{"SUBYARD_KEYS_ROOT=/current-yard"}
	runtime.config.TargetEnvironment = []string{"SUBYARD_KEYS_ROOT=/target-command"}

	output, err := runtime.callTarget(context.Background(), Target{
		Name: "other", Transport: "local",
	}, []string{"_keys-identity"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(output) != "/target-command\n" {
		t.Fatalf("local target inherited resolved current-yard config: %q", output)
	}
}

func credentialFixture(t *testing.T) *Runtime {
	t.Helper()
	root := t.TempDir()
	tools := filepath.Join(root, "tools")
	for _, name := range []string{"sops", "age-keygen"} {
		writeCredentialFile(t, filepath.Join(tools, "bin", name), "#!/bin/sh\nexit 0\n", 0o700)
	}
	runtime, err := New(Config{
		RepositoryRoot: filepath.Join(root, "checkout"),
		Root:           filepath.Join(root, "credentials"),
		ConsumerRoot:   filepath.Join(root, "consumers"),
		ToolsDirectory: tools,
		HostBase:       filepath.Join(root, "yards"),
		Context:        "default",
		Environment: []string{
			"SUBYARD_GIT_BIN=/bin/true",
			"SUBYARD_SSH_KEYGEN_BIN=/bin/true",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(runtime.config.RepositoryRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	return runtime
}

func credentialPeerIdentity(actor string) Identity {
	return Identity{
		SchemaVersion: credentialSchema,
		ActorID:       actor,
		IdentityScope: "host",
		AgeRecipient:  "age1fixture",
		SigningPublic: credentialFixturePublicKey,
	}
}

func installCredentialIdentity(t *testing.T, runtime *Runtime) Identity {
	t.Helper()
	identity := credentialPeerIdentity("host-fixture")
	payload, err := json.Marshal(identity)
	if err != nil {
		t.Fatal(err)
	}
	writeCredentialFile(t, runtime.identityFile, string(payload), 0o600)
	writeCredentialFile(t, runtime.ageIdentity, "AGE-SECRET-KEY-fixture\n", 0o600)
	writeCredentialFile(t, runtime.signingKey, "private\n", 0o600)
	for _, path := range []string{
		filepath.Join(runtime.shared, ".git"),
		runtime.sharedBare,
		filepath.Join(runtime.local, ".git"),
	} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return identity
}

func credentialMetadata(revision, actor string, counter int64) domain.CredentialMetadata {
	return domain.CredentialMetadata{
		SchemaVersion: credentialSchema,
		CredentialID:  "cred-0123456789abcdef0123456789abcdef",
		RevisionID:    revision,
		Label:         "fixture",
		Kind:          "token",
		Zone:          "qa",
		Scope:         "staging",
		Consumer:      "staging-env",
		State:         "active",
		RecipientActors: []string{
			"actor-a",
		},
		Syncable:     true,
		ActorID:      actor,
		ActorCounter: counter,
		Timestamp:    time.Unix(100, 0).UTC(),
	}
}

func writeCredentialRecord(
	t *testing.T,
	runtime *Runtime,
	scope ledgerScope,
	metadata domain.CredentialMetadata,
) {
	t.Helper()
	writeCredentialEnvelope(t,
		runtime.recordPath(scope, metadata.CredentialID, metadata.RevisionID), metadata)
}

func writeCredentialEnvelope(t *testing.T, path string, metadata domain.CredentialMetadata) {
	t.Helper()
	envelope := recordEnvelope{
		CredentialMetadata: metadata,
		Payload:            "encrypted-fixture",
		SOPS: json.RawMessage(
			`{"age":[{"recipient":"age1fixture"}]}`,
		),
	}
	payload, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	writeCredentialFile(t, path, string(payload), 0o600)
}

func credentialTar(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var archive bytes.Buffer
	writer := tar.NewWriter(&archive)
	for name, payload := range files {
		if err := writer.WriteHeader(&tar.Header{
			Name: name, Mode: 0o600, Size: int64(len(payload)), Typeflag: tar.TypeReg,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte(payload)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return archive.Bytes()
}

func writeCredentialFile(t *testing.T, path, payload string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(payload), mode); err != nil {
		t.Fatal(err)
	}
}

func assertCredentialFileContains(t *testing.T, path, expected string) {
	t.Helper()
	payload, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(payload), expected) {
		t.Fatalf("%s does not contain %q: %q err=%v", path, expected, payload, err)
	}
}
