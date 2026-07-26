package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/Subyard/Subyard/internal/application"
	"github.com/Subyard/Subyard/internal/config"
	"github.com/Subyard/Subyard/internal/configsync"
	"github.com/Subyard/Subyard/internal/domain"
)

type preparedConfigSyncPull struct {
	checkout       string
	expectedHead   string
	expectedRemote string
	preview        configsync.Plan
	options        configsync.Options
	worktree       string
	worktreeParent string
	fastForward    bool
}

func (cli *CLI) runConfigSyncPull(
	ctx context.Context,
	loaded config.Loaded,
	arguments []string,
	assumeYes bool,
) int {
	if loaded.Context.YardType == domain.YardRemote {
		forwarded := append([]string{"sync", "pull"}, arguments...)
		if assumeYes {
			forwarded = append(forwarded, "--yes")
		}
		return cli.forwardRemote(ctx, loaded.Context, "config", forwarded)
	}
	materialize := false
	for _, argument := range arguments {
		switch argument {
		case "--apply":
			materialize = true
		case "-y", "--yes":
			assumeYes = true
		default:
			cli.errorf("config sync pull: unknown option %q", argument)
			return 2
		}
	}
	prepared, err := cli.prepareConfigSyncPull(ctx, loaded)
	if err != nil {
		cli.errorf("config sync pull: %v", err)
		return 1
	}
	defer prepared.cleanup(cli, ctx)

	fmt.Fprintln(cli.options.Stdout, "Versioned configuration pull")
	fmt.Fprintf(cli.options.Stdout, "  checkout: %s\n", prepared.checkout)
	if prepared.fastForward {
		fmt.Fprintf(cli.options.Stdout, "  fast-forward: %s -> %s\n",
			prepared.expectedHead, prepared.expectedRemote)
	} else {
		fmt.Fprintln(cli.options.Stdout, "  fast-forward: not required")
	}
	writeConfigSyncPlan(cli.options.Stdout, prepared.preview)

	needsConfirmation := prepared.fastForward || prepared.preview.NeedsConfirmation()
	var applied configsync.Plan
	if needsConfirmation {
		consequences := []string{}
		if prepared.fastForward {
			consequences = append(consequences,
				"fast-forward the registered configuration checkout")
		}
		if prepared.preview.InitializeHostID {
			consequences = append(consequences,
				"record owner host ID "+prepared.preview.HostID)
		}
		for _, change := range prepared.preview.Changes {
			consequences = append(consequences, change.Action+" "+change.Path)
		}
		if materialize && configSyncPlanNeedsMaterialization(prepared.preview) {
			consequences = append(consequences,
				"refresh affected file settings in running local yards")
		}
		orchestrator := cli.operationOrchestrator(
			cli.env["SUBYARD_OPERATION_ID"], loaded, nil, nil,
		)
		operation, err := orchestrator.Prepare(loaded.Context, domain.CommandPolicy{
			Name: "config sync pull", Effect: domain.CommandMutate,
			RemotePolicy: domain.RemoteOnOwner, Consequences: consequences,
		})
		if err != nil {
			cli.errorf("config sync pull: %v", err)
			return 1
		}
		operation, err = orchestrator.Confirm(ctx, operation, assumeYes)
		if errors.Is(err, application.ErrDeclined) {
			cli.errorf("config sync pull: operation declined")
			return 1
		}
		if err != nil {
			cli.errorf("config sync pull: %v", err)
			return 1
		}
		adapter := &configSyncPullAdapter{cli: cli, prepared: prepared}
		orchestrator.Runner = adapter
		if _, _, err := orchestrator.RunAdapter(ctx, operation, domain.AdapterRequest{
			OperationID: operation.OperationID,
			Adapter:     "config-sync",
			Action:      "pull",
		}, nil); err != nil {
			cli.errorf("config sync pull: %v", err)
			return 1
		}
		applied = adapter.plan
	} else {
		applied = prepared.preview
		if err := configsync.Apply(applied); err != nil {
			cli.errorf("config sync pull: %v", err)
			return 1
		}
	}
	if applied.NeedsApply() {
		fmt.Fprintf(cli.options.Stdout, "config sync: applied generation %d\n",
			applied.Generation)
	} else {
		fmt.Fprintln(cli.options.Stdout, "config sync: already converged")
	}
	if materialize {
		if err := cli.materializeConfigSyncPlan(ctx, loaded, applied, true); err != nil {
			cli.errorf("config sync pull --apply: %v", err)
			return 1
		}
	}
	cli.writeConfigSyncFollowups(loaded, applied, materialize)
	return 0
}

func (cli *CLI) prepareConfigSyncPull(
	ctx context.Context,
	loaded config.Loaded,
) (*preparedConfigSyncPull, error) {
	record, exists, err := configsync.ReadSourceRecord(
		loaded.Context.Paths.ConfigHome,
	)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, fmt.Errorf(
			"no source is registered; run %s config sync connect <git-url>",
			cli.options.Program,
		)
	}
	state := cli.inspectConfigGit(ctx, record.Checkout, true)
	verifyConfigGitRegistration(record, &state)
	if state.Problem != nil {
		return nil, state.Problem
	}
	if state.Branch == "detached" || state.Branch == "" {
		return nil, errors.New("registered checkout has detached HEAD")
	}
	if state.Upstream == "" || state.Upstream == "not configured" {
		return nil, errors.New(
			"current branch has no upstream; configure one with git push -u",
		)
	}
	if state.Worktree != "clean" {
		return nil, fmt.Errorf(
			"checkout is %s; review it with git -C %q status --short",
			state.Worktree, record.Checkout,
		)
	}
	if state.Relation == "diverged" {
		return nil, errors.New(
			"branch has diverged from upstream; Subyard will not merge or rebase it",
		)
	}
	if state.Relation == "unknown" {
		return nil, errors.New(
			"cannot determine the exact relation to upstream",
		)
	}
	options := configsync.Options{
		SourceRoot:     record.Checkout,
		ConfigHome:     loaded.Context.Paths.ConfigHome,
		RepositoryRoot: cli.options.RepositoryRoot,
		OperatorHome:   loaded.Context.Paths.OperatorHome,
		Environment:    cli.baseEnv,
		FileSettings:   config.SyncableFileMappings(loaded),
		YardInUse:      cli.configSyncYardInUse(loaded),
	}
	prepared := &preparedConfigSyncPull{
		checkout: record.Checkout, expectedHead: state.Head,
		expectedRemote: state.UpstreamCommit, options: options,
		fastForward: state.Behind > 0,
	}
	if !prepared.fastForward {
		prepared.preview, err = configsync.BuildPlan(options)
		if err != nil {
			return nil, err
		}
		return prepared, nil
	}
	parent, err := os.MkdirTemp("", ".subyard-config-pull-")
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(parent, 0o700); err != nil {
		_ = os.Remove(parent)
		return nil, err
	}
	prepared.worktreeParent = parent
	prepared.worktree = filepath.Join(parent, "candidate")
	if err := cli.configGitRun(
		ctx, record.Checkout, "worktree", "add", "--quiet", "--detach",
		prepared.worktree, state.UpstreamCommit,
	); err != nil {
		prepared.cleanup(cli, ctx)
		return nil, fmt.Errorf("prepare upstream candidate: %w", err)
	}
	if err := hardenConfigCandidate(prepared.worktree); err != nil {
		prepared.cleanup(cli, ctx)
		return nil, fmt.Errorf("protect upstream candidate: %w", err)
	}
	candidateOptions := options
	candidateOptions.SourceRoot = prepared.worktree
	candidateOptions.SourceIdentityRoot = record.Checkout
	prepared.preview, err = configsync.BuildPlan(candidateOptions)
	if err != nil {
		prepared.cleanup(cli, ctx)
		return nil, fmt.Errorf("validate upstream candidate: %w", err)
	}
	return prepared, nil
}

func (prepared *preparedConfigSyncPull) cleanup(cli *CLI, ctx context.Context) {
	if prepared == nil || prepared.worktreeParent == "" {
		return
	}
	if filepath.Dir(prepared.worktree) == prepared.worktreeParent &&
		strings.HasPrefix(filepath.Base(prepared.worktreeParent), ".subyard-config-pull-") {
		_ = cli.configGitRun(
			ctx, prepared.checkout, "worktree", "remove", "--force", prepared.worktree,
		)
		_ = os.RemoveAll(prepared.worktreeParent)
	}
	prepared.worktree = ""
	prepared.worktreeParent = ""
}

type configSyncPullAdapter struct {
	cli      *CLI
	prepared *preparedConfigSyncPull
	plan     configsync.Plan
}

func (adapter *configSyncPullAdapter) Run(
	ctx context.Context,
	request domain.AdapterRequest,
	_ io.Reader,
) (domain.AdapterResult, string, error) {
	if request.Adapter != "config-sync" || request.Action != "pull" {
		return domain.AdapterResult{}, "", errors.New(
			"invalid configuration pull adapter request",
		)
	}
	prepared := adapter.prepared
	head, err := adapter.cli.configGitOutput(
		ctx, prepared.checkout, "rev-parse", "--verify", "HEAD",
	)
	if err != nil || strings.TrimSpace(head) != prepared.expectedHead {
		return domain.AdapterResult{}, "", errors.New(
			"checkout HEAD changed after preview; rerun pull",
		)
	}
	if prepared.fastForward {
		upstream, err := adapter.cli.configGitOutput(
			ctx, prepared.checkout, "rev-parse", "--verify", "@{upstream}",
		)
		if err != nil || strings.TrimSpace(upstream) != prepared.expectedRemote {
			return domain.AdapterResult{}, "", errors.New(
				"upstream changed after preview; rerun pull",
			)
		}
		if err := adapter.cli.configGitRun(
			ctx, prepared.checkout, "merge", "--ff-only", "--no-edit",
			prepared.expectedRemote,
		); err != nil {
			return domain.AdapterResult{}, "", fmt.Errorf(
				"fast-forward checkout: %w", err,
			)
		}
	}
	if err := hardenClonedConfigSource(prepared.checkout); err != nil {
		return domain.AdapterResult{}, "", fmt.Errorf(
			"protect pulled configuration checkout: %w", err,
		)
	}
	options := prepared.options
	options.SourceRoot = prepared.checkout
	options.SourceIdentityRoot = prepared.checkout
	plan, err := configsync.BuildPlan(options)
	if err != nil {
		return domain.AdapterResult{}, "", fmt.Errorf(
			"revalidate pulled configuration: %w", err,
		)
	}
	if plan.Digest != prepared.preview.Digest {
		return domain.AdapterResult{}, "", errors.New(
			"configuration source or live settings changed after preview; rerun pull",
		)
	}
	if err := configsync.Apply(plan); err != nil {
		return domain.AdapterResult{}, "", err
	}
	adapter.plan = plan
	return domain.AdapterResult{
		Schema: 1, OperationID: request.OperationID, Status: "ok",
		Output: map[string]any{
			"commit": plan.SourceCommit, "generation": plan.Generation,
		},
	}, "", nil
}

func configSyncPlanNeedsMaterialization(plan configsync.Plan) bool {
	for _, change := range plan.Changes {
		for _, application := range change.Applications {
			if application == config.SettingConfigApply {
				return true
			}
		}
	}
	return false
}
