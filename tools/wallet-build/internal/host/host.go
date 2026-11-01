// Package host is the host side of a run: run directory, image, podman run, host-only commands (stage, image, shell, lsp, mcp).
package host

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"wallet-build/internal/image"
	"wallet-build/internal/run"
	"wallet-build/internal/steps"
	"wallet-build/internal/sys"
)

// Host runs commands on the machine that has Podman.
type Host struct {
	C     *run.Ctx
	Self  string      // this binary, for nested runs (stage, relay-native-test)
	Usage func() int  // prints the usage text, returns 2
	IsTTY func() bool // stdin and stdout are terminals
	Image string
	// Download fetches url into dest (sqlite3mc.wasm); a variable for the tests.
	Download func(url, dest string) error
	// Signals delivers SIGINT/SIGTERM; a variable for the tests.
	Signals func() (<-chan os.Signal, func())

	flutter string
	run     *run.Dir
}

// New returns a Host with the real terminal check, downloader and signals.
func New(c *run.Ctx, self string, usage func() int) *Host {
	return &Host{C: c, Self: self, Usage: usage, IsTTY: realTTY, Download: httpDownload, Signals: realSignals}
}

func realSignals() (<-chan os.Signal, func()) {
	ch := make(chan os.Signal, 2)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	return ch, func() { signal.Stop(ch) }
}

var runCommands = map[string]bool{"test": true, "lint": true, "apk": true, "linux": true, "all": true, "importer": true, "core": true, "sync": true,
	"relay": true, "app": true, "mutate": true, "desktop-test": true, "desktop-smoke": true, "perf": true, "web": true, "web-test": true,
	"analyze": true, "outdated": true, "relay-bin": true, "format": true}

// begin starts the run (a nested call joins the outer one).
func (h *Host) begin(cmd string) error {
	d, err := h.C.Begin(cmd)
	if err != nil {
		return err
	}
	if d != nil {
		h.run = d
	}
	return nil
}

// failHost: a failure before any container step ran (missing key, unpinned wasm, ...): message to stderr and, in a run, to
// <step>.log with a failed status so last-failed.txt names it.
func (h *Host) failHost(step, msg string) int {
	c := h.C
	c.Eprintf("%s\n", msg)
	if dir := c.Getenv("BW_RUN_DIR"); dir != "" {
		now := c.NowISO()
		_ = os.WriteFile(filepath.Join(dir, step+".log"), []byte(fmt.Sprintf("# %s: started %s\n%s\n# %s: finished %s, 0.0 s, exit 1\n", step, now, c.Red.Clean(msg), step, c.NowISO())), 0o644)
		_ = os.WriteFile(filepath.Join(dir, step+".status"), []byte("0.0 1 "+c.NowISO()+"\n"), 0o644)
	}
	return 1
}

// TimedLog runs argv with its output on the terminal (stderr; split keeps stdout on stdout) and in logPath between start/end
// stamps, then writes a .status next to the log (same name) and a history line (step name; cold as given).
func (h *Host) TimedLog(name, logPath string, split bool, cold string, history bool, argv []string) int {
	c := h.C
	_ = os.MkdirAll(filepath.Dir(logPath), 0o755)
	startUs, started := c.Us(), c.NowISO()
	f, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|os.O_APPEND, 0o644)
	if err != nil {
		c.Eprintf("cannot write %s: %v\n", logPath, err)
		return 1
	}
	lf := run.NewLockedFile(f)
	fmt.Fprintf(lf, "# %s: started %s\n", name, started)
	outDst, errDst := c.Err, c.Err
	if split {
		outDst = c.Out
	}
	ow := c.Red.Writer(io.MultiWriter(lf, outDst))
	var ew io.WriteCloser = ow
	if split {
		ew = c.Red.Writer(io.MultiWriter(lf, errDst))
	}
	timeout := run.StepTimeout(c.Env, name, run.DefaultTimeout(c.Env, name))
	ctx, cancel := c.Ctx, context.CancelFunc(func() {})
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(c.Ctx, timeout)
	}
	rc := c.R.Run(ctx, sys.Cmd{Argv: argv, Env: c.Env, Stdout: ow, Stderr: ew})
	timedOut := ctx.Err() == context.DeadlineExceeded
	cancel()
	_ = ow.Close()
	if split {
		_ = ew.Close()
	}
	if timedOut {
		fmt.Fprintf(lf, "# %s: timed out after %d s\n", name, int(timeout/time.Second))
		rc = 124
	}
	secs := c.SecsSince(startUs)
	fmt.Fprintf(lf, "# %s: finished %s, %s s, exit %d\n", name, c.NowISO(), secs, rc)
	_ = f.Close()
	_ = os.WriteFile(strings.TrimSuffix(logPath, ".log")+".status", []byte(fmt.Sprintf("%s %d %s\n", secs, rc, started)), 0o644)
	if history {
		res := "ok"
		if rc != 0 {
			res = "FAILED"
		}
		c.LogHistory(name, secs, res, cold, started)
	}
	return rc
}

func (h *Host) buildImage(cmd string) int {
	if err := h.begin(cmd); err != nil {
		h.C.Eprintf("%v\n", err)
		return 1
	}
	rc := h.TimedLog("image", filepath.Join(h.C.Getenv("BW_RUN_DIR"), "image-dev.log"), false, "true", true,
		[]string{"podman", "build", "--build-arg", "FLUTTER_VERSION=" + h.flutter, "-t", h.Image, filepath.Join(h.C.Root, "dev")})
	h.C.Setenv("BW_COLD", "1")
	return rc
}

func (h *Host) imageExists() bool {
	return h.C.R.Run(h.C.Ctx, sys.Cmd{Argv: []string{"podman", "image", "exists", h.Image}, Env: h.C.Env}) == 0
}

// Main runs one command on the host and returns its exit code.
func (h *Host) Main(cmd string, rest []string) (code int) {
	c := h.C
	defer func() {
		if h.run != nil {
			h.run.Finish(code)
		}
	}()
	var err error
	if h.flutter, err = image.FlutterVersion(c.Root); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	if h.Image, err = image.Tag(c.Root); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	c.Setenv("BW_IMAGE", h.Image)
	_, envFile := h.signingPaths()
	c.Red = sys.NewRedactor(c.Env, sys.ReadSecretsFile(envFile)...) // the key's passwords never reach a log
	switch {
	case cmd == "image":
		return h.buildImage(cmd)
	case cmd == "image-name":
		if !h.imageExists() {
			if rc := h.buildImage(cmd); rc != 0 {
				return rc
			}
		}
		fmt.Fprintln(c.Out, h.Image)
		return 0
	case runCommands[cmd]:
		if err := h.begin(cmd); err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
	case cmd == "stage":
		return h.stage()
	case cmd == "relay-native-test":
		if err := h.begin(cmd); err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		if rc := h.nested("relay-bin", "x64"); rc != 0 {
			return 1
		}
		return h.TimedLog("relay-native-test", filepath.Join(c.Getenv("BW_RUN_DIR"), "relay-native-test.log"), true, "false", true,
			append([]string{filepath.Join(c.Root, "tools", "relay-native-test.sh")}, rest...))
	case cmd == "shell":
		if len(rest) > 0 && rest[0] == "-c" {
			if err := h.begin(cmd); err != nil {
				c.Eprintf("%v\n", err)
				return 1
			}
		}
	case cmd == "lsp" || cmd == "mcp":
	default:
		return h.Usage()
	}
	if cmd == "web" || cmd == "web-test" {
		if err := h.fetchSQLiteWasm(); err != nil {
			return h.failHost(cmd, "sqlite3mc.wasm unavailable (see the message above)")
		}
	}
	// mutate works on a copy, but a leftover mutant from an older run would be mutated again: refuse (checked here, the
	// worktree's git directory is not visible inside the container)
	if cmd == "mutate" {
		dirs := []string{"packages/wallet_core/lib", "packages/sync/lib", "packages/wallet_importer/lib"}
		if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: append([]string{"git", "-C", c.Root, "diff", "--quiet", "HEAD", "--"}, dirs...), Env: c.Env}); rc != 0 {
			return h.failHost("mutate", "mutate: lib files differ from HEAD (a leftover mutant?). Restore with: git checkout -- packages/wallet_core/lib packages/sync/lib packages/wallet_importer/lib")
		}
	}
	// Build output goes to stderr (stdout belongs to the LSP client in `lsp` mode)
	if !h.imageExists() {
		if rc := h.buildImage(cmd); rc != 0 {
			return rc
		}
	}
	switch cmd {
	case "lsp":
		return h.execStdio("lsp", nil, []string{"-v", fmt.Sprintf("%s:%s:z", c.Root, c.Root), "-v", "bw-pub-cache:/cache/pub", "-v", "bw-dart-server:/root/.dartServer"},
			[]string{filepath.Join(c.Root, "dist", "bin", "wallet-build"), "lsp"})
	case "mcp":
		// Like lsp, in the pod of tools/live.sh: the live app's VM service and DTD listen on the pod's 127.0.0.1.
		// dart mcp-server installs its pinned dart_mcp_server bundle on first use; the volume keeps it.
		pod, rc := c.Capture("", filepath.Join(c.Root, "tools", "live.sh"), "pod")
		if rc != 0 || pod == "" {
			c.Eprintf("tools/live.sh pod failed\n")
			return 1
		}
		return h.execStdio("mcp", []string{"--pod", pod}, []string{"-v", fmt.Sprintf("%s:%s:z", c.Root, c.Root), "-v", "bw-pub-cache:/cache/pub",
			"-v", "bw-dart-server:/root/.dartServer", "-v", "bw-dart-state:/root/.local/state/Dart"},
			append([]string{filepath.Join(c.Root, "dist", "bin", "wallet-build"), "mcp"}, rest...))
	}
	return h.podRun(cmd, rest)
}

// nested runs this binary again inside the current run (BW_RUN_DIR is set, so it joins it).
func (h *Host) nested(args ...string) int {
	c := h.C
	return c.R.Run(c.Ctx, sys.Cmd{Argv: append([]string{h.Self}, args...), Env: c.Env, Stdout: c.ChildOut, Stderr: c.ChildErr})
}

// execStdio replaces this process by podman: the editor talks to it on stdin/stdout.
func (h *Host) execStdio(kind string, podArgs, mounts, inner []string) int {
	c := h.C
	if d := h.run; d != nil { // a first-time image build left a run behind: close it before we vanish
		d.Finish(0)
		h.run = nil
	}
	argv := []string{"podman", "run", "--rm", "--init", "--name", image.ContainerName(orDefault(c.Getenv("BW_WORKTREE"), filepath.Base(c.Root)), fmt.Sprintf("%s-%d", kind, c.Clock().UnixNano())), "-i"}
	argv = append(argv, podArgs...)
	argv = append(argv, mounts...)
	argv = append(argv, "-e", "BW_NATIVE=1", "-w", c.Root, h.Image)
	argv = append(argv, inner...)
	if err := c.R.Exec(sys.Cmd{Argv: argv, Env: c.Env}); err != nil {
		c.Eprintf("exec podman: %v\n", err)
		return 127
	}
	return 0
}

// podRun hands the command to the container.
func (h *Host) podRun(cmd string, rest []string) int {
	c := h.C
	// Android release signing key (tools/make-signing-key.sh), mounted read-only
	signingDir, envFile := h.signingPaths()
	var signing []string
	if st, err := os.Stat(envFile); err == nil && st.Mode().IsRegular() {
		signing = []string{"-v", signingDir + ":/signing:ro,z", "--env-file", envFile, "-e", "BW_KEYSTORE=/signing/android-release.jks"}
	} else if cmd == "apk" || cmd == "all" {
		return h.failHost(cmd, fmt.Sprintf("No Android signing key in %s. Run tools/make-signing-key.sh first, otherwise the APK can't update the installed app.", signingDir))
	}
	// the host's go-check runs before the container (lint and test, in step lists of both implementations)
	if cmd == "lint" || cmd == "test" {
		s := run.NewSession(c)
		rc := s.RunStep("go-check", steps.GoCheck, true)
		s.Record("go-check", false)
		if rc != 0 {
			return 1
		}
	}
	tty := h.IsTTY()
	runDir := c.Getenv("BW_RUN_DIR")
	if runDir != "" && cmd == "shell" {
		tty = false // shell -c: logged through a pipe, no terminal
	}
	inner := append([]string{"dist/bin/wallet-build", cmd}, rest...)
	if cmd == "shell" {
		inner = append([]string{"bash"}, rest...)
	}
	name := image.ContainerName(orDefault(c.Getenv("BW_WORKTREE"), filepath.Base(c.Root)),
		orDefault(c.Getenv("BW_RUN_ID"), fmt.Sprintf("%s-%d", cmd, c.Clock().UnixNano())))
	argv := []string{"podman", "run", "--rm", "--init", "--name", name}
	if tty {
		argv = append(argv, "-it")
	}
	argv = append(argv, "-v", c.Root+":/work:z", "-v", "bw-pub-cache:/cache/pub", "-v", "bw-gradle-cache:/cache/gradle", "-v", "bw-android-user:/cache/android")
	argv = append(argv, signing...)
	if runDir != "" {
		argv = append(argv, "-v", c.Data+":"+c.Data+":z")
		for _, e := range image.RunEnv {
			argv = append(argv, "-e", e)
		}
	}
	argv = append(argv, "-e", "BW_NATIVE=1")
	for _, e := range image.PassEnv {
		argv = append(argv, "-e", e)
	}
	argv = append(argv, "-w", "/work", h.Image)
	argv = append(argv, inner...)
	if cmd == "shell" && runDir != "" { // shell -c: output to the terminal and to the run's shell.log
		return h.TimedLog("shell", filepath.Join(runDir, "shell.log"), true, "false", true, argv)
	}
	return h.runPodman(argv, name, tty)
}

func (h *Host) signingPaths() (dir, envFile string) {
	c := h.C
	dir = c.Getenv("BW_SIGNING_DIR")
	if dir == "" {
		dir = filepath.Join(c.Getenv("HOME"), ".config", "budget-wallet")
	}
	return dir, filepath.Join(dir, "signing.env")
}

func orDefault(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

// runPodman runs the container. SIGINT/SIGTERM on the host stop the container (`podman stop -t 10`), which --init reaps.
func (h *Host) runPodman(argv []string, name string, tty bool) int {
	c := h.C
	cmd := sys.Cmd{Argv: argv, Env: c.Env, Stdout: c.ChildOut, Stderr: c.ChildErr}
	if tty {
		cmd.Stdin, cmd.Foreground = os.Stdin, true
	}
	sigs, stop := h.Signals()
	defer stop()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan int, 1)
	go func() { done <- c.R.Run(ctx, cmd) }()
	select {
	case rc := <-done:
		return rc
	case sig := <-sigs:
		code := 130
		if sig == syscall.SIGTERM {
			code = 143
		}
		c.R.Run(context.Background(), sys.Cmd{Argv: []string{"podman", "stop", "-t", "10", name}, Env: c.Env})
		select {
		case rc := <-done:
			if rc == 0 || rc == 125 {
				rc = code
			}
			return rc
		case <-time.After(20 * time.Second):
			cancel()
			c.R.Run(context.Background(), sys.Cmd{Argv: []string{"podman", "rm", "-f", name}, Env: c.Env})
			<-done
			return code
		}
	}
}

// stage is the stage verification: one sub-run per step so each keeps its own run dir and history lines. Continues after a
// failure; stage-summary.txt goes into the stage's own run dir (dist/logs points there at the end).
func (h *Host) stage() int {
	c := h.C
	if err := h.begin("stage"); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	stageDir := c.Getenv("BW_RUN_DIR")
	type sub struct {
		name string
		argv []string
	}
	subs := []sub{{"test", []string{h.Self, "test"}}, {"desktop-test", []string{h.Self, "desktop-test"}}, {"web-test", []string{h.Self, "web-test"}}}
	vol := func(n string) bool {
		return c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "volume", "exists", n}, Env: c.Env}) == 0
	}
	if vol("bw-emulator") && vol("bw-emulator-image") {
		subs = append(subs, sub{"emulator-screens", []string{filepath.Join(c.Root, "tools", "emulator.sh"), "screens"}})
	} else {
		c.Printf("stage: emulator volumes missing, skipping emulator-screens (tools/emulator.sh screens sets them up, ~2 GB)\n")
	}
	subs = append(subs, sub{"perf", []string{h.Self, "perf"}})
	var names, secs, results, dirs []string
	failed := false
	subEnv := c.Env.Without("BW_RUN_DIR", "BW_RUN_ID", "BW_RUN", "BW_CMD", "BW_COLD")
	for _, s := range subs {
		c.Printf("=== stage: %s ===\n", s.name)
		start := c.Us()
		rc := c.R.Run(c.Ctx, sys.Cmd{Argv: s.argv, Env: subEnv, Stdout: c.ChildOut, Stderr: c.ChildErr})
		names = append(names, s.name)
		secs = append(secs, c.SecsSince(start))
		res := "ok"
		if rc != 0 {
			res = "FAILED"
			failed = true
		}
		results = append(results, res)
		d, _ := os.Readlink(filepath.Join(c.Root, "dist", "logs"))
		dirs = append(dirs, d)
		_ = os.WriteFile(filepath.Join(stageDir, s.name+".log"), []byte(fmt.Sprintf("# %s: sub-run %s\nfailed steps: %s/last-failed.txt\n", s.name, d, d)), 0o644)
		_ = os.WriteFile(filepath.Join(stageDir, s.name+".status"), []byte(fmt.Sprintf("%s %d %s\n", secs[len(secs)-1], rc, c.NowISO())), 0o644)
	}
	c.Link(stageDir)
	var sb strings.Builder
	for i := range names {
		fmt.Fprintf(&sb, "%-18s %8s s  %s\n", names[i], secs[i], results[i])
	}
	sb.WriteString(stageSummary(dirs))
	sb.WriteString("--- slowest 10 tests (tools/build-times.sh trend)\n")
	sb.WriteString(trendText(c))
	c.Printf("%s", sb.String())
	_ = os.WriteFile(filepath.Join(stageDir, "stage-summary.txt"), []byte(c.Red.Clean(sb.String())), 0o644)
	if failed {
		return 1
	}
	return 0
}
