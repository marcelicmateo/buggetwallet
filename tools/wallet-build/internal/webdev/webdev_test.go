package webdev

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

type fixture struct {
	w       *Web
	fake    *sys.Fake
	out     *bytes.Buffer
	err     *bytes.Buffer
	root    string
	data    string
	spawned [][]string
	pid     int
	getErrs int
	sleeps  int
}

func newFixture(t *testing.T, withBuild bool) *fixture {
	t.Helper()
	f := &fixture{out: &bytes.Buffer{}, err: &bytes.Buffer{}, root: t.TempDir(), data: t.TempDir(), fake: &sys.Fake{}}
	if withBuild {
		os.MkdirAll(filepath.Join(f.root, "dist", "web"), 0o755)
		os.WriteFile(filepath.Join(f.root, "dist", "web", "index.html"), []byte("x"), 0o644)
		os.MkdirAll(filepath.Join(f.root, "dist", "bin"), 0o755)
		os.WriteFile(filepath.Join(f.root, "dist", "bin", "wallet-build"), []byte("bin"), 0o755)
	}
	c := run.New(f.root, sys.Env{"BW_DATA_DIR=" + f.data, "HOME=" + f.data}, f.out, f.err, f.fake)
	f.w = &Web{C: c, Self: "/x/wallet-build",
		ImageName: func() (string, int) { return "localhost/budget-wallet-dev:1-abc", 0 },
		Spawn: func(argv []string, dir, logPath string, env sys.Env) (int, error) {
			f.spawned = append(f.spawned, append([]string{dir, logPath}, argv...))
			return f.pid, nil
		},
		Get: func(url string) error {
			if f.getErrs > 0 {
				f.getErrs--
				return errors.New("refused")
			}
			return nil
		},
		Sleep: func(time.Duration) { f.sleeps++ }}
	return f
}

// sleeper starts a process that does nothing for a minute; the test kills it at the end.
func sleeper(t *testing.T) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Skip("no sleep binary")
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	return cmd
}

func (f *fixture) pidFile() string { return filepath.Join(f.root, "dist", "web-serve.pid") }

func TestServeNeedsTheBuild(t *testing.T) {
	f := newFixture(t, false)
	if rc := f.w.Main([]string{"serve"}); rc != 1 || !strings.Contains(f.err.String(), "no dist/web: run wallet-build web first") || len(f.spawned) != 0 {
		t.Errorf("rc %d err %q", rc, f.err.String())
	}
}

func TestServeStartsADetachedLoopbackServer(t *testing.T) {
	f := newFixture(t, true)
	f.pid = 4242
	f.getErrs = 2
	if rc := f.w.Main([]string{"serve", "9090"}); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	if len(f.spawned) != 1 {
		t.Fatalf("spawned %v", f.spawned)
	}
	s := f.spawned[0]
	web := filepath.Join(f.root, "dist", "web")
	if s[0] != web || filepath.Base(s[1]) != "web-serve.log" || strings.Join(s[2:], " ") != "/x/wallet-build web _serve "+web+" 9090" {
		t.Errorf("spawn %v", s)
	}
	// the log is in the run directory of the serve call, which stays marked as running
	runDir := filepath.Dir(s[1])
	if !strings.Contains(filepath.Base(runDir), "-web-serve-") {
		t.Errorf("run dir %s", runDir)
	}
	if _, err := os.Stat(filepath.Join(runDir, ".running")); err != nil {
		t.Error("the run's .running marker is gone: the server outlives the command")
	}
	pf, _ := os.ReadFile(f.pidFile())
	if want := fmt.Sprintf("4242 http://127.0.0.1:9090/ (log %s)\n", s[1]); string(pf) != want {
		t.Errorf("pid file %q, want %q", pf, want)
	}
	if got := f.out.String(); got != "serving dist/web on http://127.0.0.1:9090/ (pid 4242, loopback only)\n" {
		t.Errorf("out %q", got)
	}
	if f.sleeps != 2 {
		t.Errorf("sleeps %d", f.sleeps)
	}
}

func TestServeDefaultPortAndBadPort(t *testing.T) {
	f := newFixture(t, true)
	f.pid = 7
	f.w.Main([]string{"serve"})
	if !strings.HasSuffix(strings.Join(f.spawned[0], " "), " 8080") || !strings.Contains(f.out.String(), "http://127.0.0.1:8080/") {
		t.Errorf("spawned %v out %q", f.spawned, f.out.String())
	}
	for _, p := range []string{"80x", "-1", "", "http", "8080 "} {
		f := newFixture(t, true)
		if rc := f.w.Main([]string{"serve", p}); rc != 2 || !strings.Contains(f.out.String(), "wallet-build web serve [port]") || len(f.spawned) != 0 {
			t.Errorf("port %q: rc %d", p, rc)
		}
	}
}

func TestServeAlreadyRunning(t *testing.T) {
	f := newFixture(t, true)
	os.WriteFile(f.pidFile(), []byte(fmt.Sprintf("%d http://127.0.0.1:8080/ (log /x/web-serve.log)\n", os.Getpid())), 0o644)
	if rc := f.w.Main([]string{"serve"}); rc != 0 || len(f.spawned) != 0 {
		t.Errorf("rc %d spawned %v", rc, f.spawned)
	}
	if want := "already running: http://127.0.0.1:8080/ (log /x/web-serve.log) (wallet-build web stop first)\n"; f.out.String() != want {
		t.Errorf("out %q", f.out.String())
	}
	// a stale pid file (no such process) is replaced
	f = newFixture(t, true)
	f.pid = 5
	dead := exec.Command("true")
	dead.Run()
	os.WriteFile(f.pidFile(), []byte(fmt.Sprintf("%d http://127.0.0.1:8080/ (log x)\n", dead.Process.Pid)), 0o644)
	if rc := f.w.Main([]string{"serve"}); rc != 0 || len(f.spawned) != 1 {
		t.Errorf("stale pid file: rc %d spawned %v", rc, f.spawned)
	}
}

func TestServeThatNeverAnswersIsKilled(t *testing.T) {
	f := newFixture(t, true)
	victim := sleeper(t)
	f.pid = victim.Process.Pid
	f.getErrs = 1000
	if rc := f.w.Main([]string{"serve"}); rc != 1 || !strings.Contains(f.err.String(), "server did not come up; see ") {
		t.Errorf("rc %d err %q", rc, f.err.String())
	}
	if _, err := os.Stat(f.pidFile()); err == nil {
		t.Error("pid file left behind")
	}
	if f.sleeps != 10 {
		t.Errorf("retries %d", f.sleeps)
	}
	done := make(chan error, 1)
	go func() { done <- victim.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Error("the server process was not stopped")
	}
}

func TestStopAndStatus(t *testing.T) {
	f := newFixture(t, true)
	f.w.Main([]string{"status"})
	f.w.Main([]string{"stop"})
	if f.out.String() != "not running\nnot running\n" {
		t.Errorf("out %q", f.out.String())
	}
	f = newFixture(t, true)
	victim := sleeper(t)
	os.WriteFile(f.pidFile(), []byte(fmt.Sprintf("%d http://127.0.0.1:8081/ (log /l)\n", victim.Process.Pid)), 0o644)
	f.w.Main([]string{"status"})
	if f.out.String() != "running: http://127.0.0.1:8081/ (log /l)\n" {
		t.Errorf("status %q", f.out.String())
	}
	f.out.Reset()
	if rc := f.w.Main([]string{"stop"}); rc != 0 || f.out.String() != "stopped\n" {
		t.Errorf("stop: rc %d %q", rc, f.out.String())
	}
	if _, err := os.Stat(f.pidFile()); err == nil {
		t.Error("pid file left after stop")
	}
	done := make(chan error, 1)
	go func() { done <- victim.Wait() }()
	select {
	case err := <-done:
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if ws, ok := ee.Sys().(syscall.WaitStatus); !ok || ws.Signal() != syscall.SIGTERM {
				t.Errorf("stopped with %v, want SIGTERM", err)
			}
		}
	case <-time.After(5 * time.Second):
		t.Error("the process was not stopped")
	}
	// a stale pid file is removed by stop
	f = newFixture(t, true)
	os.WriteFile(f.pidFile(), []byte("999999999 x\n"), 0o644)
	f.w.Main([]string{"stop"})
	if _, err := os.Stat(f.pidFile()); err == nil || f.out.String() != "not running\n" {
		t.Errorf("stale: out %q", f.out.String())
	}
	// default command is status
	f = newFixture(t, true)
	if rc := f.w.Main(nil); rc != 0 || f.out.String() != "not running\n" {
		t.Errorf("default: rc %d out %q", rc, f.out.String())
	}
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{{"bogus"}, {"shot"}, {"shot", "/"}, {"shot", "/", "x.png", "412"}, {"shot", "/", "x.png", "412x"}, {"shot", "/", "x.png", "ax9"}} {
		f := newFixture(t, true)
		if rc := f.w.Main(args); rc != 2 || !strings.HasPrefix(f.out.String(), "Serve the web build") {
			t.Errorf("%v: rc %d", args, rc)
		}
	}
	if !IsCommand("serve") || !IsCommand("shot") || IsCommand("") || IsCommand("build") || IsCommand("_serve") {
		t.Error("IsCommand")
	}
}

func TestShotRunsChromeInTheContainer(t *testing.T) {
	f := newFixture(t, true)
	cwd, _ := os.Getwd()
	os.Chdir(f.root)
	defer os.Chdir(cwd)
	if rc := f.w.Main([]string{"shot", "app/home", "shots/out.png"}); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	abs := filepath.Join(f.root, "shots", "out.png")
	if st, err := os.Stat(filepath.Dir(abs)); err != nil || !st.IsDir() {
		t.Error("output directory not created")
	}
	if f.out.String() != "screenshot: "+abs+"\n" {
		t.Errorf("out %q", f.out.String())
	}
	if len(f.fake.Calls) != 1 {
		t.Fatalf("calls %v", f.fake.Argvs())
	}
	a := f.fake.Calls[0].Argv
	web := filepath.Join(f.root, "dist", "web")
	wantHead := []string{"podman", "run", "--rm", "-e", "BW_SHOT_SETTLE", "-v", web + ":/web:ro,z", "-v", filepath.Join(f.root, "dist", "bin") + ":/tool:ro,z",
		"-v", filepath.Join(f.root, "shots") + ":/out:z", "localhost/budget-wallet-dev:1-abc", "bash", "-c"}
	if strings.Join(a[:len(wantHead)], "\x00") != strings.Join(wantHead, "\x00") {
		t.Errorf("podman args %q", a)
	}
	if tail := a[len(wantHead)+1:]; strings.Join(tail, " ") != "_ 412x915 out.png /app/home" {
		t.Errorf("script args %q", tail)
	}
	script := a[len(wantHead)]
	for _, want := range []string{"web _serve /web 18080", "http://127.0.0.1:18080/", `web-shot "http://127.0.0.1:18080$3" "/out/$2" "$1"`} {
		if !strings.Contains(script, want) {
			t.Errorf("script lacks %q:\n%s", want, script)
		}
	}
	// size argument, absolute path, leading slash kept
	f = newFixture(t, true)
	out := filepath.Join(t.TempDir(), "a", "b.png")
	f.w.Main([]string{"shot", "/", out, "800x600"})
	a = f.fake.Calls[0].Argv
	if strings.Join(a[len(a)-3:], " ") != "800x600 b.png /" || !strings.Contains(strings.Join(a, " "), filepath.Dir(out)+":/out:z") {
		t.Errorf("args %q", a)
	}
}

func TestShotFailures(t *testing.T) {
	f := newFixture(t, false)
	if rc := f.w.Main([]string{"shot", "/", "x.png"}); rc != 1 || !strings.Contains(f.err.String(), "no dist/web") {
		t.Errorf("no build: rc %d err %q", rc, f.err.String())
	}
	f = newFixture(t, true)
	f.w.ImageName = func() (string, int) { return "", 1 }
	if rc := f.w.Main([]string{"shot", "/", filepath.Join(t.TempDir(), "x.png")}); rc != 1 || len(f.fake.Calls) != 0 {
		t.Errorf("image failure: rc %d", rc)
	}
	f = newFixture(t, true)
	f.fake.Handle = func(c sys.Cmd) int { return 3 }
	if rc := f.w.Main([]string{"shot", "/", filepath.Join(t.TempDir(), "x.png")}); rc != 3 || strings.Contains(f.out.String(), "screenshot:") {
		t.Errorf("chrome failure: rc %d out %q", rc, f.out.String())
	}
	f = newFixture(t, true)
	os.Remove(filepath.Join(f.root, "dist", "bin", "wallet-build"))
	if rc := f.w.Main([]string{"shot", "/", "x.png"}); rc != 1 || !regexp.MustCompile(`no dist/bin/wallet-build`).MatchString(f.err.String()) {
		t.Errorf("no binary: rc %d err %q", rc, f.err.String())
	}
}
