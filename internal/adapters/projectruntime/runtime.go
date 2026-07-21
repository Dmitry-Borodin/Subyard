package projectruntime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
)

const metadataCommand = `for f in /srv/workspaces/*/.subyard-meta.json; do [ -e "$f" ] || continue; cat "$f"; printf "\n"; done`

type Runtime struct {
	Incus     ports.Incus
	Executor  ports.InstanceExecutor
	SSHBinary string
}

func (runtime Runtime) Observe(
	ctx context.Context,
	yard domain.Context,
	records []domain.ProjectRecord,
	live bool,
) (domain.ProjectObservation, error) {
	result := domain.ProjectObservation{
		Presence: make(map[string]domain.ProjectPresence, len(records)),
		Boxes:    make(map[string]domain.ProjectBoxState, len(records)),
	}
	for _, record := range records {
		result.Presence[record.ProjectID] = domain.ProjectPresenceUnknown
		if record.Target == "" || record.Target == "yard" {
			result.Boxes[record.ProjectID] = "-"
		} else {
			result.Boxes[record.ProjectID] = domain.ProjectBoxUnknown
		}
	}

	if yard.YardType == domain.YardRemote {
		if live {
			payload, err := runtime.readSSH(ctx, yard.SSHHost)
			if err == nil {
				result.Reached = true
				result.Live, result.Warnings = parseMetadata(payload)
				markLive(&result)
			}
		}
		return result, nil
	}

	if runtime.Incus != nil {
		instance, err := runtime.Incus.Instance(ctx, yard.IncusProject, yard.InstanceName)
		if err == nil && strings.EqualFold(instance.Status, "running") {
			result.Running = true
		}
	}
	if result.Running && runtime.Executor != nil {
		observeProjects(ctx, runtime.Executor, yard, records, &result)
	}
	if live {
		// Preserve the existing fast path: an SSH alias proves the same data-plane view as Incus
		// and is also the only valid path for a remote yard.
		payload, err := runtime.readSSH(ctx, yard.SSHHost)
		if err != nil && result.Running && runtime.Executor != nil {
			payload, err = execBytes(ctx, runtime.Executor, yard, []string{"sh", "-c", metadataCommand}, nil)
		}
		if err == nil {
			result.Reached = true
			result.Live, result.Warnings = parseMetadata(payload)
			markLive(&result)
		}
	}
	return result, nil
}

func observeProjects(
	ctx context.Context,
	executor ports.InstanceExecutor,
	yard domain.Context,
	records []domain.ProjectRecord,
	result *domain.ProjectObservation,
) {
	var input bytes.Buffer
	for _, record := range records {
		fmt.Fprintf(&input, "%s\t%s\n", record.ProjectID, record.YardPath)
	}
	payload, err := execBytes(ctx, executor, yard, []string{"sh", "-c", `while IFS='\t' read -r id path; do [ -n "$id" ] || continue; if [ -d "$path" ]; then printf '%s\tpresent\n' "$id"; else printf '%s\tmissing\n' "$id"; fi; done`}, input.Bytes())
	if err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(payload)), "\n") {
			id, value, ok := strings.Cut(line, "\t")
			if ok && (value == "present" || value == "missing") {
				result.Presence[id] = domain.ProjectPresence(value)
			}
		}
	}
	payload, err = execBytes(ctx, executor, yard, []string{"docker", "ps", "-a", "--filter", "label=subyard.env=1", "--format", `{{index .Labels "subyard.project"}}\t{{.State}}`}, nil)
	if err == nil {
		seen := make(map[string]bool)
		for _, line := range strings.Split(strings.TrimSpace(string(payload)), "\n") {
			id, value, ok := strings.Cut(line, "\t")
			if !ok || id == "" {
				continue
			}
			seen[id] = true
			if value == "running" {
				result.Boxes[id] = domain.ProjectBoxUp
			} else {
				result.Boxes[id] = domain.ProjectBoxDown
			}
		}
		for _, record := range records {
			if record.Target != "" && record.Target != "yard" && !seen[record.ProjectID] {
				result.Boxes[record.ProjectID] = domain.ProjectBoxNone
			}
		}
	}
}

func execBytes(
	ctx context.Context,
	executor ports.InstanceExecutor,
	yard domain.Context,
	command []string,
	stdin []byte,
) ([]byte, error) {
	result, err := executor.Exec(ctx, yard.IncusProject, yard.InstanceName, ports.InstanceExecRequest{
		Command: command, Stdin: stdin,
	})
	return result.Stdout, err
}

func (runtime Runtime) readSSH(ctx context.Context, host string) ([]byte, error) {
	binary := runtime.SSHBinary
	if binary == "" {
		binary = "ssh"
	}
	command := exec.CommandContext(ctx, binary,
		"-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, metadataCommand)
	return command.Output()
}

func parseMetadata(payload []byte) ([]domain.ProjectRecord, []string) {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	var records []domain.ProjectRecord
	var warnings []string
	for {
		var wire struct {
			Schema    int                `json:"schema"`
			ProjectID string             `json:"projectId"`
			Name      string             `json:"name"`
			Mode      domain.ProjectMode `json:"mode"`
			Target    string             `json:"target"`
		}
		if err := decoder.Decode(&wire); err != nil {
			if !errors.Is(err, io.EOF) {
				warnings = append(warnings, "ignored invalid yard project metadata")
			}
			break
		}
		record := domain.ProjectRecord{
			Schema: 1, ProjectID: wire.ProjectID, Name: wire.Name, Mode: wire.Mode,
			YardPath: "/srv/workspaces/" + wire.ProjectID + "/src", SSHHost: "yard", Target: wire.Target,
		}
		if wire.Schema != 1 || record.Validate(record.ProjectID) != nil {
			warnings = append(warnings, "ignored invalid yard project metadata")
			continue
		}
		records = append(records, record)
	}
	return records, warnings
}

func markLive(result *domain.ProjectObservation) {
	for id := range result.Presence {
		result.Presence[id] = domain.ProjectMissing
	}
	for _, record := range result.Live {
		result.Presence[record.ProjectID] = domain.ProjectPresent
	}
}
