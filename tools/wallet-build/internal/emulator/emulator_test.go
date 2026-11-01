package emulator

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/host"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

const devTag = "localhost/budget-wallet-dev:3.47.7-"

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func file(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func mkRepo(t *testing.T) string {
	root := t.TempDir()
	write(t, filepath.Join(root, "app/pubspec.yaml"), "environment:\n  sdk: ^3.0.0\n  flutter: \"3.47.7\"\n")
	for _, f := range []string{"dev/Containerfile", "dev/install-lint-tools.sh", "dev/linux-packages.txt"} {
		write(t, filepath.Join(root, f), f)
	}
	write(t, filepath.Join(root, "dev/Containerfile.emulator"), "FROM x\n")
	for _, n := range []string{"flows", "screens", "a"} {
		write(t, filepath.Join(root, "app/integration_test/"+n+"_test.dart"), "")
	}
	return root
}

// rig is a host side with a fake podman.
type rig struct {
	t      *testing.T
	root   string
	data   string
	fake   *sys.Fake
	c      *run.Ctx
	h      *host.Host
	out    bytes.Buffer
	errb   bytes.Buffer
	exists map[string]bool // podman image/container exists
	state  struct{ running bool }
	logs   string // what `podman logs` prints
	hook   func(c sys.Cmd) (int, bool)
}

func newRig(t *testing.T, env ...string) *rig {
	r := &rig{t: t, root: mkRepo(t), data: t.TempDir(), exists: map[string]bool{}}
	sleep = func(time.Duration) {}
	t.Cleanup(func() { sleep = time.Sleep })
	r.fake = &sys.Fake{Handle: r.handle}
	e := append([]string{"PATH=/usr/bin", "HOME=" + t.TempDir(), "BW_DATA_DIR=" + r.data, "BW_COMMIT=abc1234", "BW_SOURCE=local", "BW_WORKTREE=wt"}, env...)
	r.c = run.New(r.root, sys.Env(e), &r.out, &r.errb, r.fake)
	r.h = host.New(r.c, "/x/wallet-build", func() int { return 2 })
	return r
}

func (r *rig) handle(c sys.Cmd) int {
	a := c.Argv
	if r.hook != nil {
		if rc, ok := r.hook(c); ok {
			return rc
		}
	}
	if a[0] != "podman" {
		return 0
	}
	switch {
	case len(a) > 3 && a[1] == "image" && a[2] == "exists":
		return b2rc(r.exists[a[3]])
	case len(a) > 3 && a[1] == "container" && a[2] == "exists":
		return b2rc(r.exists[a[3]])
	case a[1] == "inspect" && strings.Contains(strings.Join(a, " "), ".State.Running"):
		if r.state.running {
			c.Stdout.Write([]byte("true\n"))
		} else {
			c.Stdout.Write([]byte("false\n"))
		}
	case a[1] == "inspect":
		c.Stdout.Write([]byte(r.labelRun() + "\n"))
	case a[1] == "logs":
		c.Stdout.Write([]byte(r.logs))
	}
	return 0
}

var labelDir string

func (r *rig) labelRun() string { return labelDir }

func b2rc(b bool) int {
	if b {
		return 0
	}
	return 1
}

// allImages makes the dev and the emulator image exist.
func (r *rig) allImages() {
	b, _ := os.ReadFile(filepath.Join(r.root, "dev/Containerfile.emulator"))
	r.exists[r.devImage()] = true
	r.exists[EmuTag(r.devImage(), b)] = true
}

func (r *rig) devImage() string {
	if err := r.h.Init(); err != nil {
		r.t.Fatal(err)
	}
	return r.h.Image
}

func (r *rig) host(args ...string) int { return Host(r.h, args) }

func (r *rig) podmanRuns(verb string) []string {
	var out []string
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == verb {
			out = append(out, strings.Join(c.Argv, " "))
		}
	}
	return out
}

func (r *rig) runDir() string {
	m, _ := filepath.Glob(filepath.Join(r.data, "runs", "*"))
	if len(m) != 1 {
		r.t.Fatalf("run dirs: %v", m)
	}
	return m[0]
}

func (r *rig) history() string {
	b, _ := os.ReadFile(filepath.Join(r.data, "history", "steps.jsonl"))
	return string(b)
}

const runEnvFlags = "-e BW_DATA_DIR -e BW_RUN_DIR -e BW_RUN_ID -e BW_RUN -e BW_COMMIT -e BW_CMD -e BW_IMAGE -e BW_COLD -e BW_SOURCE -e BW_WORKTREE"

func TestEmuTag(t *testing.T) {
	// made by: (echo base; cat dev/Containerfile.emulator) | sha256sum | cut -c1-8
	if got := EmuTag("localhost/budget-wallet-dev:3.47.7-abcd1234", []byte("FROM x\n")); got != "localhost/budget-wallet-emu:aadc027d" {
		t.Errorf("tag %s", got)
	}
}

func TestUsageIsTwoForEveryUnknownCommand(t *testing.T) {
	for _, cmd := range []string{"no-such-command", "setup", "boot", "serve", "Screens"} {
		r := newRig(t)
		if rc := r.host(cmd); rc != 2 {
			t.Errorf("%s: exit %d", cmd, rc)
		}
		if r.out.String() != usageText || !strings.HasPrefix(r.out.String(), "Android emulator in a rootless Podman container") {
			t.Errorf("%s: usage text %q", cmd, r.out.String())
		}
		if len(r.fake.Calls) != 0 {
			t.Errorf("%s: ran %v", cmd, r.fake.Argvs())
		}
	}
	r := newRig(t)
	r.exists["bw-emulator"], r.state.running = true, true
	if rc := r.host("shot"); rc != 2 { // shot needs a name
		t.Errorf("shot without a name: %d", rc)
	}
	r = newRig(t)
	if rc := r.host("shot", "x"); rc != 1 || !strings.Contains(r.errb.String(), "No emulator running. Start one with: tools/emulator.sh start") {
		t.Errorf("shot, not running: %d %q", rc, r.errb.String())
	}
}

func TestScreensArgvAndFiles(t *testing.T) {
	r := newRig(t)
	r.allImages()
	if rc := r.host("screens"); rc != 0 {
		t.Fatalf("exit %d\n%s%s", rc, r.out.String(), r.errb.String())
	}
	id := filepath.Base(r.runDir())
	if !strings.HasSuffix(id, "-screens-abc1234") {
		t.Errorf("run id %s", id)
	}
	runs := r.podmanRuns("run")
	if len(runs) != 2 {
		t.Fatalf("podman runs: %v", runs)
	}
	emu := "localhost/budget-wallet-emu:" + strings.TrimPrefix(strings.Fields(runs[0])[len(strings.Fields(runs[0]))-4], "localhost/budget-wallet-emu:")
	vols := "-v bw-emulator:/opt/android-sdk/emulator -v bw-emulator-image:/opt/android-sdk/system-images -v bw-emulator-avd:/opt/avd"
	wantSetup := "podman run --rm --init --name wallet-build-wt-" + id + "-setup --device /dev/kvm --shm-size=2g " + vols + " -v " + r.data + ":" + r.data + ":z " +
		runEnvFlags + " -v " + r.root + ":/work:z -e BW_NATIVE=1 -w /work " + emu + " dist/bin/wallet-build emulator setup"
	if runs[0] != wantSetup {
		t.Errorf("setup argv\n got %s\nwant %s", runs[0], wantSetup)
	}
	wantScreens := "podman run --rm --init --name wallet-build-wt-" + id + "-screens --device /dev/kvm --shm-size=2g -e BW_DRIVE_ARGS -v " + r.root + ":/work:z " +
		"-v bw-pub-cache:/cache/pub -v bw-gradle-cache:/cache/gradle -v bw-android-user:/cache/android -e BW_NATIVE=1 -w /work " +
		"-v bw-emulator:/opt/android-sdk/emulator:ro -v bw-emulator-image:/opt/android-sdk/system-images:ro -v bw-emulator-avd:/opt/avd " +
		"-v " + r.data + ":" + r.data + ":z " + runEnvFlags + " -e BW_CLEAR_AVD_LOCK=1 " + emu + " dist/bin/wallet-build emulator screens"
	if runs[1] != wantScreens {
		t.Errorf("screens argv\n got %s\nwant %s", runs[1], wantScreens)
	}
	dir := r.runDir()
	for _, f := range []string{"emulator-screens.log", "emulator-screens.status", "image-emulator-setup.log", "last.status", "last-failed.txt"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("missing %s", f)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, ".running")); err == nil {
		t.Error(".running left behind")
	}
	log := file(t, filepath.Join(dir, "emulator-screens.log"))
	if !strings.HasPrefix(log, "# emulator-screens: started ") || !strings.Contains(log, "# emulator-screens: finished ") || !strings.HasSuffix(log, "s, exit 0\n") {
		t.Errorf("log stamps %q", log)
	}
	if got := strings.Fields(file(t, filepath.Join(dir, "emulator-screens.status"))); len(got) != 3 || got[1] != "0" {
		t.Errorf("status %v", got)
	}
	if ls := file(t, filepath.Join(dir, "last.status")); !strings.HasPrefix(ls, "emulator-screens ok ") {
		t.Errorf("last.status %q", ls)
	}
	// history: prepare and total, nothing for the emulator-screens step itself, image = the emulator image
	h := r.history()
	if !strings.Contains(h, `"step":"prepare"`) || !strings.Contains(h, `"step":"total"`) || strings.Contains(h, `"step":"emulator-screens"`) {
		t.Errorf("history:\n%s", h)
	}
	if !strings.Contains(h, `"cmd":"screens"`) || !strings.Contains(h, `"image":"`+emu+`"`) || !strings.Contains(h, `"cold":false`) {
		t.Errorf("history fields:\n%s", h)
	}
}

func TestScreensCopiesScreenshots(t *testing.T) {
	r := newRig(t)
	r.allImages()
	write(t, filepath.Join(r.root, "dist/screens/home.png"), "png")
	write(t, filepath.Join(r.root, "dist/screens/flows/a.png"), "a")
	write(t, filepath.Join(r.root, "dist/screens/flows/deep/b.png"), "b")
	if rc := r.host("screens"); rc != 0 {
		t.Fatal(rc)
	}
	if file(t, filepath.Join(r.runDir(), "home.png")) != "png" {
		t.Error("screens: png not copied")
	}
	if _, err := os.Stat(filepath.Join(r.runDir(), "flows")); err == nil {
		t.Error("screens copies the top-level pngs only")
	}
	r = newRig(t)
	r.allImages()
	write(t, filepath.Join(r.root, "dist/screens/home.png"), "png")
	write(t, filepath.Join(r.root, "dist/screens/flows/a.png"), "a")
	write(t, filepath.Join(r.root, "dist/screens/flows/deep/b.png"), "b")
	if rc := r.host("test", "flows"); rc != 0 {
		t.Fatal(rc)
	}
	d := r.runDir()
	if file(t, filepath.Join(d, "screens/flows/a.png")) != "a" || file(t, filepath.Join(d, "screens/flows/deep/b.png")) != "b" {
		t.Error("test: screenshot folders not copied")
	}
	if _, err := os.Stat(filepath.Join(d, "screens/home.png")); err == nil {
		t.Error("test copies the folders only")
	}
	runs := r.podmanRuns("run")
	if !strings.HasSuffix(runs[1], " dist/bin/wallet-build emulator test flows") {
		t.Errorf("test argv %s", runs[1])
	}
	if !strings.Contains(runs[1], "--name wallet-build-wt-"+filepath.Base(d)+"-test ") {
		t.Errorf("container name %s", runs[1])
	}
}

func TestTestPassesNamesThrough(t *testing.T) {
	r := newRig(t)
	r.allImages()
	r.host("test", "flows_test", "app/integration_test/a_test.dart")
	if runs := r.podmanRuns("run"); !strings.HasSuffix(runs[1], " emulator test flows_test app/integration_test/a_test.dart") {
		t.Errorf("%s", runs[1])
	}
}

func TestScreensFailureIsRecorded(t *testing.T) {
	r := newRig(t)
	r.allImages()
	r.hook = func(c sys.Cmd) (int, bool) {
		if c.Argv[0] == "podman" && c.Argv[1] == "run" && strings.HasSuffix(strings.Join(c.Argv, " "), "emulator screens") {
			c.Stdout.Write([]byte("out line\n"))
			c.Stderr.Write([]byte("err line\n"))
			return 1, true
		}
		return 0, false
	}
	if rc := r.host("screens"); rc != 1 {
		t.Fatalf("exit %d", rc)
	}
	if !strings.Contains(r.out.String(), "out line\n") || !strings.Contains(r.errb.String(), "err line\n") {
		t.Errorf("stdout/stderr stay apart: %q %q", r.out.String(), r.errb.String())
	}
	d := r.runDir()
	log := file(t, filepath.Join(d, "emulator-screens.log"))
	if !strings.Contains(log, "out line\n") || !strings.Contains(log, "err line\n") || !strings.HasSuffix(log, "s, exit 1\n") {
		t.Errorf("log %q", log)
	}
	if lf := file(t, filepath.Join(d, "last-failed.txt")); lf != "emulator-screens "+r.root+"/dist/logs/emulator-screens.log\n" {
		t.Errorf("last-failed %q", lf)
	}
	if !strings.Contains(r.history(), `"step":"total","seconds":`) || !strings.Contains(r.history(), `"result":"FAILED"`) {
		t.Errorf("history:\n%s", r.history())
	}
}

func TestSetupFailureStopsTheRun(t *testing.T) {
	r := newRig(t)
	r.allImages()
	r.hook = func(c sys.Cmd) (int, bool) {
		if c.Argv[0] == "podman" && c.Argv[1] == "run" && strings.HasSuffix(strings.Join(c.Argv, " "), "emulator setup") {
			return 125, true
		}
		return 0, false
	}
	if rc := r.host("screens"); rc != 125 {
		t.Errorf("exit %d", rc)
	}
	if len(r.podmanRuns("run")) != 1 {
		t.Errorf("the screens container must not start: %v", r.podmanRuns("run"))
	}
	if lf := file(t, filepath.Join(r.runDir(), "last-failed.txt")); !strings.HasPrefix(lf, "run "+r.runDir()+" (exit 125, no failed step recorded)") {
		t.Errorf("last-failed %q", lf)
	}
}

func TestImagesBuiltAndColdStart(t *testing.T) {
	r := newRig(t) // nothing exists: both images are built
	if rc := r.host("screens"); rc != 0 {
		t.Fatalf("exit %d %s", rc, r.errb.String())
	}
	var builds []string
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "build" {
			builds = append(builds, strings.Join(c.Argv, " "))
		}
	}
	dev := r.devImage()
	if len(builds) != 2 || builds[0] != "podman build --build-arg FLUTTER_VERSION=3.47.7 -t "+dev+" "+r.root+"/dev" ||
		!strings.HasPrefix(builds[1], "podman build --build-arg BASE="+dev+" -f "+r.root+"/dev/Containerfile.emulator -t localhost/budget-wallet-emu:") ||
		!strings.HasSuffix(builds[1], " "+r.root+"/dev") {
		t.Errorf("builds: %v", builds)
	}
	d := r.runDir()
	for _, f := range []string{"image-dev.log", "image-dev.status", "image-emulator.log", "image-emulator.status"} {
		if _, err := os.Stat(filepath.Join(d, f)); err != nil {
			t.Errorf("missing %s", f)
		}
	}
	h := r.history()
	if !strings.Contains(h, `"step":"emulator-image"`) || !strings.Contains(h, `"step":"image"`) {
		t.Errorf("history:\n%s", h)
	}
	for _, line := range strings.Split(strings.TrimSpace(h), "\n") {
		if !strings.HasSuffix(line, `"cold":true}`) {
			t.Errorf("a cold start marks every line: %s", line)
		}
	}
	// the host's setup log with "Setting up" also makes the run cold
	r = newRig(t)
	r.allImages()
	r.hook = func(c sys.Cmd) (int, bool) {
		if c.Argv[0] == "podman" && c.Argv[1] == "run" && strings.HasSuffix(strings.Join(c.Argv, " "), "emulator setup") {
			c.Stdout.Write([]byte("Setting up the emulator (first run: ~2 GB download)…\nemulator ready\n"))
			return 0, true
		}
		return 0, false
	}
	r.host("screens")
	if !strings.Contains(r.history(), `"step":"total"`) || !strings.Contains(r.history(), `"cold":true`) {
		t.Errorf("history:\n%s", r.history())
	}
	if !strings.Contains(r.out.String(), "") || !strings.Contains(r.errb.String(), "Setting up the emulator") {
		t.Errorf("the setup output goes to stderr: %q", r.errb.String())
	}
	if !strings.Contains(file(t, filepath.Join(r.runDir(), "image-emulator-setup.log")), "emulator ready") {
		t.Error("setup log")
	}
}

func TestStartArgvAndReady(t *testing.T) {
	r := newRig(t, "DISPLAY=:7", "XAUTHORITY=/home/u/.Xauthority")
	r.allImages()
	n := 0
	r.hook = func(c sys.Cmd) (int, bool) {
		if len(c.Argv) > 1 && c.Argv[1] == "logs" {
			if n++; n >= 3 {
				c.Stdout.Write([]byte("emulator booted\n"))
			}
			return 0, true
		}
		if len(c.Argv) > 1 && c.Argv[1] == "run" && c.Argv[2] == "-d" {
			r.exists["bw-emulator"], r.state.running = true, true // the new container is running
		}
		return 0, false
	}
	if rc := r.host("start"); rc != 0 {
		t.Fatalf("exit %d %s", rc, r.errb.String())
	}
	if !strings.Contains(r.out.String(), "booting…\nready (emulator-5554)\n") {
		t.Errorf("out %q", r.out.String())
	}
	runs := r.podmanRuns("run")
	d := r.runDir()
	want := "podman run -d --init --name bw-emulator --label bw.run=" + d + " --device /dev/kvm --shm-size=2g -e BW_DRIVE_ARGS -v " + r.root + ":/work:z " +
		"-v bw-pub-cache:/cache/pub -v bw-gradle-cache:/cache/gradle -v bw-android-user:/cache/android -e BW_NATIVE=1 -w /work " +
		"-v bw-emulator:/opt/android-sdk/emulator:ro -v bw-emulator-image:/opt/android-sdk/system-images:ro -v bw-emulator-avd:/opt/avd " +
		"-v " + r.data + ":" + r.data + ":z " + runEnvFlags + " "
	if !strings.HasPrefix(runs[1], want) || !strings.HasSuffix(runs[1], " dist/bin/wallet-build emulator boot") {
		t.Errorf("start argv\n got %s\nwant %s...", runs[1], want)
	}
	if strings.Contains(runs[1], "DISPLAY") || strings.Contains(runs[1], ".X11-unix") {
		t.Error("no window: no X11")
	}
	// `podman rm -f bw-emulator` first, quietly
	if !contains(r.fake.Argvs(), "podman rm -f bw-emulator") {
		t.Errorf("calls %v", r.fake.Argvs())
	}
	if ls := file(t, filepath.Join(d, "last.status")); !strings.Contains(ls, "") {
		t.Error(ls)
	}
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func TestStartWindow(t *testing.T) {
	r := newRig(t, "DISPLAY=:7", "XAUTHORITY=/home/u/.Xauthority")
	r.allImages()
	r.logs = "emulator booted\n"
	r.hook = func(c sys.Cmd) (int, bool) { return 0, false }
	if rc := r.host("start", "--window"); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	got := r.podmanRuns("run")[1]
	win := "-e DISPLAY=:7 -e QT_QPA_PLATFORM=xcb -v /tmp/.X11-unix:/tmp/.X11-unix:ro -e XAUTHORITY=/tmp/xauth -v /home/u/.Xauthority:/tmp/xauth:ro --security-opt label=disable "
	if !strings.Contains(got, runEnvFlags+" -e BW_CLEAR_AVD_LOCK=1 "+win+devOrEmu(got)) || !strings.HasSuffix(got, " dist/bin/wallet-build emulator boot window") {
		t.Errorf("window argv %s", got)
	}
	// without DISPLAY: :0
	r = newRig(t)
	r.allImages()
	r.logs = "emulator booted\n"
	r.host("start", "--window")
	if got := r.podmanRuns("run")[1]; !strings.Contains(got, "-e DISPLAY=:0 -e QT_QPA_PLATFORM=xcb") || strings.Contains(got, "XAUTHORITY") {
		t.Errorf("default display: %s", got)
	}
}

func devOrEmu(argv string) string {
	f := strings.Fields(argv)
	for i, x := range f {
		if strings.HasPrefix(x, "localhost/budget-wallet-emu:") {
			_ = i
			return x
		}
	}
	return ""
}

func TestStartAlreadyRunningAndFailures(t *testing.T) {
	r := newRig(t)
	r.exists["bw-emulator"], r.state.running = true, true
	if rc := r.host("start"); rc != 0 || r.out.String() != "already running\n" {
		t.Errorf("already running: %d %q", rc, r.out.String())
	}
	if len(r.podmanRuns("run")) != 0 {
		t.Error("nothing starts")
	}
	// the container dies before it booted: its last log lines, exit 1
	r = newRig(t)
	r.allImages()
	var lines []string
	for i := 1; i <= 40; i++ {
		lines = append(lines, "line "+string(rune('a'+i%26))+strings.Repeat("x", i%3))
	}
	r.logs = strings.Join(lines, "\n") + "\n"
	r.hook = func(c sys.Cmd) (int, bool) { return 0, false } // never running
	if rc := r.host("start"); rc != 1 {
		t.Errorf("died: %d", rc)
	}
	if got := strings.Count(r.out.String(), "\n"); got != 1+30 { // "booting…" + 30 log lines
		t.Errorf("tail of 30 lines, got %d lines:\n%s", got, r.out.String())
	}
	// never booted within 180 polls
	r = newRig(t)
	r.allImages()
	r.logs = "still starting\n"
	polls := 0
	r.hook = func(c sys.Cmd) (int, bool) {
		if len(c.Argv) > 2 && c.Argv[1] == "run" && c.Argv[2] == "-d" {
			r.exists["bw-emulator"], r.state.running = true, true
		}
		if len(c.Argv) > 2 && c.Argv[1] == "logs" {
			polls++
		}
		return 0, false
	}
	if rc := r.host("start"); rc != 1 || !strings.Contains(r.out.String(), "timed out\nstill starting\n") {
		t.Errorf("timeout: %d %q", rc, r.out.String())
	}
	if polls != StartPolls+1 { // 180 polls plus the tail
		t.Errorf("polls %d", polls)
	}
	// podman run itself fails
	r = newRig(t)
	r.allImages()
	r.hook = func(c sys.Cmd) (int, bool) {
		if len(c.Argv) > 2 && c.Argv[1] == "run" && c.Argv[2] == "-d" {
			return 125, true
		}
		return 0, false
	}
	if rc := r.host("start"); rc != 125 {
		t.Errorf("run -d failed: %d", rc)
	}
}

func TestInstall(t *testing.T) {
	r := newRig(t)
	r.exists["bw-emulator"], r.state.running = true, true
	r.hook = func(c sys.Cmd) (int, bool) {
		if len(c.Argv) > 2 && c.Argv[1] == "exec" {
			c.Stdout.Write([]byte("Success\n"))
		}
		return 0, false
	}
	if rc := r.host("install"); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	if !contains(r.fake.Argvs(), "podman exec bw-emulator adb install -r /work/dist/BudgetWallet-android.apk") {
		t.Errorf("calls %v", r.fake.Argvs())
	}
	if r.out.String() != "Success\n" {
		t.Errorf("stdout %q", r.out.String())
	}
	d := r.runDir()
	if !strings.Contains(file(t, filepath.Join(d, "emulator-install.log")), "Success\n") {
		t.Error("log")
	}
	h := r.history()
	if !strings.Contains(h, `"cmd":"install","step":"emulator-install"`) || !strings.Contains(h, `"result":"ok"`) || !strings.Contains(h, `"cold":false`) {
		t.Errorf("history %s", h)
	}
	r = newRig(t)
	r.exists["bw-emulator"], r.state.running = true, true
	r.host("install", "/tmp/x.apk")
	if !contains(r.fake.Argvs(), "podman exec bw-emulator adb install -r /tmp/x.apk") {
		t.Errorf("absolute path: %v", r.fake.Argvs())
	}
	r = newRig(t)
	if rc := r.host("install"); rc != 1 || len(r.fake.Calls) != 1 { // container exists (no), nothing else
		t.Errorf("not running: %d %v", rc, r.fake.Argvs())
	}
}

func TestShotAndAdb(t *testing.T) {
	r := newRig(t)
	r.exists["bw-emulator"], r.state.running = true, true
	r.hook = func(c sys.Cmd) (int, bool) {
		if len(c.Argv) > 3 && c.Argv[1] == "exec" && c.Argv[4] == "exec-out" {
			c.Stdout.Write([]byte("\x89PNGdata"))
			return 0, true
		}
		if len(c.Argv) > 3 && c.Argv[1] == "exec" {
			c.Stdout.Write([]byte("List of devices attached\n"))
			return 0, true
		}
		return 0, false
	}
	if rc := r.host("shot", "home"); rc != 0 || r.out.String() != "dist/screens/home.png\n" {
		t.Errorf("shot: %d %q", rc, r.out.String())
	}
	if file(t, filepath.Join(r.root, "dist/screens/home.png")) != "\x89PNGdata" {
		t.Error("png")
	}
	if !contains(r.fake.Argvs(), "podman exec bw-emulator adb exec-out screencap -p") {
		t.Errorf("%v", r.fake.Argvs())
	}
	r.out.Reset()
	if rc := r.host("adb", "devices", "-l"); rc != 0 || r.out.String() != "List of devices attached\n" {
		t.Errorf("adb: %d %q", rc, r.out.String())
	}
	if !contains(r.fake.Argvs(), "podman exec bw-emulator adb devices -l") {
		t.Errorf("%v", r.fake.Argvs())
	}
	if len(r.podmanRuns("run")) != 0 {
		t.Error("no run dir, no image for shot and adb")
	}
	if m, _ := filepath.Glob(filepath.Join(r.data, "runs", "*")); len(m) != 0 {
		t.Errorf("shot and adb make no run: %v", m)
	}
}

func TestStopAndReset(t *testing.T) {
	r := newRig(t)
	if rc := r.host("stop"); rc != 0 || r.out.String() != "not running\n" {
		t.Errorf("stop, none: %d %q", rc, r.out.String())
	}
	r = newRig(t)
	dir := t.TempDir()
	labelDir = dir
	t.Cleanup(func() { labelDir = "" })
	r.exists["bw-emulator"] = true
	if rc := r.host("stop"); rc != 0 || r.out.String() != "stopped\n" {
		t.Errorf("stop: %d %q", rc, r.out.String())
	}
	got := r.fake.Argvs()
	if !contains(got, "podman cp bw-emulator:/tmp/emulator.log "+dir+"/emulator.log") || !contains(got, "podman rm -f -t 0 bw-emulator") {
		t.Errorf("stop calls %v", got)
	}
	// reset refuses while running
	r = newRig(t)
	r.exists["bw-emulator"], r.state.running = true, true
	if rc := r.host("reset"); rc != 1 || !strings.Contains(r.errb.String(), "Stop the running emulator first: tools/emulator.sh stop") {
		t.Errorf("reset running: %d %q", rc, r.errb.String())
	}
	r = newRig(t)
	if rc := r.host("reset"); rc != 0 || r.out.String() != "emulator volumes deleted\n" {
		t.Errorf("reset: %d %q", rc, r.out.String())
	}
	if !contains(r.fake.Argvs(), "podman volume rm -f bw-emulator bw-emulator-image bw-emulator-avd") {
		t.Errorf("%v", r.fake.Argvs())
	}
}

func TestDefaultCommandIsScreens(t *testing.T) {
	r := newRig(t)
	r.allImages()
	if rc := Host(r.h, nil); rc != 0 {
		t.Fatal(rc)
	}
	if runs := r.podmanRuns("run"); !strings.HasSuffix(runs[1], " emulator screens") {
		t.Errorf("%v", runs)
	}
}

// GO-BUG3: a finished --rm emulator container leaves bw.avd/multiinstance.lock; the boot container removes it, but only when the
// host saw no emulator container running.
func TestStaleLockFlagOnlyWhenNothingRuns(t *testing.T) {
	for _, tc := range []struct {
		name     string
		ps       string
		psRC     int
		wantFlag bool
	}{
		{"nothing runs", "", 0, true},
		{"only other images", "localhost/budget-wallet-dev:3.47.7-x\ndocker.io/library/busybox:latest\n", 0, true},
		{"the emulator container runs", "localhost/budget-wallet-emu:54a1eab8\n", 0, false},
		{"another worktree's screens run", "localhost/budget-wallet-dev:3.47.7-x\nlocalhost/budget-wallet-emu:54a1eab8\n", 0, false},
		{"podman ps fails: cannot tell", "", 125, false},
	} {
		for _, cmd := range []string{"screens", "start"} {
			r := newRig(t)
			r.allImages()
			r.logs = "emulator booted\n"
			r.hook = func(c sys.Cmd) (int, bool) {
				if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "ps" {
					if got := strings.Join(c.Argv, " "); got != "podman ps --format {{.Image}}" {
						t.Errorf("ps argv %q", got)
					}
					c.Stdout.Write([]byte(tc.ps))
					return tc.psRC, true
				}
				return 0, false
			}
			r.host(cmd)
			runs := r.podmanRuns("run")
			got := runs[len(runs)-1]
			if has := strings.Contains(got, "-e BW_CLEAR_AVD_LOCK=1 "); has != tc.wantFlag {
				t.Errorf("%s/%s: flag present %v, want %v: %s", tc.name, cmd, has, tc.wantFlag, got)
			}
			if strings.Contains(runs[0], "BW_CLEAR_AVD_LOCK") {
				t.Errorf("%s/%s: the setup container (flock-guarded) gets no lock flag", tc.name, cmd)
			}
		}
	}
}
