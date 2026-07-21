package domain

type ProjectPresence string

const (
	ProjectPresenceUnknown ProjectPresence = "?"
	ProjectPresent         ProjectPresence = "present"
	ProjectMissing         ProjectPresence = "missing"
)

type ProjectBoxState string

const (
	ProjectBoxUnknown ProjectBoxState = "?"
	ProjectBoxNone    ProjectBoxState = "none"
	ProjectBoxUp      ProjectBoxState = "up"
	ProjectBoxDown    ProjectBoxState = "down"
)

type ProjectObservation struct {
	Reached  bool                       `json:"reached"`
	Running  bool                       `json:"running"`
	Live     []ProjectRecord            `json:"live,omitempty"`
	Presence map[string]ProjectPresence `json:"presence"`
	Boxes    map[string]ProjectBoxState `json:"boxes"`
	Warnings []string                   `json:"warnings,omitempty"`
}
