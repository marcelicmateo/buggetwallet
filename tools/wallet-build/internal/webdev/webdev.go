// Package webdev ports tools/web.sh and tools/web_shot.py: serve the web build (dist/web/) on this computer only, and screenshot it
// with headless Chrome. Nothing is published: the server binds 127.0.0.1 and the app's data lives in the browser profile.
package webdev

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// Usage is what `web` prints for a wrong command line (the header of tools/web.sh).
const Usage = `Serve the web build (wallet-build web -> dist/web/) on this computer only, and screenshot it.

  wallet-build web serve [port]        serve dist/web/ on http://127.0.0.1:<port> (default 8080): loopback only, in the background
  wallet-build web stop                stop it            wallet-build web status   running? where? (pid file: dist/web-serve.pid)
  wallet-build web shot <path> <out.png> [WxH]
                                       headless Chrome screenshot of <path> (e.g. "/") of dist/web/, default 412x915, written
                                       to <out.png>. Chrome runs in the build container and cannot reach the host's loopback,
                                       so the container serves dist/web/ itself on its own 127.0.0.1 for the shot; the host
                                       server need not be running.

Nothing is published: the server binds 127.0.0.1 and the app's data lives in the browser profile. The pid file and the
server log are in the run directory of the serve call (~/.local/share/budget-wallet/runs/...-web-serve-...).
`

// Commands are the words that make "web <word>" this helper; plain "web" builds the Flutter web app.
var Commands = []string{"serve", "stop", "status", "shot"}

// IsCommand reports whether word selects the web server helper.
func IsCommand(word string) bool {
	for _, c := range Commands {
		if c == word {
			return true
		}
	}
	return false
}

// Web is one invocation of `wallet-build web`.
type Web struct {
	C    *run.Ctx
	Self string // this binary: the detached server is `self web _serve`
	// ImageName ensures the dev image exists (building it when missing) and returns its tag (tools/build.sh image-name).
	ImageName func() (string, int)
	// Spawn starts the detached server and returns its pid; replaced by the tests.
	Spawn func(argv []string, dir, logPath string, env sys.Env) (int, error)
	// Get fetches a URL (the readiness check); Sleep waits between attempts.
	Get   func(url string) error
	Sleep func(time.Duration)
}

// New returns a Web with the real process start, HTTP check and sleep.
func New(c *run.Ctx, self string) *Web {
	return &Web{C: c, Self: self, Spawn: spawnDetached, Get: httpGet, Sleep: time.Sleep}
}

func httpGet(url string) error {
	cl := &http.Client{Timeout: 5 * time.Second}
	resp, err := cl.Get(url)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

// spawnDetached starts argv in its own session (setsid) with stdin from /dev/null and stdout/stderr in logPath. It outlives us.
func spawnDetached(argv []string, dir, logPath string, env sys.Env) (int, error) {
	lf, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return 0, err
	}
	defer lf.Close()
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = dir
	cmd.Env = env.Environ()
	cmd.Stdout, cmd.Stderr = lf, lf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	pid := cmd.Process.Pid
	_ = cmd.Process.Release()
	return pid, nil
}

func (w *Web) pidFile() string { return filepath.Join(w.C.Root, "dist", "web-serve.pid") }

// alive: the pid file exists and its process does.
func (w *Web) alive() bool {
	pid, ok := w.pid()
	return ok && syscall.Kill(pid, 0) == nil
}

func (w *Web) pid() (int, bool) {
	b, err := os.ReadFile(w.pidFile())
	if err != nil {
		return 0, false
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0, false
	}
	pid, err := strconv.Atoi(f[0])
	return pid, err == nil && pid > 0
}

// pidInfo is the pid file without its first field ("http://127.0.0.1:8080/ (log …)").
func (w *Web) pidInfo() string {
	b, _ := os.ReadFile(w.pidFile())
	_, rest, _ := strings.Cut(strings.TrimRight(string(b), "\n"), " ")
	return rest
}

func (w *Web) needBuild() bool {
	if _, err := os.Stat(filepath.Join(w.C.Root, "dist", "web", "index.html")); err != nil {
		w.C.Eprintf("no dist/web: run tools/build.sh web first\n") // M6: rename with the scripts
		return false
	}
	return true
}

var (
	reDigits = regexp.MustCompile(`^[0-9]+$`)
	reSize   = regexp.MustCompile(`^[0-9]+x[0-9]+$`)
)

// Main is `web <serve|stop|status|shot> …`.
func (w *Web) Main(args []string) int {
	c := w.C
	usage := func() int {
		c.Printf("%s", Usage)
		return 2
	}
	cmd := "status"
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "serve":
		port := "8080"
		if len(args) > 1 {
			port = args[1]
		}
		if !reDigits.MatchString(port) {
			return usage()
		}
		return w.serve(port)
	case "stop":
		if w.alive() {
			pid, _ := w.pid()
			_ = syscall.Kill(pid, syscall.SIGTERM)
			c.Printf("stopped\n")
		} else {
			c.Printf("not running\n")
		}
		_ = os.Remove(w.pidFile())
		return 0
	case "status":
		if w.alive() {
			c.Printf("running: %s\n", w.pidInfo())
		} else {
			c.Printf("not running\n")
		}
		return 0
	case "shot":
		if len(args) < 3 {
			return usage()
		}
		size := "412x915"
		if len(args) > 3 {
			size = args[3]
		}
		if !reSize.MatchString(size) {
			return usage()
		}
		return w.shot(args[1], args[2], size)
	}
	return usage()
}

func (w *Web) serve(port string) int {
	c := w.C
	if !w.needBuild() {
		return 1
	}
	if w.alive() {
		c.Printf("already running: %s (wallet-build web stop first)\n", w.pidInfo())
		return 0
	}
	// The server outlives this command: the run is never finished, so its .running marker stays (prune ignores it after 24 h).
	if _, err := c.Begin("web-serve"); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	logPath := filepath.Join(c.Getenv("BW_RUN_DIR"), "web-serve.log")
	pid, err := w.Spawn([]string{w.Self, "web", "_serve", filepath.Join(c.Root, "dist", "web"), port}, filepath.Join(c.Root, "dist", "web"), logPath, c.Env)
	if err != nil {
		c.Eprintf("cannot start the server: %v\n", err)
		return 1
	}
	url := "http://127.0.0.1:" + port + "/"
	_ = os.MkdirAll(filepath.Dir(w.pidFile()), 0o755)
	_ = os.WriteFile(w.pidFile(), []byte(fmt.Sprintf("%d %s (log %s)\n", pid, url, logPath)), 0o644)
	for i := 0; i <= 10; i++ { // curl --retry 10 --retry-delay 1
		if w.Get(url) == nil {
			c.Printf("serving dist/web on %s (pid %d, loopback only)\n", url, pid)
			return 0
		}
		if i < 10 {
			w.Sleep(time.Second)
		}
	}
	c.Eprintf("server did not come up; see %s\n", logPath)
	_ = syscall.Kill(pid, syscall.SIGTERM)
	_ = os.Remove(w.pidFile())
	return 1
}

// shotScript runs inside the build container: the container serves dist/web/ itself on its own 127.0.0.1, then the Go binary
// drives Chrome over the DevTools protocol and captures once Flutter has drawn (Chrome's --screenshot fires at the load event,
// before that). $1 = WxH, $2 = file name below /out, $3 = the path of the page.
const shotScript = `
/tool/wallet-build web _serve /web 18080 > /tmp/http.log 2>&1 &
curl -fsS -o /dev/null --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:18080/ 2> /dev/null
/tool/wallet-build web-shot "http://127.0.0.1:18080$3" "/out/$2" "$1"
`

func (w *Web) shot(urlPath, out, size string) int {
	c := w.C
	if !w.needBuild() {
		return 1
	}
	bin := filepath.Join(c.Root, "dist", "bin", "wallet-build")
	if _, err := os.Stat(bin); err != nil {
		c.Eprintf("no dist/bin/wallet-build: run make bin first\n")
		return 1
	}
	path := "/" + strings.TrimPrefix(urlPath, "/")
	abs, err := filepath.Abs(out)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	img, rc := w.ImageName()
	if rc != 0 {
		return rc
	}
	argv := []string{"podman", "run", "--rm", "-e", "BW_SHOT_SETTLE",
		"-v", filepath.Join(c.Root, "dist", "web") + ":/web:ro,z", "-v", filepath.Dir(bin) + ":/tool:ro,z", "-v", filepath.Dir(abs) + ":/out:z",
		img, "bash", "-c", shotScript, "_", size, filepath.Base(abs), path}
	if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: argv, Env: c.Env, Stdout: c.ChildOut, Stderr: c.ChildErr}); rc != 0 {
		return rc
	}
	c.Printf("screenshot: %s\n", abs)
	return 0
}
