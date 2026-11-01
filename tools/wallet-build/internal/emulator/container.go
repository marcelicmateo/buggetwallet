package emulator

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"

	"wallet-build/internal/report"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// emulatorLog is where the emulator process writes inside the container; avdHome is the AVD volume. Variables for the tests.
var (
	emulatorLog = "/tmp/emulator.log"
	avdHome     = "/opt/avd"
)

// Container runs one emulator command inside the container (BW_NATIVE=1): setup, boot, screens, test. args[0] is the command.
func Container(c *run.Ctx, args []string) int {
	cmd := "screens"
	if len(args) > 0 && args[0] != "" {
		cmd = args[0]
	}
	k := &cont{c: c}
	avd := avdHome
	emuDir := filepath.Join(c.Getenv("ANDROID_HOME"), "emulator")
	k.emuBin = filepath.Join(emuDir, "emulator")
	if c.Getenv("ANDROID_HOME") == "" {
		k.emuBin = "emulator"
	}
	k.avd = avd
	k.env = c.Env.With("ANDROID_AVD_HOME", avd, "PATH", emuDir+":"+c.Getenv("PATH"))
	k.logs = c.Getenv("BW_RUN_DIR")
	if k.logs == "" {
		k.logs = filepath.Join(c.Root, "dist", "logs")
	}
	_ = os.MkdirAll(k.logs, 0o755)
	c.TimingInit(cmd)
	switch cmd {
	case "setup":
		return k.setup()
	case "boot":
		return k.bootCmd(args[1:])
	case "screens":
		defer k.saveLog()
		return k.screens()
	case "test":
		defer k.saveLog()
		return k.test(args[1:])
	}
	return usage(c)
}

type cont struct {
	c      *run.Ctx
	env    sys.Env
	emuBin string
	avd    string
	logs   string

	mu      sync.Mutex
	stopEmu context.CancelFunc
	emuDone chan struct{}
}

// saveLog is the EXIT trap: the emulator's log goes into the run.
func (k *cont) saveLog() {
	k.stopEmulator()
	_ = copyFile(emulatorLog, filepath.Join(k.logs, "emulator.log"))
}

// startEmulator starts the emulator in the background with its output in /tmp/emulator.log.
func (k *cont) startEmulator(extra ...string) {
	f, err := os.Create(emulatorLog)
	if err != nil {
		k.c.Eprintf("%v\n", err)
		f = nil
	}
	ctx, cancel := context.WithCancel(k.c.Ctx)
	done := make(chan struct{})
	k.mu.Lock()
	k.stopEmu, k.emuDone = cancel, done
	k.mu.Unlock()
	argv := append(append([]string{k.emuBin}, EmuArgs...), extra...)
	go func() {
		defer close(done)
		cmd := sys.Cmd{Argv: argv, Env: k.env}
		if f != nil {
			cmd.Stdout, cmd.Stderr = f, f
			defer f.Close()
		}
		k.c.R.Run(ctx, cmd)
	}()
}

// stopEmulator ends the background emulator (SIGTERM, then SIGKILL after the runner's grace).
func (k *cont) stopEmulator() {
	k.mu.Lock()
	cancel, done := k.stopEmu, k.emuDone
	k.mu.Unlock()
	if cancel == nil {
		return
	}
	cancel()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
	}
}

func (k *cont) adb(ctx context.Context, out io.Writer, errw io.Writer, args ...string) int {
	return k.c.R.Run(ctx, sys.Cmd{Argv: append([]string{"adb"}, args...), Env: k.env, Stdout: out, Stderr: errw})
}

func (k *cont) adbOut(errw io.Writer, args ...string) (string, int) {
	var b strings.Builder
	rc := k.adb(k.c.Ctx, &b, errw, args...)
	return strings.TrimSpace(strings.ReplaceAll(b.String(), "\r", "")), rc
}

// tailLog prints the last n lines of the emulator log.
func (k *cont) tailLog(n int) {
	b, err := os.ReadFile(emulatorLog)
	if err != nil {
		return
	}
	lines := strings.SplitAfter(string(b), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	k.c.Printf("%s", strings.Join(lines, ""))
}

// waitBooted waits for the device and for sys.boot_completed (150 s), then turns the animations off. Returns 1 when it did not boot.
func (k *cont) waitBooted() int {
	c := k.c
	wctx, cancel := context.WithTimeout(c.Ctx, 60*time.Second)
	rc := k.adb(wctx, nil, c.Err, "wait-for-device")
	cancel()
	if rc != 0 {
		if b, err := os.ReadFile(emulatorLog); err == nil {
			c.Printf("%s", b)
		}
		return 1
	}
	for i := 0; i < 150; i++ {
		if v, _ := k.adbOut(nil, "shell", "getprop", "sys.boot_completed"); v == "1" {
			break
		}
		sleep(time.Second)
	}
	if v, _ := k.adbOut(c.Err, "shell", "getprop", "sys.boot_completed"); v != "1" {
		c.Printf("emulator did not boot\n")
		k.tailLog(30)
		return 1
	}
	for _, s := range []string{"window_animation_scale", "transition_animation_scale", "animator_duration_scale"} {
		k.adb(c.Ctx, c.Out, c.Err, "shell", "settings", "put", "global", s, "0")
	}
	return 0
}

// setup is the first use: install into the volumes, create the AVD, cold boot it once and save the clean-boot snapshot.
func (k *cont) setup() int {
	c := k.c
	lock, err := os.OpenFile(filepath.Join(k.avd, ".lock"), os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	defer lock.Close()
	_ = unix.Flock(int(lock.Fd()), unix.LOCK_EX) // several worktrees may start at once
	ready := filepath.Join(k.avd, ".ready")
	if b, err := os.ReadFile(ready); err == nil && strings.TrimRight(string(b), "\n") == SetupID {
		return 0
	}
	c.Printf("Setting up the emulator (first run: ~2 GB download)…\n")
	old, _ := filepath.Glob(filepath.Join(k.avd, "bw.*"))
	for _, p := range append(old, ready) {
		_ = os.RemoveAll(p)
	}
	if rc := k.sdk(nil, "sdkmanager", "emulator", SysImg); rc != 0 {
		return rc
	}
	if rc := k.sdk(strings.NewReader("no\n"), "avdmanager", "create", "avd", "-n", "bw", "-k", SysImg, "-d", "pixel_6"); rc != 0 {
		return rc
	}
	cfg, err := os.OpenFile(filepath.Join(k.avd, "bw.avd", "config.ini"), os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	_, _ = cfg.WriteString("hw.keyboard=yes\nhw.ramSize=3072\ndisk.dataPartition.size=6G\n")
	cfg.Close()
	k.startEmulator("-no-window", "-no-snapshot-load", "-wipe-data")
	k.adb(c.Ctx, nil, c.Err, "start-server")
	if rc := k.waitBooted(); rc != 0 {
		k.stopEmulator()
		return rc
	}
	sleep(10 * time.Second)                 // let first-boot work settle before the snapshot
	k.adb(c.Ctx, nil, c.Err, "emu", "kill") // saves the default_boot snapshot on exit
	k.mu.Lock()
	done := k.emuDone
	k.mu.Unlock()
	<-done
	if err := os.WriteFile(ready, []byte(SetupID+"\n"), 0o644); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	c.Printf("emulator ready\n")
	return 0
}

// sdk runs an SDK tool with its output thrown away (>/dev/null); errors stay visible.
func (k *cont) sdk(stdin io.Reader, tool string, args ...string) int {
	return k.c.R.Run(k.c.Ctx, sys.Cmd{Argv: append([]string{tool}, args...), Env: k.env, Stdin: stdin, Stderr: k.c.Err})
}

// boot starts the emulator from the snapshot, read-only (nothing is saved back) and waits until Android is up.
func (k *cont) boot(window bool) int {
	args := []string{"-read-only", "-no-snapshot-save"}
	if !window {
		args = append(args, "-no-window")
	}
	k.startEmulator(args...)
	k.adb(k.c.Ctx, nil, k.c.Err, "start-server")
	if rc := k.waitBooted(); rc != 0 {
		return rc
	}
	k.c.Printf("emulator booted\n")
	return 0
}

// timedBoot is `t=$(now_us); boot; log_history boot …`.
func (k *cont) timedBoot(window bool) int {
	t := k.c.Us()
	if rc := k.boot(window); rc != 0 {
		return rc
	}
	k.c.LogHistory("boot", k.c.SecsSince(t), "ok", "false", "")
	return 0
}

// bootCmd is `boot [window]`: the emulator keeps running as long as the container does.
func (k *cont) bootCmd(rest []string) int {
	window := len(rest) > 0 && rest[0] != ""
	if rc := k.timedBoot(window); rc != 0 {
		return rc
	}
	k.mu.Lock()
	done := k.emuDone
	k.mu.Unlock()
	select {
	case <-k.c.Ctx.Done():
		k.stopEmulator()
	case <-done: // the emulator exited: so does the container, the host's start sees it
	}
	return 0
}

func (k *cont) pubGet() int {
	return k.c.R.Run(k.c.Ctx, sys.Cmd{Argv: []string{"flutter", "pub", "get", "--enforce-lockfile"}, Dir: filepath.Join(k.c.Root, "app"), Env: k.env, Stderr: k.c.Err})
}

func (k *cont) screens() int {
	if rc := k.timedBoot(false); rc != 0 {
		return rc
	}
	_ = os.MkdirAll(filepath.Join(k.c.Root, "dist", "screens"), 0o755)
	if rc := k.pubGet(); rc != 0 {
		return rc
	}
	return k.drive("screens", "")
}

// testNames maps arguments (flows, flows_test, app/integration_test/flows_test.dart) to test names; none = every file.
func testNames(root string, args []string) []string {
	var names []string
	for _, n := range args {
		n = n[strings.LastIndex(n, "/")+1:]
		n = strings.TrimSuffix(n, ".dart")
		names = append(names, strings.TrimSuffix(n, "_test"))
	}
	if len(names) == 0 {
		files, _ := filepath.Glob(filepath.Join(root, "app", "integration_test", "*_test.dart"))
		sort.Strings(files)
		for _, f := range files {
			names = append(names, strings.TrimSuffix(filepath.Base(f), "_test.dart"))
		}
	}
	return names
}

func (k *cont) test(args []string) int {
	c := k.c
	names := testNames(c.Root, args)
	for _, n := range names {
		if _, err := os.Stat(filepath.Join(c.Root, "app", "integration_test", n+"_test.dart")); err != nil {
			c.Eprintf("no such test: app/integration_test/%s_test.dart\n", n)
			return 2
		}
	}
	if rc := k.timedBoot(false); rc != 0 {
		return rc
	}
	if rc := k.pubGet(); rc != 0 {
		return rc
	}
	rc := 0
	var table []string
	for _, n := range names {
		_ = os.RemoveAll(filepath.Join(c.Root, "dist", "screens", n))
		k.adb(c.Ctx, nil, nil, "uninstall", AppID) // each test file starts on a clean app
		t := c.Us()
		r := k.drive(n, n)
		res := "ok"
		if r != 0 {
			rc, res = 1, "FAILED"
		}
		table = append(table, fmt.Sprintf("%-12s %-7s %6s s", n, res, c.SecsSince(t)))
	}
	c.Printf("--- integration tests (emulator): %d files\n", len(names))
	for _, row := range table {
		c.Printf("  %s\n", row)
	}
	return rc
}

var (
	reBuild   = regexp.MustCompile(`Running Gradle task 'assembleDebug'\.\.\. *([0-9.]+)s$`)
	reInstall = regexp.MustCompile(`^Installing .*?([0-9]+)ms$`)
)

// lastMatch is `grep -oP … | tail -1` over the log's lines.
func lastMatch(path string, re *regexp.Regexp) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	last := ""
	r := bufio.NewReaderSize(f, 1<<20)
	for {
		line, err := r.ReadString('\n')
		line = strings.TrimRight(line, "\r\n")
		if m := re.FindStringSubmatch(line); m != nil {
			last = m[1]
		}
		if err != nil {
			return last
		}
	}
}

// driveArgs are the extra arguments of `flutter drive`: Skia, not Impeller (Impeller's GLES calls trip an abort in the emulator's
// software GLES decoder, 37.x). BW_DRIVE_ARGS="" (set but empty) switches that off once a newer emulator fixes it.
func driveArgs(env sys.Env) []string {
	if v, ok := env.Lookup("BW_DRIVE_ARGS"); ok {
		return strings.Fields(v)
	}
	return []string{"--no-enable-impeller"}
}

// drive runs `flutter drive` for one integration test (in app/), log in <logs>/[drive-]<suite>.log, then the build/install/test
// history lines and the per-test summary. An empty test name keeps the screenshot test's old output paths.
func (k *cont) drive(suite, name string) int {
	c := k.c
	logName := suite + ".log"
	if name != "" {
		logName = "drive-" + logName
	}
	logPath := filepath.Join(k.logs, logName)
	f, err := os.Create(logPath)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	argv := append([]string{"flutter", "drive", "--driver=test_driver/integration_test.dart", "--target=integration_test/" + suite + "_test.dart", "-d", Serial}, driveArgs(c.Env)...)
	t := c.Us()
	out := c.Red.Writer(io.MultiWriter(f, &lockedOut{c: c}))
	rc := c.R.Run(c.Ctx, sys.Cmd{Argv: argv, Dir: filepath.Join(c.Root, "app"), Env: k.env.With("BW_TEST_NAME", name), Stdout: out, Stderr: out})
	_ = out.Close()
	_ = f.Close()
	total, _ := strconv.ParseFloat(c.SecsSince(t), 64) // flutter drive builds, installs and runs in one go: split the time with the durations it prints
	build := lastMatch(logPath, reBuild)
	install := lastMatch(logPath, reInstall)
	result := "ok"
	if rc != 0 {
		result = "FAILED"
	}
	b, _ := strconv.ParseFloat(build, 64)
	instMS, _ := strconv.ParseFloat(install, 64)
	if build != "" {
		c.LogHistory("build", build, "ok", "false", "")
	}
	if install != "" {
		c.LogHistory("install", fmt.Sprintf("%.1f", instMS/1000), "ok", "false", "")
	}
	step := "test"
	if name != "" {
		step += "-" + name
	}
	c.LogHistory(step, fmt.Sprintf("%.1f", total-b-instMS/1000), result, "false", "")
	report.FromCtx(c, k.logs).Tests("drive", suite, []string{logPath})
	return rc
}

// lockedOut is the context's stdout as a writer.
type lockedOut struct{ c *run.Ctx }

func (l *lockedOut) Write(p []byte) (int, error) {
	l.c.Printf("%s", p)
	return len(p), nil
}
