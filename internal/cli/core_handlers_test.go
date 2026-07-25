package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Subyard/Subyard/internal/adapters/testvmsruntime"
	"github.com/Subyard/Subyard/internal/command"
	"github.com/Subyard/Subyard/internal/config"
	"github.com/Subyard/Subyard/internal/domain"
	"github.com/Subyard/Subyard/internal/ports"
	"github.com/Subyard/Subyard/internal/state"
	"github.com/Subyard/Subyard/internal/testkit"
	"golang.org/x/crypto/ssh"
)

type enrollmentProjectData struct {
	request []byte
	reread  []byte
	route   []byte
	known   []byte
	removed bool
	reads   int
}

func (data *enrollmentProjectData) Execute(
	_ context.Context,
	_ domain.Context,
	request ports.InstanceExecRequest,
) (ports.InstanceExecResult, error) {
	if len(request.Command) < 5 {
		return ports.InstanceExecResult{}, errors.New("unexpected project command")
	}
	script := request.Command[3]
	switch {
	case strings.Contains(script, "cat -- \"$target\""):
		data.reads++
		if !strings.HasSuffix(
			request.Command[len(request.Command)-1],
			"/temp/agent-e2e/default/agent-access.pub",
		) {
			return ports.InstanceExecResult{}, errors.New("unbounded enrollment path")
		}
		payload := data.request
		if data.reads > 1 && data.reread != nil {
			payload = data.reread
		}
		return ports.InstanceExecResult{Stdout: append([]byte(nil), payload...)}, nil
	case strings.Contains(script, "base64 -d"):
		var err error
		data.route, err = base64.StdEncoding.DecodeString(request.Command[len(request.Command)-2])
		if err != nil {
			return ports.InstanceExecResult{}, err
		}
		data.known, err = base64.StdEncoding.DecodeString(request.Command[len(request.Command)-1])
		return ports.InstanceExecResult{}, err
	case strings.Contains(script, "rm -f --"):
		data.removed = true
		return ports.InstanceExecResult{}, nil
	default:
		return ports.InstanceExecResult{}, errors.New("unexpected project command")
	}
}

func (data *enrollmentProjectData) Stream(
	ctx context.Context,
	yard domain.Context,
	request ports.InstanceExecRequest,
	_ io.Reader,
) (ports.InstanceExecResult, error) {
	return data.Execute(ctx, yard, request)
}

func TestTestVMsUsesTypedWorkerInvocation(t *testing.T) {
	root, environment, _ := nativeFixture(t)
	environment = append(environment, "NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=test-vms-up")
	incus := lifecycleIncus()
	instance := incus.Instances["subyard/yard"]
	instance.Status = "Running"
	incus.Instances["subyard/yard"] = instance
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "test-vms-up", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"test-vms", "up"},
		Environment: environment, WorkingDir: root, Incus: incus, AdapterRunner: runner,
		Prompt: prompt, Clock: testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("test-vms failed with %d", code)
	}
	if len(runner.Requests) != 1 || runner.Requests[0].Adapter != "test-vms" ||
		runner.Requests[0].Action != "up" ||
		!slices.Equal(runner.Requests[0].Arguments, []string{"up", "--yes"}) {
		t.Fatalf("requests=%#v", runner.Requests)
	}
}

func TestTestVMStatusIsReadOnly(t *testing.T) {
	loaded := config.Loaded{Context: domain.Context{
		NestedE2EVMs: true, InstanceType: domain.InstanceContainer,
	}}
	program := &CLI{}
	execution, err := program.prepareTestVMExecution(
		context.Background(), loaded, []string{"status"},
	)
	if err != nil {
		t.Fatal(err)
	}
	policy := execution.policy(testDefinition("test-vms"), loaded.Context)
	if policy.Effect != domain.CommandRead {
		t.Fatalf("policy=%#v", policy)
	}
}

func TestTestVMEnrollmentBridgesRegisteredProjectAndStableHostState(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	record := domain.ProjectRecord{
		Schema: 1, ProjectID: "subyard-12345678", Name: "Subyard",
		HostPath: "/host/Subyard", YardPath: "/srv/workspaces/subyard-12345678/src",
		Mode: domain.ProjectGit, Target: "yard", SSHHost: "yard",
	}
	if err := store.Put(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	key := testEnrollmentPublicKey(t)
	projectData := &enrollmentProjectData{request: []byte(key + " developer-controller\n")}
	incus := lifecycleIncus()
	instance := incus.Instances["subyard/yard"]
	instance.Status = "Running"
	incus.Instances["subyard/yard"] = instance
	var applied []string
	apply := func(
		_ context.Context,
		_ config.Loaded,
		directory string,
		_ io.Writer,
	) error {
		applied = append(applied, directory)
		if err := os.WriteFile(filepath.Join(directory, "route.tsv"), []byte(
			"subyard-e2e-route-v1\nhostname\t10.0.0.2\nport\t22\nhost_key_alias\tsubyard-e2e-bastion\n",
		), 0o644); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(directory, "known_hosts"),
			[]byte("subyard-e2e-bastion "+key+"\n"), 0o644)
	}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	var stdout, stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{"test-vms", "enroll", "--project", "Subyard"},
		Environment: append(environment,
			"NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=enrollment-test",
		),
		WorkingDir: root, Incus: incus, ProjectData: projectData,
		TestVMEnrollmentApply: apply, Prompt: prompt,
		Clock:  testkit.NewManualClock(time.Unix(100, 0)),
		Stdout: &stdout, Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("enroll failed: code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if projectData.reads != 2 || len(projectData.route) == 0 ||
		!strings.Contains(string(projectData.known), "subyard-e2e-bastion ssh-ed25519 ") {
		t.Fatalf("project bridge = %#v", projectData)
	}
	if len(applied) != 1 || strings.Contains(applied[0], root+"/temp/") {
		t.Fatalf("apply directories = %v", applied)
	}
	managed, active, fingerprint, err := testvmsruntime.CurrentEnrollment(applied[0])
	if err != nil {
		t.Fatal(err)
	}
	if !managed || active != key || fingerprint == "" {
		t.Fatalf("persistent enrollment = managed:%v key:%q fingerprint:%q",
			managed, active, fingerprint)
	}
	if len(prompt.Seen) != 1 {
		t.Fatalf("prompt count = %d", len(prompt.Seen))
	}
}

func TestTestVMEnrollmentReconciliationFailureRestoresPreviousController(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), domain.ProjectRecord{
		Schema: 1, ProjectID: "subyard-12345678", Name: "Subyard",
		HostPath: "/host/Subyard", YardPath: "/srv/workspaces/subyard-12345678/src",
		Mode: domain.ProjectGit, Target: "yard", SSHHost: "yard",
	}); err != nil {
		t.Fatal(err)
	}
	oldKey := testEnrollmentPublicKey(t)
	newKey := testEnrollmentPublicKey(t)
	directory, err := testvmsruntime.EnrollmentDirectory(filepath.Join(root, "data"), "default")
	if err != nil {
		t.Fatal(err)
	}
	if err := testvmsruntime.SetEnrollment(directory, oldKey); err != nil {
		t.Fatal(err)
	}
	projectData := &enrollmentProjectData{request: []byte(newKey + "\n")}
	incus := lifecycleIncus()
	instance := incus.Instances["subyard/yard"]
	instance.Status = "Running"
	incus.Instances["subyard/yard"] = instance
	var applied []string
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{"test-vms", "enroll", "--project", "Subyard"},
		Environment: append(environment,
			"NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=enrollment-rollback-test",
		),
		WorkingDir: root, Incus: incus, ProjectData: projectData,
		TestVMEnrollmentApply: func(
			_ context.Context,
			_ config.Loaded,
			current string,
			_ io.Writer,
		) error {
			applied = append(applied, current)
			if len(applied) == 1 {
				return errors.New("fixture reconciliation failure")
			}
			return nil
		},
		Prompt: &testkit.Prompt{Answers: []bool{true}},
		Clock:  testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 {
		t.Fatalf("failed enrollment code = %d", code)
	}
	if len(applied) != 2 || applied[0] != directory || applied[1] != directory {
		t.Fatalf("reconcile/rollback calls = %v", applied)
	}
	managed, active, _, err := testvmsruntime.CurrentEnrollment(directory)
	if err != nil {
		t.Fatal(err)
	}
	if !managed || active != oldKey || len(projectData.route) != 0 {
		t.Fatalf("rollback state = managed:%v key:%q project:%#v",
			managed, active, projectData)
	}
}

func TestTestVMEnrollmentDeclineDoesNotCreatePersistentState(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), domain.ProjectRecord{
		Schema: 1, ProjectID: "subyard-12345678", Name: "Subyard",
		HostPath: "/host/Subyard", YardPath: "/srv/workspaces/subyard-12345678/src",
		Mode: domain.ProjectGit, Target: "yard", SSHHost: "yard",
	}); err != nil {
		t.Fatal(err)
	}
	projectData := &enrollmentProjectData{
		request: []byte(testEnrollmentPublicKey(t) + "\n"),
	}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{"test-vms", "enroll", "--project", "Subyard"},
		Environment: append(environment,
			"NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=enrollment-decline-test",
		),
		WorkingDir: root, Incus: lifecycleIncus(), ProjectData: projectData,
		TestVMEnrollmentApply: func(
			context.Context, config.Loaded, string, io.Writer,
		) error {
			t.Fatal("declined enrollment mutated backend")
			return nil
		},
		Prompt: &testkit.Prompt{Answers: []bool{false}},
		Clock:  testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 {
		t.Fatalf("declined enrollment code = %d", code)
	}
	directory, err := testvmsruntime.EnrollmentDirectory(filepath.Join(root, "data"), "default")
	if err != nil {
		t.Fatal(err)
	}
	if managed, _, _, err := testvmsruntime.CurrentEnrollment(directory); err != nil || managed {
		t.Fatalf("declined enrollment persisted state: managed=%v err=%v", managed, err)
	}
}

func TestTestVMEnrollmentRejectsProjectRequestDriftAfterPreview(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), domain.ProjectRecord{
		Schema: 1, ProjectID: "subyard-12345678", Name: "Subyard",
		HostPath: "/host/Subyard", YardPath: "/srv/workspaces/subyard-12345678/src",
		Mode: domain.ProjectGit, Target: "yard", SSHHost: "yard",
	}); err != nil {
		t.Fatal(err)
	}
	projectData := &enrollmentProjectData{
		request: []byte(testEnrollmentPublicKey(t) + "\n"),
		reread:  []byte(testEnrollmentPublicKey(t) + "\n"),
	}
	incus := lifecycleIncus()
	instance := incus.Instances["subyard/yard"]
	instance.Status = "Running"
	incus.Instances["subyard/yard"] = instance
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{"test-vms", "enroll", "--project", "Subyard"},
		Environment: append(environment,
			"NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=enrollment-stale-test",
		),
		WorkingDir: root, Incus: incus, ProjectData: projectData,
		TestVMEnrollmentApply: func(
			context.Context, config.Loaded, string, io.Writer,
		) error {
			t.Fatal("stale enrollment request mutated backend")
			return nil
		},
		Prompt: &testkit.Prompt{Answers: []bool{true}},
		Clock:  testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 1 {
		t.Fatalf("stale enrollment code = %d", code)
	}
	directory, err := testvmsruntime.EnrollmentDirectory(filepath.Join(root, "data"), "default")
	if err != nil {
		t.Fatal(err)
	}
	if managed, _, _, err := testvmsruntime.CurrentEnrollment(directory); err != nil || managed {
		t.Fatalf("stale enrollment persisted state: managed=%v err=%v", managed, err)
	}
}

func TestProjectEnrollmentReaderRejectsSymlinksAndHardLinks(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "temp", "agent-e2e", "test-yard")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(directory, "agent-access.pub")
	if err := os.WriteFile(target, []byte(testEnrollmentPublicKey(t)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run := func(path string) error {
		command := exec.Command(
			"sh", "-eu", "-c", readProjectEnrollmentScript,
			"subyard-read-enrollment-test", root, path,
		)
		return command.Run()
	}
	if err := run(target); err != nil {
		t.Fatalf("regular enrollment rejected: %v", err)
	}
	link := filepath.Join(directory, "link.pub")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := run(link); err == nil {
		t.Fatal("symlink enrollment was accepted")
	}
	hard := filepath.Join(directory, "hard.pub")
	if err := os.Link(target, hard); err != nil {
		t.Fatal(err)
	}
	if err := run(target); err == nil {
		t.Fatal("hard-linked enrollment was accepted")
	}
}

func TestProjectEnrollmentPublisherRejectsSymlinkAncestorBeforeMutation(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "temp")); err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(root, "temp", "agent-e2e", "test-yard")
	command := exec.Command(
		"sh", "-eu", "-c", publishProjectEnrollmentScript,
		"subyard-publish-enrollment-test", root, directory,
		base64.StdEncoding.EncodeToString([]byte("route\n")),
		base64.StdEncoding.EncodeToString([]byte("known\n")),
	)
	if err := command.Run(); err == nil {
		t.Fatal("symlinked publish ancestor was accepted")
	}
	if _, err := os.Lstat(filepath.Join(outside, "agent-e2e")); !os.IsNotExist(err) {
		t.Fatalf("publisher mutated outside the project root: %v", err)
	}
}

func TestTestVMEnrollmentRejectsMalformedProjectRequestBeforePrompt(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	store, err := state.NewFileStore(stateDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), domain.ProjectRecord{
		Schema: 1, ProjectID: "subyard-12345678", Name: "Subyard",
		HostPath: "/host/Subyard", YardPath: "/srv/workspaces/subyard-12345678/src",
		Mode: domain.ProjectGit, Target: "yard", SSHHost: "yard",
	}); err != nil {
		t.Fatal(err)
	}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard",
		Arguments: []string{"test-vms", "enroll", "--project", "Subyard"},
		Environment: append(environment,
			"NESTED_E2E_VMS=1", "SUBYARD_OPERATION_ID=enrollment-malformed-test",
		),
		WorkingDir: root, ProjectData: &enrollmentProjectData{request: []byte("not-a-key\n")},
		Prompt: prompt, Clock: testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 2 {
		t.Fatalf("malformed enrollment code = %d", code)
	}
	if len(prompt.Seen) != 0 {
		t.Fatal("malformed enrollment reached confirmation")
	}
}

func testEnrollmentPublicKey(t *testing.T) string {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ssh.NewPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))
}

func TestTeardownRejectsUnknownInputAndPublishesMode(t *testing.T) {
	if _, err := prepareTeardownExecution([]string{"keepdata"}); err == nil {
		t.Fatal("unsafe teardown argument was accepted")
	}
	root, environment, _ := nativeFixture(t)
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "teardown-test", Status: "ok",
	}}}}
	prompt := &testkit.Prompt{Answers: []bool{true}}
	var stderr bytes.Buffer
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"teardown", "--keep-data"},
		Environment: append(environment, "SUBYARD_OPERATION_ID=teardown-test"), WorkingDir: root,
		AdapterRunner: runner, Prompt: prompt, Clock: testkit.NewManualClock(time.Unix(100, 0)),
		Stderr: &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("teardown failed: code=%d stderr=%q", code, stderr.String())
	}
	if len(runner.Requests) != 1 || runner.Requests[0].Adapter != "teardown" ||
		runner.Requests[0].Context["SUBYARD_TEARDOWN_KEEP_DATA"] != "1" ||
		runner.Requests[0].Context["SUBYARD_TEARDOWN_KEEP_SHARED"] != "0" {
		t.Fatalf("requests=%#v", runner.Requests)
	}
}

func TestTeardownKeepsSharedIncusForAnotherRegisteredLocalYard(t *testing.T) {
	root, environment, stateDirectory := nativeFixture(t)
	yardDirectory := filepath.Join(filepath.Dir(stateDirectory), "yards", "other")
	if err := os.MkdirAll(yardDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	writeCLIFile(t, filepath.Join(yardDirectory, "config.env"), "SSH_PORT=2223\n", 0o600)
	runner := &testkit.ScriptedAdapter{Steps: []testkit.AdapterStep{{Result: domain.AdapterResult{
		Schema: 1, OperationID: "teardown-shared-test", Status: "ok",
	}}}}
	program, err := New(Options{
		RepositoryRoot: root, Program: "yard", Arguments: []string{"teardown", "--yes"},
		Environment: append(environment, "SUBYARD_OPERATION_ID=teardown-shared-test"), WorkingDir: root,
		AdapterRunner: runner, Prompt: &testkit.Prompt{},
		Clock: testkit.NewManualClock(time.Unix(100, 0)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if code := program.Run(context.Background()); code != 0 {
		t.Fatalf("teardown failed with %d", code)
	}
	if len(runner.Requests) != 1 ||
		runner.Requests[0].Context["SUBYARD_TEARDOWN_KEEP_SHARED"] != "1" {
		t.Fatalf("shared Incus lifecycle was not preserved: %#v", runner.Requests)
	}
}

func testDefinition(name string) command.Definition {
	return command.Definition{Name: name, Effect: command.EffectMutate, Remote: command.RemoteForward}
}
