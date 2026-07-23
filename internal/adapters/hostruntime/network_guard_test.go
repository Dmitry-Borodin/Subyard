package hostruntime

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func testNetworkGuard(
	binaries map[string]bool,
	run func(string, ...string) ([]byte, error),
) NetworkGuard {
	return NetworkGuard{
		Lookup: func(name string) (string, bool) {
			if binaries[name] {
				return "/test/" + name, true
			}
			return "", false
		},
		Run: func(_ context.Context, name string, arguments ...string) ([]byte, error) {
			return run(strings.TrimPrefix(name, "/test/"), arguments...)
		},
	}
}

func TestNetworkGuardAcceptsSafeRoutesWithoutNetworkManager(t *testing.T) {
	guard := testNetworkGuard(map[string]bool{"systemctl": true, "ip": true},
		func(name string, arguments ...string) ([]byte, error) {
			switch fmt.Sprint(append([]string{name}, arguments...)) {
			case "[systemctl is-active NetworkManager]":
				return []byte("inactive\n"), errors.New("inactive")
			case "[ip -j -4 route show default]":
				return []byte(`[{"dev":"enp1s0"}]`), nil
			case "[ip -j -d link show dev enp1s0]":
				return []byte(`[{}]`), nil
			default:
				return nil, errors.New("unexpected command")
			}
		})
	if err := guard.Check(context.Background(), []string{"incusbr0"}); err != nil {
		t.Fatal(err)
	}
}

func TestNetworkGuardValidatesEffectiveNetworkManagerConfig(t *testing.T) {
	guard := testNetworkGuard(map[string]bool{"systemctl": true, "NetworkManager": true, "ip": true},
		func(name string, arguments ...string) ([]byte, error) {
			switch name {
			case "systemctl":
				return []byte("active\n"), nil
			case "NetworkManager":
				return []byte("unmanaged-devices=type:veth;driver:veth;interface-name:incusbr0\n" +
					"no-auto-default=type:veth;interface-name:incusbr0\nmanaged=0\n"), nil
			case "ip":
				if len(arguments) > 1 && arguments[1] == "-4" {
					return []byte(`[]`), nil
				}
			}
			return nil, errors.New("unexpected command")
		})
	if err := guard.Check(context.Background(), []string{"incusbr0"}); err != nil {
		t.Fatal(err)
	}
}

func TestNetworkGuardRejectsIncompleteNetworkManagerConfig(t *testing.T) {
	guard := testNetworkGuard(map[string]bool{"systemctl": true, "NetworkManager": true, "ip": true},
		func(name string, _ ...string) ([]byte, error) {
			if name == "systemctl" {
				return []byte("active\n"), nil
			}
			if name == "NetworkManager" {
				return []byte("unmanaged-devices=type:veth;driver:veth\n" +
					"no-auto-default=type:veth;interface-name:incusbr0\nmanaged=0\n"), nil
			}
			return []byte(`[]`), nil
		})
	err := guard.Check(context.Background(), []string{"incusbr0"})
	if err == nil || !strings.Contains(err.Error(), "lacks bridge") {
		t.Fatalf("expected missing bridge guard, got %v", err)
	}
}

func TestNetworkGuardRejectsUnsafeDefaultRoute(t *testing.T) {
	guard := testNetworkGuard(map[string]bool{"systemctl": true, "ip": true},
		func(name string, arguments ...string) ([]byte, error) {
			if name == "systemctl" {
				return []byte("inactive\n"), nil
			}
			if len(arguments) > 1 && arguments[1] == "-4" {
				return []byte(`[{"dev":"veth1234"}]`), nil
			}
			return []byte(`[{}]`), nil
		})
	err := guard.Check(context.Background(), []string{"incusbr0"})
	if err == nil || !strings.Contains(err.Error(), "unsafe host default route") {
		t.Fatalf("expected unsafe route error, got %v", err)
	}
}

func TestNetworkGuardFailsClosedWhenNetworkManagerStateIsUnknown(t *testing.T) {
	guard := testNetworkGuard(map[string]bool{"NetworkManager": true, "ip": true},
		func(string, ...string) ([]byte, error) { return nil, nil })
	err := guard.Check(context.Background(), []string{"incusbr0"})
	if err == nil || !strings.Contains(err.Error(), "cannot inspect NetworkManager") {
		t.Fatalf("expected NetworkManager state error, got %v", err)
	}
}

func TestNetworkGuardRejectsUnsafeBridgeName(t *testing.T) {
	guard := testNetworkGuard(nil, func(string, ...string) ([]byte, error) { return nil, nil })
	if err := guard.Check(context.Background(), []string{"incusbr0;reboot"}); err == nil {
		t.Fatal("unsafe bridge name accepted")
	}
}
