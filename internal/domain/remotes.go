package domain

import "time"

type RemoteAction string

const (
	RemoteAdd       RemoteAction = "add"
	RemoteRepairKey RemoteAction = "repair-key"
	RemoteRemove    RemoteAction = "remove"
	RemoteList      RemoteAction = "list"
)

type RemoteSpec struct {
	Name        string `json:"name"`
	Destination string `json:"destination"`
	OwnerYard   string `json:"ownerYard,omitempty"`
}

type RemoteInfo struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Version  string `json:"version"`
	Instance string `json:"instance"`
	Project  string `json:"project"`
	State    string `json:"state"`
	SSHHost  string `json:"sshHost"`
	SSHPort  int    `json:"sshPort"`
	DevUser  string `json:"devUser"`
	Projects *int   `json:"projects"`
}

type RemoteKey struct {
	Material    string `json:"material"`
	Fingerprint string `json:"fingerprint"`
}

type RemoteRecord struct {
	Spec      RemoteSpec `json:"spec"`
	Remote    bool       `json:"remote"`
	Path      string     `json:"path,omitempty"`
	SSHPort   int        `json:"sshPort"`
	LastProbe time.Time  `json:"lastProbe,omitempty"`
}

type RemotePrepared struct {
	Action   RemoteAction   `json:"action"`
	Spec     RemoteSpec     `json:"spec"`
	Existing *RemoteRecord  `json:"existing,omitempty"`
	Owner    RemoteInfo     `json:"owner,omitempty"`
	Recorded []RemoteKey    `json:"recorded,omitempty"`
	Scanned  []RemoteKey    `json:"scanned,omitempty"`
	Records  []RemoteRecord `json:"records,omitempty"`
}

type RemoteResult struct {
	Message string         `json:"message,omitempty"`
	Records []RemoteRecord `json:"records,omitempty"`
}

func RemoteKeysOverlap(left, right []RemoteKey) bool {
	for _, first := range left {
		for _, second := range right {
			if first.Material == second.Material {
				return true
			}
		}
	}
	return false
}
