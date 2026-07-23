package hostruntime

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type NetworkGuard struct {
	Lookup func(string) (string, bool)
	Run    func(context.Context, string, ...string) ([]byte, error)
}

func (guard NetworkGuard) Check(ctx context.Context, bridges []string) error {
	if len(bridges) == 0 {
		return errors.New("host network guard needs at least one managed bridge")
	}
	for _, bridge := range bridges {
		if !safeInterfaceName(bridge) {
			return fmt.Errorf("unsafe managed bridge %q", bridge)
		}
	}
	active, err := guard.networkManagerActive(ctx)
	if err != nil {
		return err
	}
	if active {
		binary, ok := guard.lookup("NetworkManager")
		if !ok {
			return errors.New("NetworkManager is active but its binary is unavailable")
		}
		output, err := guard.run(ctx, binary, "--print-config")
		if err != nil {
			return fmt.Errorf("read NetworkManager effective configuration: %w", err)
		}
		if err := validateNetworkManagerConfig(string(output), bridges); err != nil {
			return err
		}
	}
	return guard.routesSafe(ctx, bridges)
}

func (guard NetworkGuard) networkManagerActive(ctx context.Context) (bool, error) {
	systemctl, systemctlOK := guard.lookup("systemctl")
	_, networkManagerOK := guard.lookup("NetworkManager")
	if !systemctlOK {
		if networkManagerOK {
			return false, errors.New("cannot inspect NetworkManager service state")
		}
		return false, nil
	}
	output, _ := guard.run(ctx, systemctl, "is-active", "NetworkManager")
	switch strings.TrimSpace(string(output)) {
	case "active", "activating", "reloading", "deactivating":
		return true, nil
	case "inactive", "failed", "unknown":
		return false, nil
	default:
		return false, errors.New("cannot inspect NetworkManager service state")
	}
}

func (guard NetworkGuard) routesSafe(ctx context.Context, bridges []string) error {
	ip, ok := guard.lookup("ip")
	if !ok {
		return errors.New("ip is required for the host route guard")
	}
	output, err := guard.run(ctx, ip, "-j", "-4", "route", "show", "default")
	if err != nil {
		return fmt.Errorf("inspect host IPv4 default routes: %w", err)
	}
	var routes []struct {
		Device string `json:"dev"`
	}
	if err := json.Unmarshal(output, &routes); err != nil {
		return fmt.Errorf("parse host IPv4 default routes: %w", err)
	}
	for _, route := range routes {
		if route.Device == "" {
			continue
		}
		if unsafeDeviceName(route.Device, bridges) {
			return fmt.Errorf("unsafe host default route uses %q", route.Device)
		}
		link, err := guard.run(ctx, ip, "-j", "-d", "link", "show", "dev", route.Device)
		if err != nil {
			return fmt.Errorf("inspect route device %q: %w", route.Device, err)
		}
		var links []struct {
			LinkInfo struct {
				Kind string `json:"info_kind"`
			} `json:"linkinfo"`
		}
		if err := json.Unmarshal(link, &links); err != nil {
			return fmt.Errorf("parse route device %q: %w", route.Device, err)
		}
		if len(links) != 0 && links[0].LinkInfo.Kind == "veth" {
			return fmt.Errorf("unsafe host default route uses veth %q", route.Device)
		}
	}
	return nil
}

func (guard NetworkGuard) lookup(name string) (string, bool) {
	if guard.Lookup != nil {
		return guard.Lookup(name)
	}
	candidates := map[string][]string{
		"systemctl":      {"/usr/bin/systemctl", "/bin/systemctl"},
		"NetworkManager": {"/usr/sbin/NetworkManager", "/usr/bin/NetworkManager", "/sbin/NetworkManager"},
		"ip":             {"/usr/sbin/ip", "/usr/bin/ip", "/sbin/ip", "/bin/ip"},
	}
	for _, candidate := range candidates[name] {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return candidate, true
		}
	}
	return "", false
}

func (guard NetworkGuard) run(ctx context.Context, name string, arguments ...string) ([]byte, error) {
	if guard.Run != nil {
		return guard.Run(ctx, name, arguments...)
	}
	return exec.CommandContext(ctx, name, arguments...).CombinedOutput()
}

func validateNetworkManagerConfig(contents string, bridges []string) error {
	values := make(map[string]string)
	scanner := bufio.NewScanner(strings.NewReader(contents))
	managed := false
	for scanner.Scan() {
		name, value, found := strings.Cut(scanner.Text(), "=")
		if !found {
			continue
		}
		name = strings.TrimSpace(name)
		value = strings.TrimSpace(value)
		values[name] = value
		if name == "managed" && value == "0" {
			managed = true
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	unmanaged := semicolonSet(values["unmanaged-devices"])
	noAuto := semicolonSet(values["no-auto-default"])
	for _, value := range []string{"type:veth", "driver:veth"} {
		if !unmanaged[value] {
			return fmt.Errorf("NetworkManager unmanaged-devices lacks %s", value)
		}
	}
	if !noAuto["type:veth"] {
		return errors.New("NetworkManager no-auto-default lacks type:veth")
	}
	for _, bridge := range bridges {
		value := "interface-name:" + bridge
		if !unmanaged[value] {
			return fmt.Errorf("NetworkManager unmanaged-devices lacks bridge %s", bridge)
		}
		if !noAuto[value] {
			return fmt.Errorf("NetworkManager no-auto-default lacks bridge %s", bridge)
		}
	}
	if !managed {
		return errors.New("NetworkManager effective config lacks managed=0")
	}
	return nil
}

func semicolonSet(value string) map[string]bool {
	result := make(map[string]bool)
	for _, part := range strings.Split(value, ";") {
		if part = strings.TrimSpace(part); part != "" {
			result[part] = true
		}
	}
	return result
}

func safeInterfaceName(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || strings.ContainsRune("._:-", character) {
			continue
		}
		return false
	}
	return true
}

func unsafeDeviceName(device string, bridges []string) bool {
	for _, bridge := range bridges {
		if device == bridge {
			return true
		}
	}
	for _, prefix := range []string{"veth", "tap", "macvtap", "vnet", "docker", "br-", "virbr"} {
		if strings.HasPrefix(device, prefix) {
			return true
		}
	}
	return false
}
