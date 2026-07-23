package cli

import (
	"bufio"
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
	"sync"
	"sync/atomic"
	"time"

	"github.com/Dmitry-Borodin/Subyard/internal/adapters/credentialmeta"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/incusclient"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/projectruntime"
	"github.com/Dmitry-Borodin/Subyard/internal/adapters/shelladapter"
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
	"golang.org/x/crypto/ssh"
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
	ProjectData     ports.YardExecutor
	ProjectDevices  ports.InstanceDeviceManager
	ProjectArchive  ports.DirectoryArchiver
	ProjectObserver ports.ProjectObserver
	StatusFacts     ports.StatusFactsReader
	Credentials     ports.CredentialMetadataReader
	AdapterRunner   ports.AdapterRunner
	RemoteControl   ports.RemoteControl
	Prompt          ports.Prompter
	Clock           ports.Clock
	Audit           ports.AuditSink
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
	var projectRun *projectExecution
	var remoteRun *domain.RemotePrepared
	if !commandHelpRequested(commandArguments) {
		projectRun, err = cli.prepareProjectExecution(ctx, loaded, definition, commandArguments, explicit)
		if err != nil {
			cli.errorf("prepare %s: %v", name, err)
			return 1
		}
		if definition.Name == "remote" {
			remoteRun, err = cli.prepareRemoteExecution(ctx, loaded, commandArguments)
			if err != nil {
				cli.errorf("prepare remote: %v", err)
				return 1
			}
		}
	}
	if projectRun != nil {
		loaded = projectRun.Loaded
		loadedContext = loaded.Context
		commandArguments = projectRun.Arguments
		for key, value := range projectRun.Environment {
			cli.env[key] = value
		}
	}
	remote := ""
	if loadedContext.YardType == domain.YardRemote {
		remote = loadedContext.RemoteDest
	}
	if name != "_info" && cli.env["SUBYARD_NO_AUDIT"] == "" {
		cli.audit(name, commandArguments, yard, remote)
	}
	if core && definition.Name == "start" {
		return cli.runStructuredStart(ctx, loaded, definition, commandArguments,
			yes || cli.env["ASSUME_YES"] == "1")
	}
	if core && definition.Effect == command.EffectMutate && structuredCommandSupported(definition.Name) &&
		!commandHelpRequested(commandArguments) {
		return cli.runStructuredCommand(ctx, loaded, definition, commandArguments,
			yes || cli.env["ASSUME_YES"] == "1", projectRun, remoteRun)
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
	case "@info":
		return cli.runOwnerInfo(ctx, loaded)
	case "@yards":
		return cli.runYards(ctx, loaded, commandArguments)
	case "@authorize":
		return cli.runAuthorize(ctx, loaded, commandArguments)
	case "@logs":
		return cli.runLogs(ctx, loaded, commandArguments)
	case "@usage":
		return cli.runUsage(ctx, loaded, commandArguments)
	case "@shell":
		return cli.runShell(ctx, loaded, commandArguments, projectRun)
	case "@list":
		return cli.runProjectList(ctx, loaded, explicit, commandArguments)
	case "@state":
		return cli.runProjectState(ctx, loadedContext, commandArguments, false)
	case "@project-state":
		return cli.runProjectState(ctx, loadedContext, commandArguments, true)
	case "@remote":
		fmt.Fprintf(cli.options.Stdout, "Usage: %s remote add <name> <user@host> [--yard <yard>] | repair-key <name> | remove <name> | list\n", cli.options.Program)
		return 0
	case "@project":
		fmt.Fprintf(cli.options.Stdout, "Usage: %s %s\n", cli.options.Program, definition.Display)
		return 0
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
	code := cli.runCommand(ctx, path, handlerArguments, cli.handlerEnvironment(definition.Name, definition.Arg0))
	if code == 0 && projectRun != nil {
		if err := cli.commitProjectExecution(ctx, projectRun); err != nil {
			cli.errorf("commit %s: %v", name, err)
			return 1
		}
	}
	return code
}

func (cli *CLI) projectObserver() ports.ProjectObserver {
	if cli.options.ProjectObserver != nil {
		return cli.options.ProjectObserver
	}
	incusPort, executor := cli.statusPorts()
	return projectruntime.Runtime{Incus: incusPort, Executor: executor}
}

func (cli *CLI) projectDataPlane() ports.YardExecutor {
	if cli.options.ProjectData != nil {
		return cli.options.ProjectData
	}
	_, executor := cli.statusPorts()
	streamer, _ := executor.(ports.InstanceStreamExecutor)
	return projectruntime.Runtime{
		Executor: executor, Streamer: streamer,
		Environment: environmentList(cli.env, nil), Timeout: 10 * time.Minute,
	}
}

func (cli *CLI) projectArchiver() ports.DirectoryArchiver {
	if cli.options.ProjectArchive != nil {
		return cli.options.ProjectArchive
	}
	return projectruntime.TarArchiver{Environment: environmentList(cli.env, nil)}
}

func (cli *CLI) projectDeviceManager() ports.InstanceDeviceManager {
	if cli.options.ProjectDevices != nil {
		return cli.options.ProjectDevices
	}
	incusPort, _ := cli.statusPorts()
	manager, _ := incusPort.(ports.InstanceDeviceManager)
	return manager
}

func openProjectStore(ctx context.Context, directory string) (*state.FileStore, error) {
	store, err := state.NewFileStore(directory)
	if err != nil {
		return nil, err
	}
	if _, err := store.RepairLegacyPermissions(ctx); err != nil {
		return nil, err
	}
	return store, nil
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
		loaded.Context.Paths.ConfigDir, loaded.Context.Paths.ConfigHome,
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
	store, err := openProjectStore(ctx, loaded.Context.Paths.StateDir)
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

type ownerInfo = domain.RemoteInfo

func (cli *CLI) runOwnerInfo(ctx context.Context, loaded config.Loaded) int {
	yard := loaded.Context
	info := ownerInfo{
		Name: yard.YardName, Type: string(domain.YardLocal), Version: Version,
		Instance: yard.InstanceName, Project: yard.IncusProject, State: "UNKNOWN",
		SSHHost: yard.SSHHost, SSHPort: yard.SSHPort, DevUser: yard.DevUser,
	}
	incusPort, _ := cli.statusPorts()
	if _, err := incusPort.Server(ctx); err == nil {
		info.State = "STOPPED"
		if instance, instanceErr := incusPort.Instance(ctx, yard.IncusProject, yard.InstanceName); instanceErr == nil {
			if state := strings.ToUpper(strings.TrimSpace(instance.Status)); state != "" {
				info.State = state
			}
		}
	}
	if info.State == "RUNNING" {
		observation, err := cli.projectObserver().Observe(ctx, yard, nil, true)
		if err == nil && observation.Reached {
			ids := make(map[string]struct{}, len(observation.Live))
			for _, record := range observation.Live {
				ids[record.ProjectID] = struct{}{}
			}
			count := len(ids)
			info.Projects = &count
		}
	}
	if err := json.NewEncoder(cli.options.Stdout).Encode(info); err != nil {
		cli.errorf("write owner info: %v", err)
		return 1
	}
	return 0
}

func (cli *CLI) runYards(ctx context.Context, loaded config.Loaded, arguments []string) int {
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
		case "-h", "--help":
			fmt.Fprintf(cli.options.Stdout, "Usage: %s yards\n", cli.options.Program)
			return 0
		default:
			cli.errorf("yards takes no arguments")
			return 2
		}
	}
	names, err := config.YardNames(config.RegistryDirectories(
		loaded.Context.Paths.ConfigDir, loaded.Context.Paths.ConfigHome,
	)...)
	if err != nil {
		cli.errorf("discover yards: %v", err)
		return 1
	}
	fmt.Fprintf(cli.options.Stdout, "%-14s %-6s %-16s %-9s %-7s %-8s %s\n",
		"NAME", "TYPE", "INSTANCE", "STATE", "SSH", "PROJECTS", "SIZE")
	for _, name := range names {
		selected := loaded
		if name != loaded.Context.YardName {
			selected, err = cli.loadInventoryLoaded(name, loaded)
			if err != nil {
				cli.errorf("load yard %q: %v", name, err)
				continue
			}
		}
		yard := selected.Context
		if yard.YardType == domain.YardRemote {
			info, age, observeErr := cli.observeRemoteInfo(ctx, yard)
			if observeErr != nil {
				cli.errorf("remote yard %q: %v", yard.YardName, observeErr)
				continue
			}
			stateValue := info.State
			if stateValue == "" {
				stateValue = "?"
			}
			projects := "-"
			if info.Projects != nil {
				projects = strconv.Itoa(*info.Projects)
			}
			marker := ""
			if age != "" {
				marker = "  (seen " + age + " ago)"
			}
			fmt.Fprintf(cli.options.Stdout, "%-14s %-6s %-16s %-9s %-7s %-8s %s%s\n",
				yard.YardName, "remote", yard.InstanceName, stateValue,
				"yard-"+yard.YardName, projects, "-", marker)
			continue
		}
		stateValue := "-"
		incusPort, _ := cli.statusPorts()
		if instance, instanceErr := incusPort.Instance(ctx, yard.IncusProject, yard.InstanceName); instanceErr == nil {
			if value := strings.ToUpper(strings.TrimSpace(instance.Status)); value != "" {
				stateValue = value
			}
		}
		projects := "-"
		if store, storeErr := openProjectStore(ctx, yard.Paths.StateDir); storeErr == nil {
			if records, listErr := store.List(ctx); listErr == nil {
				projects = strconv.Itoa(len(records))
			}
		}
		sshPort := "-"
		if yard.SSHPort > 0 {
			sshPort = strconv.Itoa(yard.SSHPort)
		}
		fmt.Fprintf(cli.options.Stdout, "%-14s %-6s %-16s %-9s %-7s %-8s %s\n",
			yard.YardName, "local", yard.InstanceName, stateValue, sshPort, projects,
			cachedYardSize(yard))
	}
	return 0
}

func cachedYardSize(yard domain.Context) string {
	name := "space.cache"
	if yard.YardName != "default" {
		name = "space-" + yard.YardName + ".cache"
	}
	payload, err := os.ReadFile(filepath.Join(yard.Paths.DataHome, name))
	if err != nil {
		return "-"
	}
	fields := strings.Fields(string(payload))
	if len(fields) == 0 {
		return "-"
	}
	return fields[0]
}

func (cli *CLI) runAuthorize(ctx context.Context, loaded config.Loaded, arguments []string) int {
	if len(arguments) != 0 {
		cli.errorf("_authorize takes no arguments")
		return 2
	}
	scanner := bufio.NewScanner(cli.options.Stdin)
	publicKey := ""
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line != "" && !strings.HasPrefix(line, "#") {
			publicKey = line
			break
		}
	}
	if err := scanner.Err(); err != nil {
		cli.errorf("_authorize: read public key: %v", err)
		return 1
	}
	if _, _, _, rest, err := ssh.ParseAuthorizedKey([]byte(publicKey)); err != nil || len(bytes.TrimSpace(rest)) != 0 {
		cli.errorf("_authorize: stdin does not contain a supported SSH public key")
		return 2
	}
	yard := loaded.Context
	incusPort, executor := cli.statusPorts()
	instance, err := incusPort.Instance(ctx, yard.IncusProject, yard.InstanceName)
	if err != nil {
		cli.errorf("_authorize: instance %q is unavailable: %v", yard.InstanceName, err)
		return 1
	}
	if !strings.EqualFold(instance.Status, "running") {
		cli.errorf("_authorize: yard %q is not running", yard.InstanceName)
		return 1
	}
	result, err := executor.Exec(ctx, yard.IncusProject, yard.InstanceName, ports.InstanceExecRequest{
		Command: []string{"sh", "-eu", "-c", `
home="$(getent passwd "$DEV_USER" | cut -d: -f6)"
[ -n "$home" ]
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "$home/.ssh"
ak="$home/.ssh/authorized_keys"
touch "$ak"
if grep -qxF "$PUBKEY" "$ak"; then printf already; else printf '%s\n' "$PUBKEY" >> "$ak"; printf added; fi
chmod 600 "$ak"
chown "$DEV_USER:$DEV_USER" "$ak"`},
		Environment: map[string]string{"PUBKEY": publicKey, "DEV_USER": yard.DevUser},
	})
	if err != nil || result.ExitCode != 0 {
		cli.errorf("_authorize: could not update authorized_keys")
		return 1
	}
	action := strings.TrimSpace(string(result.Stdout))
	if action != "added" && action != "already" {
		cli.errorf("_authorize: unexpected guest result")
		return 1
	}
	message := "authorized"
	if action == "already" {
		message = "already authorized"
	}
	fmt.Fprintf(cli.options.Stderr, "  [ ok ] controller key %s for %s in %s\n",
		message, yard.DevUser, yard.InstanceName)
	return 0
}

func (cli *CLI) runLogs(ctx context.Context, loaded config.Loaded, arguments []string) int {
	journalArguments, help, err := parseLogArguments(arguments)
	if err != nil {
		cli.errorf("logs: %v", err)
		return 2
	}
	if help {
		fmt.Fprintf(cli.options.Stdout, "Usage: %s logs [-f] [-n LINES] [UNIT]\n", cli.options.Program)
		return 0
	}
	yard := loaded.Context
	incusPort, _ := cli.statusPorts()
	instance, err := incusPort.Instance(ctx, yard.IncusProject, yard.InstanceName)
	if err != nil {
		cli.errorf("logs: instance %q is unavailable: %v", yard.InstanceName, err)
		return 1
	}
	if !strings.EqualFold(instance.Status, "running") {
		cli.errorf("logs: yard is not running")
		return 1
	}
	commandArguments := []string{"exec", yard.InstanceName, "--project", yard.IncusProject, "--"}
	commandArguments = append(commandArguments, journalArguments...)
	return cli.runExternal(ctx, "incus", commandArguments)
}

func parseLogArguments(arguments []string) ([]string, bool, error) {
	follow := false
	lines := 200
	unit := ""
	for index := 0; index < len(arguments); index++ {
		switch argument := arguments[index]; argument {
		case "-f":
			follow = true
		case "-n":
			index++
			if index >= len(arguments) {
				return nil, false, errors.New("-n needs a positive number")
			}
			value, err := strconv.Atoi(arguments[index])
			if err != nil || value < 1 {
				return nil, false, errors.New("-n needs a positive number")
			}
			lines = value
		case "-y", "--yes":
		case "-h", "--help":
			return nil, true, nil
		default:
			if strings.HasPrefix(argument, "-") {
				return nil, false, fmt.Errorf("unknown option %q", argument)
			}
			if unit != "" {
				return nil, false, errors.New("logs accepts at most one unit")
			}
			unit = argument
		}
	}
	result := []string{"journalctl", "-n", strconv.Itoa(lines)}
	if unit != "" {
		result = append(result, "-u", unit)
	}
	if follow {
		result = append(result, "-f")
	} else {
		result = append(result, "--no-pager")
	}
	return result, false, nil
}

func (cli *CLI) runUsage(ctx context.Context, loaded config.Loaded, arguments []string) int {
	filtered := make([]string, 0, len(arguments))
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
		case "-h", "--help":
			fmt.Fprintf(cli.options.Stdout, "Usage: %s usage [CCUSAGE ARG...]\n", cli.options.Program)
			return 0
		default:
			filtered = append(filtered, argument)
		}
	}
	yard := loaded.Context
	if !cli.incusCLIYardRunning(ctx, yard) {
		cli.errorf("usage: yard is not running")
		return 1
	}
	probe := exec.CommandContext(ctx, "incus", "exec", yard.InstanceName, "--project", yard.IncusProject,
		"--", "sh", "-eu", "-c", "[ -f /usr/local/bin/ccusage ] && [ ! -L /usr/local/bin/ccusage ] && [ -x /usr/local/bin/ccusage ]")
	probe.Env = environmentList(cli.env, nil)
	if err := probe.Run(); err != nil {
		hint := cli.env["SUBYARD_USAGE_REPAIR_HINT"]
		if hint == "" {
			hint = cli.yardHint(yard) + " init"
		}
		cli.errorf("usage: /usr/local/bin/ccusage is missing or not executable; repair with: %s", hint)
		return 1
	}
	home := "/home/" + yard.DevUser
	commandArguments := []string{
		"exec", yard.InstanceName, "--project", yard.IncusProject,
		"--user", strconv.Itoa(yard.DevUID), "--group", strconv.Itoa(yard.DevUID),
		"--cwd", home, "--env", "HOME=" + home, "--env", "USER=" + yard.DevUser,
		"--", "/usr/local/bin/ccusage",
	}
	commandArguments = append(commandArguments, filtered...)
	return cli.runExternal(ctx, "incus", commandArguments)
}

func (cli *CLI) runShell(
	ctx context.Context,
	loaded config.Loaded,
	arguments []string,
	project *projectExecution,
) int {
	root, selector, guestCommand, help, err := parseShellArguments(arguments)
	if err != nil {
		cli.errorf("shell: %v", err)
		return 2
	}
	if help {
		fmt.Fprintf(cli.options.Stdout,
			"Usage: %s shell [--root] [PROJECT] [-- COMMAND...]\n", cli.options.Program)
		return 0
	}
	yard := loaded.Context
	home := "/home/" + yard.DevUser
	cwd := home
	if selector != "" {
		if project == nil || project.Record.YardPath == "" {
			cli.errorf("shell: project %q has no yard path", selector)
			return 1
		}
		cwd = project.Record.YardPath
	}
	if !cli.incusCLIYardRunning(ctx, yard) {
		cli.errorf("shell: yard is not running - start it: %s start", cli.yardHint(yard))
		return 1
	}
	cli.autoSyncCredentials(ctx, loaded)
	uid := yard.DevUID
	userArguments := []string{
		"--user", strconv.Itoa(uid), "--group", strconv.Itoa(uid), "--env", "HOME=" + home,
	}
	if root {
		userArguments = []string{"--user", "0", "--group", "0", "--env", "HOME=/root"}
	}
	commandArguments := []string{"exec", yard.InstanceName, "--project", yard.IncusProject}
	commandArguments = append(commandArguments, userArguments...)
	commandArguments = append(commandArguments, "--cwd", cwd)
	if len(guestCommand) == 0 {
		commandArguments = append(commandArguments, "-t", "--", "bash", "-l")
	} else {
		commandArguments = append(commandArguments, "--")
		commandArguments = append(commandArguments, guestCommand...)
	}
	return cli.runExternal(ctx, "incus", commandArguments)
}

func (cli *CLI) incusCLIYardRunning(ctx context.Context, yard domain.Context) bool {
	command := exec.CommandContext(ctx, "incus", "list", yard.InstanceName,
		"--project", yard.IncusProject, "-f", "csv", "-c", "s")
	command.Env = environmentList(cli.env, nil)
	state, err := command.Output()
	return err == nil && strings.EqualFold(strings.TrimSpace(string(state)), "running")
}

func parseShellArguments(arguments []string) (root bool, selector string, command []string, help bool, err error) {
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		switch argument {
		case "-y", "--yes":
		case "-h", "--help":
			return false, "", nil, true, nil
		case "--root":
			root = true
		case "--":
			return root, selector, append([]string(nil), arguments[index+1:]...), false, nil
		default:
			if strings.HasPrefix(argument, "-") {
				return false, "", nil, false, fmt.Errorf("unknown option %q", argument)
			}
			if selector != "" {
				return false, "", nil, false,
					errors.New("only one project may be selected; put commands after '--'")
			}
			selector = argument
		}
	}
	return root, selector, nil, false, nil
}

func (cli *CLI) autoSyncCredentials(ctx context.Context, loaded config.Loaded) {
	identity := filepath.Join(cli.env["SUBYARD_CONFIG_HOME"], "keys", "identity.json")
	if root := cli.env["SUBYARD_KEYS_ROOT"]; root != "" {
		identity = filepath.Join(root, "identity.json")
	}
	if info, err := os.Stat(identity); err != nil || !info.Mode().IsRegular() {
		return
	}
	timeout := 8 * time.Second
	if raw := cli.env["SUBYARD_KEYS_CONNECT_TIMEOUT"]; raw != "" {
		if seconds, err := strconv.Atoi(raw); err == nil && seconds > 0 {
			timeout = time.Duration(seconds) * time.Second
		}
	}
	syncContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	arguments := make([]string, 0, 5)
	if loaded.Context.YardName != "default" {
		arguments = append(arguments, "-Y", loaded.Context.YardName)
	}
	arguments = append(arguments, "_keys-auto-sync", "--if-due")
	command := exec.CommandContext(syncContext, cli.options.DispatcherPath, arguments...)
	command.Dir = cli.options.WorkingDir
	command.Env = environmentList(cli.env, nil)
	if err := command.Run(); err != nil {
		fmt.Fprintln(cli.options.Stderr,
			"warning: opportunistic encrypted-credential sync did not complete; the periodic timer will retry")
	}
}

func (cli *CLI) yardHint(yard domain.Context) string {
	if yard.YardName == "default" {
		return cli.options.Program
	}
	return fmt.Sprintf("%s -Y %s", cli.options.Program, yard.YardName)
}

func (cli *CLI) printRemoteStatus(ctx context.Context, yard domain.Context) error {
	info, age, err := cli.observeRemoteInfo(ctx, yard)
	if err != nil {
		return err
	}
	stateValue := info.State
	if stateValue == "" {
		stateValue = "?"
	}
	projects := "?"
	if info.Projects != nil {
		projects = strconv.Itoa(*info.Projects)
	}
	marker := ""
	if age != "" {
		marker = ", seen " + age + " ago"
	}
	fmt.Fprintf(cli.options.Stdout, "%s  %s  (remote %s, %s projects%s)\n",
		yard.YardName, stateValue, yard.RemoteDest, projects, marker)
	return nil
}

func (cli *CLI) observeRemoteInfo(ctx context.Context, yard domain.Context) (domain.RemoteInfo, string, error) {
	info, cachedAt, err := cli.remoteControl(config.Loaded{Context: yard}, 2*time.Second).ObserveOwner(ctx,
		domain.RemoteSpec{Name: yard.YardName, Destination: yard.RemoteDest, OwnerYard: yard.RemoteYard})
	if err != nil || cachedAt.IsZero() {
		return info, "", err
	}
	return info, ageHuman(time.Since(cachedAt)), nil
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
		loaded.Context.Paths.ConfigDir, loaded.Context.Paths.ConfigHome,
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
	store, err := openProjectStore(ctx, yard.Paths.StateDir)
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
		store, err := openProjectStore(ctx, yard.Paths.StateDir)
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
	store, err := openProjectStore(ctx, yard.Paths.StateDir)
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
	var report migration.Report
	var err error
	if arguments[0] == "apply" {
		report, err = migration.Apply(ctx, projectDirectories, credentialmeta.Reader{Root: keysRoot})
	} else {
		report, err = migration.Check(ctx, projectDirectories, credentialmeta.Reader{Root: keysRoot})
	}
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
	names, err := config.YardNames(config.RegistryDirectories(yard.Paths.ConfigDir, yard.Paths.ConfigHome)...)
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
		store, err := openProjectStore(ctx, contextForYard.Paths.StateDir)
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
		"YARD_VERSION":             Version,
		"SUBYARD_DISPATCH_PATH":    cli.options.DispatcherPath,
		"SUBYARD_DISPATCH_COMMAND": name,
		"SUBYARD_DISPATCH_ARG0":    arg0,
		"SUBYARD_REPOSITORY_ROOT":  cli.options.RepositoryRoot,
	}
}

type wallClock struct{}

func (wallClock) Now() time.Time                             { return time.Now() }
func (wallClock) After(delay time.Duration) <-chan time.Time { return time.After(delay) }

type fixedIDSource struct{ value string }

func (source fixedIDSource) NewID() string { return source.value }

type streamPrompt struct {
	input  io.Reader
	output io.Writer
}

func (prompt streamPrompt) Confirm(_ context.Context, summary string, consequences []string) (bool, error) {
	fmt.Fprintf(prompt.output, "\n%s\nThis will:\n", summary)
	for _, consequence := range consequences {
		fmt.Fprintf(prompt.output, "  - %s\n", consequence)
	}
	fmt.Fprint(prompt.output, "\nProceed? [y/N] ")
	answer, err := bufio.NewReader(prompt.input).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false, err
	}
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true, nil
	default:
		return false, nil
	}
}

type rpcOperationEvents struct{ emit rpc.Emit }

func (events rpcOperationEvents) Publish(_ context.Context, event domain.OperationEvent) error {
	_, err := events.emit(event.Kind, event)
	return err
}

func (cli *CLI) operationOrchestrator(
	operationID string,
	loaded config.Loaded,
	events ports.EventSink,
	definition *command.Definition,
) *application.Orchestrator {
	clock := cli.options.Clock
	if clock == nil {
		clock = wallClock{}
	}
	prompt := cli.options.Prompt
	if prompt == nil {
		prompt = streamPrompt{input: cli.options.Stdin, output: cli.options.Stdout}
	}
	runner := cli.options.AdapterRunner
	if runner == nil {
		contextValues := structuredCommandContext(loaded)
		contextKeys := make(map[string]struct{}, len(contextValues))
		for key := range contextValues {
			contextKeys[key] = struct{}{}
		}
		for _, key := range []string{
			"SUBYARD_PROJECT_SNAPSHOT", "SUBYARD_PROJECT_ID", "SUBYARD_PROJECT_NAME",
			"SUBYARD_PROJECT_HOST_PATH", "SUBYARD_PROJECT_YARD_PATH", "SUBYARD_PROJECT_MODE",
			"SUBYARD_PROJECT_SSH_HOST", "SUBYARD_PROJECT_TARGET", "SUBYARD_PROJECT_PROFILE",
			"SUBYARD_PROJECT_DEVICE", "SUBYARD_PROJECT_EXISTS", "SUBYARD_PROJECT_PROFILES",
			"SUBYARD_PROJECT_REMOVE_SOFT", "SUBYARD_PROJECT_REBUILD",
			"SUBYARD_SUDO_PREAUTHORIZED",
		} {
			contextKeys[key] = struct{}{}
		}
		actions := map[string]map[string]shelladapter.Action{}
		if definition != nil {
			actions["command"] = map[string]shelladapter.Action{
				definition.Name: {
					Path: filepath.Join(cli.options.RepositoryRoot, "scripts", definition.Handler), Direct: true,
				},
			}
		}
		runner = shelladapter.Runner{
			RepositoryRoot: cli.options.RepositoryRoot,
			Actions:        actions,
			ContextKeys:    contextKeys,
			Diagnostics:    cli.options.Stderr,
			Timeout:        10 * time.Minute,
		}
	}
	auditSink := cli.options.Audit
	if auditSink == nil && cli.env["SUBYARD_NO_AUDIT"] == "" {
		home := cli.env["SUBYARD_HOME"]
		if home == "" {
			home = loaded.Context.Paths.DataHome
		}
		auditSink = audit.OperationLog{
			Home: home, WorkingDir: cli.options.WorkingDir, Yard: loaded.Context.YardName,
			Remote: loaded.Context.RemoteDest, Maximum: audit.MaximumFrom(cli.env["SUBYARD_AUDIT_MAX_BYTES"]),
		}
	}
	return &application.Orchestrator{
		Clock: clock, IDs: fixedIDSource{value: operationID}, Prompt: prompt,
		Runner: runner, Audit: auditSink, Events: events,
	}
}

func structuredAdapterContext(yard domain.Context) map[string]string {
	boolValue := func(value bool) string {
		if value {
			return "1"
		}
		return "0"
	}
	yardName := yard.YardName
	selectedYard := yardName
	if yardName == "default" {
		yardName = ""
		selectedYard = ""
	}
	return map[string]string{
		"YARD_VERSION":           Version,
		"HOME":                   yard.Paths.OperatorHome,
		"SUBYARD_OPERATOR_HOME":  yard.Paths.OperatorHome,
		"SUBYARD_CONFIG_DIR":     yard.Paths.ConfigDir,
		"SUBYARD_CONFIG_HOME":    yard.Paths.ConfigHome,
		"SUBYARD_HOME":           yard.Paths.DataHome,
		"SUBYARD_STATE_DIR":      yard.Paths.StateDir,
		"SUBYARD_CONFIG_LOADED":  "1",
		"SUBYARD_ENGINE_CONTEXT": "1",
		"SUBYARD_YARD":           selectedYard,
		"YARD_NAME":              yardName,
		"YARD_TYPE":              string(yard.YardType),
		"REMOTE_DEST":            yard.RemoteDest,
		"REMOTE_YARD":            yard.RemoteYard,
		"INSTANCE_TYPE":          string(yard.InstanceType),
		"INSTANCE_NAME":          yard.InstanceName,
		"INCUS_PROJECT":          yard.IncusProject,
		"INCUS_BRIDGE":           yard.IncusBridge,
		"SSH_HOST":               yard.SSHHost,
		"SSH_PORT":               strconv.Itoa(yard.SSHPort),
		"DEV_USER":               yard.DevUser,
		"DEV_UID":                strconv.Itoa(yard.DevUID),
		"DEV_SUDO":               boolValue(yard.DevSudo),
		"FORWARD_SSH_AGENT":      boolValue(yard.ForwardSSHAgent),
		"NESTED_E2E_VMS":         boolValue(yard.NestedE2EVMs),
		"SHIFT_MODE":             yard.ShiftMode,
		"STORAGE_PATH":           yard.Paths.StoragePath,
		"HOST_BASE":              yard.Paths.HostBase,
		"RESTRICTED_DISK_PATHS":  yard.Paths.HostBase,
		"ASSUME_YES":             "1",
		"PROG":                   cliProgramName,
	}
}

var structuredCommandConfigKeys = map[string]struct{}{
	"ADB_CONSOLE_EMULATOR_PORT": {}, "ADB_CONSOLE_PROXY_PORT": {},
	"ADB_EMULATOR_PORT": {}, "ADB_PROXY_PORT": {},
	"AGENTS": {}, "BASE_IMAGE": {}, "BASE_IMAGE_FALLBACK": {},
	"CCUSAGE_PROVISION": {}, "CCUSAGE_SHA256_AMD64": {}, "CCUSAGE_SHA256_ARM64": {},
	"CCUSAGE_VERSION": {}, "E2E_VM_BOOT_TIMEOUT": {}, "E2E_VM_CPU": {}, "E2E_VM_DISK": {},
	"E2E_VM_IMAGE": {}, "E2E_VM_MEMORY": {}, "E2E_VM_TTL_MINUTES": {},
	"HOST_CLAUDE_MD": {}, "HOST_CODEX_AGENTS_MD": {}, "HOST_OPENCODE_AGENTS_MD": {},
	"HOST_LINKS": {}, "HOST_MOUNTS": {},
	"LIMITS_CPU": {}, "LIMITS_MEMORY": {}, "SRV_POOL": {}, "SRV_VOLUME": {},
	"SUBYARD_AGE_SHA256_AMD64": {}, "SUBYARD_AGE_SHA256_ARM64": {}, "SUBYARD_AGE_VERSION": {},
	"SUBYARD_KEYS_CONSUMER_ROOT": {}, "SUBYARD_KEYS_ROOT": {}, "SUBYARD_KEYS_SYSTEMD_DIR": {},
	"SUBYARD_KEYS_TOOLS_DIR": {}, "SUBYARD_POWER_LIBEXEC_DIR": {}, "SUBYARD_POWER_LIB_PATH": {},
	"SUBYARD_POWER_RECONCILER_PATH": {}, "SUBYARD_POWER_UNIT_PATH": {},
	"SUBYARD_SOPS_SHA256_AMD64": {}, "SUBYARD_SOPS_SHA256_ARM64": {}, "SUBYARD_SOPS_VERSION": {},
	"YARD_CAPABILITIES": {}, "YARD_DEVICES": {}, "YARD_MOUNTS": {}, "YARD_PROFILES": {},
	"YARD_TEMPLATE": {},
}

func structuredAgentConfigKey(name string) bool {
	if !strings.HasPrefix(name, "AGENT_") {
		return false
	}
	for _, suffix := range []string{
		"_COMMAND", "_CONFIG", "_CONFIG_DEST", "_PERSIST", "_PROVISION", "_RULES", "_RULES_DEST",
	} {
		agent, found := strings.CutSuffix(strings.TrimPrefix(name, "AGENT_"), suffix)
		if found && domain.SafeName(agent) {
			return true
		}
	}
	return false
}

func structuredCommandContext(loaded config.Loaded) map[string]string {
	values := structuredAdapterContext(loaded.Context)
	for name, value := range loaded.Environment {
		if _, ok := structuredCommandConfigKeys[name]; ok || structuredAgentConfigKey(name) {
			values[name] = value
		}
	}
	return values
}

const cliProgramName = "yard"

func startPolicy(definition command.Definition, yard domain.Context) domain.CommandPolicy {
	return domain.CommandPolicy{
		Name: definition.Name, Effect: domain.CommandEffect(definition.Effect),
		RemotePolicy: domain.RemotePolicy(definition.Remote),
		Consequences: []string{
			fmt.Sprintf("start Incus instance %s in project %s", yard.InstanceName, yard.IncusProject),
			"verify the host route before and after the start",
			"record desired power as running only after the safety checks pass",
		},
	}
}

func commandPolicy(
	definition command.Definition,
	yard domain.Context,
	arguments []string,
	project *projectExecution,
	remote *domain.RemotePrepared,
) domain.CommandPolicy {
	if remote != nil {
		return application.RemotePolicy(*remote)
	}
	consequences := []string{
		fmt.Sprintf("%s in yard %s", definition.Summary, yard.YardName),
		fmt.Sprintf("execute the allowlisted physical adapter for %s", definition.Name),
		"publish typed operation events and an audit result",
	}
	if len(arguments) != 0 {
		consequences = append(consequences, "use validated command arguments")
	}
	if project != nil && project.Record.ProjectID != "" {
		consequences = append(consequences, fmt.Sprintf("operate on project %s (%s)",
			project.Record.Name, project.Record.ProjectID))
		consequences = append(consequences, application.ProjectConsequences(definition.Name,
			project.Record, project.Environment["SUBYARD_PROJECT_REMOVE_SOFT"] == "1")...)
		switch project.Commit {
		case projectCommitPut:
			consequences = append(consequences, "publish project state only after the physical operation succeeds")
		case projectCommitDelete:
			consequences = append(consequences, "delete project state only after physical cleanup succeeds")
		}
	}
	return domain.CommandPolicy{
		Name: definition.Name, Effect: domain.CommandEffect(definition.Effect),
		RemotePolicy: domain.RemotePolicy(definition.Remote), Consequences: consequences,
	}
}

func structuredCommandSupported(name string) bool {
	switch name {
	case "init", "provision", "test-vms", "stop", "teardown", "sync", "bind", "clone",
		"export", "remove", "up", "down", "remote", "update":
		return true
	default:
		return false
	}
}

func commandHelpRequested(arguments []string) bool {
	for _, argument := range arguments {
		if argument == "-h" || argument == "--help" {
			return true
		}
	}
	return false
}

func (cli *CLI) runStructuredCommand(
	ctx context.Context,
	loaded config.Loaded,
	definition command.Definition,
	arguments []string,
	assumeYes bool,
	project *projectExecution,
	remote *domain.RemotePrepared,
) int {
	for _, argument := range arguments {
		if argument == "-y" || argument == "--yes" {
			assumeYes = true
		}
	}
	orchestrator := cli.operationOrchestrator(cli.env["SUBYARD_OPERATION_ID"], loaded, nil, &definition)
	plan, err := orchestrator.Plan(ctx, loaded.Context,
		commandPolicy(definition, loaded.Context, arguments, project, remote), assumeYes)
	if err != nil {
		if errors.Is(err, application.ErrDeclined) {
			cli.errorf("operation declined")
		} else {
			cli.errorf("plan %s: %v", definition.Name, err)
		}
		return 1
	}
	if plan.Target == domain.TargetRemoteOwner {
		remoteArguments := append([]string(nil), arguments...)
		hasYes := false
		for _, argument := range remoteArguments {
			hasYes = hasYes || argument == "-y" || argument == "--yes"
		}
		if !hasYes {
			remoteArguments = append([]string{"--yes"}, remoteArguments...)
		}
		return cli.forwardRemote(ctx, loaded.Context, definition.Name, remoteArguments)
	}
	result, err := cli.executeStructuredCommand(ctx, orchestrator, loaded, definition, arguments,
		plan, project, remote, cli.options.Stdout)
	if err != nil {
		cli.errorf("%s: %v", definition.Name, err)
		return 1
	}
	if result.Status != "ok" {
		cli.errorf("%s adapter returned %s (%s)", definition.Name, result.Status, result.ErrorCode)
		return 1
	}
	if project != nil {
		if err := cli.commitProjectExecution(ctx, project); err != nil {
			cli.errorf("commit %s: %v", definition.Name, err)
			return 1
		}
	}
	if remote != nil {
		cli.printRemoteResult(result)
	}
	return 0
}

func (cli *CLI) executeStructuredCommand(
	ctx context.Context,
	orchestrator *application.Orchestrator,
	loaded config.Loaded,
	definition command.Definition,
	arguments []string,
	plan domain.OperationPlan,
	project *projectExecution,
	remote *domain.RemotePrepared,
	diagnostics io.Writer,
) (domain.AdapterResult, error) {
	if remote != nil {
		orchestrator.Runner = application.RemoteRunner{Control: cli.remoteService(loaded).Control, Prepared: *remote}
		request := domain.AdapterRequest{
			Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
			Adapter: "remote", Action: string(remote.Action),
		}
		result, _, err := orchestrator.RunAdapter(ctx, plan, request, nil)
		return result, err
	}
	if project != nil && definition.Handler == "@project" {
		orchestrator.Runner = application.ProjectActionRunner{
			Data: cli.projectDataPlane(), Devices: cli.projectDeviceManager(), Archive: cli.projectArchiver(),
			Yard: loaded.Context, Project: project.Record,
			SoftRemove: project.Environment["SUBYARD_PROJECT_REMOVE_SOFT"] == "1",
		}
		request := domain.AdapterRequest{
			Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
			Adapter: "project", Action: definition.Name,
		}
		result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
		if stderr != "" {
			_, _ = io.WriteString(diagnostics, stderr)
		}
		return result, err
	}
	handlerArguments := append([]string(nil), arguments...)
	if definition.Arg0 != "" {
		handlerArguments = append([]string{definition.Arg0}, handlerArguments...)
	}
	contextValues := structuredCommandContext(loaded)
	if structuredCommandNeedsSudo(definition.Name) {
		if cli.options.AdapterRunner == nil {
			if err := cli.prepareSudoPrivileges(
				ctx, diagnostics, os.Geteuid(), definition.Name,
			); err != nil {
				return domain.AdapterResult{}, err
			}
		}
		contextValues["SUBYARD_SUDO_PREAUTHORIZED"] = "1"
	}
	if project != nil {
		for key, value := range project.Environment {
			contextValues[key] = value
		}
	}
	request := domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
		Adapter: "command", Action: definition.Name, Arguments: handlerArguments, Context: contextValues,
	}
	result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
	if stderr != "" {
		_, _ = io.WriteString(diagnostics, stderr)
		if !strings.HasSuffix(stderr, "\n") {
			_, _ = io.WriteString(diagnostics, "\n")
		}
	}
	return result, err
}

func structuredCommandNeedsSudo(name string) bool {
	return name == "init" || name == "teardown"
}

func parseStructuredStartArguments(arguments []string, inheritedYes bool) (assumeYes, help bool, err error) {
	assumeYes = inheritedYes
	for _, argument := range arguments {
		switch argument {
		case "-y", "--yes":
			assumeYes = true
		case "-h", "--help":
			help = true
		default:
			return false, false, fmt.Errorf("unknown option %q", argument)
		}
	}
	return assumeYes, help, nil
}

func (cli *CLI) runStructuredStart(
	ctx context.Context,
	loaded config.Loaded,
	definition command.Definition,
	arguments []string,
	inheritedYes bool,
) int {
	assumeYes, help, err := parseStructuredStartArguments(arguments, inheritedYes)
	if err != nil {
		cli.errorf("%v", err)
		return 2
	}
	if help {
		fmt.Fprintf(cli.options.Stdout, "Usage: %s start [--yes]\n", cli.options.Program)
		return 0
	}
	operationID := cli.env["SUBYARD_OPERATION_ID"]
	orchestrator := cli.operationOrchestrator(operationID, loaded, nil, &definition)
	plan, err := orchestrator.Plan(ctx, loaded.Context, startPolicy(definition, loaded.Context), assumeYes)
	if err != nil {
		if errors.Is(err, application.ErrDeclined) {
			cli.errorf("operation declined")
		} else {
			cli.errorf("plan start: %v", err)
		}
		return 1
	}
	if plan.Target == domain.TargetRemoteOwner {
		return cli.forwardRemote(ctx, loaded.Context, definition.Name, []string{"--yes"})
	}
	result, err := cli.executeStructuredStart(ctx, orchestrator, loaded.Context, plan, cli.options.Stdout)
	if err != nil {
		cli.errorf("start: %v", err)
		return 1
	}
	if result.Status != "ok" {
		cli.errorf("start adapter returned %s (%s)", result.Status, result.ErrorCode)
		return 1
	}
	return 0
}

func (cli *CLI) executeStructuredStart(
	ctx context.Context,
	orchestrator *application.Orchestrator,
	yard domain.Context,
	plan domain.OperationPlan,
	diagnostics io.Writer,
) (domain.AdapterResult, error) {
	if cli.options.AdapterRunner == nil {
		if err := cli.prepareNetworkManagerPrivileges(ctx, diagnostics, os.Geteuid()); err != nil {
			return domain.AdapterResult{}, err
		}
	}
	adapterContext := structuredAdapterContext(yard)
	adapterContext["SUBYARD_SUDO_PREAUTHORIZED"] = "1"
	fmt.Fprintf(diagnostics, "  [ .. ] starting %s\n", yard.InstanceName)
	request := domain.AdapterRequest{
		Schema: shelladapter.ProtocolSchema, OperationID: plan.OperationID,
		Adapter: "command", Action: "start", Arguments: []string{"start", "--yes"},
		Context: adapterContext,
	}
	result, stderr, err := orchestrator.RunAdapter(ctx, plan, request, nil)
	if stderr != "" {
		_, _ = io.WriteString(diagnostics, stderr)
		if !strings.HasSuffix(stderr, "\n") {
			_, _ = io.WriteString(diagnostics, "\n")
		}
	}
	return result, err
}

func (cli *CLI) prepareSudoPrivileges(
	ctx context.Context,
	diagnostics io.Writer,
	effectiveUID int,
	operation string,
) error {
	if effectiveUID == 0 {
		return nil
	}
	if cli.sudoAvailableWithoutPrompt(ctx) {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("authorize root steps for %s: %w", operation, err)
	}
	fmt.Fprintf(diagnostics, "  [ .. ] authorizing root steps for %s\n", operation)
	command := exec.CommandContext(ctx, "sudo", "-v")
	command.Env = environmentList(cli.env, nil)
	command.Stdin = cli.options.Stdin
	command.Stdout = cli.options.Stdout
	command.Stderr = cli.options.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("authorize root steps for %s: %w", operation, err)
	}
	return nil
}

func (cli *CLI) sudoAvailableWithoutPrompt(ctx context.Context) bool {
	command := exec.CommandContext(ctx, "sudo", "-n", "true")
	command.Env = environmentList(cli.env, nil)
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	return command.Run() == nil
}

func (cli *CLI) prepareNetworkManagerPrivileges(ctx context.Context, diagnostics io.Writer, effectiveUID int) error {
	if effectiveUID == 0 {
		return nil
	}
	check := exec.CommandContext(ctx, "systemctl", "is-active", "NetworkManager")
	check.Env = environmentList(cli.env, nil)
	output, checkErr := check.Output()
	state := strings.TrimSpace(string(output))
	switch state {
	case "inactive", "failed", "unknown":
		return nil
	case "active", "activating", "reloading", "deactivating":
	case "":
		if checkErr != nil {
			return fmt.Errorf("inspect NetworkManager before host network check: %w", checkErr)
		}
		return errors.New("inspect NetworkManager before host network check: empty service state")
	default:
		return fmt.Errorf("inspect NetworkManager before host network check: unexpected state %q", state)
	}
	if cli.sudoAvailableWithoutPrompt(ctx) {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("authorize the NetworkManager safety check: %w", err)
	}
	fmt.Fprintln(diagnostics, "  [ .. ] authorizing the NetworkManager safety check")
	command := exec.CommandContext(ctx, "sudo", "-v")
	command.Env = environmentList(cli.env, nil)
	command.Stdin = cli.options.Stdin
	command.Stdout = cli.options.Stdout
	command.Stderr = cli.options.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("authorize the NetworkManager safety check: %w", err)
	}
	return nil
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
	// An RPC session is bound to one validated context. Cross-yard selection is represented as a
	// remote-owner route, never as an implicit context switch inside the session.
	cli.env["SUBYARD_YARD_EXPLICIT"] = "1"
	handler := &rpcHandler{cli: cli, loaded: loaded, plans: make(map[string]rpcPlannedOperation)}
	session := rpc.Session{Handler: handler, EngineVersion: Version, Capabilities: []string{
		"snapshot", "ordered-events", "cancellation", "deadlines", "commands", "context",
		"projects", "yard-status", "credential-metadata", "credential-status",
		"operation-plan", "operation-execute", "resync",
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
	cli     *CLI
	loaded  config.Loaded
	plansMu sync.Mutex
	plans   map[string]rpcPlannedOperation
}

type rpcPlannedOperation struct {
	Plan       domain.OperationPlan
	Definition command.Definition
	Arguments  []string
	Loaded     config.Loaded
	Project    *projectExecution
	Remote     *domain.RemotePrepared
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
	case "operation.plan":
		var params struct {
			Command   string   `json:"command"`
			Arguments []string `json:"arguments"`
		}
		if err := decodeRPCParams(call.Params, &params); err != nil {
			return nil, err
		}
		definition, ok := handler.cli.manifest.Lookup(params.Command)
		if !ok || definition.Visibility != command.VisibilityPublic {
			return nil, &rpc.Error{Code: "command_not_found", Message: params.Command}
		}
		if definition.Effect != command.EffectMutate {
			return nil, &rpc.Error{Code: "command_not_mutating", Message: params.Command}
		}
		if definition.Name != "start" && !structuredCommandSupported(definition.Name) {
			return nil, &rpc.Error{Code: "interactive_or_payload_command", Message: params.Command}
		}
		if definition.Name == "start" && len(params.Arguments) != 0 {
			return nil, &rpc.Error{Code: "invalid_params", Message: "start does not accept RPC arguments"}
		}
		project, err := handler.cli.prepareProjectExecution(
			ctx, handler.loaded, definition, params.Arguments, true,
		)
		if err != nil {
			return nil, &rpc.Error{Code: "invalid_params", Message: err.Error()}
		}
		loaded := handler.loaded
		arguments := append([]string(nil), params.Arguments...)
		if project != nil {
			loaded = project.Loaded
			arguments = project.Arguments
		}
		var remote *domain.RemotePrepared
		if definition.Name == "remote" {
			remote, err = handler.cli.prepareRemoteExecution(ctx, loaded, arguments)
			if err != nil {
				return nil, &rpc.Error{Code: "invalid_params", Message: err.Error()}
			}
		}
		policy := commandPolicy(definition, loaded.Context, arguments, project, remote)
		if definition.Name == "start" {
			policy = startPolicy(definition, loaded.Context)
		}
		orchestrator := handler.cli.operationOrchestrator(call.OperationID, loaded, nil, nil)
		plan, err := orchestrator.Prepare(loaded.Context, policy)
		if err != nil {
			return nil, &rpc.Error{Code: "plan_failed", Message: err.Error()}
		}
		handler.plansMu.Lock()
		if handler.plans == nil {
			handler.plans = make(map[string]rpcPlannedOperation)
		}
		if _, exists := handler.plans[plan.OperationID]; exists {
			handler.plansMu.Unlock()
			return nil, &rpc.Error{Code: "duplicate_plan", Message: plan.OperationID}
		}
		if len(handler.plans) >= 64 {
			handler.plansMu.Unlock()
			return nil, &rpc.Error{Code: "too_many_plans", Message: "execute an existing plan or start a new RPC session"}
		}
		handler.plans[plan.OperationID] = rpcPlannedOperation{
			Plan: plan, Definition: definition, Arguments: arguments, Loaded: loaded, Project: project, Remote: remote,
		}
		handler.plansMu.Unlock()
		return plan, nil
	case "operation.execute":
		var params struct {
			Confirmed bool `json:"confirmed"`
		}
		if err := decodeRPCParams(call.Params, &params); err != nil {
			return nil, err
		}
		if !params.Confirmed {
			return nil, &rpc.Error{Code: "confirmation_required", Message: "execute requires confirmed=true"}
		}
		handler.plansMu.Lock()
		planned, ok := handler.plans[call.OperationID]
		if ok {
			delete(handler.plans, call.OperationID)
		}
		handler.plansMu.Unlock()
		if !ok {
			return nil, &rpc.Error{Code: "plan_not_found", Message: call.OperationID}
		}
		if planned.Plan.Target == domain.TargetRemoteOwner {
			return nil, &rpc.Error{Code: "remote_owner_required", Message: "execute this plan through owner-host SSH stdio"}
		}
		orchestrator := handler.cli.operationOrchestrator(
			call.OperationID, planned.Loaded, rpcOperationEvents{emit: emit}, &planned.Definition,
		)
		plan, err := orchestrator.Confirm(ctx, planned.Plan, true)
		if err != nil {
			return nil, &rpc.Error{Code: "confirmation_failed", Message: err.Error()}
		}
		var result domain.AdapterResult
		if planned.Definition.Name == "start" {
			result, err = handler.cli.executeStructuredStart(
				ctx, orchestrator, planned.Loaded.Context, plan, handler.cli.options.Stderr,
			)
		} else {
			result, err = handler.cli.executeStructuredCommand(
				ctx, orchestrator, planned.Loaded, planned.Definition, planned.Arguments,
				plan, planned.Project, planned.Remote, handler.cli.options.Stderr,
			)
		}
		if err != nil {
			return nil, err
		}
		if result.Status != "ok" {
			return nil, &rpc.Error{Code: "adapter_failed", Message: result.ErrorCode}
		}
		if planned.Project != nil {
			if err := handler.cli.commitProjectExecution(ctx, planned.Project); err != nil {
				return nil, &rpc.Error{Code: "state_commit_failed", Message: err.Error()}
			}
		}
		return map[string]any{"plan": plan, "result": result}, nil
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
	case "system.snapshot", "system.resync":
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
	store, err := openProjectStore(ctx, handler.loaded.Context.Paths.StateDir)
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
	store, err := openProjectStore(ctx, handler.loaded.Context.Paths.StateDir)
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
