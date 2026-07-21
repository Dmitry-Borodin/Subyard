package cli

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/credentialmeta"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/incusclient"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/projectruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/statusruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/application"
	"github.com/Dmitry-Borodin/Subyard/internal/audit"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/credential"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/migration"
	"github.com/Dmitry-Borodin/Subyard/internal/ports"
	"github.com/Dmitry-Borodin/Subyard/internal/resource"
	"github.com/Dmitry-Borodin/Subyard/internal/rpc"
	"github.com/Dmitry-Borodin/Subyard/internal/state"
)

var Version = "0.1.0-dev"
var operationCounter atomic.Uint64

type Options struct {
	RepositoryRoot  string
	DispatcherPath  string
	Program         string
	Arguments       []string
	Environment     []string
	WorkingDir      string
	Stdin           io.Reader
	Stdout          io.Writer
	Stderr          io.Writer
	Incus           ports.Incus
	Executor        ports.InstanceExecutor
	ProjectObserver ports.ProjectObserver
	StatusFacts     ports.StatusFactsReader
	Credentials     ports.CredentialMetadataReader
}

type CLI struct {
	options   Options
	env       map[string]string
	baseEnv   map[string]string
	manifest  command.Manifest
	resources resource.Registry
}

func New(options Options) (*CLI, error) {
	root, err := filepath.Abs(options.RepositoryRoot)
	if err != nil {
		return nil, err
	}
	options.RepositoryRoot = filepath.Clean(root)
	if options.Program == "" {
		options.Program = "yard"
	}
	if options.DispatcherPath == "" {
		options.DispatcherPath = options.Program
	}
	if options.Stdin == nil {
		options.Stdin = strings.NewReader("")
	}
	if options.Stdout == nil {
		options.Stdout = io.Discard
	}
	if options.Stderr == nil {
		options.Stderr = io.Discard
	}
	manifestFile, err := os.Open(filepath.Join(root, "config", "commands.registry"))
	if err != nil {
		return nil, fmt.Errorf("open command manifest: %w", err)
	}
	manifest, parseErr := command.Parse(manifestFile)
	closeErr := manifestFile.Close()
	if parseErr != nil {
		return nil, parseErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	resources, err := resource.Load(root)
	if err != nil {
		return nil, err
	}
	for _, definition := range resources.Definitions() {
		if _, conflict := manifest.Lookup(definition.Command); conflict {
			return nil, fmt.Errorf("profile resource command conflicts with core command: %s", definition.Command)
		}
	}
	baseEnvironment := environmentMap(options.Environment)
	activeEnvironment := make(map[string]string, len(baseEnvironment))
	for name, value := range baseEnvironment {
		activeEnvironment[name] = value
	}
	return &CLI{
		options: options, env: activeEnvironment, baseEnv: baseEnvironment,
		manifest: manifest, resources: resources,
	}, nil
}

func (cli *CLI) Run(ctx context.Context) int {
	arguments := append([]string(nil), cli.options.Arguments...)
	yard, explicit, yes, remaining, err := parseGlobals(arguments, cli.env["SUBYARD_YARD"])
	if err != nil {
		cli.errorf("%v", err)
		return 2
	}
	if len(remaining) == 0 {
		cli.usage()
		return 0
	}
	if code, handled := cli.globalQuery(remaining); handled {
		return code
	}
	name := remaining[0]
	commandArguments := append([]string(nil), remaining[1:]...)
	if yes {
		commandArguments = append([]string{"--yes"}, commandArguments...)
	}
	definition, core := cli.manifest.Lookup(name)
	resourceDefinition, profileResource := cli.resources.Lookup(name)
	if !core && !profileResource {
		cli.errorf("unknown command %q\nTry %q.", name, cli.options.Program+" --help")
		return 2
	}
	if explicit {
		cli.env["SUBYARD_YARD_EXPLICIT"] = "1"
	}
	cli.env["SUBYARD_YARD"] = yard
	if core && definition.Handler == "@help" {
		if cli.env["SUBYARD_NO_AUDIT"] == "" {
			cli.audit(name, commandArguments, yard, "")
		}
		cli.usage()
		return 0
	}
	if core && definition.Handler == "@rpc" {
		if cli.env["SUBYARD_NO_AUDIT"] == "" {
			cli.audit(name, commandArguments, yard, "")
		}
		return cli.serveRPC(ctx, yard, commandArguments)
	}
	if core && definition.Handler == "@credential-policy" {
		return cli.runCredentialPolicy(commandArguments)
	}
	if core && definition.Handler == "@migrate" {
		return cli.runMigration(ctx, commandArguments)
	}
	remotePlane := command.RemoteForward
	if core {
		remotePlane = definition.Remote
	}
	loaded, err := cli.loadContext(yard)
	if err != nil {
		cli.errorf("%v", err)
		return 2
	}
	loadedContext := loaded.Context
	if cli.env["SUBYARD_OPERATION_ID"] == "" {
		cli.env["SUBYARD_OPERATION_ID"] = newOperationID()
	}
	remote := ""
	if loadedContext.YardType == domain.YardRemote {
		remote = loadedContext.RemoteDest
	}
	if name != "_info" && cli.env["SUBYARD_NO_AUDIT"] == "" {
		cli.audit(name, commandArguments, yard, remote)
	}
	target, routeErr := application.Route(loadedContext, domain.RemotePolicy(remotePlane))
	if routeErr != nil {
		if remotePlane == command.RemoteDeny {
			fmt.Fprintf(cli.options.Stderr, "%s is host-local — use sync or clone\n", name)
		} else {
			cli.errorf("route %s: %v", name, routeErr)
		}
		return 1
	}
	if target == domain.TargetRemoteOwner {
		return cli.forwardRemote(ctx, loadedContext, name, commandArguments)
	}
	switch definition.Handler {
	case "@status":
		return cli.runStatus(ctx, loaded, commandArguments)
	case "@list":
		return cli.runProjectList(ctx, loaded, explicit, commandArguments)
	case "@state":
		return cli.runProjectState(ctx, loadedContext, commandArguments, false)
	case "@project-state":
		return cli.runProjectState(ctx, loadedContext, commandArguments, true)
	}
	if profileResource {
		return cli.runCommand(ctx, resourceDefinition.HandlerPath(), commandArguments,
			cli.handlerEnvironment(resourceDefinition.Command, ""))
	}
	if definition.Handler == "@resource" {
		if len(commandArguments) == 0 {
			cli.errorf("'svc' needs a resource name or command (see '%s --resources')", cli.options.Program)
			return 2
		}
		selected, ok := cli.resources.Lookup(commandArguments[0])
		if !ok {
			cli.errorf("unknown resource %q (see '%s --resources')", commandArguments[0], cli.options.Program)
			return 2
		}
		return cli.runCommand(ctx, selected.HandlerPath(), commandArguments[1:],
			cli.handlerEnvironment(selected.Command, ""))
	}
	path := filepath.Join(cli.options.RepositoryRoot, "scripts", definition.Handler)
	handlerArguments := commandArguments
	if definition.Arg0 != "" {
		handlerArguments = append([]string{definition.Arg0}, handlerArguments...)
	}
	return cli.runCommand(ctx, path, handlerArguments, cli.handlerEnvironment(definition.Name, definition.Arg0))
}

func (cli *CLI) projectObserver() ports.ProjectObserver {
	if cli.options.ProjectObserver != nil {
		return cli.options.ProjectObserver
	}
	incusPort := cli.options.Incus
	executor := cli.options.Executor
	if incusPort == nil || executor == nil {
		client := incusclient.New(cli.env["SUBYARD_INCUS_SOCKET"], "projects")
		if incusPort == nil {
			incusPort = client
		}
		if executor == nil {
			executor = client
		}
	}
	return projectruntime.Runtime{Incus: incusPort, Executor: executor}
}

func (cli *CLI) statusPorts() (ports.Incus, ports.InstanceExecutor) {
	incusPort := cli.options.Incus
	executor := cli.options.Executor
	if incusPort == nil || executor == nil {
		client := incusclient.New(cli.env["SUBYARD_INCUS_SOCKET"], "projects")
		if incusPort == nil {
			incusPort = client
		}
		if executor == nil {
			executor = client
		}
	}
	return incusPort, executor
}

func (cli *CLI) statusFacts(loaded config.Loaded) ports.StatusFactsReader {
	if cli.options.StatusFacts != nil {
		return cli.options.StatusFacts
	}
	environment := make(map[string]string, len(loaded.Environment)+5)
	for key, value := range loaded.Environment {
		environment[key] = value
	}
	environment["SUBYARD_CONFIG_LOADED"] = "1"
	environment["SUBYARD_ENGINE_CONTEXT"] = "1"
	environment["SUBYARD_REPOSITORY_ROOT"] = cli.options.RepositoryRoot
	environment["PROG"] = cli.options.Program
	return statusruntime.Runtime{RepositoryRoot: cli.options.RepositoryRoot, Environment: environment}
}

func (cli *CLI) runStatus(ctx context.Context, loaded config.Loaded, arguments []string) int {
	all := false
	for _, argument := range arguments {
		switch argument {
		case "--all":
			all = true
		case "-h", "--help":
			fmt.Fprintf(cli.options.Stdout, "Usage: %s status [--all]\n", cli.options.Program)
			return 0
		case "--yes":
		default:
			cli.errorf("unknown option %q", argument)
			return 2
		}
	}
	if !all {
		return cli.printYardStatus(ctx, loaded)
	}
	names, err := config.YardNames(config.RegistryDirectories(
		cli.options.RepositoryRoot, loaded.Context.Paths.ConfigHome,
	)...)
	if err != nil {
		cli.errorf("discover yards: %v", err)
		return 1
	}
	code := 0
	for index, name := range names {
		if index != 0 {
			fmt.Fprintln(cli.options.Stdout)
		}
		selected := loaded
		if name != loaded.Context.YardName {
			selected, err = cli.loadInventoryLoaded(name, loaded)
			if err != nil {
				cli.errorf("load yard %q: %v", name, err)
				code = 1
				continue
			}
		}
		if selected.Context.YardType == domain.YardRemote {
			if err := cli.printRemoteStatus(ctx, selected.Context); err != nil {
				cli.errorf("remote status for %q: %v", name, err)
				code = 1
			}
			continue
		}
		if current := cli.printYardStatus(ctx, selected); current != 0 {
			code = current
		}
	}
	return code
}

func (cli *CLI) printYardStatus(ctx context.Context, loaded config.Loaded) int {
	store, err := state.NewFileStore(loaded.Context.Paths.StateDir)
	if err != nil {
		cli.errorf("open project state: %v", err)
		return 1
	}
	incusPort, executor := cli.statusPorts()
	service := application.StatusService{
		Incus: incusPort, Executor: executor, Store: store, Facts: cli.statusFacts(loaded),
	}
	status, err := service.Read(ctx, loaded.Context)
	if err != nil {
		cli.errorf("status: %v", err)
		return 1
	}
	label := loaded.Context.YardName
	if label == "default" {
		label = "yard"
	}
	fmt.Fprintf(cli.options.Stdout, "%s  %s\n", label, status.State)
	fmt.Fprintf(cli.options.Stdout, "  desired  %s  (initialized=%s, incus-autostart=%s)\n",
		status.Desired, status.Initialized, status.IncusAutostart)
	if status.State == "RUNNING" {
		ip := status.IP
		if ip == "" {
			ip = "—"
		}
		fmt.Fprintf(cli.options.Stdout, "  ip       %s\n", ip)
	}
	if status.SSHConfigured {
		fmt.Fprintf(cli.options.Stdout, "  ssh      127.0.0.1:%d  (ssh %s)\n",
			status.Context.SSHPort, status.Context.SSHHost)
	} else {
		fmt.Fprintf(cli.options.Stdout,
			"  ssh      not set up  (run: %s init, or scripts/07-ssh-access.sh)\n",
			cli.yardHint(status.Context))
	}
	mounts := "none"
	if len(status.Mounts) != 0 {
		mounts = strings.Join(status.Mounts, " ")
	}
	fmt.Fprintf(cli.options.Stdout, "  mounts   %s\n", mounts)
	if status.State == "RUNNING" {
		fmt.Fprintf(cli.options.Stdout, "  services ssh/docker = %s\n", status.Services)
		forward := "off"
		if status.Context.ForwardSSHAgent {
			forward = "on"
		}
		fmt.Fprintf(cli.options.Stdout, "  vscode   %s agent-fwd=%s  (yard code <project>)\n",
			status.VSCode, forward)
	}
	fmt.Fprintf(cli.options.Stdout, "  projects %d  (%s list)\n", status.ProjectCount, cli.yardHint(status.Context))
	if len(status.Facts.Shared) == 0 {
		fmt.Fprintln(cli.options.Stdout, "  shared   none")
	} else {
		fmt.Fprintln(cli.options.Stdout, "  shared:")
		for _, shared := range status.Facts.Shared {
			if shared.Hint == "" {
				fmt.Fprintf(cli.options.Stdout, "    %-9s %-16s %s\n", shared.Profile, shared.Name, shared.State)
			} else {
				fmt.Fprintf(cli.options.Stdout, "    %-9s %-16s %-5s (%s)\n",
					shared.Profile, shared.Name, shared.State, shared.Hint)
			}
		}
	}
	switch status.Facts.Security {
	case "live":
		fmt.Fprintln(cli.options.Stdout, "  security ok (live)")
	case "static-only":
		fmt.Fprintln(cli.options.Stdout, "  security static-only")
	default:
		fmt.Fprintf(cli.options.Stdout, "  security FAIL  (inspect: %s security)\n", cli.yardHint(status.Context))
	}
	fmt.Fprintf(cli.options.Stdout, "  space    %s\n", status.Facts.Space)
	return 0
}

func (cli *CLI) yardHint(yard domain.Context) string {
	if yard.YardName == "default" {
		return cli.options.Program
	}
	return fmt.Sprintf("%s -Y %s", cli.options.Program, yard.YardName)
}

type remoteInfo struct {
	State    string `json:"state"`
	Projects *int   `json:"projects"`
}

func (cli *CLI) printRemoteStatus(ctx context.Context, yard domain.Context) error {
	cachePath := filepath.Join(yard.Paths.DataHome, "remote-"+yard.YardName+".cache")
	cached, cachedAt, _ := readRemoteStatusCache(cachePath)
	remoteLine := "yard _info"
	if yard.RemoteYard != "" {
		if !domain.SafeName(yard.RemoteYard) {
			return errors.New("invalid remote owner yard")
		}
		remoteLine = "yard -Y " + shellQuote(yard.RemoteYard) + " _info"
	}
	command := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=2",
		"-o", "StrictHostKeyChecking=accept-new", yard.RemoteDest, "--", "bash", "-lc", remoteLine)
	payload, callErr := command.Output()
	info := remoteInfo{}
	age := ""
	if callErr == nil && json.Unmarshal(payload, &info) == nil && info.State != "" {
		if info.Projects == nil && cached.Projects != nil {
			info.Projects = cached.Projects
		}
		_ = writeRemoteStatusCache(cachePath, info)
	} else {
		info = cached
		if !cachedAt.IsZero() {
			age = ", seen " + ageHuman(time.Since(cachedAt)) + " ago"
		}
	}
	stateValue := info.State
	if stateValue == "" {
		stateValue = "?"
	}
	projects := "?"
	if info.Projects != nil {
		projects = strconv.Itoa(*info.Projects)
	}
	fmt.Fprintf(cli.options.Stdout, "%s  %s  (remote %s, %s projects%s)\n",
		yard.YardName, stateValue, yard.RemoteDest, projects, age)
	return nil
}

func readRemoteStatusCache(path string) (remoteInfo, time.Time, error) {
	payload, err := os.ReadFile(path)
	if err != nil {
		return remoteInfo{}, time.Time{}, err
	}
	epochLine, jsonLine, ok := strings.Cut(string(payload), "\n")
	if !ok {
		return remoteInfo{}, time.Time{}, errors.New("invalid remote status cache")
	}
	epoch, err := strconv.ParseInt(strings.TrimSpace(epochLine), 10, 64)
	if err != nil {
		return remoteInfo{}, time.Time{}, err
	}
	var info remoteInfo
	if err := json.Unmarshal([]byte(strings.TrimSpace(jsonLine)), &info); err != nil {
		return remoteInfo{}, time.Time{}, err
	}
	return info, time.Unix(epoch, 0), nil
}

func writeRemoteStatusCache(path string, info remoteInfo) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	payload, err := json.Marshal(info)
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, []byte(fmt.Sprintf("%d\n%s\n", time.Now().Unix(), payload)), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

func ageHuman(age time.Duration) string {
	seconds := int64(age.Seconds())
	if seconds < 0 {
		seconds = 0
	}
	switch {
	case seconds < 60:
		return fmt.Sprintf("%ds", seconds)
	case seconds < 3600:
		return fmt.Sprintf("%dm", seconds/60)
	case seconds < 86400:
		return fmt.Sprintf("%dh", seconds/3600)
	default:
		return fmt.Sprintf("%dd", seconds/86400)
	}
}

func (cli *CLI) runProjectList(
	ctx context.Context,
	loaded config.Loaded,
	explicit bool,
	arguments []string,
) int {
	live := false
	for _, argument := range arguments {
		switch argument {
		case "--live":
			live = true
		case "-h", "--help":
			fmt.Fprintf(cli.options.Stdout, "Usage: %s list [--live]\n", cli.options.Program)
			return 0
		case "--yes":
		default:
			cli.errorf("unknown option %q", argument)
			return 2
		}
	}
	names, err := config.YardNames(config.RegistryDirectories(
		cli.options.RepositoryRoot, loaded.Context.Paths.ConfigHome,
	)...)
	if err != nil {
		cli.errorf("discover yards: %v", err)
		return 1
	}
	explicit = explicit || cli.env["SUBYARD_YARD_EXPLICIT"] != "" || loaded.Context.YardName != "default"
	if explicit || len(names) == 1 {
		if explicit {
			fmt.Fprintf(cli.options.Stdout, "Yard: %s\n", loaded.Context.YardName)
		}
		return cli.printSingleProjectList(ctx, loaded.Context, live)
	}
	return cli.printAllProjectLists(ctx, names, loaded, live)
}

func (cli *CLI) printSingleProjectList(ctx context.Context, yard domain.Context, live bool) int {
	store, err := state.NewFileStore(yard.Paths.StateDir)
	if err != nil {
		cli.errorf("open project state: %v", err)
		return 1
	}
	inventory := application.ProjectInventory{Store: store, Observer: cli.projectObserver()}
	records, observation, err := inventory.Read(ctx, yard, live)
	if err != nil {
		cli.errorf("list projects: %v", err)
		return 1
	}
	for _, warning := range observation.Warnings {
		fmt.Fprintf(cli.options.Stderr, "Warning: %s\n", warning)
	}
	if len(records) == 0 {
		fmt.Fprintf(cli.options.Stdout,
			"No projects in the yard yet — add one with: %s sync <path> (or: bind <path>)\n",
			cli.options.Program)
		return 0
	}
	fmt.Fprintf(cli.options.Stdout, "%-22s %-6s %-10s %-8s %-5s %s\n", "NAME", "MODE", "TARGET", "YARD", "BOX", "HOST PATH")
	for _, record := range records {
		target := record.Target
		if target == "" {
			target = "yard"
		}
		hostPath := record.HostPath
		if hostPath == "" {
			hostPath = "(yard)"
		}
		presence := observation.Presence[record.ProjectID]
		if presence == "" {
			presence = domain.ProjectPresenceUnknown
		}
		box := observation.Boxes[record.ProjectID]
		if target == "yard" {
			box = "-"
		} else if box == "" {
			box = domain.ProjectBoxUnknown
		}
		fmt.Fprintf(cli.options.Stdout, "%-22s %-6s %-10s %-8s %-5s %s\n",
			record.Name, record.Mode, target, presence, box, hostPath)
	}
	return 0
}

type yardInventory struct {
	name    string
	records []domain.ProjectRecord
}

func (cli *CLI) printAllProjectLists(
	ctx context.Context,
	names []string,
	loaded config.Loaded,
	live bool,
) int {
	all := make([]yardInventory, 0, len(names))
	counts := make(map[string]map[string]struct{})
	for _, name := range names {
		yard, err := cli.loadInventoryContext(name, loaded)
		if err != nil {
			cli.errorf("load yard %q: %v", name, err)
			return 1
		}
		store, err := state.NewFileStore(yard.Paths.StateDir)
		if err != nil {
			cli.errorf("open project state for %q: %v", name, err)
			return 1
		}
		inventory := application.ProjectInventory{Store: store}
		if live {
			inventory.Observer = cli.projectObserver()
		}
		records, observation, err := inventory.Read(ctx, yard, live)
		if err != nil {
			cli.errorf("list projects in %q: %v", name, err)
			return 1
		}
		for _, warning := range observation.Warnings {
			fmt.Fprintf(cli.options.Stderr, "Warning: %s: %s\n", name, warning)
		}
		all = append(all, yardInventory{name: name, records: records})
		for _, record := range records {
			key := strings.ToLower(record.Name)
			if counts[key] == nil {
				counts[key] = make(map[string]struct{})
			}
			counts[key][name] = struct{}{}
		}
	}
	total := 0
	for _, inventory := range all {
		total += len(inventory.records)
	}
	if total == 0 {
		fmt.Fprintf(cli.options.Stdout,
			"No projects in any yard yet — add one with: %s sync <path> (or: bind <path>)\n",
			cli.options.Program)
		return 0
	}
	fmt.Fprintf(cli.options.Stdout, "%-12s %-24s %-6s %-10s %s\n", "YARD", "NAME", "MODE", "TARGET", "HOST PATH")
	for _, inventory := range all {
		for _, record := range inventory.records {
			name := record.Name
			if len(counts[strings.ToLower(name)]) > 1 {
				name = inventory.name + "/" + name
			}
			target := record.Target
			if target == "" {
				target = "yard"
			}
			hostPath := record.HostPath
			if hostPath == "" {
				hostPath = "(yard)"
			}
			fmt.Fprintf(cli.options.Stdout, "%-12s %-24s %-6s %-10s %s\n",
				inventory.name, name, record.Mode, target, hostPath)
		}
	}
	return 0
}

func (cli *CLI) loadInventoryContext(name string, loaded config.Loaded) (domain.Context, error) {
	contextLoaded, err := cli.loadInventoryLoaded(name, loaded)
	return contextLoaded.Context, err
}

func (cli *CLI) loadInventoryLoaded(name string, loaded config.Loaded) (config.Loaded, error) {
	environment := make(map[string]string, len(cli.baseEnv))
	for key, value := range cli.baseEnv {
		environment[key] = value
	}
	return config.Load(config.LoadOptions{
		RepositoryRoot: cli.options.RepositoryRoot,
		OperatorHome:   loaded.Context.Paths.OperatorHome,
		YardName:       name,
		Environment:    environment,
	})
}

func (cli *CLI) runProjectState(
	ctx context.Context,
	yard domain.Context,
	arguments []string,
	ownerEndpoint bool,
) int {
	store, err := state.NewFileStore(yard.Paths.StateDir)
	if err != nil {
		cli.errorf("open project state: %v", err)
		return 1
	}
	service := state.Service{Store: store}
	if ownerEndpoint {
		return cli.runOwnerProjectState(ctx, service, yard, arguments)
	}
	if len(arguments) == 0 {
		cli.errorf("internal: _state needs an action")
		return 2
	}
	action := arguments[0]
	arguments = arguments[1:]
	fail := func(err error) int {
		cli.errorf("project state %s: %v", action, err)
		return 1
	}
	switch action {
	case "validate":
		if len(arguments) != 0 {
			return fail(errors.New("validate takes no arguments"))
		}
		if err := service.Validate(ctx); err != nil {
			return fail(err)
		}
	case "ids":
		if len(arguments) != 0 {
			return fail(errors.New("ids takes no arguments"))
		}
		records, err := store.List(ctx)
		if err != nil {
			return fail(err)
		}
		for _, record := range records {
			fmt.Fprintln(cli.options.Stdout, record.ProjectID)
		}
	case "validate-file":
		if len(arguments) != 2 {
			return fail(errors.New("validate-file needs path and expected ID"))
		}
		if err := store.ValidateFile(arguments[0], arguments[1]); err != nil {
			return fail(err)
		}
	case "project-id":
		if len(arguments) != 1 {
			return fail(errors.New("project-id needs a path"))
		}
		path := arguments[0]
		if !filepath.IsAbs(path) && cli.options.WorkingDir != "" {
			path = filepath.Join(cli.options.WorkingDir, path)
		}
		id, err := state.ProjectID(path)
		if err != nil {
			return fail(err)
		}
		fmt.Fprintln(cli.options.Stdout, id)
	case "yard-path":
		if len(arguments) != 1 || !domain.SafeID(arguments[0]) {
			return fail(errors.New("yard-path needs a valid project ID"))
		}
		fmt.Fprintln(cli.options.Stdout, state.YardPath(arguments[0]))
	case "device":
		if len(arguments) != 1 || !domain.SafeID(arguments[0]) {
			return fail(errors.New("device needs a valid project ID"))
		}
		fmt.Fprintln(cli.options.Stdout, state.WorkspaceDevice(arguments[0]))
	case "valid":
		if len(arguments) != 2 || !validStateValue(arguments[0], arguments[1]) {
			return 1
		}
	case "resolve-local", "resolve-local-soft":
		if len(arguments) != 1 {
			return fail(errors.New("resolve-local needs a selector"))
		}
		match, err := cli.resolveLocalProject(ctx, yard, store, arguments[0])
		if err != nil {
			if action == "resolve-local-soft" {
				return 1
			}
			return fail(err)
		}
		fmt.Fprintln(cli.options.Stdout, match.Record.ProjectID)
	case "resolve-global":
		if len(arguments) != 1 {
			return fail(errors.New("resolve-global needs a selector"))
		}
		match, err := cli.resolveGlobalProject(ctx, yard, arguments[0])
		if err != nil {
			return fail(err)
		}
		fmt.Fprintf(cli.options.Stdout, "%s\t%s\n", match.Yard, match.Record.ProjectID)
	case "route-sync":
		if len(arguments) != 2 || !domain.SafeID(arguments[0]) {
			return fail(errors.New("route-sync needs a valid project ID and target yard"))
		}
		target, err := cli.routeSyncProject(ctx, yard, arguments[0], arguments[1])
		if err != nil {
			return fail(err)
		}
		fmt.Fprintln(cli.options.Stdout, target)
	case "exists":
		if len(arguments) != 1 {
			return 2
		}
		if _, err := store.Get(ctx, arguments[0]); err != nil {
			if errors.Is(err, state.ErrNotFound) {
				return 1
			}
			return fail(err)
		}
	case "get":
		if len(arguments) != 2 {
			return fail(errors.New("get needs ID and field"))
		}
		record, err := store.Get(ctx, arguments[0])
		if err != nil {
			return fail(err)
		}
		value, err := state.Field(record, arguments[1])
		if err != nil {
			return fail(err)
		}
		fmt.Fprintln(cli.options.Stdout, value)
	case "remove":
		if len(arguments) != 1 {
			return fail(errors.New("remove needs ID"))
		}
		if err := store.Delete(ctx, arguments[0]); err != nil {
			return fail(err)
		}
	case "write":
		if len(arguments) != 6 {
			return fail(errors.New("write needs ID, name, host path, yard path, mode and SSH host"))
		}
		if err := service.Write(ctx, arguments[0], arguments[1], arguments[2], arguments[3],
			domain.ProjectMode(arguments[4]), arguments[5], time.Now().UTC().Format(time.RFC3339)); err != nil {
			return fail(err)
		}
	case "set":
		if len(arguments) != 3 {
			return fail(errors.New("set needs ID, field and value"))
		}
		if err := service.Set(ctx, arguments[0], arguments[1], arguments[2]); err != nil {
			return fail(err)
		}
	case "upsert-yard":
		if len(arguments) != 5 {
			return fail(errors.New("upsert-yard needs ID, name, mode, target and SSH host"))
		}
		if err := service.UpsertYard(ctx, arguments[0], arguments[1], domain.ProjectMode(arguments[2]),
			arguments[3], arguments[4]); err != nil {
			return fail(err)
		}
	default:
		return fail(fmt.Errorf("unknown action %q", action))
	}
	return 0
}

func (cli *CLI) runCredentialPolicy(arguments []string) int {
	if len(arguments) == 0 {
		cli.errorf("internal: _credential-policy needs an action")
		return 2
	}
	action := arguments[0]
	arguments = arguments[1:]
	writeJSON := func(value any) int {
		encoder := json.NewEncoder(cli.options.Stdout)
		encoder.SetEscapeHTML(false)
		if err := encoder.Encode(value); err != nil {
			cli.errorf("credential policy output: %v", err)
			return 1
		}
		return 0
	}
	fail := func(err error) int {
		cli.errorf("credential policy %s: %v", action, err)
		return 1
	}
	decode := func(target any) error {
		decoder := json.NewDecoder(io.LimitReader(cli.options.Stdin, rpc.MaxFrameSize+1))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(target); err != nil {
			return err
		}
		var trailing any
		if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
			return errors.New("credential metadata input has trailing data")
		}
		return nil
	}
	switch action {
	case "heads":
		if len(arguments) != 1 {
			return fail(errors.New("heads needs a credential ID"))
		}
		var revisions []domain.CredentialMetadata
		if err := decode(&revisions); err != nil {
			return fail(err)
		}
		if err := credential.ValidateRevisions(revisions); err != nil {
			return fail(err)
		}
		return writeJSON(credential.Heads(revisions, arguments[0]))
	case "parents":
		if len(arguments) != 0 {
			return fail(errors.New("parents takes no arguments"))
		}
		var heads []domain.CredentialMetadata
		if err := decode(&heads); err != nil {
			return fail(err)
		}
		parents := make([]string, 0, len(heads))
		for _, head := range heads {
			if err := credential.ValidateMetadata(head); err != nil {
				return fail(err)
			}
			parents = append(parents, head.RevisionID)
		}
		sort.Strings(parents)
		parents = slices.Compact(parents)
		return writeJSON(parents)
	case "recipients":
		var heads []domain.CredentialMetadata
		if err := decode(&heads); err != nil {
			return fail(err)
		}
		for _, head := range heads {
			if err := credential.ValidateMetadata(head); err != nil {
				return fail(err)
			}
		}
		return writeJSON(credential.RecipientIntersection(heads))
	case "compatible":
		var heads []domain.CredentialMetadata
		if err := decode(&heads); err != nil {
			return fail(err)
		}
		for _, head := range heads {
			if err := credential.ValidateMetadata(head); err != nil {
				return fail(err)
			}
		}
		if !credential.MetadataCompatible(heads) {
			return 1
		}
		return 0
	case "decision":
		if len(arguments) != 0 {
			return fail(errors.New("decision takes no arguments"))
		}
		var heads []domain.CredentialMetadata
		if err := decode(&heads); err != nil {
			return fail(err)
		}
		decision, err := credential.AnalyzeMetadataHeads(heads)
		if err != nil {
			return fail(err)
		}
		return writeJSON(decision)
	case "validate-incoming":
		if len(arguments) != 0 {
			return fail(errors.New("validate-incoming takes no arguments"))
		}
		var input struct {
			Incoming []domain.CredentialMetadata `json:"incoming"`
			Existing []domain.CredentialMetadata `json:"existing"`
		}
		if err := decode(&input); err != nil {
			return fail(err)
		}
		if err := credential.ValidateIncomingRevisions(input.Incoming, input.Existing); err != nil {
			return fail(err)
		}
		return 0
	case "rekey":
		if len(arguments) != 2 || (arguments[1] != "add" && arguments[1] != "remove") {
			return fail(errors.New("rekey needs actor and add or remove"))
		}
		var recipients []string
		if err := decode(&recipients); err != nil {
			return fail(err)
		}
		updated, err := credential.RekeyRecipients(recipients, arguments[0], arguments[1] == "add")
		if err != nil {
			return fail(err)
		}
		return writeJSON(updated)
	case "peer-merge":
		if len(arguments) != 0 {
			return fail(errors.New("peer-merge takes no arguments"))
		}
		var input struct {
			Incoming domain.CredentialPeer  `json:"incoming"`
			Existing *domain.CredentialPeer `json:"existing"`
		}
		if err := decode(&input); err != nil {
			return fail(err)
		}
		merged, err := credential.MergePeer(input.Incoming, input.Existing)
		if err != nil {
			return fail(err)
		}
		return writeJSON(merged)
	case "exclusive-access":
		if len(arguments) != 0 {
			return fail(errors.New("exclusive-access takes no arguments"))
		}
		var input struct {
			Head              domain.CredentialMetadata `json:"head"`
			Actor             string                    `json:"actor"`
			Yard              string                    `json:"yard"`
			AuthorityTrusted  bool                      `json:"authorityTrusted"`
			LastSuccess       int64                     `json:"lastSuccess"`
			Now               int64                     `json:"now"`
			MaximumAgeSeconds int64                     `json:"maximumAgeSeconds"`
		}
		if err := decode(&input); err != nil {
			return fail(err)
		}
		decision, err := credential.CheckExclusiveAccess(input.Head, input.Actor, input.Yard,
			input.AuthorityTrusted, input.LastSuccess, input.Now,
			time.Duration(input.MaximumAgeSeconds)*time.Second)
		if err != nil {
			return fail(err)
		}
		return writeJSON(decision)
	case "move":
		if len(arguments) != 3 {
			return fail(errors.New("move needs authority, assignment and expected epoch"))
		}
		expected, err := strconv.ParseInt(arguments[2], 10, 64)
		if err != nil {
			return fail(err)
		}
		var head domain.CredentialMetadata
		if err := decode(&head); err != nil {
			return fail(err)
		}
		updated, err := credential.MoveAssignment(head, arguments[0], arguments[1], expected)
		if err != nil {
			return fail(err)
		}
		return writeJSON(updated)
	case "retry":
		if len(arguments) != 1 {
			return fail(errors.New("retry needs a failure count"))
		}
		failures, err := strconv.Atoi(arguments[0])
		if err != nil {
			return fail(err)
		}
		fmt.Fprintln(cli.options.Stdout, int64(credential.RetryDelay(failures)/time.Second))
		return 0
	case "sync-next":
		if len(arguments) != 0 {
			return fail(errors.New("sync-next takes no arguments"))
		}
		var input struct {
			Current             domain.CredentialSyncState `json:"current"`
			Peer                string                     `json:"peer"`
			Now                 int64                      `json:"now"`
			Success             bool                       `json:"success"`
			Error               string                     `json:"error"`
			LastHead            string                     `json:"lastHead"`
			SuccessRetrySeconds int64                      `json:"successRetrySeconds"`
		}
		if err := decode(&input); err != nil {
			return fail(err)
		}
		next, err := credential.NextSyncState(input.Current, input.Peer, input.Now, input.Success,
			input.Error, input.LastHead, time.Duration(input.SuccessRetrySeconds)*time.Second)
		if err != nil {
			return fail(err)
		}
		return writeJSON(next)
	case "sync-due":
		if len(arguments) != 2 {
			return fail(errors.New("sync-due needs current epoch and minimum seconds"))
		}
		now, err := strconv.ParseInt(arguments[0], 10, 64)
		if err != nil {
			return fail(err)
		}
		minimum, err := strconv.ParseInt(arguments[1], 10, 64)
		if err != nil {
			return fail(err)
		}
		var state domain.CredentialSyncState
		if err := decode(&state); err != nil {
			return fail(err)
		}
		due, err := credential.SyncDue(state, now, time.Duration(minimum)*time.Second)
		if err != nil {
			return fail(err)
		}
		if !due {
			return 1
		}
		return 0
	default:
		return fail(fmt.Errorf("unknown action %q", action))
	}
}

func (cli *CLI) runMigration(ctx context.Context, arguments []string) int {
	if len(arguments) != 1 || (arguments[0] != "check" && arguments[0] != "apply") {
		cli.errorf("internal: _migrate expects check or apply")
		return 2
	}
	operatorHome := cli.baseEnv["SUBYARD_OPERATOR_HOME"]
	if operatorHome == "" {
		operatorHome = cli.baseEnv["HOME"]
	}
	configHome := cli.baseEnv["SUBYARD_CONFIG_HOME"]
	if configHome == "" {
		configHome = filepath.Join(operatorHome, ".config", "subyard")
	}
	projectDirectories := []string{filepath.Join(configHome, "projects")}
	if explicit := cli.baseEnv["SUBYARD_STATE_DIR"]; explicit != "" {
		projectDirectories = append(projectDirectories, explicit)
	}
	named, _ := filepath.Glob(filepath.Join(configHome, "yards", "*", "projects"))
	projectDirectories = append(projectDirectories, named...)
	keysRoot := cli.baseEnv["SUBYARD_KEYS_ROOT"]
	if keysRoot == "" {
		keysRoot = filepath.Join(configHome, "keys")
	}
	report, err := migration.Check(ctx, projectDirectories, credentialmeta.Reader{Root: keysRoot})
	if err != nil {
		cli.errorf("state migration %s: %v", arguments[0], err)
		return 1
	}
	if err := json.NewEncoder(cli.options.Stdout).Encode(report); err != nil {
		cli.errorf("state migration report: %v", err)
		return 1
	}
	return 0
}

func validStateValue(kind, value string) bool {
	switch kind {
	case "id":
		return domain.SafeID(value)
	case "mode":
		return value == string(domain.ProjectSync) || value == string(domain.ProjectGit) ||
			value == string(domain.ProjectBind)
	case "target":
		return value == "" || value == "yard" || domain.SafeName(value)
	case "name":
		return value != "" && !strings.ContainsAny(value, "\n\t")
	default:
		return false
	}
}

func (cli *CLI) resolveLocalProject(
	ctx context.Context,
	yard domain.Context,
	store ports.ProjectStore,
	selector string,
) (state.Match, error) {
	path := selector
	if !filepath.IsAbs(path) && cli.options.WorkingDir != "" {
		path = filepath.Join(cli.options.WorkingDir, path)
	}
	if _, err := os.Stat(path); err == nil {
		id, err := state.ProjectID(path)
		if err != nil {
			return state.Match{}, err
		}
		record, err := store.Get(ctx, id)
		if err != nil {
			return state.Match{}, fmt.Errorf("%q is not in the yard", filepath.Base(path))
		}
		return state.Match{Yard: yard.YardName, Record: record}, nil
	}
	return (state.Resolver{Stores: map[string]ports.ProjectStore{yard.YardName: store}}).Resolve(ctx, selector)
}

func (cli *CLI) projectStores(ctx context.Context, yard domain.Context) (map[string]ports.ProjectStore, error) {
	names, err := config.YardNames(config.RegistryDirectories(cli.options.RepositoryRoot, yard.Paths.ConfigHome)...)
	if err != nil {
		return nil, err
	}
	stores := make(map[string]ports.ProjectStore, len(names))
	loaded := config.Loaded{Context: yard}
	for _, name := range names {
		contextForYard, err := cli.loadInventoryContext(name, loaded)
		if err != nil {
			return nil, err
		}
		store, err := state.NewFileStore(contextForYard.Paths.StateDir)
		if err != nil {
			return nil, err
		}
		if _, err := store.List(ctx); err != nil {
			return nil, err
		}
		stores[name] = store
	}
	return stores, nil
}

func (cli *CLI) resolveGlobalProject(
	ctx context.Context,
	yard domain.Context,
	selector string,
) (state.Match, error) {
	stores, err := cli.projectStores(ctx, yard)
	if err != nil {
		return state.Match{}, err
	}
	path := selector
	if !filepath.IsAbs(path) && cli.options.WorkingDir != "" {
		path = filepath.Join(cli.options.WorkingDir, path)
	}
	if _, err := os.Stat(path); err == nil {
		id, err := state.ProjectID(path)
		if err != nil {
			return state.Match{}, err
		}
		return (state.Resolver{Stores: stores}).Resolve(ctx, id)
	}
	return (state.Resolver{Stores: stores}).Resolve(ctx, selector)
}

func (cli *CLI) routeSyncProject(
	ctx context.Context,
	yard domain.Context,
	id string,
	explicitTarget string,
) (string, error) {
	stores, err := cli.projectStores(ctx, yard)
	if err != nil {
		return "", err
	}
	if cli.env["SUBYARD_YARD_EXPLICIT"] != "" {
		if explicitTarget != "" && explicitTarget != yard.YardName {
			return "", fmt.Errorf("conflicting yard: context is -Y %s but @%s was given", yard.YardName, explicitTarget)
		}
		return yard.YardName, nil
	}
	if explicitTarget != "" {
		if _, ok := stores[explicitTarget]; !ok {
			return "", fmt.Errorf("unknown yard %q", explicitTarget)
		}
		return explicitTarget, nil
	}
	matches := make([]string, 0)
	for name, store := range stores {
		if _, err := store.Get(ctx, id); err == nil {
			matches = append(matches, name)
		} else if !errors.Is(err, state.ErrNotFound) {
			return "", err
		}
	}
	sort.Strings(matches)
	switch len(matches) {
	case 0:
		return yard.YardName, nil
	case 1:
		return matches[0], nil
	default:
		return "", fmt.Errorf("this path is already in multiple yards (%s) — pick one with @<yard> or -Y <yard>",
			strings.Join(matches, " "))
	}
}

func (cli *CLI) runOwnerProjectState(
	ctx context.Context,
	service state.Service,
	yard domain.Context,
	arguments []string,
) int {
	if len(arguments) == 0 {
		cli.errorf("internal: _project-state expects upsert or unregister")
		return 2
	}
	switch arguments[0] {
	case "upsert":
		if len(arguments) != 5 {
			cli.errorf("internal: _project-state upsert needs <id> <name> <mode> <target>")
			return 2
		}
		if err := service.UpsertYard(ctx, arguments[1], arguments[2], domain.ProjectMode(arguments[3]),
			arguments[4], yard.SSHHost); err != nil {
			cli.errorf("converge owner project state: %v", err)
			return 1
		}
	case "unregister":
		if len(arguments) != 2 {
			cli.errorf("internal: _project-state unregister needs <id>")
			return 2
		}
		if err := service.UnregisterYard(ctx, arguments[1]); err != nil {
			cli.errorf("converge owner project state: %v", err)
			return 1
		}
	default:
		cli.errorf("internal: _project-state expects upsert or unregister")
		return 2
	}
	return 0
}

func (cli *CLI) handlerEnvironment(name, arg0 string) map[string]string {
	return map[string]string{
		"YARD_ENGINE":              Version,
		"SUBYARD_DISPATCH_PATH":    cli.options.DispatcherPath,
		"SUBYARD_DISPATCH_COMMAND": name,
		"SUBYARD_DISPATCH_ARG0":    arg0,
		"SUBYARD_REPOSITORY_ROOT":  cli.options.RepositoryRoot,
	}
}

func (cli *CLI) globalQuery(arguments []string) (int, bool) {
	query := arguments[0]
	switch query {
	case "-h", "--help":
		cli.usage()
		return 0, true
	case "-l", "--list":
		for _, name := range cli.manifest.PublicNames() {
			fmt.Fprintln(cli.options.Stdout, name)
		}
		for _, definition := range cli.resources.Definitions() {
			fmt.Fprintln(cli.options.Stdout, definition.Command)
		}
		return 0, true
	case "--resources":
		for _, definition := range cli.resources.Definitions() {
			fmt.Fprintf(cli.options.Stdout, "%s\t%s\n", definition.Command, strings.Join(definition.Verbs, " "))
		}
		return 0, true
	case "-V", "--version":
		fmt.Fprintf(cli.options.Stdout, "%s %s\n", cli.options.Program, Version)
		return 0, true
	case "--command-manifest":
		for _, definition := range cli.manifest.Commands() {
			fmt.Fprintln(cli.options.Stdout, definition.Row())
		}
		return 0, true
	case "--command-completion", "--command-options", "--command-verbs", "--command-effect":
		if len(arguments) < 2 {
			cli.errorf("%s needs a command", query)
			return 2, true
		}
		definition, ok := cli.manifest.Lookup(arguments[1])
		if !ok {
			return 2, true
		}
		switch query {
		case "--command-completion":
			fmt.Fprintln(cli.options.Stdout, definition.Completion)
		case "--command-options":
			fmt.Fprintln(cli.options.Stdout, strings.Join(definition.Options, " "))
		case "--command-verbs":
			fmt.Fprintln(cli.options.Stdout, strings.Join(definition.Verbs, " "))
		case "--command-effect":
			fmt.Fprintln(cli.options.Stdout, definition.Effect)
		}
		return 0, true
	default:
		if strings.HasPrefix(query, "-") {
			cli.errorf("unknown option %q\nTry %q.", query, cli.options.Program+" --help")
			return 2, true
		}
	}
	return 0, false
}

func (cli *CLI) usage() {
	fmt.Fprintf(cli.options.Stdout, "%s %s — a local yard for isolated project environments.\n\n", cli.options.Program, Version)
	fmt.Fprintf(cli.options.Stdout, "Usage: %s [option] <command> [args]\n\n", cli.options.Program)
	cli.usageSection("Yard lifecycle:", "lifecycle")
	cli.usageSection("Project workflow (default path '.'):", "projects")
	cli.usageSection("Project-env (L2 box; for a project added with --target <profile>):", "project_env")
	cli.usageSection("Remote-yard registry:", "remote")
	if definitions := cli.resources.Definitions(); len(definitions) != 0 {
		fmt.Fprintf(cli.options.Stdout, "Profile resources (long-lived in-yard services; run '%s <cmd> -h' for each):\n", cli.options.Program)
		for _, definition := range definitions {
			fmt.Fprintf(cli.options.Stdout, "  %-9s %s\n            verbs: %s\n", definition.Command, definition.Title, strings.Join(definition.Verbs, " "))
		}
		fmt.Fprintln(cli.options.Stdout)
	}
	fmt.Fprintf(cli.options.Stdout, `  (init runs the phases in scripts/00-05; run those directly only for debugging.)

Named yards:
  Run several independent yards on one host, each with its own instance, /srv, ssh port,
  personal-data mount root and projects. Pick one for a command with -Y/--yard (or the
  sugar '@<name>' as the first token); no selection = the default yard, unchanged. Define a
  yard in private/yards/<name>.env or ~/.config/subyard/yards/<name>.env (SSH_PORT required).
  '%s yards' lists them all.

Remote yards:
  Drive a yard on ANOTHER host as if it were local. '%s remote add <name> <user@host>'
  probes it, registers a context, wires a collision-free ProxyJump ssh identity, authorizes
  your key and verifies the complete data plane before reporting it ready.
  Then '%s -Y <name> <cmd>': lifecycle commands (start/stop/status/provision/logs/shell/...)
  forward over ssh to the owner host with their native prompts; data-plane commands
  (code/sync/export/clone/remove) go straight into the yard. 'bind' is host-local and
  disabled for remote yards. 'remote add' never copies secrets; only a separate confirmed
  'keys trust' permits authorized encrypted ledger records to sync between owner hosts.
  A real in-yard host-key change stays blocked. Verify its fingerprint on the trusted owner
  host, then use 'remote repair-key <name>' for an explicit, context-scoped rotation.
  Subcommands:  remote add <name> <user@host> [--yard <remote-yard>] | remote repair-key <name> | remote remove <name> | remote list

Options:
  -Y, --yard <name>  run the command against a named yard ('@<name>' first-token sugar)
  -h, --help         show this help and exit
  -l, --list         list command names (one per line) and exit
      --resources    list profile-resource commands + verbs and exit
  -V, --version      show version and exit
  -y, --yes          skip a command's confirmation prompt (pass-through)

Run '%s <command> -h' for a command's own help.
`, cli.options.Program, cli.options.Program, cli.options.Program, cli.options.Program)
}

func (cli *CLI) usageSection(title, section string) {
	fmt.Fprintln(cli.options.Stdout, title)
	for _, definition := range cli.manifest.Section(section) {
		fmt.Fprintf(cli.options.Stdout, "  %-20s %s\n", definition.Display, definition.Summary)
	}
	fmt.Fprintln(cli.options.Stdout)
}

func (cli *CLI) loadContext(yard string) (config.Loaded, error) {
	operatorHome := cli.env["SUBYARD_OPERATOR_HOME"]
	if operatorHome == "" {
		operatorHome = cli.env["HOME"]
	}
	loaded, err := config.Load(config.LoadOptions{
		RepositoryRoot: cli.options.RepositoryRoot,
		OperatorHome:   operatorHome,
		YardName:       yard,
		Environment:    cli.env,
	})
	if err != nil {
		return config.Loaded{}, err
	}
	for name, value := range loaded.Environment {
		cli.env[name] = value
	}
	cli.env["SUBYARD_CONFIG_LOADED"] = "1"
	cli.env["SUBYARD_ENGINE_CONTEXT"] = "1"
	return loaded, nil
}

func (cli *CLI) runCommand(ctx context.Context, path string, arguments []string, extra map[string]string) int {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		cli.errorf("command handler is unavailable: %s", path)
		return 2
	}
	command := exec.CommandContext(ctx, path, arguments...)
	command.Dir = cli.options.WorkingDir
	command.Env = environmentList(cli.env, extra)
	command.Stdin = cli.options.Stdin
	command.Stdout = cli.options.Stdout
	command.Stderr = cli.options.Stderr
	if err := command.Run(); err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			return exitError.ExitCode()
		}
		cli.errorf("run command: %v", err)
		return 1
	}
	return 0
}

func (cli *CLI) forwardRemote(ctx context.Context, yardContext domain.Context, name string, arguments []string) int {
	remote := []string{"yard"}
	if yardContext.RemoteYard != "" {
		remote = append(remote, "-Y", yardContext.RemoteYard)
	}
	remote = append(remote, name)
	remote = append(remote, arguments...)
	parts := make([]string, len(remote))
	for index, argument := range remote {
		parts[index] = shellQuote(argument)
	}
	remoteLine := "SUBYARD_OPERATION_ID=" + shellQuote(cli.env["SUBYARD_OPERATION_ID"]) + " " + strings.Join(parts, " ")
	if name == "usage" {
		hint := "yard -Y " + cli.env["SUBYARD_YARD"] + " init"
		remoteLine = "SUBYARD_USAGE_REPAIR_HINT=" + shellQuote(hint) + " " + remoteLine
	}
	return cli.runExternal(ctx, "ssh", []string{"-t", yardContext.RemoteDest, "--", "bash", "-lc", shellQuote(remoteLine)})
}

func (cli *CLI) runExternal(ctx context.Context, program string, arguments []string) int {
	command := exec.CommandContext(ctx, program, arguments...)
	command.Dir = cli.options.WorkingDir
	command.Env = environmentList(cli.env, nil)
	command.Stdin = cli.options.Stdin
	command.Stdout = cli.options.Stdout
	command.Stderr = cli.options.Stderr
	if err := command.Run(); err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			return exitError.ExitCode()
		}
		cli.errorf("run %s: %v", program, err)
		return 1
	}
	return 0
}

func (cli *CLI) audit(commandName string, arguments []string, yard, remote string) {
	home := cli.env["SUBYARD_HOME"]
	if home == "" {
		operatorHome := cli.env["SUBYARD_OPERATOR_HOME"]
		if operatorHome == "" {
			operatorHome = cli.env["HOME"]
		}
		home = filepath.Join(operatorHome, ".subyard")
	}
	_ = audit.WriteInvocation(audit.Invocation{
		Home: home, Command: commandName, Arguments: arguments, WorkingDir: cli.options.WorkingDir,
		Yard: yard, Remote: remote, Maximum: audit.MaximumFrom(cli.env["SUBYARD_AUDIT_MAX_BYTES"]),
		OperationID: cli.env["SUBYARD_OPERATION_ID"],
	})
}

func newOperationID() string {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err == nil {
		return "op-" + hex.EncodeToString(value)
	}
	seed := fmt.Sprintf("%d-%d-%d", os.Getpid(), time.Now().UnixNano(), operationCounter.Add(1))
	hash := sha256.Sum256([]byte(seed))
	return "op-" + hex.EncodeToString(hash[:16])
}

func (cli *CLI) errorf(format string, arguments ...any) {
	fmt.Fprintf(cli.options.Stderr, "%s: ", cli.options.Program)
	fmt.Fprintf(cli.options.Stderr, format, arguments...)
	fmt.Fprintln(cli.options.Stderr)
}

func parseGlobals(arguments []string, inheritedYard string) (yard string, explicit, yes bool, remaining []string, err error) {
	yard = inheritedYard
	for len(arguments) != 0 {
		switch {
		case arguments[0] == "-Y" || arguments[0] == "--yard":
			if len(arguments) < 2 {
				return "", false, false, nil, fmt.Errorf("unknown option %q", arguments[0])
			}
			yard, explicit, arguments = arguments[1], true, arguments[2:]
		case strings.HasPrefix(arguments[0], "--yard="):
			yard, explicit, arguments = strings.TrimPrefix(arguments[0], "--yard="), true, arguments[1:]
		case strings.HasPrefix(arguments[0], "@") && len(arguments[0]) > 1:
			yard, explicit, arguments = strings.TrimPrefix(arguments[0], "@"), true, arguments[1:]
		case arguments[0] == "-y" || arguments[0] == "--yes":
			yes, arguments = true, arguments[1:]
		default:
			if yard == "" {
				yard = "default"
			}
			return yard, explicit, yes, arguments, nil
		}
	}
	if yard == "" {
		yard = "default"
	}
	return yard, explicit, yes, arguments, nil
}

func environmentMap(environment []string) map[string]string {
	values := make(map[string]string)
	for _, pair := range environment {
		name, value, ok := strings.Cut(pair, "=")
		if ok {
			values[name] = value
		}
	}
	return values
}

func environmentList(values map[string]string, extra map[string]string) []string {
	merged := make(map[string]string, len(values)+len(extra))
	for key, value := range values {
		merged[key] = value
	}
	for key, value := range extra {
		merged[key] = value
	}
	keys := make([]string, 0, len(merged))
	for key := range merged {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	environment := make([]string, 0, len(keys))
	for _, key := range keys {
		environment = append(environment, key+"="+merged[key])
	}
	return environment
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func (cli *CLI) serveRPC(ctx context.Context, yard string, arguments []string) int {
	if len(arguments) != 1 || arguments[0] != "--stdio" {
		cli.errorf("rpc requires exactly --stdio")
		return 2
	}
	loaded, err := cli.loadContext(yard)
	if err != nil {
		cli.errorf("load RPC context: %v", err)
		return 2
	}
	handler := &rpcHandler{cli: cli, loaded: loaded}
	session := rpc.Session{Handler: handler, EngineVersion: Version, Capabilities: []string{
		"snapshot", "ordered-events", "cancellation", "deadlines", "commands", "context",
		"projects", "yard-status", "credential-metadata", "credential-status",
	}, DrainOnEOF: true}
	if err := session.Serve(ctx, cli.options.Stdin, cli.options.Stdout); err != nil {
		if !errors.Is(err, io.EOF) && !errors.Is(err, context.Canceled) {
			cli.errorf("RPC session: %v", err)
			return 1
		}
	}
	return 0
}

type rpcHandler struct {
	cli    *CLI
	loaded config.Loaded
}

type rpcProjectList struct {
	Projects    []domain.ProjectRecord    `json:"projects"`
	Observation domain.ProjectObservation `json:"observation"`
}

type rpcSnapshot struct {
	Revision         uint64                      `json:"revision"`
	Context          domain.Context              `json:"context"`
	Commands         []map[string]any            `json:"commands"`
	Projects         rpcProjectList              `json:"projects"`
	Status           domain.YardStatus           `json:"status"`
	Credentials      []domain.CredentialMetadata `json:"credentials"`
	CredentialStatus domain.CredentialStatus     `json:"credentialStatus"`
}

func (handler *rpcHandler) Handle(ctx context.Context, call rpc.Call, emit rpc.Emit) (any, error) {
	switch call.Method {
	case "command.list":
		return handler.commands(), nil
	case "context.get":
		return handler.loaded.Context, nil
	case "operation.route":
		var params struct {
			Command string `json:"command"`
		}
		if err := decodeRPCParams(call.Params, &params); err != nil {
			return nil, err
		}
		definition, ok := handler.cli.manifest.Lookup(params.Command)
		if !ok || definition.Visibility != command.VisibilityPublic {
			return nil, &rpc.Error{Code: "command_not_found", Message: params.Command}
		}
		target, err := application.Route(handler.loaded.Context, domain.RemotePolicy(definition.Remote))
		if err != nil {
			return nil, &rpc.Error{Code: "route_denied", Message: err.Error()}
		}
		return map[string]any{
			"operationId": call.OperationID, "command": definition.Name, "effect": definition.Effect,
			"target": target, "summary": definition.Summary,
		}, nil
	case "project.list":
		var params struct {
			Live bool `json:"live"`
		}
		if err := decodeRPCParams(call.Params, &params); err != nil {
			return nil, err
		}
		return handler.projects(ctx, params.Live)
	case "yard.status":
		if err := decodeRPCParams(call.Params, &struct{}{}); err != nil {
			return nil, err
		}
		return handler.status(ctx)
	case "credential.list":
		if err := decodeRPCParams(call.Params, &struct{}{}); err != nil {
			return nil, err
		}
		return handler.credentials().ListMetadata(ctx)
	case "credential.status":
		if err := decodeRPCParams(call.Params, &struct{}{}); err != nil {
			return nil, err
		}
		return handler.credentialStatus(ctx)
	case "incus.events":
		var params struct {
			Types []string `json:"types"`
		}
		if err := decodeRPCParams(call.Params, &params); err != nil {
			return nil, err
		}
		if len(params.Types) == 0 {
			params.Types = []string{"lifecycle", "operation"}
		}
		if len(params.Types) > 8 {
			return nil, &rpc.Error{Code: "invalid_params", Message: "too many Incus event types"}
		}
		for _, eventType := range params.Types {
			if !domain.SafeName(eventType) {
				return nil, &rpc.Error{Code: "invalid_params", Message: "invalid Incus event type"}
			}
		}
		incusPort, _ := handler.cli.statusPorts()
		events, errorsOut := incusPort.Events(ctx, params.Types)
		for events != nil || errorsOut != nil {
			select {
			case event, ok := <-events:
				if !ok {
					events = nil
					continue
				}
				if _, err := emit("incus."+event.Kind, event); err != nil {
					return nil, err
				}
			case streamErr, ok := <-errorsOut:
				if !ok {
					errorsOut = nil
					continue
				}
				if streamErr != nil {
					return nil, &rpc.Error{Code: "incus_disconnected", Message: streamErr.Error()}
				}
			case <-ctx.Done():
				return nil, context.Cause(ctx)
			}
		}
		return map[string]any{"closed": true}, nil
	case "system.snapshot":
		if err := decodeRPCParams(call.Params, &struct{}{}); err != nil {
			return nil, err
		}
		projects, err := handler.projects(ctx, false)
		if err != nil {
			return nil, err
		}
		status, err := handler.status(ctx)
		if err != nil {
			return nil, err
		}
		credentials, err := handler.credentials().ListMetadata(ctx)
		if err != nil {
			return nil, err
		}
		credentialStatus, err := handler.credentialStatus(ctx)
		if err != nil {
			return nil, err
		}
		snapshot := rpcSnapshot{
			Context: handler.loaded.Context, Commands: handler.commands(), Projects: projects,
			Status: status, Credentials: credentials, CredentialStatus: credentialStatus,
		}
		revision, err := emit("snapshot.ready", map[string]any{"complete": true})
		if err != nil {
			return nil, err
		}
		snapshot.Revision = revision
		return snapshot, nil
	case "system.ping":
		if _, err := emit("operation.started", map[string]any{"method": call.Method}); err != nil {
			return nil, err
		}
		if _, err := emit("operation.finished", map[string]any{"method": call.Method}); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil
	default:
		return nil, &rpc.Error{Code: "method_not_found", Message: call.Method}
	}
}

func (handler *rpcHandler) commands() []map[string]any {
	definitions := handler.cli.manifest.Commands()
	result := make([]map[string]any, 0, len(definitions))
	for _, definition := range definitions {
		if definition.Visibility != command.VisibilityPublic {
			continue
		}
		result = append(result, map[string]any{
			"name": definition.Name, "aliases": definition.Aliases, "effect": definition.Effect,
			"remote": definition.Remote, "summary": definition.Summary,
			"options": definition.Options, "verbs": definition.Verbs,
		})
	}
	return result
}

func (handler *rpcHandler) projects(ctx context.Context, live bool) (rpcProjectList, error) {
	store, err := state.NewFileStore(handler.loaded.Context.Paths.StateDir)
	if err != nil {
		return rpcProjectList{}, err
	}
	inventory := application.ProjectInventory{Store: store}
	if live {
		inventory.Observer = handler.cli.projectObserver()
	}
	records, observation, err := inventory.Read(ctx, handler.loaded.Context, live)
	return rpcProjectList{Projects: records, Observation: observation}, err
}

func (handler *rpcHandler) status(ctx context.Context) (domain.YardStatus, error) {
	store, err := state.NewFileStore(handler.loaded.Context.Paths.StateDir)
	if err != nil {
		return domain.YardStatus{}, err
	}
	incusPort, executor := handler.cli.statusPorts()
	return (application.StatusService{
		Incus: incusPort, Executor: executor, Store: store,
		Facts: handler.cli.statusFacts(handler.loaded),
	}).Read(ctx, handler.loaded.Context)
}

func (handler *rpcHandler) credentials() ports.CredentialMetadataReader {
	if handler.cli.options.Credentials != nil {
		return handler.cli.options.Credentials
	}
	root := handler.loaded.Environment["SUBYARD_KEYS_ROOT"]
	if root == "" {
		root = filepath.Join(handler.loaded.Context.Paths.ConfigHome, "keys")
	}
	return credentialmeta.Reader{Root: root}
}

func (handler *rpcHandler) credentialStatus(ctx context.Context) (domain.CredentialStatus, error) {
	reader := handler.credentials()
	if statusReader, ok := reader.(ports.CredentialStatusReader); ok {
		return statusReader.ReadCredentialStatus(ctx)
	}
	metadata, err := reader.ListMetadata(ctx)
	if err != nil {
		return domain.CredentialStatus{}, err
	}
	summaries, err := credential.Summarize(metadata)
	if err != nil {
		return domain.CredentialStatus{}, err
	}
	return domain.CredentialStatus{Credentials: summaries, Peers: []domain.CredentialPeerStatus{}}, nil
}

func decodeRPCParams(raw json.RawMessage, target any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return &rpc.Error{Code: "invalid_params", Message: err.Error()}
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return &rpc.Error{Code: "invalid_params", Message: "params have trailing data"}
	}
	return nil
}
