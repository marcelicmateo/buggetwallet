// Package live ports tools/live.sh: the Linux desktop app in debug mode (`flutter run -d linux`) in the build container, kept
// running in the background so Claude can hot-reload it, read the widget tree and take screenshots.
//
// Privacy rules kept from the script: the app window uses only the Wayland socket (never X11), the container mounts only the repo,
// this run's folder, history/ and live-files (never all of BW_DATA), no host input tools, and screenshots come from the VM
// service or the container's own Xvfb.
package live

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"wallet-build/internal/host"
	"wallet-build/internal/image"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
	"wallet-build/internal/vmservice"
)

//go:embed usage.txt
var usageText string

// Inner is the command the container runs (the static binary in the mounted repo, which is mounted at the same path).
const Inner = "dist/bin/wallet-build"

// FIFO is flutter run's stdin inside the container.
const FIFO = "/tmp/bw-live-in"

// Replaced by the tests.
var (
	sleep    = time.Sleep
	now      = time.Now
	isSocket = func(p string) bool { st, err := os.Stat(p); return err == nil && st.Mode()&os.ModeSocket != 0 }
	isDir    = func(p string) bool { st, err := os.Stat(p); return err == nil && st.IsDir() }
	exists   = func(p string) bool { _, err := os.Stat(p); return err == nil }
	uid      = os.Getuid
	dial     = func(uri string) (screenshotter, error) { return vmservice.Dial(uri) }
	forward  = vmservice.Forward
	fifoPath = FIFO
	// runtimeDirPath is XDG_RUNTIME_DIR inside the container.
	runtimeDirPath = "/tmp/bw-runtime"
)

// Poll counts of `start`: 1800 half-second polls for the build, 50 fifth-second polls for the first frame line.
const (
	buildPolls = 1800
	framePolls = 50
)

type screenshotter interface {
	Screenshot() ([]byte, error)
	TraceStart() error
	TraceStop() ([]json.RawMessage, error)
	Close() error
}

func usage(c *run.Ctx) int {
	fmt.Fprint(c.Out, usageText)
	return 2
}

// Sanitize is `basename | tr -c 'a-zA-Z0-9_.\n-' '-'`: every byte outside the set becomes a dash.
func Sanitize(base string) string {
	b := []byte(base)
	for i, ch := range b {
		switch {
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch >= '0' && ch <= '9', ch == '_', ch == '.', ch == '-':
		default:
			b[i] = '-'
		}
	}
	return string(b)
}

var crcTable = func() (t [256]uint32) {
	for i := range t {
		c := uint32(i) << 24
		for k := 0; k < 8; k++ {
			if c&0x80000000 != 0 {
				c = c<<1 ^ 0x04C11DB7
			} else {
				c <<= 1
			}
		}
		t[i] = c
	}
	return
}()

// Cksum is POSIX cksum(1): the CRC of the bytes followed by their length.
func Cksum(data []byte) uint32 {
	var crc uint32
	for _, b := range data {
		crc = crc<<8 ^ crcTable[byte(crc>>24)^b]
	}
	for n := len(data); n != 0; n >>= 8 {
		crc = crc<<8 ^ crcTable[byte(crc>>24)^byte(n)]
	}
	return ^crc
}

// Names are the container, pod and port of a checkout: the port is fixed per checkout because a pod's published ports are set
// when it is created.
func Names(root string) (name, pod string, port int) {
	base := Sanitize(filepath.Base(root))
	pod = "bw-" + base
	return "bw-live-" + base, pod, 20000 + int(Cksum([]byte(pod+"\n"))%20000)
}

type liveSide struct {
	h    *host.Host
	c    *run.Ctx
	name string
	pod  string
	port int

	// from load(): the run folder, wallet folder and flutter run's state
	runDir, dataDir string
	st              vmservice.State
}

// Host runs one live command on the machine that has Podman. args[0] is the command (default status).
func Host(h *host.Host, args []string) int {
	c := h.C
	cmd := "status"
	if len(args) > 0 && args[0] != "" {
		cmd = args[0]
	}
	var rest []string
	if len(args) > 1 {
		rest = args[1:]
	}
	l := &liveSide{h: h, c: c}
	l.name, l.pod, l.port = Names(c.Root)
	switch cmd {
	case "start":
		return l.start(rest)
	case "reload", "restart":
		return l.reload(cmd)
	case "shot":
		return l.shot(rest)
	case "trace":
		return l.trace(rest)
	case "status":
		return l.status()
	case "stop":
		return l.stop()
	case "pod":
		if rc := l.ensurePod(); rc != 0 {
			return rc
		}
		c.Printf("%s\n", l.pod)
		return 0
	case "mcp":
		if err := c.R.Exec(sys.Cmd{Argv: append([]string{filepath.Join(c.Root, "tools", "build.sh"), "mcp"}, rest...), Env: c.Env}); err != nil {
			c.Eprintf("exec build.sh: %v\n", err)
			return 127
		}
		return 0
	}
	return usage(c)
}

// podman runs a podman command with its output thrown away; the result is the exit code.
func (l *liveSide) podman(args ...string) int {
	return l.c.R.Run(l.c.Ctx, sys.Cmd{Argv: append([]string{"podman"}, args...), Env: l.c.Env})
}

func (l *liveSide) ensurePod() int {
	if l.podman("pod", "exists", l.pod) == 0 {
		return 0
	}
	if l.podman("pod", "create", "--name", l.pod, "--share", "net", "-p", fmt.Sprintf("127.0.0.1:%d:%d", l.port, l.port)) == 0 {
		return 0
	}
	return l.podman("pod", "exists", l.pod)
}

func (l *liveSide) running() bool {
	out, _ := l.c.CaptureQuiet("", "podman", "inspect", "-f", "{{.State.Running}}", l.name)
	return out == "true"
}

func (l *liveSide) needRunning() bool {
	if l.running() {
		return true
	}
	l.c.Eprintf("Live mode is not running. Start it with: tools/live.sh start\n")
	return false
}

func (l *liveSide) label(k string) string {
	out, _ := l.c.CaptureQuiet("", "podman", "inspect", "-f", fmt.Sprintf(`{{index .Config.Labels "%s"}}`, k), l.name)
	return out
}

// load reads the run folder and flutter run's state. It reports false (after the message) when the run folder is gone.
func (l *liveSide) load() bool {
	c := l.c
	l.runDir, l.dataDir = l.label("bw.run"), l.label("bw.data")
	if !isDir(l.runDir) {
		c.Eprintf("Live mode's run folder is gone; tools/live.sh stop, then start.\n")
		return false
	}
	l.st = vmservice.Info(filepath.Join(l.runDir, "flutter-run.jsonl"))
	c.Setenv("BW_RUN_ID", filepath.Base(l.runDir))
	c.TimingInit("live")
	return true
}

func (l *liveSide) hist(step, secs, result string) { l.c.LogHistory(step, secs, result, "false", "") }

// daemon sends a request to flutter run's stdin and waits for its reply (printed). timeout is in seconds.
func (l *liveSide) daemon(method string, full bool, timeout float64) int {
	c := l.c
	app := l.st.Get("app")
	id, _ := strconv.Atoi(strconv.FormatInt(time.Now().UnixNano(), 10)[7:16]) // date +%s%N | cut -c8-16
	line := vmservice.Request(id, method, app, full) + "\n"
	c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "exec", "-i", l.name, "sh", "-c", "cat > " + FIFO}, Env: c.Env, Stdin: strings.NewReader(line), Stderr: c.ChildErr})
	return vmservice.Reply(filepath.Join(l.runDir, "flutter-run.jsonl"), id, timeout, c.Out, sleep, now)
}

var reFirstFrame = regexp.MustCompile(`app\.start \{"phase":"total","ms":([0-9]+)`)

// appLogs are the app's log files (path_provider: $XDG_DATA_HOME/<application id>/logs/), oldest first.
func appLogs(dataDir string) []byte {
	var files []string
	_ = filepath.WalkDir(filepath.Join(dataDir, "data"), func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if i := strings.Index(p, "/logs/bw-"); i >= 0 && strings.HasSuffix(p, ".log") && len(p)-4 >= i+len("/logs/bw-") {
				files = append(files, p)
			}
		}
		return nil
	})
	sort.Strings(files)
	var all []byte
	for _, f := range files {
		if b, err := os.ReadFile(f); err == nil {
			all = append(all, b...)
		}
	}
	return all
}

// firstFrames are the "main() to first frame" milliseconds in the app's logs.
func firstFrames(dataDir string) []string {
	var out []string
	for _, m := range reFirstFrame.FindAllSubmatch(appLogs(dataDir), -1) {
		out = append(out, string(m[1]))
	}
	return out
}

func (l *liveSide) show() {
	c := l.c
	st := l.st
	mode := st.Get("mode")
	if mode == "" {
		mode = "?"
	}
	c.Printf("mode:      %s (%s)\n", mode, st.Get("state"))
	for _, kv := range [][2]string{{"vm:        ", st.Get("vm")}, {"dtd:       ", st.Get("dtd")}, {"devtools:  ", st.Get("devtools")}} {
		if kv[1] != "" {
			c.Printf("%s%s\n", kv[0], kv[1])
		}
	}
	c.Printf("wallet:    %s (throwaway)\n", strings.TrimPrefix(l.dataDir, c.Root+"/"))
	c.Printf("logs:      %s\n", l.runDir)
}

func (l *liveSide) start(rest []string) int {
	c := l.c
	headless, demo, fresh := false, false, false
	mode := "debug"
	for _, a := range rest {
		switch a {
		case "--headless":
			headless = true
		case "--demo":
			demo = true
		case "--profile":
			mode = "profile"
		case "--fresh":
			fresh = true
		default:
			return usage(c)
		}
	}
	if l.running() {
		c.Printf("already running (tools/live.sh stop first):\n")
		if !l.load() {
			return 1
		}
		l.show()
		return 0
	}
	l.podman("rm", "-f", l.name)
	if err := l.h.Init(); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	// the live app outlives this command: no Finish, so the .running marker stays (prune ignores it after 24 h)
	if _, err := l.h.BeginRun("live"); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	if rc := l.h.EnsureImage(); rc != 0 {
		return rc
	}
	runDir := c.Getenv("BW_RUN_DIR")
	t0 := c.Us()
	data := filepath.Join(c.Root, "dist", "live", "wallet")
	target := ""
	if demo {
		data, target = filepath.Join(c.Root, "dist", "live", "demo"), "tool/live_demo.dart"
	}
	if fresh {
		_ = os.RemoveAll(data)
	}
	if err := os.MkdirAll(data, 0o755); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	framesBefore := len(firstFrames(data))
	b2s := func(b bool) string {
		if b {
			return "1"
		}
		return "0"
	}
	opts := []string{"-v", c.Root + ":" + c.Root + ":z", "-v", "bw-pub-cache:/cache/pub",
		"-e", "BW_NATIVE=1", "-e", "BW_LIVE_DIR=" + data, "-e", "BW_LIVE_MODE=" + mode, "-e", "BW_LIVE_TARGET=" + target, "-e", fmt.Sprintf("BW_LIVE_PORT=%d", l.port),
		"-e", "BW_LIVE_DEMO=" + b2s(demo)}
	// The one host folder for the file pickers (import bank files, Syncthing folder, saved logs), mounted at /files
	files := filepath.Join(c.Data, "live-files")
	_ = os.MkdirAll(files, 0o755)
	_ = os.MkdirAll(filepath.Join(c.Data, "history"), 0o755)
	opts = append(opts, "-v", files+":/files:z")
	// Only this run's folder and the timing history, not all of BW_DATA (device-logs/ holds logs the owner sends): the file
	// dialog can browse every mounted folder.
	runArgs := []string{"-v", runDir + ":" + runDir + ":z", "-v", filepath.Join(c.Data, "history") + ":" + filepath.Join(c.Data, "history") + ":z"}
	for _, e := range image.RunEnv {
		runArgs = append(runArgs, "-e", e)
	}
	way := c.Getenv("WAYLAND_DISPLAY")
	if way != "" && !strings.HasPrefix(way, "/") {
		xdg := c.Getenv("XDG_RUNTIME_DIR")
		if xdg == "" {
			xdg = fmt.Sprintf("/run/user/%d", uid())
		}
		way = xdg + "/" + way
	}
	if !headless && (way == "" || !isSocket(way)) {
		c.Eprintf("No Wayland session here: running headless (X11 is never passed through).\n")
		headless = true
	}
	if !headless {
		// Only the Wayland socket itself. label=disable: SELinux keeps containers off the session's sockets, and relabeling (:z)
		// them would be wrong.
		opts = append(opts, "--security-opt", "label=disable", "-v", way+":/tmp/bw-wayland:ro", "-e", "WAYLAND_DISPLAY=/tmp/bw-wayland", "-e", "GDK_BACKEND=wayland")
		// The host's mouse cursors (the image has no cursor theme)
		if isDir("/usr/share/icons") {
			theme := c.Getenv("XCURSOR_THEME")
			if theme == "" {
				theme = "Adwaita"
			}
			opts = append(opts, "-v", "/usr/share/icons:/tmp/bw-icons:ro", "-e", "XCURSOR_PATH=/tmp/bw-icons", "-e", "XCURSOR_THEME="+theme)
		}
		// GPU rendering when the host has a render node (Mesa); BW_LIVE_GPU=0 for software rendering
		if c.Getenv("BW_LIVE_GPU") != "0" && exists("/dev/dri/renderD128") {
			opts = append(opts, "--device", "/dev/dri")
		} else {
			opts = append(opts, "-e", "LIBGL_ALWAYS_SOFTWARE=1")
		}
	}
	if rc := l.ensurePod(); rc != 0 {
		return rc
	}
	argv := []string{"podman", "run", "-d", "--init", "--name", l.name, "--pod", l.pod, "--label", "bw.run=" + runDir, "--label", "bw.data=" + data,
		"--label", "bw.headless=" + b2s(headless), "-e", "BW_LIVE_HEADLESS=" + b2s(headless)}
	argv = append(argv, opts...)
	argv = append(argv, runArgs...)
	argv = append(argv, "-w", c.Root, l.h.Image, Inner, "live", "serve")
	if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: argv, Env: c.Env, Stderr: c.ChildErr}); rc != 0 {
		return rc
	}
	extra := ""
	if demo {
		extra += ", demo wallet"
	}
	if headless {
		extra += ", headless"
	}
	c.Printf("building and starting (%s%s)…\n", mode, extra)
	l.runDir = runDir
	for i := 0; i < buildPolls; i++ {
		if !l.load() {
			return 1
		}
		if s := l.st.Get("state"); s == "started" || s == "stopped" {
			break
		}
		if !l.running() || c.Ctx.Err() != nil {
			break
		}
		sleep(500 * time.Millisecond)
	}
	secs := c.SecsSince(t0)
	if l.st.Get("state") != "started" {
		msg := ""
		if e := l.st.Get("error"); e != "" {
			msg = ": " + e
		}
		c.Eprintf("FAILED to start (%s%s). Last lines of %s/flutter-run.err:\n", l.st.Get("state"), msg, l.runDir)
		c.Eprintf("%s", tailLines(filepath.Join(l.runDir, "flutter-run.err"), 20))
		l.hist("live-start", secs, "FAILED")
		return 1
	}
	l.hist("live-start", secs, "ok")
	// The app logs main() -> first frame shortly after flutter run reports it started
	for i := 0; i < framePolls; i++ {
		if len(firstFrames(data)) > framesBefore {
			break
		}
		sleep(200 * time.Millisecond)
	}
	first := ""
	if f := firstFrames(data); len(f) > 0 {
		first = f[len(f)-1]
	}
	if first != "" {
		first = " (main() to first frame: " + first + " ms)"
	}
	c.Printf("started in %s s%s\n", secs, first)
	l.show()
	return 0
}

// tailLines is `tail -n N file` (nothing for a missing file).
func tailLines(path string, n int) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.SplitAfter(string(b), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "")
}

func (l *liveSide) reload(cmd string) int {
	c := l.c
	if !l.needRunning() || !l.load() {
		return 1
	}
	if l.st.Get("mode") == "profile" {
		c.Eprintf("No hot %s in --profile mode: tools/live.sh stop, then start again.\n", cmd)
		return 1
	}
	t := c.Us()
	rc := l.daemon("app.restart", cmd == "restart", 120)
	secs := c.SecsSince(t)
	c.Printf("%s: %s s\n", cmd, secs)
	res := "ok"
	if rc != 0 {
		res = "FAILED"
	}
	l.hist("live-"+cmd, secs, res)
	return rc
}

// xshotScript finds the Xvfb display of a process that xvfb-run started (it has DISPLAY and XAUTHORITY) and grabs its screen.
const xshotScript = `for e in /proc/[0-9]*/environ; do grep -qz "^XAUTHORITY=/tmp/xvfb-run" "$e" 2>/dev/null && break; done
        while IFS= read -r -d "" v; do case $v in DISPLAY=* | XAUTHORITY=*) export "${v?}" ;; esac; done < "$e"
        "$1/` + Inner + `" live xshot -`

func (l *liveSide) shot(rest []string) int {
	c := l.c
	if !l.needRunning() || !l.load() {
		return 1
	}
	file := filepath.Join(c.Root, "dist", "screens", "live.png")
	if len(rest) > 0 && rest[0] != "" {
		file = rest[0]
	}
	_ = os.MkdirAll(filepath.Dir(file), 0o755)
	switch {
	case l.st.Get("mode") == "debug":
		conn, err := dial(l.st.Get("vm"))
		if err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		defer conn.Close()
		data, err := conn.Screenshot()
		if err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		if err := os.WriteFile(file, data, 0o644); err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		c.Printf("%s (%d KB)\n", file, len(data)/1024)
	case l.label("bw.headless") == "1":
		// Profile builds have no inspector: grab the Xvfb screen (sized like the app's window) inside the container.
		f, err := os.Create(file)
		if err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "exec", l.name, "bash", "-c", xshotScript, "_", c.Root}, Env: c.Env, Stdout: f, Stderr: c.ChildErr})
		f.Close()
		if rc != 0 {
			return rc
		}
		st, _ := os.Stat(file)
		size := int64(0)
		if st != nil {
			size = st.Size()
		}
		c.Printf("%s (%d KB)\n", file, size/1024)
	default:
		c.Eprintf("A --profile app on the desktop has no in-app screenshot; start it with --headless for screenshots.\n")
		return 1
	}
	if err := copyFile(file, filepath.Join(l.runDir, "shot-"+c.Clock().Format("150405")+".png")); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	return 0
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}

func (l *liveSide) trace(rest []string) int {
	c := l.c
	if !l.needRunning() || !l.load() {
		return 1
	}
	sub := ""
	if len(rest) > 0 {
		sub = rest[0]
	}
	switch sub {
	case "start":
		conn, err := dial(l.st.Get("vm"))
		if err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		defer conn.Close()
		if err := conn.TraceStart(); err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		c.Printf("recording the timeline (Dart, Embedder, GC)\n")
	case "stop":
		name := c.Clock().Format("150405")
		if len(rest) > 1 && rest[1] != "" {
			name = rest[1]
		}
		conn, err := dial(l.st.Get("vm"))
		if err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		defer conn.Close()
		ev, err := conn.TraceStop()
		if err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		if err := vmservice.SaveTrace(filepath.Join(l.runDir, "trace-"+name+".json"), ev, l.st.Get("mode"), c.Out); err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
	default:
		return usage(c)
	}
	return 0
}

func (l *liveSide) status() int {
	c := l.c
	if l.podman("container", "exists", l.name) != 0 {
		c.Printf("not running\n")
		return 0
	}
	if !l.load() {
		return 1
	}
	if !l.running() {
		e := ""
		if v := l.st.Get("error"); v != "" {
			e = " (" + v + ")"
		}
		c.Printf("the container has exited%s; see %s/flutter-run.err; tools/live.sh stop cleans up\n", e, l.runDir)
	}
	l.show()
	return 0
}

func (l *liveSide) stop() int {
	c := l.c
	if l.podman("container", "exists", l.name) != 0 {
		c.Printf("not running\n")
		return 0
	}
	if !l.load() {
		return 1
	}
	if l.running() && l.st.Get("app") != "" {
		saved := c.Out
		c.Out = discard{} // `daemon app.stop '' 15 >/dev/null || true`
		l.daemon("app.stop", false, 15)
		c.Out = saved
	}
	if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "rm", "-f", "-t", "5", l.name}, Env: c.Env, Stderr: c.ChildErr}); rc != 0 {
		return rc
	}
	l.podman("pod", "rm", l.pod) // kept while the MCP server still runs in it
	if err := os.WriteFile(filepath.Join(l.runDir, "app-live.log"), appLogs(l.dataDir), 0o644); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	c.Printf("stopped; logs in %s\n", l.runDir)
	return 0
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }
