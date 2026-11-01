package emulator

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

type crig struct {
	mu     sync.Mutex // the emulator runs in the background: the fake is called from two goroutines
	t      *testing.T
	root   string
	data   string
	logs   string
	avd    string
	elog   string
	fake   *sys.Fake
	c      *run.Ctx
	out    bytes.Buffer
	errb   bytes.Buffer
	booted bool // getprop says 1
	drive  func(c sys.Cmd) int
	sleeps []time.Duration
	envs   map[string]sys.Env // argv joined -> env of the call
	stdins map[string]string
	elogTx string // written to the emulator log once the emulator has started (at `adb start-server`)
}

func newCRig(t *testing.T, env ...string) *crig {
	r := &crig{t: t, root: mkRepo(t), data: t.TempDir(), booted: true, envs: map[string]sys.Env{}, stdins: map[string]string{}}
	r.logs, r.avd, r.elog = t.TempDir(), t.TempDir(), filepath.Join(t.TempDir(), "emulator.log")
	oldA, oldL := avdHome, emulatorLog
	avdHome, emulatorLog = r.avd, r.elog
	sleep = func(d time.Duration) { r.sleeps = append(r.sleeps, d) }
	t.Cleanup(func() { avdHome, emulatorLog, sleep = oldA, oldL, time.Sleep })
	r.fake = &sys.Fake{Handle: r.handle}
	e := append([]string{"PATH=/usr/bin", "HOME=" + t.TempDir(), "ANDROID_HOME=/opt/android-sdk", "BW_NATIVE=1", "BW_DATA_DIR=" + r.data, "BW_RUN_DIR=" + r.logs,
		"BW_RUN_ID=r1", "BW_RUN=2026-11-01T10:00:00+00:00", "BW_COMMIT=abc1234", "BW_CMD=test", "BW_SOURCE=local", "BW_WORKTREE=wt", "BW_IMAGE=img:1"}, env...)
	r.c = run.New(r.root, sys.Env(e), &r.out, &r.errb, r.fake)
	return r
}

func (r *crig) handle(c sys.Cmd) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := strings.Join(c.Argv, " ")
	r.envs[key] = c.Env
	if c.Stdin != nil && c.Argv[0] != "flutter" {
		b, _ := io.ReadAll(c.Stdin)
		r.stdins[key] = string(b)
	}
	switch {
	case key == "adb start-server" && r.elogTx != "":
		os.WriteFile(r.elog, []byte(r.elogTx), 0o644)
	case c.Argv[0] == "avdmanager":
		os.MkdirAll(filepath.Join(r.avd, "bw.avd"), 0o755)
		os.WriteFile(filepath.Join(r.avd, "bw.avd/config.ini"), []byte("image.sysdir.1=x\n"), 0o644)
	case c.Argv[0] == "adb" && strings.Contains(key, "getprop sys.boot_completed"):
		if r.booted {
			c.Stdout.Write([]byte("1\r\n"))
		} else {
			c.Stdout.Write([]byte("0\r\n"))
		}
	case c.Argv[0] == "flutter" && len(c.Argv) > 1 && c.Argv[1] == "drive" && r.drive != nil:
		return r.drive(c)
	}
	return 0
}

func (r *crig) calls() []string { return r.fake.Argvs() }

func (r *crig) history() string {
	b, _ := os.ReadFile(filepath.Join(r.data, "history", "steps.jsonl"))
	return string(b)
}

func idx(l []string, s string) int {
	for i, x := range l {
		if x == s {
			return i
		}
	}
	return -1
}

const emuBin = "/opt/android-sdk/emulator/emulator"

func TestContainerUsage(t *testing.T) {
	for _, cmd := range []string{"bogus", "host", "start"} {
		r := newCRig(t)
		if rc := Container(r.c, []string{cmd}); rc != 2 || r.out.String() != usageText {
			t.Errorf("%s: %d %q", cmd, rc, r.out.String())
		}
	}
}

func TestSetupAlreadyDone(t *testing.T) {
	r := newCRig(t)
	write(t, filepath.Join(r.avd, ".ready"), SetupID+"\n")
	if rc := Container(r.c, []string{"setup"}); rc != 0 {
		t.Fatal(rc)
	}
	if len(r.calls()) != 0 || r.out.String() != "" {
		t.Errorf("nothing to do: %v %q", r.calls(), r.out.String())
	}
	// a different id sets everything up again
	write(t, filepath.Join(r.avd, ".ready"), "0 old setup\n")
	if rc := Container(r.c, []string{"setup"}); rc != 0 || len(r.calls()) == 0 {
		t.Errorf("a changed setup id runs the setup: %d %v", rc, r.calls())
	}
}

func TestSetupSteps(t *testing.T) {
	r := newCRig(t)
	write(t, filepath.Join(r.avd, "bw.old/x"), "x")
	write(t, filepath.Join(r.avd, ".ready"), "stale\n")
	if rc := Container(r.c, []string{"setup"}); rc != 0 {
		t.Fatalf("exit %d %s", rc, r.errb.String())
	}
	want := []string{
		"sdkmanager emulator " + SysImg,
		"avdmanager create avd -n bw -k " + SysImg + " -d pixel_6",
		emuBin + " -avd bw -no-audio -no-boot-anim -gpu lavapipe -accel on -no-metrics -no-window -no-snapshot-load -wipe-data",
		"adb start-server",
		"adb wait-for-device",
		"adb shell getprop sys.boot_completed",
		"adb shell getprop sys.boot_completed",
		"adb shell settings put global window_animation_scale 0",
		"adb shell settings put global transition_animation_scale 0",
		"adb shell settings put global animator_duration_scale 0",
		"adb emu kill",
	}
	got := r.calls()
	// the emulator runs in the background: its call may land anywhere after sdkmanager/avdmanager, the rest is in order
	var rest []string
	for _, g := range got {
		if g != want[2] {
			rest = append(rest, g)
		}
	}
	wantRest := append(append([]string{}, want[:2]...), want[3:]...)
	if strings.Join(rest, "\n") != strings.Join(wantRest, "\n") || idx(got, want[2]) < 2 {
		t.Errorf("calls\n got %v\nwant %v", got, want)
	}
	if r.stdins["avdmanager create avd -n bw -k "+SysImg+" -d pixel_6"] != "no\n" {
		t.Errorf("avdmanager answers 'no' to the hardware profile question: %q", r.stdins)
	}
	env := r.envs[want[2]]
	if env.Get("ANDROID_AVD_HOME") != r.avd || !strings.HasPrefix(env.Get("PATH"), "/opt/android-sdk/emulator:") {
		t.Errorf("emulator env: AVD %q PATH %q", env.Get("ANDROID_AVD_HOME"), env.Get("PATH"))
	}
	if cfg := file(t, filepath.Join(r.avd, "bw.avd/config.ini")); cfg != "image.sysdir.1=x\nhw.keyboard=yes\nhw.ramSize=3072\ndisk.dataPartition.size=6G\n" {
		t.Errorf("config.ini %q", cfg)
	}
	if file(t, filepath.Join(r.avd, ".ready")) != SetupID+"\n" {
		t.Error(".ready")
	}
	if _, err := os.Stat(filepath.Join(r.avd, "bw.old")); err == nil {
		t.Error("old bw.* removed")
	}
	if r.out.String() != "Setting up the emulator (first run: ~2 GB download)…\nemulator ready\n" {
		t.Errorf("out %q", r.out.String())
	}
	if len(r.sleeps) != 1 || r.sleeps[0] != 10*time.Second {
		t.Errorf("sleeps %v (10 s before the snapshot)", r.sleeps)
	}
	if hist := r.history(); hist != "" {
		t.Errorf("setup writes no history: %s", hist)
	}
}

func TestSetupSdkFailure(t *testing.T) {
	r := newCRig(t)
	r.fake.Handle = func(c sys.Cmd) int {
		if c.Argv[0] == "sdkmanager" {
			return 7
		}
		return 0
	}
	if rc := Container(r.c, []string{"setup"}); rc != 7 {
		t.Errorf("exit %d", rc)
	}
	if _, err := os.Stat(filepath.Join(r.avd, ".ready")); err == nil {
		t.Error("no .ready after a failed setup")
	}
}

func TestBootStepsAndHistory(t *testing.T) {
	r := newCRig(t)
	if rc := Container(r.c, []string{"boot"}); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	got := r.calls()
	if idx(got, emuBin+" -avd bw -no-audio -no-boot-anim -gpu lavapipe -accel on -no-metrics -read-only -no-snapshot-save -no-window") < 0 {
		t.Errorf("boot argv %v", got)
	}
	if !strings.HasSuffix(r.out.String(), "emulator booted\n") {
		t.Errorf("out %q", r.out.String())
	}
	if h := r.history(); !strings.Contains(h, `"step":"boot","seconds":`) || !strings.Contains(h, `"cmd":"test"`) || !strings.Contains(h, `"result":"ok"`) {
		t.Errorf("history %s", h)
	}
	r = newCRig(t)
	Container(r.c, []string{"boot", "window"})
	if idx(r.calls(), emuBin+" -avd bw -no-audio -no-boot-anim -gpu lavapipe -accel on -no-metrics -read-only -no-snapshot-save") < 0 {
		t.Errorf("window: no -no-window: %v", r.calls())
	}
}

func TestBootFailures(t *testing.T) {
	r := newCRig(t)
	r.booted = false
	r.elogTx = strings.Repeat("old line\n", 40) + "last line\n"
	if rc := Container(r.c, []string{"boot"}); rc != 1 {
		t.Errorf("exit %d", rc)
	}
	if !strings.HasPrefix(r.out.String(), "emulator did not boot\n") || !strings.HasSuffix(r.out.String(), "last line\n") || strings.Count(r.out.String(), "\n") != 31 {
		t.Errorf("out %q", r.out.String())
	}
	if len(r.sleeps) != 150 {
		t.Errorf("polls: %d", len(r.sleeps))
	}
	if strings.Contains(strings.Join(r.calls(), "\n"), "settings put") || r.history() != "" {
		t.Error("no settings, no history after a failed boot")
	}
	// adb wait-for-device fails (timeout): the emulator log is shown
	r = newCRig(t)
	r.elogTx = "qemu says no\n"
	inner := r.fake.Handle
	r.fake.Handle = func(c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[1] == "wait-for-device" {
			return 143
		}
		return inner(c)
	}
	if rc := Container(r.c, []string{"boot"}); rc != 1 || r.out.String() != "qemu says no\n" {
		t.Errorf("wait-for-device: %d %q", rc, r.out.String())
	}
}

func driveOutput(c sys.Cmd, rc int) int {
	c.Stdout.Write([]byte("Launching integration_test/flows_test.dart on sdk gphone64 x86 64 in debug mode...\n" +
		"Running Gradle task 'assembleDebug'...                             45.3s\n" +
		"Installing build/app/outputs/flutter-apk/app-debug.apk...           2500ms\n" +
		"I/flutter ( 100): 00:00 +0: loading\n" +
		"I/flutter ( 100): 00:03 +1: first test\n" +
		"I/flutter ( 100): 00:07 +2: second test\n" +
		"I/flutter ( 100): 00:07 +2: All tests passed!\n"))
	return rc
}

func TestTestCommand(t *testing.T) {
	r := newCRig(t)
	var driveEnv []sys.Env
	var driveDirs []string
	r.drive = func(c sys.Cmd) int {
		driveEnv = append(driveEnv, c.Env)
		driveDirs = append(driveDirs, c.Dir)
		return driveOutput(c, 0)
	}
	os.MkdirAll(filepath.Join(r.root, "dist/screens/flows"), 0o755)
	write(t, filepath.Join(r.root, "dist/screens/flows/old.png"), "x")
	if rc := Container(r.c, []string{"test", "flows_test", "app/integration_test/a_test.dart"}); rc != 0 {
		t.Fatalf("exit %d\n%s%s", rc, r.out.String(), r.errb.String())
	}
	got := r.calls()
	order := []string{
		"adb start-server",
		"flutter pub get --enforce-lockfile",
		"adb uninstall hr.marcelic.budget_wallet",
		"flutter drive --driver=test_driver/integration_test.dart --target=integration_test/flows_test.dart -d emulator-5554 --no-enable-impeller",
		"adb uninstall hr.marcelic.budget_wallet",
		"flutter drive --driver=test_driver/integration_test.dart --target=integration_test/a_test.dart -d emulator-5554 --no-enable-impeller",
	}
	pos := 0
	for _, g := range got {
		if pos < len(order) && g == order[pos] {
			pos++
		}
	}
	if pos != len(order) {
		t.Errorf("calls out of order, matched %d of %d: %v", pos, len(order), got)
	}
	if _, err := os.Stat(filepath.Join(r.root, "dist/screens/flows")); err == nil {
		t.Error("the old screenshots of a test are removed first")
	}
	if len(driveEnv) != 2 || driveEnv[0].Get("BW_TEST_NAME") != "flows" || driveEnv[1].Get("BW_TEST_NAME") != "a" || driveDirs[0] != filepath.Join(r.root, "app") {
		t.Errorf("drive env/dir: %v %v", driveEnv, driveDirs)
	}
	for _, n := range []string{"flows", "a"} {
		if !strings.Contains(file(t, filepath.Join(r.logs, "drive-"+n+".log")), "Running Gradle task") {
			t.Errorf("drive-%s.log", n)
		}
		if !strings.HasPrefix(file(t, filepath.Join(r.logs, "tests-"+n+"-summary.txt")), "--- "+n+": 3 tests") {
			t.Errorf("tests-%s-summary.txt: %q", n, file(t, filepath.Join(r.logs, "tests-"+n+"-summary.txt")))
		}
	}
	// the table
	if !strings.Contains(r.out.String(), "--- integration tests (emulator): 2 files\n  flows        ok         0.0 s\n  a            ok         0.0 s\n") {
		t.Errorf("table:\n%s", r.out.String())
	}
	h := r.history()
	for _, want := range []string{`"step":"boot"`, `"step":"build","seconds":45.3,`, `"step":"install","seconds":2.5,`, `"step":"test-flows","seconds":`, `"step":"test-a","seconds":`,
		`"step": "flows", "kind": "drive"`} {
		if !strings.Contains(h, want) {
			t.Errorf("history lacks %s:\n%s", want, h)
		}
	}
	// the test seconds are the total minus the build and install time (the fake finishes at once: negative)
	if !strings.Contains(h, `"step":"test-flows","seconds":-4`) {
		t.Errorf("test-flows seconds should be 0 - 45.3 - 2.5 = -47.8:\n%s", h)
	}
}

func TestTestUnknownNameIsUsageError(t *testing.T) {
	r := newCRig(t)
	if rc := Container(r.c, []string{"test", "flows", "nope"}); rc != 2 {
		t.Errorf("exit %d", rc)
	}
	if r.errb.String() != "no such test: app/integration_test/nope_test.dart\n" {
		t.Errorf("err %q", r.errb.String())
	}
	if len(r.calls()) != 0 {
		t.Errorf("nothing starts: %v", r.calls())
	}
}

func TestTestAllFilesAndFailure(t *testing.T) {
	r := newCRig(t)
	r.drive = func(c sys.Cmd) int {
		rc := 0
		if strings.Contains(strings.Join(c.Argv, " "), "flows_test") {
			rc = 1
		}
		return driveOutput(c, rc)
	}
	if rc := Container(r.c, []string{"test"}); rc != 1 {
		t.Errorf("exit %d", rc)
	}
	// every *_test.dart of app/integration_test, sorted
	o := r.out.String()
	if !strings.Contains(o, "3 files\n  a            ok ") || !strings.Contains(o, "\n  flows        FAILED ") || !strings.Contains(o, "\n  screens      ok ") {
		t.Errorf("table:\n%s", o)
	}
	if !strings.Contains(r.history(), `"step":"test-flows","seconds":`) || !strings.Contains(r.history(), `"result":"FAILED"`) {
		t.Errorf("history:\n%s", r.history())
	}
}

func TestDriveArgs(t *testing.T) {
	for _, c := range []struct {
		env  []string
		want string
	}{{nil, "--no-enable-impeller"}, {[]string{"BW_DRIVE_ARGS="}, ""}, {[]string{"BW_DRIVE_ARGS=--enable-impeller -v"}, "--enable-impeller -v"}} {
		r := newCRig(t, c.env...)
		Container(r.c, []string{"test", "a"})
		want := "flutter drive --driver=test_driver/integration_test.dart --target=integration_test/a_test.dart -d emulator-5554"
		if c.want != "" {
			want += " " + c.want
		}
		if idx(r.calls(), want) < 0 {
			t.Errorf("%v: %v", c.env, r.calls())
		}
	}
}

func TestScreensCommand(t *testing.T) {
	r := newCRig(t)
	r.elogTx = "emulator log\n"
	r.drive = func(c sys.Cmd) int { return driveOutput(c, 0) }
	if rc := Container(r.c, []string{"screens"}); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	// the old output paths: screens.log (no drive- prefix), history step "test" (no name)
	if !strings.Contains(file(t, filepath.Join(r.logs, "screens.log")), "Installing build/app") {
		t.Error("screens.log")
	}
	if !strings.Contains(r.history(), `"step":"test","seconds":`) || strings.Contains(r.history(), `"step":"test-`) {
		t.Errorf("history %s", r.history())
	}
	if env := r.envs["flutter drive --driver=test_driver/integration_test.dart --target=integration_test/screens_test.dart -d emulator-5554 --no-enable-impeller"]; env.Get("BW_TEST_NAME") != "" {
		t.Error("BW_TEST_NAME is empty for the screenshot test")
	}
	if _, err := os.Stat(filepath.Join(r.root, "dist/screens")); err != nil {
		t.Error("dist/screens is created")
	}
	// the EXIT trap: the emulator's log into the run
	if file(t, filepath.Join(r.logs, "emulator.log")) != "emulator log\n" {
		t.Error("emulator.log not copied")
	}
	// default command
	r = newCRig(t)
	Container(r.c, nil)
	if idx(r.calls(), "flutter pub get --enforce-lockfile") < 0 {
		t.Errorf("default is screens: %v", r.calls())
	}
}

func TestLastMatchAndNames(t *testing.T) {
	p := filepath.Join(t.TempDir(), "l")
	write(t, p, "Installing a.apk...   10ms\nRunning Gradle task 'assembleDebug'...   1.5s\nInstalling a.apk...   1234ms\nRunning Gradle task 'assembleDebug'... 20s\nxInstalling no 5ms\n")
	if got := lastMatch(p, reInstall); got != "1234" {
		t.Errorf("install %q", got)
	}
	if got := lastMatch(p, reBuild); got != "20" {
		t.Errorf("build %q", got)
	}
	if got := lastMatch(filepath.Join(t.TempDir(), "none"), reBuild); got != "" {
		t.Errorf("missing %q", got)
	}
	if got := strings.Join(testNames("/nowhere", []string{"flows", "x_test", "dir/y_test.dart", "z.dart"}), ","); got != "flows,x,y,z" {
		t.Errorf("names %s", got)
	}
}
