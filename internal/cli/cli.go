package cli

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Dmitry-Borodin/Subyard/internal/audit"
	"github.com/Dmitry-Borodin/Subyard/internal/command"
	"github.com/Dmitry-Borodin/Subyard/internal/config"
	"github.com/Dmitry-Borodin/Subyard/internal/domain"
	"github.com/Dmitry-Borodin/Subyard/internal/resource"
	"github.com/Dmitry-Borodin/Subyard/internal/rpc"
)

var Version = "0.1.0-dev"

type Options struct {
	RepositoryRoot string
	DispatcherPath string
	Program        string
	Arguments      []string
	Environment    []string
	WorkingDir     string
	Stdin          io.Reader
	Stdout         io.Writer
	Stderr         io.Writer
}

type CLI struct {
	options   Options
	env       map[string]string
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
	return &CLI{options: options, env: environmentMap(options.Environment), manifest: manifest, resources: resources}, nil
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
	remote := ""
	if loadedContext.YardType == domain.YardRemote {
		remote = loadedContext.RemoteDest
	}
	if name != "_info" && cli.env["SUBYARD_NO_AUDIT"] == "" {
		cli.audit(name, commandArguments, yard, remote)
	}
	if loadedContext.YardType == domain.YardRemote {
		switch remotePlane {
		case command.RemoteDeny:
			fmt.Fprintf(cli.options.Stderr, "%s is host-local — use sync or clone\n", name)
			return 1
		case command.RemoteForward:
			return cli.forwardRemote(ctx, loadedContext, name, commandArguments)
		}
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
	remoteLine := strings.Join(parts, " ")
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
	})
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
	handler := &rpcHandler{cli: cli, yardContext: loaded.Context}
	session := rpc.Session{Handler: handler, Capabilities: []string{
		"snapshot", "ordered-events", "cancellation", "commands", "context",
	}}
	if err := session.Serve(ctx, cli.options.Stdin, cli.options.Stdout); err != nil {
		if !errors.Is(err, io.EOF) && !errors.Is(err, context.Canceled) {
			cli.errorf("RPC session: %v", err)
			return 1
		}
	}
	return 0
}

type rpcHandler struct {
	cli         *CLI
	yardContext domain.Context
}

func (handler *rpcHandler) Handle(_ context.Context, call rpc.Call, emit rpc.Emit) (any, error) {
	switch call.Method {
	case "command.list":
		definitions := handler.cli.manifest.Commands()
		result := make([]map[string]any, 0, len(definitions))
		for _, definition := range definitions {
			if definition.Visibility != command.VisibilityPublic {
				continue
			}
			result = append(result, map[string]any{
				"name": definition.Name, "aliases": definition.Aliases, "effect": definition.Effect,
				"summary": definition.Summary, "options": definition.Options, "verbs": definition.Verbs,
			})
		}
		return result, nil
	case "context.get":
		return handler.yardContext, nil
	case "system.snapshot":
		revision := snapshotRevision(handler.yardContext, handler.cli.manifest.Commands())
		return map[string]any{"revision": revision, "context": handler.yardContext}, nil
	case "system.ping":
		if err := emit("operation.started", 0, map[string]any{"method": call.Method}); err != nil {
			return nil, err
		}
		if err := emit("operation.finished", 0, map[string]any{"method": call.Method}); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil
	default:
		return nil, &rpc.Error{Code: "method_not_found", Message: call.Method}
	}
}

func snapshotRevision(ctx domain.Context, definitions []command.Definition) uint64 {
	payload, _ := json.Marshal(struct {
		Context  domain.Context
		Commands []command.Definition
	}{ctx, definitions})
	hash := sha256Sum(payload)
	return binary.BigEndian.Uint64(hash[:8])
}

func sha256Sum(payload []byte) [32]byte {
	return sha256.Sum256(payload)
}
