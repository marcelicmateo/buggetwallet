package steps

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"wallet-build/internal/mutate"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// GoCheck is the host step of lint and test: gofmt, go vet, go test for tools/wallet-build, and a check that the binary
// was built with CGO_ENABLED=0 (a Fedora glibc binary would not run in the Ubuntu image). Natively without Go (CI before
// GO3) it is skipped and counts as ok; on the host a missing Go fails the step.
func GoCheck(sc *run.StepCtx) int {
	if _, err := sc.C.R.LookPath("go"); err != nil {
		if sc.Env.Get("BW_NATIVE") == "1" {
			sc.Printf("go not found (CI before GO3), skipped\n")
			return 0
		}
		sc.Printf("go not found on PATH: the host needs Go for tools/wallet-build\n")
		return 1
	}
	if sc.Env.Get("BW_NATIVE") == "1" && goTooOld(sc) { // ubuntu-latest's Go before GO3 sets up the pinned one
		sc.Printf("go not found (CI before GO3), skipped\n")
		return 0
	}
	rc := 0
	mod := "tools/wallet-build"
	goEnv := []string{"GOTOOLCHAIN", "local"}
	sc.Printf("--- gofmt -l %s\n", mod)
	var listed strings.Builder
	if r := sc.Do(sys.Cmd{Argv: []string{"gofmt", "-l", mod}, Stdout: &listed, Stderr: sc.Out}); r != 0 {
		rc = 1
	}
	if strings.TrimSpace(listed.String()) != "" {
		sc.Printf("gofmt: these files need formatting (run gofmt -w):\n%s", listed.String())
		rc = 1
	}
	sc.Printf("--- go vet ./...\n")
	if sc.CmdEnv(mod, goEnv, "go", "vet", "./...") != 0 {
		rc = 1
	}
	// CI (BW_NATIVE=1) skips the tool's own tests: a cold 2-core runner spent ~45 s of the lint job compiling and running them,
	// and every local `make lint`/`make test` runs them before a push.
	native := sc.Env.Get("BW_NATIVE") == "1"
	if native {
		sc.Printf("--- go test not run in CI (make lint runs it)\n")
	} else {
		sc.Printf("--- go test ./...\n")
		if sc.CmdEnv(mod, goEnv, "go", "test", "./...") != 0 {
			rc = 1
		}
	}
	sc.Printf("--- go version -m dist/bin/wallet-build\n")
	var info strings.Builder
	if r := sc.Do(sys.Cmd{Argv: []string{"go", "version", "-m", "dist/bin/wallet-build"}, Env: sc.Env.With(goEnv...), Stdout: &info, Stderr: sc.Out}); r != 0 {
		sc.Printf("cannot read the build info of dist/bin/wallet-build (build it with: make dist/bin/wallet-build)\n")
		rc = 1
	} else if !strings.Contains(info.String(), "CGO_ENABLED=0") {
		sc.Printf("dist/bin/wallet-build was not built with CGO_ENABLED=0\n")
		rc = 1
	}
	return rc
}

var (
	reModGo  = regexp.MustCompile(`(?m)^go (\d+)\.(\d+)(?:\.(\d+))?\s*$`)
	reModTC  = regexp.MustCompile(`(?m)^toolchain go(\d+)\.(\d+)(?:\.(\d+))?\s*$`)
	reGoVers = regexp.MustCompile(`go(\d+)\.(\d+)(?:\.(\d+))?`)
)

func versionParts(m []string) [3]int {
	var v [3]int
	for i := 0; i < 3; i++ {
		v[i], _ = strconv.Atoi(m[i+1])
	}
	return v
}

// goTooOld: the go on PATH is older than the go line of tools/wallet-build/go.mod (it could not build the tool).
func goTooOld(sc *run.StepCtx) bool {
	mod, err := os.ReadFile(filepath.Join(sc.C.Root, "tools", "wallet-build", "go.mod"))
	if err != nil {
		return false
	}
	want := reModGo.FindStringSubmatch(string(mod))
	if tc := reModTC.FindStringSubmatch(string(mod)); tc != nil { // CI must build with the toolchain the laptop uses
		want = tc
	}
	var out strings.Builder
	sc.Do(sys.Cmd{Argv: []string{"go", "version"}, Stdout: &out})
	have := reGoVers.FindStringSubmatch(out.String())
	if want == nil || have == nil {
		return false
	}
	w, h := versionParts(want), versionParts(have)
	for i := range w {
		if h[i] != w[i] {
			return h[i] < w[i]
		}
	}
	return false
}

func dartExe(c *run.Ctx) string {
	if h := c.Getenv("FLUTTER_HOME"); h != "" {
		return filepath.Join(h, "bin/cache/dart-sdk/bin/dart")
	}
	return "dart"
}

// Stdio runs lsp or mcp: pub get to stderr (stdout belongs to the client), then exec the SDK's own dart binary (the Flutter
// wrapper may print to stdout, which would corrupt the LSP stream; launch_app & co. would start apps in this display-less
// container: live mode does that instead).
func Stdio(c *run.Ctx, cmd string, rest []string) int {
	sc := &run.StepCtx{C: c, Name: "pub", Out: c.Err, Ctx: c.Ctx, Env: c.Env}
	PubReady(sc)
	argv := []string{dartExe(c), "language-server", "--protocol=lsp"}
	if cmd == "mcp" {
		argv = append([]string{dartExe(c), "mcp-server", "--disable", "flutter_app_lifecycle"}, rest...)
	}
	if err := c.R.Exec(sys.Cmd{Argv: argv, Dir: c.Root, Env: c.Env}); err != nil {
		c.Eprintf("exec %s: %v\n", argv[0], err)
		return 127
	}
	return 0
}

// Container runs one command inside the container (or natively in CI): wallet-build's `case "$CMD"`. args[0] is the
// command. usage prints the usage text and returns 2.
func Container(c *run.Ctx, args []string, self string, usage func() int) int {
	cmd := args[0]
	rest := args[1:]
	if cmd == "lsp" || cmd == "mcp" {
		return Stdio(c, cmd, rest)
	}
	s := run.NewSession(c)
	c.TimingInit(cmd)
	pub := func() bool { RunPub(s); return !s.Failed }
	// go-check runs on the host before the container; natively (no run directory) it is the first step
	nativeGoCheck := func() {
		if c.Getenv("BW_RUN_DIR") == "" {
			s.Step(run.Spec{Name: "go-check", Fn: GoCheck})
		}
	}
	lint := func() []run.Spec { return lintSpecs(c, self) }
	switch cmd {
	case "format":
		if pub() {
			s.Step(run.Spec{Name: "format", Fn: Format})
		}
	case "lint":
		nativeGoCheck()
		pub()
		s.Steps(lint()...)
	case "analyze":
		if pub() {
			AnalyzePkgs(s, rest)
		}
	case "outdated":
		s.Step(run.Spec{Name: "outdated", Fn: Outdated})
	case "test":
		nativeGoCheck()
		if pub() {
			s.Steps(append(lint(), SuiteSpecs()...)...)
		}
	case "importer", "core", "sync", "relay", "app":
		if len(rest) > 0 {
			if pub() {
				OneSuite(s, cmd, rest)
			}
		} else if pub() {
			d, _ := findSuite(cmd)
			s.Steps(run.Spec{Name: cmd, Fn: suiteFn(cmd, d.dir, d.analyze, d.test)})
		}
	case "mutate":
		if len(rest) < 2 {
			return usage()
		}
		mo, help, err := mutate.ParseArgs(rest)
		if help {
			c.Printf("%s", mutate.Usage)
			return 0
		}
		if err != nil { // argparse's exit 2, before any step
			c.Eprintf("usage: mutate <importer|core|sync> <lib file>... [--max N] [--seed S] [--tests <test file>...] [--timeout SECS] [--list]\nmutate: error: %v\n", err)
			return 2
		}
		if pub() {
			s.Step(run.Spec{Name: "mutate", Fn: func(sc *run.StepCtx) int {
				return mutate.Run(sc.Ctx, mutate.Env{Root: c.Root, R: c.R, Env: sc.Env, Out: sc.Out, Err: sc.Out}, mo)
			}})
		}
	case "apk":
		if pub() {
			BuildAPK(s)
		}
	case "relay-bin":
		arch := "arm64"
		if len(rest) > 0 {
			arch = rest[0]
		}
		if arch != "arm64" && arch != "x64" {
			return usage()
		}
		if pub() {
			s.Step(run.Spec{Name: "relay-bin", Fn: func(sc *run.StepCtx) int { return RelayBin(sc, arch) }})
		}
	case "linux":
		if pub() {
			BuildLinux(s)
		}
	case "desktop-test":
		if pub() {
			DesktopTests(s, rest)
		}
	case "perf":
		if pub() {
			s.Step(run.Spec{Name: "perf", Fn: PerfRun})
		}
	case "web":
		if pub() {
			s.Step(run.Spec{Name: "web", Fn: BuildWeb})
		}
	case "web-test":
		if pub() {
			s.Step(run.Spec{Name: "web-test", Fn: func(sc *run.StepCtx) int { return WebTest(sc, rest) }})
		}
	case "desktop-smoke":
		if pub() {
			BuildLinux(s)
		}
		if !s.Failed {
			s.Step(run.Spec{Name: "desktop-smoke", Fn: func(sc *run.StepCtx) int { return DesktopSmoke(sc, self) }})
		}
	case "all":
		nativeGoCheck()
		if pub() {
			s.Steps(append(lint(), SuiteSpecs()...)...)
		}
		if !s.Failed {
			BuildAPK(s)
			BuildLinux(s)
			DesktopTests(s, nil)
			s.Step(run.Spec{Name: "desktop-smoke", Fn: func(sc *run.StepCtx) int { return DesktopSmoke(sc, self) }})
		}
	default:
		return usage()
	}
	s.Summary()
	return s.Exit()
}
