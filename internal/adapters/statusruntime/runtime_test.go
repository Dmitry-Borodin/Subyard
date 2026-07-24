package statusruntime

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/resource"
	"github.com/Dmitry-Borodin/Subyard/internal/testkit"
)

type securityStub struct{ state string }

func (stub securityStub) CheckSecurity(context.Context, bool, bool) (string, error) {
	return stub.state, nil
}

func TestRuntimeMeasuresAndCachesSpaceNatively(t *testing.T) {
	root := t.TempDir()
	now := time.Unix(1_700_000_000, 0)
	incus := &testkit.Incus{ExecSteps: []testkit.IncusExecStep{{
		Result: ports.InstanceExecResult{Stdout: []byte("1.5G\n")},
	}}}
	yard := domain.Context{
		YardName: "demo", IncusProject: "subyard-demo", InstanceName: "yard-demo",
		Paths: domain.RuntimePaths{DataHome: root},
	}
	facts, err := (Runtime{
		Environment: map[string]string{}, Security: securityStub{state: "live"},
		Executor: incus, Now: func() time.Time { return now },
	}).ReadStatusFacts(context.Background(), yard, true)
	if err != nil || len(facts.Shared) != 0 || facts.Security != "live" ||
		facts.Space != "1.5G  (in-yard rootfs, 0s ago)" {
		t.Fatalf("structured status result changed: %#v err=%v", facts, err)
	}
	if len(incus.ExecCalls) != 1 || incus.ExecCalls[0].Project != yard.IncusProject ||
		incus.ExecCalls[0].Name != yard.InstanceName {
		t.Fatalf("typed space probe was not used: %#v", incus.ExecCalls)
	}
	cache := filepath.Join(root, "space-demo.cache")
	if payload, err := os.ReadFile(cache); err != nil || string(payload) != "1.5G 1700000000\n" {
		t.Fatalf("space cache = %q err=%v", payload, err)
	}
	facts, err = (Runtime{
		Environment: map[string]string{}, Executor: incus,
		Now: func() time.Time { return now.Add(time.Second) },
	}).ReadStatusFacts(context.Background(), yard, true)
	if err != nil || facts.Space != "1.5G  (in-yard rootfs, 1s ago)" ||
		len(incus.ExecCalls) != 1 {
		t.Fatalf("fresh native cache was not reused: %#v err=%v", facts, err)
	}
	facts, err = (Runtime{}).ReadStatusFacts(context.Background(), yard, false)
	if err != nil || facts.Space != "—  (yard stopped; on-host size: sudo du -sh "+root+")" {
		t.Fatalf("stopped status = %#v err=%v", facts, err)
	}
	if got := spaceCachePath(root, "default"); got != filepath.Join(root, "space-default.cache") {
		t.Fatalf("default yard cache path = %q", got)
	}
}

func TestRuntimeKeepsStaleSpaceWhenRefreshFails(t *testing.T) {
	root := t.TempDir()
	measured := time.Unix(1_700_000_000, 0)
	if err := writeSpaceCache(filepath.Join(root, "space-demo.cache"), "2G", measured); err != nil {
		t.Fatal(err)
	}
	incus := &testkit.Incus{ExecSteps: []testkit.IncusExecStep{{
		Result: ports.InstanceExecResult{ExitCode: 1},
	}}}
	facts, err := (Runtime{
		Environment: map[string]string{"SPACE_TTL": "1"}, Executor: incus,
		Now: func() time.Time { return measured.Add(2 * time.Minute) },
	}).ReadStatusFacts(context.Background(), domain.Context{
		YardName: "demo", IncusProject: "subyard-demo", InstanceName: "yard-demo",
		Paths: domain.RuntimePaths{DataHome: root},
	}, true)
	if err != nil || facts.Space != "2G  (in-yard rootfs, 2m ago, refresh failed)" {
		t.Fatalf("stale status result = %#v err=%v", facts, err)
	}
}

func TestRuntimeProbesPreparedResources(t *testing.T) {
	root := t.TempDir()
	resources := filepath.Join(root, "config", "profiles", "demo", "resources")
	if err := os.MkdirAll(filepath.Join(resources, "service"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(resources, "service.res"), []byte(
		"COMMAND=svc\nHANDLER=resources/service/handler.sh\nTITLE=Service\nVERBS=up down\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := filepath.Join(resources, "service", "handler.sh")
	if err := os.WriteFile(handler, []byte("#!/bin/sh\n[ \"$1\" = is-up ]\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	registry, err := resource.Load(root)
	if err != nil {
		t.Fatal(err)
	}
	incus := &testkit.Incus{ExecSteps: []testkit.IncusExecStep{{
		Result: ports.InstanceExecResult{Stdout: []byte("1G\n")},
	}}}
	facts, err := (Runtime{
		Environment: map[string]string{"PATH": "/usr/bin:/bin"},
		Resources:   registry.Definitions(), Program: "yard", Security: securityStub{state: "live"},
		Executor: incus,
	}).ReadStatusFacts(context.Background(), domain.Context{
		IncusProject: "subyard", InstanceName: "yard",
		Paths: domain.RuntimePaths{DataHome: filepath.Join(root, "data")},
	}, true)
	if err != nil || len(facts.Shared) != 1 {
		t.Fatalf("resource status failed: %#v err=%v", facts, err)
	}
	status := facts.Shared[0]
	if status.Profile != "demo" || status.Name != "service" || status.State != "up" || status.Hint != "yard svc down" {
		t.Fatalf("unexpected resource status: %#v", status)
	}
}
