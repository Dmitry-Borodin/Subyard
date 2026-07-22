package domain

import "testing"

func TestContextRejectsUnsafeBoundaries(t *testing.T) {
	valid := Context{
		YardName: "default", YardType: YardLocal, InstanceType: InstanceContainer,
		InstanceName: "yard", IncusProject: "subyard", SSHHost: "yard", DevUser: "dev",
		SSHPort: 2222, ShiftMode: "shift", DevUID: 1000,
		Paths: RuntimePaths{
			RepositoryRoot: "/repo", ConfigDir: "/repo/config", OperatorHome: "/home/dev",
			ConfigHome: "/home/dev/.config/subyard", DataHome: "/home/dev/.subyard",
			StoragePath: "/home/dev/.subyard/incus", HostBase: "/srv/subyard", StateDir: "/state",
		},
	}
	if _, err := NormalizeContext(valid); err != nil {
		t.Fatal(err)
	}
	tests := map[string]Context{
		"nested VM yard": func() Context {
			value := valid
			value.InstanceType, value.NestedE2EVMs = InstanceVM, true
			return value
		}(),
		"broad host base": func() Context { value := valid; value.Paths.HostBase = "/"; return value }(),
		"invalid port":    func() Context { value := valid; value.SSHPort = 70000; return value }(),
	}
	for name, value := range tests {
		if _, err := NormalizeContext(value); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
}
