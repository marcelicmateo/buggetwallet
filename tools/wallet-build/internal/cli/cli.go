// Package cli is the command table of wallet-build: argument handling, quiet mode, exit codes.
package cli

import (
	"bufio"
	"context"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"

	"wallet-build/internal/ci"
	"wallet-build/internal/emulator"
	"wallet-build/internal/host"
	"wallet-build/internal/live"
	"wallet-build/internal/report"
	"wallet-build/internal/run"
	"wallet-build/internal/shellhelpers"
	"wallet-build/internal/steps"
	"wallet-build/internal/sys"
)

//go:embed usage.txt
var usageText string

// UsageText is what a usage error prints (the header of tools/build.sh).
func UsageText() string { return usageText }

// Deps are the things the tests replace.
type Deps struct {
	R    sys.Runner
	Root string // the repository; "" = found from the binary's location
	Self string // path of this binary; "" = os.Executable
	// Host overrides the host side's terminal/signal/download hooks (tests).
	HostSetup func(h *host.Host)
}

// BuildCommands are the commands tools/build.sh has (the host or container side runs them).
var BuildCommands = []string{"test", "lint", "analyze", "stage", "outdated", "format", "apk", "linux", "relay-bin", "relay-native-test", "web", "web-test",
	"all", "desktop-test", "desktop-smoke", "perf", "importer", "core", "sync", "relay", "app", "mutate", "shell", "image", "lsp", "mcp", "image-name"}

// Main runs wallet-build with the process environment and returns the exit code.
func Main(args []string, environ []string, out, errw io.Writer) int {
	return Run(args, environ, out, errw, Deps{R: sys.Real{}})
}

func findRoot(self string) string {
	if d := filepath.Dir(self); filepath.Base(d) == "bin" && filepath.Base(filepath.Dir(d)) == "dist" {
		return filepath.Dir(filepath.Dir(d))
	}
	dir, _ := os.Getwd()
	for dir != "/" && dir != "." {
		if _, err := os.Stat(filepath.Join(dir, "tools", "wallet-build", "go.mod")); err == nil {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	wd, _ := os.Getwd()
	return wd
}

// Run is Main with replaceable dependencies.
func Run(args []string, environ []string, out, errw io.Writer, d Deps) int {
	env := sys.Env(environ)
	quiet := env.Get("BW_QUIET") == "1"
	if len(args) > 0 && (args[0] == "-q" || args[0] == "--quiet") {
		quiet, args = true, args[1:]
	}
	cmd := "test"
	if len(args) > 0 && args[0] != "" {
		cmd = args[0]
	}
	var rest []string
	if len(args) > 1 {
		rest = args[1:]
	}
	self := d.Self
	if self == "" {
		self, _ = os.Executable()
	}
	root := d.Root
	if root == "" {
		root = findRoot(self)
	}
	c := run.New(root, env, out, errw, d.R)
	// Quiet: nothing on stdout or stderr, ours or any child's (the logs are written by the steps). lsp, mcp and
	// image-name use stdout as their result.
	// `live` has no quiet mode (tools/live.sh has none: -q is a usage error there and BW_QUIET is ignored).
	if quiet && cmd != "lsp" && cmd != "mcp" && cmd != "image-name" && cmd != "live" {
		c.SetQuiet()
	}
	usage := func() int {
		fmt.Fprint(c.Out, usageText)
		return 2
	}
	// SIGINT/SIGTERM: stop the children (host runs stop the container instead, see host.runPodman)
	sigs := make(chan os.Signal, 2)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigs)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c.Ctx = ctx
	got := make(chan os.Signal, 1)
	go func() {
		select {
		case s := <-sigs:
			got <- s
			cancel()
		case <-ctx.Done():
		}
	}()
	code := dispatch(c, cmd, rest, self, usage, d)
	select {
	case s := <-got:
		code = 130 // 128 + the signal, as a shell reports an interrupted command
		if s == syscall.SIGTERM {
			code = 143
		}
	default:
	}
	return code
}

func dispatch(c *run.Ctx, cmd string, rest []string, self string, usage func() int, d Deps) int {
	switch cmd {
	case "version":
		fmt.Fprintln(c.Out, Version())
		return 0
	case "times", "trend":
		return timesCmd(c, cmd, rest, usage)
	case "ci":
		rc, ok := ci.New(c).Main(rest)
		if !ok {
			return usage()
		}
		return rc
	case "log":
		return logCmd(c, rest, usage)
	case "smoke-run": // inside the headless chain of desktop-smoke
		if len(rest) != 2 {
			return usage()
		}
		n, err := strconv.Atoi(rest[1])
		if err != nil {
			return usage()
		}
		return steps.SmokeRun(c.Out, rest[0], n, c.Getenv("SMOKE_OUT"), c.Env)
	// ---- GO4-A helpers (ported Python tools; one block, GO4-B adds its own) ----
	case "fixtures", "token-usage", "log-summary", "lsp-query":
		return helpersA(c, cmd, rest, self)
	}
	// GO4-B helpers (relay, web serve/shot, web-shot, relay-native-check, signing-key, hook): host or container, no run directory
	if rc, ok := shellhelpers.Dispatch(c, cmd, rest, self, usage, shellhelpers.Deps{HostSetup: d.HostSetup}); ok {
		return rc
	}
	native := c.Getenv("BW_NATIVE") == "1"
	if native && cmd != "emulator" && cmd != "live" {
		return steps.Container(c, append([]string{cmd}, rest...), self, usage)
	}
	switch {
	case cmd == "emulator" && native:
		return emulator.Container(c, rest)
	case cmd == "live" && native:
		return live.Container(c, rest)
	}
	h := host.New(c, self, usage)
	if d.HostSetup != nil {
		d.HostSetup(h)
	}
	switch cmd {
	case "emulator":
		return emulator.Host(h, rest)
	case "live":
		return live.Host(h, rest)
	}
	return h.Main(cmd, rest)
}

// Version is the VCS stamp and Go version of this binary.
func Version() string {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return "wallet-build (no build info)"
	}
	set := map[string]string{}
	for _, s := range bi.Settings {
		set[s.Key] = s.Value
	}
	rev := set["vcs.revision"]
	if rev == "" {
		rev = "unknown"
	}
	if len(rev) > 12 {
		rev = rev[:12]
	}
	if set["vcs.modified"] == "true" {
		rev += "-dirty"
	}
	cgo := set["CGO_ENABLED"]
	if cgo == "" {
		cgo = "?"
	}
	return fmt.Sprintf("wallet-build %s %s %s CGO_ENABLED=%s", rev, set["vcs.time"], bi.GoVersion, cgo)
}

// flagSet is a tiny argparse: "--name value", "--name=value", "-n value"; repeated flags collect.
type flagSet struct {
	vals map[string][]string
	pos  []string
}

func parseFlags(args []string, valued []string, boolean []string) (*flagSet, bool) {
	f := &flagSet{vals: map[string][]string{}}
	isIn := func(l []string, s string) bool {
		for _, x := range l {
			if x == s {
				return true
			}
		}
		return false
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") || a == "-" {
			f.pos = append(f.pos, a)
			continue
		}
		name, val, hasVal := strings.Cut(a, "=")
		switch {
		case isIn(boolean, name):
			f.vals[name] = append(f.vals[name], "1")
		case isIn(valued, name):
			if !hasVal {
				if i+1 >= len(args) {
					return nil, false
				}
				i++
				val = args[i]
			}
			f.vals[name] = append(f.vals[name], val)
		default:
			return nil, false
		}
	}
	return f, true
}

func (f *flagSet) one(name string) string {
	v := f.vals[name]
	if len(v) == 0 {
		return ""
	}
	return v[len(v)-1]
}

func (f *flagSet) intv(name string, def int) (int, bool) {
	s := f.one(name)
	if s == "" {
		return def, true
	}
	n, err := strconv.Atoi(s)
	return n, err == nil
}

func timesCmd(c *run.Ctx, cmd string, args []string, usage func() int) int {
	cfg := report.FromCtx(c, "")
	if cmd == "trend" {
		f, ok := parseFlags(args, []string{"-n", "--top", "--step"}, nil)
		if !ok || len(f.pos) > 0 {
			return usage()
		}
		n, ok1 := f.intv("-n", 10)
		top, ok2 := f.intv("--top", 10)
		if !ok1 || !ok2 {
			return usage()
		}
		cfg.Trend(report.TrendOpts{N: n, Top: top, Step: f.one("--step")})
		return 0
	}
	f, ok := parseFlags(args, []string{"-n", "--cmd", "--step", "--commit", "--source", "--ci-file"}, []string{"--ci"})
	if !ok || len(f.pos) > 0 {
		return usage()
	}
	n, ok1 := f.intv("-n", 10)
	if src := f.one("--source"); !ok1 || (src != "" && src != "local" && src != "ci") {
		return usage()
	}
	o := report.TimesOpts{N: n, Cmd: f.one("--cmd"), Step: f.one("--step"), Commit: f.one("--commit"), Source: f.one("--source"), CIFiles: f.vals["--ci-file"]}
	if len(f.vals["--ci"]) > 0 { // CI's history.jsonl from the ci-logs branch
		tmp, err := os.CreateTemp("", "ci-history")
		if err == nil {
			defer os.Remove(tmp.Name())
			tmp.Close()
			x := ci.New(c)
			if _, rc := x.Capture("fetch", "-q", "origin", "ci-logs:refs/remotes/origin/ci-logs"); rc == 0 {
				if text, rc := x.CaptureQuiet("show", "origin/ci-logs:history.jsonl"); rc == 0 { // 2>/dev/null as in the script; M6: rename with the scripts
					_ = os.WriteFile(tmp.Name(), []byte(text+"\n"), 0o644)
				} else {
					c.Eprintf("no history.jsonl on ci-logs yet\n")
				}
			}
			o.CIFiles = append(o.CIFiles, tmp.Name())
		}
	}
	cfg.Times(o)
	return 0
}

func logCmd(c *run.Ctx, args []string, usage func() int) int {
	if len(args) == 0 {
		return usage()
	}
	logs := c.Getenv("BW_RUN_DIR")
	if logs == "" {
		logs = filepath.Join(c.Root, "dist", "logs")
	}
	cfg := report.FromCtx(c, logs)
	switch args[0] {
	case "tests", "drive":
		if len(args) < 3 || (args[0] == "drive" && len(args) != 3) {
			return usage()
		}
		cfg.Tests(args[0], args[1], args[2:])
	case "perf":
		if len(args) != 2 {
			return usage()
		}
		cfg.Perf(args[1])
	case "order":
		if len(args) < 2 {
			return usage()
		}
		for _, u := range cfg.Order(args[1:]) {
			c.Printf("%s\n", u)
		}
	case "ci-history":
		if len(args) != 2 {
			return usage()
		}
		cfg.CIHistory(args[1])
	case "stage-summary": // run directories on stdin, one per line
		var dirs []string
		sc := bufio.NewScanner(os.Stdin)
		for sc.Scan() {
			dirs = append(dirs, sc.Text())
		}
		c.Printf("%s", report.StageSummary(dirs))
	default:
		return usage()
	}
	return 0
}
