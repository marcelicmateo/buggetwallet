package live

import (
	"bytes"
	"context"
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
	mu     sync.Mutex
	t      *testing.T
	fake   *sys.Fake
	c      *run.Ctx
	out    bytes.Buffer
	errb   bytes.Buffer
	dir    string
	runDir string
	home   string
	fifo   string
	fwdCh  chan int
	cmds   []sys.Cmd
	stdinF bool
}

func newCRig(t *testing.T, env ...string) *crig {
	r := &crig{t: t, fwdCh: make(chan int, 4), dir: t.TempDir(), runDir: t.TempDir(), home: t.TempDir()}
	r.fifo = filepath.Join(t.TempDir(), "in")
	oldF, oldR, oldFw := fifoPath, runtimeDirPath, forward
	fifoPath, runtimeDirPath = r.fifo, filepath.Join(t.TempDir(), "rt")
	forward = func(ctx context.Context, fib string, port int) error {
		if fib != "/proc/net/fib_trie" {
			t.Errorf("fib_trie path %s", fib)
		}
		r.fwdCh <- port
		return nil
	}
	t.Cleanup(func() { fifoPath, runtimeDirPath, forward = oldF, oldR, oldFw })
	r.fake = &sys.Fake{Handle: func(c sys.Cmd) int {
		r.cmds = append(r.cmds, c)
		if f, ok := c.Stdin.(*os.File); ok && c.Argv[0] == "dbus-run-session" {
			r.stdinF = f != nil
		}
		return 0
	}}
	e := append([]string{"PATH=/usr/bin", "HOME=" + r.home, "BW_NATIVE=1", "BW_LIVE_DIR=" + r.dir, "BW_RUN_DIR=" + r.runDir, "BW_LIVE_MODE=debug", "BW_LIVE_TARGET=",
		"BW_LIVE_PORT=24680", "BW_LIVE_DEMO=0", "BW_LIVE_HEADLESS=0"}, env...)
	r.c = run.New(t.TempDir(), sys.Env(e), &r.out, &r.errb, r.fake)
	return r
}

func argvs(cmds []sys.Cmd) []string {
	var out []string
	for _, c := range cmds {
		out = append(out, strings.Join(c.Argv, " "))
	}
	return out
}

func TestServeDebug(t *testing.T) {
	r := newCRig(t)
	if rc := Container(r.c, []string{"serve"}); rc != 0 {
		t.Fatalf("exit %d %s", rc, r.errb.String())
	}
	got := argvs(r.cmds)
	want := []string{"flutter config --build-dir=build/live", "dbus-run-session -- flutter run -d linux --machine --print-dtd --dds-port 24680"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls\n got %v\nwant %v", got, want)
	}
	run := r.cmds[1]
	if run.Dir != filepath.Join(r.c.Root, "app") {
		t.Errorf("flutter runs in app/: %s", run.Dir)
	}
	for k, v := range map[string]string{"XDG_DATA_HOME": r.dir + "/data", "XDG_DOCUMENTS_DIR": r.dir + "/docs", "XDG_RUNTIME_DIR": runtimeDirPath, "NO_AT_BRIDGE": "1"} {
		if run.Env.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, run.Env.Get(k), v)
		}
	}
	if !r.stdinF {
		t.Error("flutter run's stdin is the fifo file")
	}
	select {
	case p := <-r.fwdCh:
		if p != 24680 {
			t.Errorf("forwarder port %d", p)
		}
	case <-time.After(5 * time.Second):
		t.Error("the forwarder did not start")
	}
	if fi, err := os.Stat(runtimeDirPath); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("runtime dir %v %v", fi, err)
	}
	if got := file(t, filepath.Join(r.home, ".config/xdg-desktop-portal/portals.conf")); got != "[preferred]\ndefault=gtk\n" {
		t.Errorf("portals.conf %q", got)
	}
	if got := file(t, filepath.Join(r.home, ".config/gtk-3.0/bookmarks")); got != "file:///files Test files\n" {
		t.Errorf("bookmarks %q", got)
	}
	for _, f := range []string{"flutter-run.jsonl", "flutter-run.err"} {
		if _, err := os.Stat(filepath.Join(r.runDir, f)); err != nil {
			t.Errorf("missing %s", f)
		}
	}
	if fi, err := os.Stat(r.fifo); err != nil || fi.Mode()&os.ModeNamedPipe == 0 {
		t.Errorf("fifo %v %v", fi, err)
	}
	for _, d := range []string{"data", "docs"} {
		if _, err := os.Stat(filepath.Join(r.dir, d)); err != nil {
			t.Errorf("missing %s", d)
		}
	}
}

func TestServeProfileTargetHeadless(t *testing.T) {
	r := newCRig(t, "BW_LIVE_MODE=profile", "BW_LIVE_TARGET=tool/live_demo.dart", "BW_LIVE_HEADLESS=1")
	if rc := Container(r.c, []string{"serve"}); rc != 0 {
		t.Fatal(rc)
	}
	want := `dbus-run-session -- xvfb-run -a -s -screen 0 1280x720x24 bash -c dbus-update-activation-environment DISPLAY XAUTHORITY; exec "$@" _ flutter run -d linux --machine --print-dtd --dds-port 24680 --profile -t tool/live_demo.dart`
	if got := argvs(r.cmds)[1]; got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
	if args := r.cmds[1].Argv; args[5] != "-screen 0 1280x720x24" {
		t.Errorf("one argument for the screen: %q", args[5])
	}
}

func TestServeNeedsItsEnvironment(t *testing.T) {
	for _, drop := range []string{"BW_LIVE_DIR=", "BW_RUN_DIR=", "BW_LIVE_PORT=x"} {
		r := newCRig(t, drop)
		if rc := Container(r.c, []string{"serve"}); rc != 1 || len(r.cmds) != 0 {
			t.Errorf("%s: exit %d, ran %v", drop, rc, argvs(r.cmds))
		}
	}
	r := newCRig(t)
	r.fake.Handle = func(c sys.Cmd) int { return 9 }
	if rc := Container(r.c, []string{"serve"}); rc != 9 {
		t.Errorf("flutter config fails: exit %d", rc)
	}
	r = newCRig(t)
	r.fake.Handle = func(c sys.Cmd) int {
		if c.Argv[0] == "dbus-run-session" {
			return 3
		}
		return 0
	}
	if rc := Container(r.c, []string{"serve"}); rc != 3 {
		t.Errorf("flutter run's exit code is the container's: %d", rc)
	}
}

func TestContainerUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"status"}, {"start"}, {"bogus"}} {
		r := newCRig(t)
		if rc := Container(r.c, args); rc != 2 || r.out.String() != usageText {
			t.Errorf("%v: %d", args, rc)
		}
	}
}

func TestContainerXshotWithoutDisplay(t *testing.T) {
	r := newCRig(t)
	if rc := Container(r.c, []string{"xshot", "-"}); rc != 1 || !strings.Contains(r.errb.String(), "xshot:") {
		t.Errorf("exit %d err %q", rc, r.errb.String())
	}
	if rc := Container(r.c, []string{"xshot"}); rc != 2 {
		t.Errorf("xshot without a target: %d", rc)
	}
}
