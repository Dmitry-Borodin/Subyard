package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/Subyard/Subyard/internal/config"
	"github.com/Subyard/Subyard/internal/configsync"
	"github.com/Subyard/Subyard/internal/domain"
)

const maxConfigGitDiagnosticBytes = 4096
const configGitFetchTimeout = 15 * time.Second

type configGitState struct {
	Checkout       string
	Head           string
	Branch         string
	Upstream       string
	UpstreamCommit string
	RemoteName     string
	RemoteURL      string
	RemoteRaw      string
	Worktree       string
	Staged         int
	Unstaged       int
	Untracked      int
	Conflicts      int
	Ahead          int
	Behind         int
	Relation       string
	FetchState     string
	LastFetch      string
	Problem        error
}

func (cli *CLI) runConfigSyncStatus(
	ctx context.Context,
	loaded config.Loaded,
	arguments []string,
) int {
	if loaded.Context.YardType == domain.YardRemote {
		forwarded := append([]string{"sync", "status"}, arguments...)
		return cli.forwardRemote(ctx, loaded.Context, "config", forwarded)
	}
	offline := false
	for _, argument := range arguments {
		switch argument {
		case "--offline":
			offline = true
		default:
			cli.errorf("config sync status: unknown option %q", argument)
			return 2
		}
	}
	syncStatus, statusErr := configsync.ReadStatus(
		loaded.Context.Paths.ConfigHome, cli.baseEnv,
	)
	if statusErr != nil {
		cli.errorf("config sync status: %v", statusErr)
		return 1
	}
	record, exists, recordErr := configsync.ReadSourceRecord(
		loaded.Context.Paths.ConfigHome,
	)
	fmt.Fprintln(cli.options.Stdout, "Versioned configuration sync status")
	fmt.Fprintln(cli.options.Stdout, "  automation: manual")
	fmt.Fprintf(cli.options.Stdout, "  owner-host: %s\n", syncStatus.HostID)
	if syncStatus.HostIDPending {
		fmt.Fprintln(cli.options.Stdout, "  owner-host-state: pending initialization")
	}
	if recordErr != nil {
		fmt.Fprintln(cli.options.Stdout, "  versioned: unknown")
		fmt.Fprintf(cli.options.Stdout, "  registration: broken (%s)\n",
			boundedConfigGitText(recordErr.Error()))
		fmt.Fprintf(cli.options.Stdout, "  next: repair %s\n",
			configsync.SourceRecordPath(loaded.Context.Paths.ConfigHome))
		return 1
	}
	if !exists {
		fmt.Fprintln(cli.options.Stdout, "  versioned: no")
		fmt.Fprintln(cli.options.Stdout, "  registration: not configured")
		fmt.Fprintf(cli.options.Stdout, "  next: %s config sync connect <git-url>\n",
			cli.options.Program)
		return 1
	}
	fmt.Fprintln(cli.options.Stdout, "  versioned: yes")
	fmt.Fprintln(cli.options.Stdout, "  registration: configured")
	fmt.Fprintf(cli.options.Stdout, "  checkout: %s\n", record.Checkout)

	gitState := cli.inspectConfigGit(ctx, record.Checkout, !offline)
	verifyConfigGitRegistration(record, &gitState)
	writeConfigGitState(cli.options.Stdout, gitState)

	recovery := "none"
	if syncStatus.RecoveryRequired {
		recovery = "required"
	}
	fmt.Fprintf(cli.options.Stdout, "  recovery: %s\n", recovery)
	applied := "none"
	if syncStatus.ManifestPresent {
		applied = syncStatus.SourceCommit
	}
	fmt.Fprintf(cli.options.Stdout, "  applied-commit: %s\n", applied)
	fmt.Fprintf(cli.options.Stdout, "  generation: %d\n", syncStatus.Generation)

	liveState := "blocked"
	var plan configsync.Plan
	var planErr error
	if !syncStatus.RecoveryRequired && gitState.Problem == nil &&
		gitState.Conflicts == 0 && gitState.Worktree == "clean" {
		plan, planErr = configsync.BuildPlan(configsync.Options{
			SourceRoot:     record.Checkout,
			ConfigHome:     loaded.Context.Paths.ConfigHome,
			RepositoryRoot: cli.options.RepositoryRoot,
			OperatorHome:   loaded.Context.Paths.OperatorHome,
			Environment:    cli.baseEnv,
			FileSettings:   config.SyncableFileMappings(loaded),
			YardInUse:      cli.configSyncYardInUse(loaded),
		})
		if planErr == nil {
			if plan.NeedsApply() {
				liveState = "changes-required"
			} else {
				liveState = "converged"
			}
		}
	}
	fmt.Fprintf(cli.options.Stdout, "  live: %s\n", liveState)
	if planErr != nil {
		fmt.Fprintf(cli.options.Stdout, "  live-detail: %s\n",
			redactConfigGitDiagnostic(planErr.Error(), gitState))
	}
	writeConfigSyncStatusNext(cli.options.Stdout, cli.options.Program, gitState, liveState)

	healthy := !syncStatus.RecoveryRequired && gitState.Problem == nil &&
		gitState.Worktree == "clean" && gitState.Relation == "up-to-date" &&
		liveState == "converged"
	if healthy {
		return 0
	}
	return 1
}

func (cli *CLI) runPendingConfigSyncStatus(
	ctx context.Context,
	configHome string,
	arguments []string,
) int {
	offline := false
	for _, argument := range arguments {
		switch argument {
		case "--offline":
			offline = true
		default:
			cli.errorf("config sync status: unknown option %q", argument)
			return 2
		}
	}
	status, err := configsync.ReadStatus(configHome, cli.baseEnv)
	if err != nil {
		cli.errorf("config sync status: %v", err)
		return 1
	}
	fmt.Fprintln(cli.options.Stdout, "Versioned configuration sync status")
	fmt.Fprintln(cli.options.Stdout, "  automation: manual")
	fmt.Fprintf(cli.options.Stdout, "  owner-host: %s\n", status.HostID)
	record, exists, err := configsync.ReadSourceRecord(configHome)
	if err != nil {
		fmt.Fprintln(cli.options.Stdout, "  versioned: unknown")
		fmt.Fprintf(cli.options.Stdout, "  registration: broken (%s)\n",
			boundedConfigGitText(err.Error()))
	} else if !exists {
		fmt.Fprintln(cli.options.Stdout, "  versioned: no")
		fmt.Fprintln(cli.options.Stdout, "  registration: not configured")
	} else {
		fmt.Fprintln(cli.options.Stdout, "  versioned: yes")
		fmt.Fprintln(cli.options.Stdout, "  registration: configured")
		fmt.Fprintf(cli.options.Stdout, "  checkout: %s\n", record.Checkout)
		state := cli.inspectConfigGit(ctx, record.Checkout, !offline)
		verifyConfigGitRegistration(record, &state)
		writeConfigGitState(cli.options.Stdout, state)
	}
	fmt.Fprintln(cli.options.Stdout, "  recovery: required")
	fmt.Fprintf(cli.options.Stdout, "  applied-commit: %s\n",
		emptyConfigGitValue(status.SourceCommit))
	fmt.Fprintf(cli.options.Stdout, "  generation: %d\n", status.Generation)
	fmt.Fprintln(cli.options.Stdout, "  live: blocked")
	fmt.Fprintf(cli.options.Stdout,
		"  next: %s config sync\n", cli.options.Program)
	return 1
}

func (cli *CLI) inspectConfigGit(
	ctx context.Context,
	checkout string,
	fetch bool,
) configGitState {
	state := configGitState{
		Checkout: checkout, Worktree: "unknown", Relation: "unknown",
		FetchState: "cached",
	}
	info, err := os.Lstat(checkout)
	if err != nil {
		state.Problem = fmt.Errorf("checkout unavailable: %w", err)
		return state
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		state.Problem = errors.New("checkout is not a real directory")
		return state
	}
	top, err := cli.configGitOutput(ctx, checkout, "rev-parse", "--show-toplevel")
	if err != nil {
		state.Problem = err
		return state
	}
	top, err = filepath.Abs(strings.TrimSpace(top))
	if err != nil || filepath.Clean(top) != filepath.Clean(checkout) {
		state.Problem = errors.New("checkout root does not match the registered path")
		return state
	}
	state.Head, err = cli.configGitOutput(ctx, checkout, "rev-parse", "--verify", "HEAD")
	if err != nil {
		state.Problem = err
		return state
	}
	state.Head = strings.TrimSpace(state.Head)
	branch, branchErr := cli.configGitOutput(
		ctx, checkout, "symbolic-ref", "--quiet", "--short", "HEAD",
	)
	if branchErr == nil {
		state.Branch = strings.TrimSpace(branch)
	} else {
		state.Branch = "detached"
	}
	upstream, upstreamErr := cli.configGitOutput(
		ctx, checkout, "rev-parse", "--abbrev-ref", "--symbolic-full-name",
		"@{upstream}",
	)
	if upstreamErr == nil {
		state.Upstream = strings.TrimSpace(upstream)
		if slash := strings.IndexByte(state.Upstream, '/'); slash > 0 {
			state.RemoteName = state.Upstream[:slash]
		}
	}
	if state.RemoteName != "" {
		raw, remoteErr := cli.configGitOutput(
			ctx, checkout, "remote", "get-url", state.RemoteName,
		)
		if remoteErr == nil {
			state.RemoteRaw = strings.TrimSpace(raw)
			state.RemoteURL = sanitizeConfigGitURL(state.RemoteRaw)
		}
	}
	if fetch && state.RemoteName != "" {
		fetchContext, cancel := context.WithTimeout(ctx, configGitFetchTimeout)
		defer cancel()
		if err := cli.configGitRun(
			fetchContext, checkout, "fetch", "--quiet", "--prune", "--", state.RemoteName,
		); err != nil {
			state.FetchState = "failed"
			state.Problem = fmt.Errorf(
				"fetch failed: %s", redactConfigGitDiagnostic(err.Error(), state),
			)
		} else {
			state.FetchState = "fresh"
		}
	} else if fetch {
		state.FetchState = "unavailable"
	} else {
		state.FetchState = "offline-cached"
	}
	state.LastFetch = cli.configGitLastFetch(ctx, checkout)

	porcelain, statusErr := cli.configGitOutputBytes(
		ctx, checkout, "status", "--porcelain=v1", "-z", "--untracked-files=all",
	)
	if statusErr == nil {
		parseConfigGitPorcelain(&state, porcelain)
	}
	if state.Upstream != "" {
		state.UpstreamCommit, _ = cli.configGitOutput(
			ctx, checkout, "rev-parse", "--verify", "@{upstream}",
		)
		state.UpstreamCommit = strings.TrimSpace(state.UpstreamCommit)
		counts, countErr := cli.configGitOutput(
			ctx, checkout, "rev-list", "--left-right", "--count",
			"HEAD...@{upstream}",
		)
		if countErr == nil {
			fields := strings.Fields(counts)
			if len(fields) == 2 {
				state.Ahead, _ = strconv.Atoi(fields[0])
				state.Behind, _ = strconv.Atoi(fields[1])
				state.Relation = configGitRelation(state.Ahead, state.Behind)
			}
		}
	} else {
		state.Upstream = "not configured"
	}
	if statusErr != nil && state.Problem == nil {
		state.Problem = statusErr
	}
	return state
}

func writeConfigGitState(output io.Writer, state configGitState) {
	remote := state.RemoteURL
	if remote == "" {
		remote = "not configured"
	}
	fmt.Fprintf(output, "  remote: %s\n", remote)
	fmt.Fprintf(output, "  branch: %s\n", emptyConfigGitValue(state.Branch))
	fmt.Fprintf(output, "  upstream: %s\n", emptyConfigGitValue(state.Upstream))
	fmt.Fprintf(output, "  head: %s\n", emptyConfigGitValue(state.Head))
	fmt.Fprintf(output, "  fetch: %s\n", state.FetchState)
	fmt.Fprintf(output, "  last-fetch: %s\n", emptyConfigGitValue(state.LastFetch))
	fmt.Fprintf(output, "  fetched-upstream: %s\n",
		emptyConfigGitValue(state.UpstreamCommit))
	fmt.Fprintf(output, "  worktree: %s (staged=%d unstaged=%d untracked=%d conflicts=%d)\n",
		state.Worktree, state.Staged, state.Unstaged, state.Untracked, state.Conflicts)
	relation := state.Relation
	switch state.Relation {
	case "ahead":
		relation = fmt.Sprintf("ahead %d", state.Ahead)
	case "behind":
		relation = fmt.Sprintf("behind %d", state.Behind)
	case "diverged":
		relation = fmt.Sprintf("diverged %d/%d", state.Ahead, state.Behind)
	}
	fmt.Fprintf(output, "  relation: %s\n", relation)
	if state.Problem != nil {
		fmt.Fprintf(output, "  git-detail: %s\n",
			redactConfigGitDiagnostic(state.Problem.Error(), state))
	}
}

func writeConfigSyncStatusNext(
	output io.Writer,
	program string,
	state configGitState,
	live string,
) {
	switch {
	case state.Conflicts != 0:
		fmt.Fprintln(output,
			"  next: resolve the Git conflict in the checkout, commit it, then rerun status")
	case state.Worktree == "dirty":
		fmt.Fprintf(output,
			"  next: review the checkout with git -C %q status --short\n", state.Checkout)
	case state.Branch == "detached":
		fmt.Fprintln(output,
			"  next: attach the checkout to the intended branch; Subyard will not choose one")
	case state.Upstream == "not configured":
		fmt.Fprintln(output,
			"  next: configure the exact upstream with git push -u")
	case state.Relation == "behind":
		fmt.Fprintf(output, "  next: %s config sync pull --apply\n", program)
	case state.Relation == "ahead":
		fmt.Fprintf(output, "  next: %s config sync push -m <message>\n", program)
	case state.Relation == "diverged":
		fmt.Fprintln(output,
			"  next: reconcile the diverged branch manually; Subyard will not merge, rebase or force")
	case live == "changes-required":
		fmt.Fprintf(output, "  next: %s config sync --apply\n", program)
	case state.Problem != nil:
		fmt.Fprintln(output, "  next: repair Git authentication or checkout configuration")
	default:
		fmt.Fprintln(output, "  next: none")
	}
}

func parseConfigGitPorcelain(state *configGitState, output []byte) {
	records := bytes.Split(output, []byte{0})
	for index := 0; index < len(records); index++ {
		record := records[index]
		if len(record) < 3 {
			continue
		}
		x, y := record[0], record[1]
		if x == '?' && y == '?' {
			state.Untracked++
			continue
		}
		if configGitConflictCode(string(record[:2])) {
			state.Conflicts++
		}
		if x != ' ' && x != '?' {
			state.Staged++
		}
		if y != ' ' && y != '?' {
			state.Unstaged++
		}
		if x == 'R' || x == 'C' || y == 'R' || y == 'C' {
			index++
		}
	}
	if state.Conflicts != 0 {
		state.Worktree = "conflicted"
	} else if state.Staged != 0 || state.Unstaged != 0 || state.Untracked != 0 {
		state.Worktree = "dirty"
	} else {
		state.Worktree = "clean"
	}
}

func configGitConflictCode(code string) bool {
	switch code {
	case "DD", "AU", "UD", "UA", "DU", "AA", "UU":
		return true
	default:
		return false
	}
}

func configGitRelation(ahead, behind int) string {
	switch {
	case ahead == 0 && behind == 0:
		return "up-to-date"
	case ahead != 0 && behind == 0:
		return "ahead"
	case ahead == 0 && behind != 0:
		return "behind"
	default:
		return "diverged"
	}
}

func sanitizeConfigGitURL(value string) string {
	if value == "" {
		return ""
	}
	if strings.Contains(value, "://") {
		parsed, err := url.Parse(value)
		if err != nil {
			return "<redacted-invalid-url>"
		}
		if parsed.User != nil {
			if parsed.Scheme == "ssh" {
				parsed.User = url.User(parsed.User.Username())
			} else {
				parsed.User = nil
			}
		}
		parsed.RawQuery = ""
		parsed.Fragment = ""
		return parsed.String()
	}
	if configGitSCPStyle(value) {
		return value
	}
	if filepath.IsAbs(value) {
		return filepath.Clean(value)
	}
	return "<redacted-remote>"
}

func verifyConfigGitRegistration(
	record configsync.SourceRecord,
	state *configGitState,
) {
	if record.Origin == "" {
		return
	}
	if state.RemoteName == "" || state.RemoteRaw == "" {
		if state.Problem == nil {
			state.Problem = errors.New(
				"registered Git origin is no longer configured for the upstream",
			)
		}
		return
	}
	if state.RemoteRaw != record.Origin {
		state.Problem = errors.New(
			"Git remote identity changed after source registration",
		)
	}
}

func (cli *CLI) configGitRun(
	ctx context.Context,
	checkout string,
	arguments ...string,
) error {
	_, err := cli.configGitOutputBytes(ctx, checkout, arguments...)
	return err
}

func (cli *CLI) configGitOutput(
	ctx context.Context,
	checkout string,
	arguments ...string,
) (string, error) {
	output, err := cli.configGitOutputBytes(ctx, checkout, arguments...)
	return string(output), err
}

func (cli *CLI) configGitOutputBytes(
	ctx context.Context,
	checkout string,
	arguments ...string,
) ([]byte, error) {
	commandArguments := append([]string{"-C", checkout}, arguments...)
	command := exec.CommandContext(ctx, "git", commandArguments...)
	command.Env = environmentList(cli.env, map[string]string{
		"GIT_TERMINAL_PROMPT": "0",
		"LC_ALL":              "C",
	})
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		detail := boundedConfigGitText(strings.TrimSpace(stderr.String()))
		if detail == "" {
			detail = err.Error()
		}
		return nil, errors.New(detail)
	}
	return stdout.Bytes(), nil
}

func (cli *CLI) configGitLastFetch(ctx context.Context, checkout string) string {
	path, err := cli.configGitOutput(ctx, checkout, "rev-parse", "--git-path", "FETCH_HEAD")
	if err != nil {
		return "never"
	}
	path = strings.TrimSpace(path)
	if !filepath.IsAbs(path) {
		path = filepath.Join(checkout, path)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "never"
	}
	return info.ModTime().UTC().Format(time.RFC3339)
}

func redactConfigGitDiagnostic(message string, state configGitState) string {
	if state.RemoteRaw != "" {
		message = strings.ReplaceAll(message, state.RemoteRaw, state.RemoteURL)
	}
	return boundedConfigGitText(message)
}

func boundedConfigGitText(value string) string {
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	if len(value) > maxConfigGitDiagnosticBytes {
		return value[:maxConfigGitDiagnosticBytes] + "..."
	}
	return value
}

func emptyConfigGitValue(value string) string {
	if strings.TrimSpace(value) == "" {
		return "unknown"
	}
	return value
}
