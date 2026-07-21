package statusruntime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"sort"

	"github.com/Dmitry-Borodin/Subyard/internal/domain"
)

type Runtime struct {
	RepositoryRoot string
	Environment    map[string]string
}

func (runtime Runtime) ReadStatusFacts(
	ctx context.Context,
	_ domain.Context,
	running bool,
) (domain.StatusFacts, error) {
	state := "stopped"
	if running {
		state = "running"
	}
	path := filepath.Join(runtime.RepositoryRoot, "scripts", "status-probe.sh")
	command := exec.CommandContext(ctx, path, state)
	command.Dir = runtime.RepositoryRoot
	command.Env = environment(runtime.Environment)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		return domain.StatusFacts{}, fmt.Errorf("status facts adapter: %w: %s", err, stderr.String())
	}
	decoder := json.NewDecoder(&stdout)
	var result domain.StatusFacts
	if err := decoder.Decode(&result); err != nil {
		return domain.StatusFacts{}, fmt.Errorf("decode status facts: %w", err)
	}
	return result, nil
}

func environment(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
}
