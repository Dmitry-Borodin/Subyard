package ports

import "testing"

func TestInstanceInfoEffectiveConfigPreservesPresenceAndIgnoresLocalProjection(t *testing.T) {
	instance := InstanceInfo{
		Config: map[string]string{
			"effective":        "profile-or-local",
			"empty":            "",
			"profile-fallback": "profile",
		},
		LocalConfig: map[string]string{
			"effective":        "stale-local-projection",
			"profile-fallback": "",
			"local-only":       "must-not-be-effective",
		},
	}
	if value, present := instance.EffectiveConfig("effective"); !present || value != "profile-or-local" {
		t.Fatalf("effective value=%q present=%v", value, present)
	}
	if value, present := instance.EffectiveConfig("empty"); !present || value != "" {
		t.Fatalf("present empty value=%q present=%v", value, present)
	}
	if value, present := instance.EffectiveConfig("profile-fallback"); !present || value != "profile" {
		t.Fatalf("profile fallback value=%q present=%v", value, present)
	}
	if value, present := instance.EffectiveConfig("local-only"); present || value != "" {
		t.Fatalf("local projection became effective: value=%q present=%v", value, present)
	}
	if value, present := instance.EffectiveConfig("absent"); present || value != "" {
		t.Fatalf("absent value=%q present=%v", value, present)
	}
}
