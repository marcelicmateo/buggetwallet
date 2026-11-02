package live

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/host"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

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

const startedEvents = `[{"event":"app.start","params":{"appId":"app-1","mode":"MODE"}}]
[{"event":"app.debugPort","params":{"appId":"app-1","wsUri":"ws://127.0.0.1:1234/tok=/ws"}}]
[{"event":"app.dtd","params":{"appId":"app-1","uri":"ws://127.0.0.1:1235/dtd="}}]
[{"event":"app.started","params":{"appId":"app-1"}}]
`

type shotConn struct {
	png    []byte
	events []json.RawMessage
	calls  *[]string
}

func (s shotConn) Screenshot() ([]byte, error) {
	*s.calls = append(*s.calls, "shot")
	return s.png, nil
}
func (s shotConn) TraceStart() error { *s.calls = append(*s.calls, "trace-start"); return nil }
func (s shotConn) TraceStop() ([]json.RawMessage, error) {
	*s.calls = append(*s.calls, "trace-stop")
	return s.events, nil
}
func (s shotConn) Close() error { return nil }

// rig is the host side with a fake podman that behaves like the live container.
type rig struct {
	t      *testing.T
	root   string
	data   string
	fake   *sys.Fake
	c      *run.Ctx
	h      *host.Host
	out    bytes.Buffer
	errb   bytes.Buffer
	name   string
	pod    string
	port   int
	exists bool // the live container exists
	runnin bool
	podEx  bool
	// what the container does when started
	startState string // "started" | "stopped-error" | "building"
	startErr   string
	frames     string // app log lines written at start
	headless   string // the label
	// labels read back
	runDir, dataDir string
	stdin           map[string]string
	replyCode       int
	replyMsg        string
	noReply         bool
	conn            *[]string
	dialURI         string
	screenshotPNG   []byte
	traceEvents     []json.RawMessage
}

func newRig(t *testing.T, env ...string) *rig {
	r := &rig{t: t, root: t.TempDir(), data: t.TempDir(), stdin: map[string]string{}, startState: "started", frames: `app.start {"phase":"total","ms":812}` + "\n", replyMsg: "Reloaded 3 libraries"}
	write(t, filepath.Join(r.root, "app/pubspec.yaml"), "environment:\n  flutter: \"3.47.7\"\n")
	for _, f := range []string{"dev/Containerfile", "dev/install-lint-tools.sh", "dev/linux-packages.txt"} {
		write(t, filepath.Join(r.root, f), f)
	}
	r.name, r.pod, r.port = Names(r.root)
	oldSleep, oldSocket, oldIsDir, oldExists, oldUID, oldDial := sleep, isSocket, isDir, exists, uid, dial
	sleep = func(time.Duration) {}
	isSocket = func(string) bool { return false }
	isDir = func(p string) bool {
		st, err := os.Stat(p)
		return err == nil && st.IsDir() && !strings.HasPrefix(p, "/usr/share")
	}
	exists = func(string) bool { return false }
	uid = func() int { return 1000 }
	r.conn = new([]string)
	dial = func(uri string) (screenshotter, error) {
		r.dialURI = uri
		return shotConn{png: r.screenshotPNG, events: r.traceEvents, calls: r.conn}, nil
	}
	t.Cleanup(func() {
		sleep, isSocket, isDir, exists, uid, dial = oldSleep, oldSocket, oldIsDir, oldExists, oldUID, oldDial
	})
	r.fake = &sys.Fake{Handle: r.handle}
	e := append([]string{"PATH=/usr/bin", "HOME=" + t.TempDir(), "BW_DATA_DIR=" + r.data, "BW_COMMIT=abc1234", "BW_SOURCE=local", "BW_WORKTREE=wt"}, env...)
	r.c = run.New(r.root, sys.Env(e), &r.out, &r.errb, r.fake)
	r.h = host.New(r.c, "/x/wallet-build", func() int { return 2 })
	return r
}

var reID = regexp.MustCompile(`"id": (\d+)`)

func (r *rig) handle(c sys.Cmd) int {
	a := c.Argv
	if a[0] != "podman" {
		return 0
	}
	key := strings.Join(a, " ")
	switch {
	case len(a) > 3 && a[1] == "image" && a[2] == "exists":
		return 0
	case len(a) > 3 && a[1] == "container" && a[2] == "exists":
		return b2rc(r.exists)
	case len(a) > 3 && a[1] == "pod" && a[2] == "exists":
		return b2rc(r.podEx)
	case len(a) > 2 && a[1] == "pod" && a[2] == "create":
		r.podEx = true
	case a[1] == "inspect" && strings.Contains(key, ".State.Running"):
		if r.runnin {
			c.Stdout.Write([]byte("true\n"))
		} else {
			c.Stdout.Write([]byte("false\n"))
		}
	case a[1] == "inspect" && strings.Contains(key, `"bw.run"`):
		c.Stdout.Write([]byte(r.runDir + "\n"))
	case a[1] == "inspect" && strings.Contains(key, `"bw.data"`):
		c.Stdout.Write([]byte(r.dataDir + "\n"))
	case a[1] == "inspect" && strings.Contains(key, `"bw.headless"`):
		c.Stdout.Write([]byte(r.headless + "\n"))
	case a[1] == "run" && len(a) > 2 && a[2] == "-d":
		for i, x := range a {
			if x == "--label" && strings.HasPrefix(a[i+1], "bw.run=") {
				r.runDir = strings.TrimPrefix(a[i+1], "bw.run=")
			}
			if x == "--label" && strings.HasPrefix(a[i+1], "bw.data=") {
				r.dataDir = strings.TrimPrefix(a[i+1], "bw.data=")
			}
			if x == "--label" && strings.HasPrefix(a[i+1], "bw.headless=") {
				r.headless = strings.TrimPrefix(a[i+1], "bw.headless=")
			}
		}
		r.exists, r.runnin = true, true
		switch r.startState {
		case "started":
			os.WriteFile(filepath.Join(r.runDir, "flutter-run.jsonl"), []byte(strings.ReplaceAll(startedEvents, "MODE", r.modeOf(a))), 0o644)
			os.MkdirAll(filepath.Join(r.dataDir, "data/hr.marcelic.budget_wallet/logs"), 0o755)
			os.WriteFile(filepath.Join(r.dataDir, "data/hr.marcelic.budget_wallet/logs/bw-2026-11-01.log"), []byte(r.frames), 0o644)
		case "stopped-error":
			os.WriteFile(filepath.Join(r.runDir, "flutter-run.jsonl"), []byte(`[{"event":"app.start","params":{"appId":"app-1","mode":"debug"}}]`+"\n"+`[{"event":"app.stop","params":{"appId":"app-1","error":"Build failed\nmore"}}]`+"\n"), 0o644)
			os.WriteFile(filepath.Join(r.runDir, "flutter-run.err"), []byte("err 1\nerr 2\n"), 0o644)
			r.runnin = false
		case "building":
			os.WriteFile(filepath.Join(r.runDir, "flutter-run.jsonl"), []byte(`[{"event":"app.start","params":{"appId":"app-1","mode":"debug"}}]`+"\n"), 0o644)
		}
	case a[1] == "exec" && len(a) > 3 && a[2] == "-i":
		b, _ := io.ReadAll(c.Stdin)
		r.stdin[key] = string(b)
		if m := reID.FindStringSubmatch(string(b)); m != nil && !r.noReply {
			f, _ := os.OpenFile(filepath.Join(r.runDir, "flutter-run.jsonl"), os.O_APPEND|os.O_WRONLY, 0o644)
			f.WriteString(`[{"id":` + m[1] + `,"result":{"code":` + itoa(r.replyCode) + `,"message":"` + r.replyMsg + `"}}]` + "\n")
			f.Close()
		}
	case a[1] == "exec" && len(a) > 4 && a[3] == "bash":
		c.Stdout.Write([]byte("PNG-FROM-XVFB"))
	}
	return 0
}

func (r *rig) modeOf(a []string) string {
	for i, x := range a {
		if strings.HasPrefix(x, "BW_LIVE_MODE=") {
			_ = i
			return strings.TrimPrefix(x, "BW_LIVE_MODE=")
		}
	}
	return "debug"
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func b2rc(b bool) int {
	if b {
		return 0
	}
	return 1
}

func (r *rig) host(args ...string) int { return Host(r.h, args) }

func (r *rig) calls() []string { return r.fake.Argvs() }

func (r *rig) history() string {
	b, _ := os.ReadFile(filepath.Join(r.data, "history", "steps.jsonl"))
	return string(b)
}

func (r *rig) podmanRun() string {
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 2 && c.Argv[0] == "podman" && c.Argv[1] == "run" {
			return strings.Join(c.Argv, " ")
		}
	}
	r.t.Fatal("no podman run")
	return ""
}

// started makes a live container that is already up (for reload, shot, trace, status, stop).
func (r *rig) started(mode string, headless string) {
	r.exists, r.runnin = true, true
	r.runDir, r.dataDir = filepath.Join(r.data, "runs", "20261101-100000-live-abc1234"), filepath.Join(r.root, "dist/live/demo")
	os.MkdirAll(r.runDir, 0o755)
	os.MkdirAll(r.dataDir, 0o755)
	write(r.t, filepath.Join(r.runDir, "flutter-run.jsonl"), strings.ReplaceAll(startedEvents, "MODE", mode))
	r.headless = headless
}

// ---- names ----

func TestNamesMatchTheScript(t *testing.T) {
	// made with: cksum <<<"bw-…" | cut -d' ' -f1, and tr -c 'a-zA-Z0-9_.\n-' '-'
	for pod, want := range map[string]uint32{"bw-wt": 3998280263, "bw-buggetwallet": 723544719, "bw-agent-a517fb123e1cee17b": 3323676713, "bw-x": 3697539994} {
		if got := Cksum([]byte(pod + "\n")); got != want {
			t.Errorf("cksum %s: %d, want %d", pod, got, want)
		}
	}
	name, pod, port := Names("/home/mateo/buggetwallet")
	if name != "bw-live-buggetwallet" || pod != "bw-buggetwallet" || port != 20000+723544719%20000 {
		t.Errorf("%s %s %d", name, pod, port)
	}
	if got := Sanitize("a b/ü"); got != "a-b---" {
		t.Errorf("sanitize %q", got)
	}
	if got := Sanitize("ok_name-1.2"); got != "ok_name-1.2" {
		t.Errorf("sanitize %q", got)
	}
	if _, err := exec.LookPath("cksum"); err == nil { // against the real tool
		out, _ := exec.Command("bash", "-c", `cksum <<<"bw-some folder/ü" | cut -d' ' -f1`).Output()
		if strings.TrimSpace(string(out)) != itoa(int(Cksum([]byte("bw-some folder/ü\n")))) {
			t.Errorf("cksum differs from the system's: %s", out)
		}
	}
}

// ---- usage ----

func TestUsageIsTwo(t *testing.T) {
	for _, args := range [][]string{{"bogus"}, {"start", "--bogus"}, {"start", "--headless", "x"}, {"serve"}, {"xshot"}, {"-q", "status"}, {"--quiet"}} {
		r := newRig(t)
		if rc := r.host(args...); rc != 2 {
			t.Errorf("%v: exit %d", args, rc)
		}
		if r.out.String() != usageText || !strings.HasPrefix(r.out.String(), "Live mode: the Linux desktop app") {
			t.Errorf("%v: out %q", args, r.out.String())
		}
		if len(r.fake.Calls) != 0 {
			t.Errorf("%v: ran %v", args, r.calls())
		}
	}
	// trace needs start or stop (after the running check, as in the script)
	r := newRig(t)
	r.started("debug", "0")
	if rc := r.host("trace", "pause"); rc != 2 {
		t.Errorf("trace pause: %d", rc)
	}
	if rc := r.host("trace"); rc != 2 {
		t.Errorf("trace: %d", rc)
	}
	r = newRig(t)
	if rc := r.host("trace", "pause"); rc != 1 || !strings.Contains(r.errb.String(), "Live mode is not running. Start it with: make live-start") {
		t.Errorf("trace not running: %d %q", rc, r.errb.String())
	}
}

func TestNotRunningMessages(t *testing.T) {
	for _, cmd := range []string{"reload", "restart", "shot", "trace"} {
		r := newRig(t)
		if rc := r.host(cmd, "start"); rc != 1 || r.errb.String() != "Live mode is not running. Start it with: make live-start\n" {
			t.Errorf("%s: %d %q", cmd, rc, r.errb.String())
		}
	}
	r := newRig(t)
	if rc := r.host(); rc != 0 || r.out.String() != "not running\n" { // the default command is status
		t.Errorf("status: %d %q", rc, r.out.String())
	}
	r = newRig(t)
	if rc := r.host("stop"); rc != 0 || r.out.String() != "not running\n" {
		t.Errorf("stop: %d %q", rc, r.out.String())
	}
	// the run folder is gone
	r = newRig(t)
	r.exists, r.runnin, r.runDir = true, true, filepath.Join(r.data, "gone")
	if rc := r.host("status"); rc != 1 || r.errb.String() != "Live mode's run folder is gone; make live-stop, then start.\n" {
		t.Errorf("status, folder gone: %d %q", rc, r.errb.String())
	}
}

// ---- start ----

func TestStartHeadlessDemoArgvAndOutput(t *testing.T) {
	r := newRig(t, "DISPLAY=:0", "XAUTHORITY=/home/u/.Xauthority") // the host's X11 must never reach the container
	if rc := r.host("start", "--headless", "--demo"); rc != 0 {
		t.Fatalf("exit %d\n%s%s", rc, r.out.String(), r.errb.String())
	}
	entries, _ := filepath.Glob(filepath.Join(r.data, "runs", "*"))
	if len(entries) != 1 || !strings.HasSuffix(entries[0], "-live-abc1234") {
		t.Fatalf("run dirs %v", entries)
	}
	dir := entries[0]
	demo := filepath.Join(r.root, "dist/live/demo")
	got := r.podmanRun()
	img := r.h.Image
	want := "podman run -d --init --name " + r.name + " --pod " + r.pod + " --label bw.run=" + dir + " --label bw.data=" + demo + " --label bw.headless=1 -e BW_LIVE_HEADLESS=1 " +
		"-v " + r.root + ":" + r.root + ":z -v bw-pub-cache:/cache/pub -e BW_NATIVE=1 -e BW_LIVE_DIR=" + demo + " -e BW_LIVE_MODE=debug -e BW_LIVE_TARGET=tool/live_demo.dart " +
		"-e BW_LIVE_PORT=" + itoa(r.port) + " -e BW_LIVE_DEMO=1 -v " + r.data + "/live-files:/files:z " +
		"-v " + dir + ":" + dir + ":z -v " + r.data + "/history:" + r.data + "/history:z " + runEnv + " -w " + r.root + " " + img + " dist/bin/wallet-build live serve"
	if got != want {
		t.Errorf("podman run\n got %s\nwant %s", got, want)
	}
	if !contains(r.calls(), "podman pod create --name "+r.pod+" --share net -p 127.0.0.1:"+itoa(r.port)+":"+itoa(r.port)) {
		t.Errorf("pod create missing: %v", r.calls())
	}
	if !contains(r.calls(), "podman rm -f "+r.name) {
		t.Error("a stale container is removed first")
	}
	wantOut := "building and starting (debug, demo wallet, headless)…\nstarted in 0.0 s (main() to first frame: 812 ms)\n" +
		"mode:      debug (started)\nvm:        ws://127.0.0.1:1234/tok=/ws\ndtd:       ws://127.0.0.1:1235/dtd=\n" +
		"wallet:    dist/live/demo (throwaway)\nlogs:      " + dir + "\n"
	if r.out.String() != wantOut {
		t.Errorf("out\n got %q\nwant %q", r.out.String(), wantOut)
	}
	// the live app outlives the command: .running stays, no last.status
	if _, err := os.Stat(filepath.Join(dir, ".running")); err != nil {
		t.Error(".running must stay")
	}
	if _, err := os.Stat(filepath.Join(dir, "last.status")); err == nil {
		t.Error("no last.status for a live run")
	}
	if h := r.history(); !strings.Contains(h, `"cmd":"live","step":"live-start","seconds":0.0,"result":"ok","image":"","cold":false`) {
		t.Errorf("history %s", h)
	}
}

const runEnv = "-e BW_DATA_DIR -e BW_RUN_DIR -e BW_RUN_ID -e BW_RUN -e BW_COMMIT -e BW_CMD -e BW_IMAGE -e BW_COLD -e BW_SOURCE -e BW_WORKTREE"

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func TestStartWaylandWindow(t *testing.T) {
	r := newRig(t, "WAYLAND_DISPLAY=wayland-0", "XDG_RUNTIME_DIR=/run/user/1000", "DISPLAY=:0", "XAUTHORITY=/home/u/.Xauthority")
	isSocket = func(p string) bool { return p == "/run/user/1000/wayland-0" }
	isDir = func(p string) bool {
		return p == "/usr/share/icons" || p == r.runDir || strings.HasPrefix(p, r.root) || strings.HasPrefix(p, r.data)
	}
	exists = func(p string) bool { return p == "/dev/dri/renderD128" }
	if rc := r.host("start"); rc != 0 {
		t.Fatalf("exit %d %s", rc, r.errb.String())
	}
	got := r.podmanRun()
	wayland := "--security-opt label=disable -v /run/user/1000/wayland-0:/tmp/bw-wayland:ro -e WAYLAND_DISPLAY=/tmp/bw-wayland -e GDK_BACKEND=wayland " +
		"-v /usr/share/icons:/tmp/bw-icons:ro -e XCURSOR_PATH=/tmp/bw-icons -e XCURSOR_THEME=Adwaita --device /dev/dri "
	if !strings.Contains(got, " -v "+r.data+"/live-files:/files:z "+wayland+"-v ") {
		t.Errorf("wayland args missing:\n%s", got)
	}
	if !strings.Contains(got, "--label bw.headless=0 -e BW_LIVE_HEADLESS=0") || !strings.Contains(got, "-e BW_LIVE_DEMO=0") || !strings.Contains(got, "-e BW_LIVE_TARGET= ") {
		t.Errorf("flags: %s", got)
	}
	if !strings.Contains(r.out.String(), "building and starting (debug)…\n") || !strings.Contains(got, "wallet-build live serve") {
		t.Errorf("out %q", r.out.String())
	}
	if !strings.Contains(got, "-v "+r.root+"/dist/live/wallet") && !strings.Contains(got, "-e BW_LIVE_DIR="+r.root+"/dist/live/wallet ") {
		t.Errorf("wallet dir: %s", got)
	}
	// software rendering without a render node, GPU off by env, an absolute WAYLAND_DISPLAY, the icon theme from the env
	exists = func(string) bool { return false }
	r2 := newRig(t, "WAYLAND_DISPLAY=/tmp/w/wl", "XCURSOR_THEME=Bibata")
	isSocket = func(p string) bool { return p == "/tmp/w/wl" }
	isDir = func(p string) bool {
		return p == "/usr/share/icons" || p == r2.runDir || strings.HasPrefix(p, r2.root) || strings.HasPrefix(p, r2.data)
	}
	exists = func(string) bool { return false }
	r2.host("start", "--profile")
	got2 := r2.podmanRun()
	if !strings.Contains(got2, "-v /tmp/w/wl:/tmp/bw-wayland:ro") || !strings.Contains(got2, "-e XCURSOR_THEME=Bibata") || !strings.Contains(got2, "-e LIBGL_ALWAYS_SOFTWARE=1") ||
		strings.Contains(got2, "--device /dev/dri") || !strings.Contains(got2, "-e BW_LIVE_MODE=profile") {
		t.Errorf("software rendering: %s", got2)
	}
	r3 := newRig(t, "WAYLAND_DISPLAY=wayland-1", "BW_LIVE_GPU=0")
	isSocket = func(p string) bool { return true }
	exists = func(string) bool { return true }
	r3.host("start")
	if got3 := r3.podmanRun(); strings.Contains(got3, "--device /dev/dri") || !strings.Contains(got3, "-e LIBGL_ALWAYS_SOFTWARE=1") || !strings.Contains(got3, "-v /run/user/1000/wayland-1:/tmp/bw-wayland:ro") {
		t.Errorf("BW_LIVE_GPU=0: %s", got3)
	}
}

func TestStartNeverPassesX11OrMoreThanThePackListedMounts(t *testing.T) {
	for _, tc := range []struct {
		name string
		env  []string
		args []string
		sock bool
	}{{"headless", nil, []string{"--headless"}, false}, {"no wayland falls back", nil, nil, false}, {"wayland", []string{"WAYLAND_DISPLAY=wayland-0"}, nil, true}} {
		r := newRig(t, append([]string{"DISPLAY=:0", "XAUTHORITY=/home/u/.Xauthority", "XDG_RUNTIME_DIR=/run/user/1000"}, tc.env...)...)
		isSocket = func(string) bool { return tc.sock }
		r.host(append([]string{"start"}, tc.args...)...)
		got := r.podmanRun()
		for _, tok := range strings.Fields(got) {
			if tok == "DISPLAY" || strings.HasPrefix(tok, "DISPLAY=") || strings.HasPrefix(tok, "XAUTHORITY") || strings.Contains(tok, ".X11-unix") ||
				strings.Contains(tok, ".Xauthority") || strings.HasPrefix(tok, "/dev/input") {
				t.Errorf("%s: the container args pass X11 or input devices through (%q):\n%s", tc.name, tok, got)
			}
		}
		// every mount: the repo, the pub cache, live-files, this run's folder, history/, and (Wayland only) the socket and icons.
		var mounts []string
		f := strings.Fields(got)
		for i, x := range f {
			if x == "-v" {
				mounts = append(mounts, f[i+1])
			}
		}
		for _, m := range mounts {
			src := strings.SplitN(m, ":", 2)[0]
			if src == r.data || src == r.data+"/" || src == "/" || src == r.c.Getenv("HOME") {
				t.Errorf("%s: mounts all of BW_DATA / / or home: %s", tc.name, m)
			}
			ok := src == r.root || src == "bw-pub-cache" || src == r.data+"/live-files" || src == r.data+"/history" || strings.HasPrefix(src, r.data+"/runs/") ||
				src == "/run/user/1000/wayland-0" || src == "/usr/share/icons"
			if !ok {
				t.Errorf("%s: unexpected mount %s", tc.name, m)
			}
		}
		if tc.name == "no wayland falls back" && !strings.Contains(r.errb.String(), "No Wayland session here: running headless (X11 is never passed through).") {
			t.Errorf("fallback message %q", r.errb.String())
		}
	}
}

func TestStartFailures(t *testing.T) {
	r := newRig(t)
	r.startState = "stopped-error"
	if rc := r.host("start", "--headless"); rc != 1 {
		t.Fatalf("exit %d", rc)
	}
	if !strings.HasPrefix(r.errb.String(), "FAILED to start (stopped: Build failed). Last lines of "+r.runDir+"/flutter-run.err:\nerr 1\nerr 2\n") {
		t.Errorf("err %q", r.errb.String())
	}
	if !strings.Contains(r.history(), `"step":"live-start","seconds":0.0,"result":"FAILED"`) {
		t.Errorf("history %s", r.history())
	}
	// still building when the container exits
	r = newRig(t)
	r.startState = "building"
	polls := 0
	sleep = func(time.Duration) {
		if polls++; polls == 3 {
			r.runnin = false
		}
	}
	if rc := r.host("start", "--headless"); rc != 1 || !strings.Contains(r.errb.String(), "FAILED to start (building).") {
		t.Errorf("exited while building: %d %q", rc, r.errb.String())
	}
	// never gets there: 1800 half-second polls
	r = newRig(t)
	r.startState = "building"
	polls = 0
	sleep = func(time.Duration) { polls++ }
	if rc := r.host("start", "--headless"); rc != 1 || polls != buildPolls {
		t.Errorf("timeout: %d after %d polls", rc, polls)
	}
	// podman run fails
	r = newRig(t)
	r.fake.Handle = func(c sys.Cmd) int {
		if len(c.Argv) > 2 && c.Argv[1] == "run" && c.Argv[2] == "-d" {
			return 125
		}
		return r.handle(c)
	}
	if rc := r.host("start", "--headless"); rc != 125 {
		t.Errorf("run failed: %d", rc)
	}
}

func TestStartWithoutFrameLineAndAlreadyRunning(t *testing.T) {
	r := newRig(t)
	r.frames = ""
	polls := 0
	sleep = func(time.Duration) { polls++ }
	if rc := r.host("start", "--headless"); rc != 0 {
		t.Fatal(rc)
	}
	if !strings.Contains(r.out.String(), "started in 0.0 s\nmode:") || polls != framePolls {
		t.Errorf("out %q, polls %d", r.out.String(), polls)
	}
	// the wait is for a new frame line, but (as in the script) the last line in the logs is reported, an old one when none came
	r = newRig(t)
	os.MkdirAll(filepath.Join(r.root, "dist/live/wallet/data/x/logs"), 0o755)
	write(t, filepath.Join(r.root, "dist/live/wallet/data/x/logs/bw-1.log"), `app.start {"phase":"total","ms":99}`+"\n")
	r.frames = ""
	r.dataDir = filepath.Join(r.root, "dist/live/wallet")
	r.host("start", "--headless")
	if !strings.Contains(r.out.String(), "started in 0.0 s (main() to first frame: 99 ms)\n") {
		t.Errorf("out %q", r.out.String())
	}
	// --fresh deletes the old wallet folder
	r = newRig(t)
	write(t, filepath.Join(r.root, "dist/live/wallet/old.txt"), "x")
	r.host("start", "--headless", "--fresh")
	if _, err := os.Stat(filepath.Join(r.root, "dist/live/wallet/old.txt")); err == nil {
		t.Error("--fresh keeps old data")
	}
	// already running: show, exit 0, nothing started
	r = newRig(t)
	r.started("debug", "0")
	if rc := r.host("start", "--demo"); rc != 0 {
		t.Fatal(rc)
	}
	if !strings.HasPrefix(r.out.String(), "already running (make live-stop first):\nmode:      debug (started)\n") || len(r.podmanRunCalls()) != 0 {
		t.Errorf("out %q", r.out.String())
	}
}

func (r *rig) podmanRunCalls() []string {
	var out []string
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "run" {
			out = append(out, strings.Join(c.Argv, " "))
		}
	}
	return out
}

// ---- status, reload, stop ----

func TestStatus(t *testing.T) {
	r := newRig(t)
	r.started("profile", "1")
	if rc := r.host("status"); rc != 0 {
		t.Fatal(rc)
	}
	want := "mode:      profile (started)\nvm:        ws://127.0.0.1:1234/tok=/ws\ndtd:       ws://127.0.0.1:1235/dtd=\nwallet:    dist/live/demo (throwaway)\nlogs:      " + r.runDir + "\n"
	if r.out.String() != want {
		t.Errorf("out %q\nwant %q", r.out.String(), want)
	}
	// an exited container
	r = newRig(t)
	r.started("debug", "0")
	r.runnin = false
	write(t, filepath.Join(r.runDir, "flutter-run.jsonl"), `[{"event":"app.start","params":{"appId":"a","mode":"debug"}}]`+"\n"+`[{"event":"app.stop","params":{"error":"boom"}}]`+"\n")
	r.host("status")
	if !strings.HasPrefix(r.out.String(), "the container has exited (boom); see "+r.runDir+"/flutter-run.err; make live-stop cleans up\nmode:      debug (stopped)\n") {
		t.Errorf("out %q", r.out.String())
	}
}

func TestReloadAndRestart(t *testing.T) {
	r := newRig(t)
	r.started("debug", "0")
	if rc := r.host("reload"); rc != 0 {
		t.Fatalf("exit %d %s", rc, r.errb.String())
	}
	if r.out.String() != "Reloaded 3 libraries\nreload: 0.0 s\n" {
		t.Errorf("out %q", r.out.String())
	}
	var in string
	for k, v := range r.stdin {
		if strings.HasPrefix(k, "podman exec -i "+r.name+" sh -c cat > /tmp/bw-live-in") {
			in = v
		}
	}
	if !regexp.MustCompile(`^\[\{"id": \d+, "method": "app.restart", "params": \{"appId": "app-1", "fullRestart": false, "pause": false, "reason": "manual"\}\}\]\n$`).MatchString(in) {
		t.Errorf("request %q", in)
	}
	if !strings.Contains(r.history(), `"cmd":"live","step":"live-reload","seconds":0.0,"result":"ok"`) || !strings.Contains(r.history(), `"run":"20261101-100000-live-abc1234"`) {
		t.Errorf("history %s", r.history())
	}
	r = newRig(t)
	r.started("debug", "0")
	r.replyCode, r.replyMsg = 1, "Hot restart failed"
	if rc := r.host("restart"); rc != 1 || r.out.String() != "Hot restart failed\nrestart: 0.0 s\n" {
		t.Errorf("failed restart: %d %q", rc, r.out.String())
	}
	for _, v := range r.stdin {
		if !strings.Contains(v, `"fullRestart": true`) {
			t.Errorf("restart is a full restart: %q", v)
		}
	}
	if !strings.Contains(r.history(), `"step":"live-restart","seconds":0.0,"result":"FAILED"`) {
		t.Errorf("history %s", r.history())
	}
	// profile mode has no hot reload
	r = newRig(t)
	r.started("profile", "1")
	if rc := r.host("reload"); rc != 1 || r.errb.String() != "No hot reload in --profile mode: make live-stop, then start again.\n" {
		t.Errorf("profile: %d %q", rc, r.errb.String())
	}
	// no reply within 120 s: the wait is cut off, the command fails
	r = newRig(t)
	r.started("debug", "0")
	r.noReply = true
	clock := time.Unix(5000, 0)
	now = func() time.Time { return clock }
	sleep = func(d time.Duration) { clock = clock.Add(d) }
	t.Cleanup(func() { now = time.Now })
	if rc := r.host("reload"); rc != 1 || !strings.HasPrefix(r.out.String(), "timed out waiting for flutter run\nreload: ") {
		t.Errorf("no reply: %d %q", rc, r.out.String())
	}
	if clock.Sub(time.Unix(5000, 0)) < 119*time.Second || clock.Sub(time.Unix(5000, 0)) > 122*time.Second {
		t.Errorf("waited %v", clock.Sub(time.Unix(5000, 0)))
	}
}

func TestStop(t *testing.T) {
	r := newRig(t)
	r.started("debug", "0")
	write(t, filepath.Join(r.dataDir, "data/id/logs/bw-2026-11-02.log"), "second\n")
	write(t, filepath.Join(r.dataDir, "data/id/logs/bw-2026-11-01.log"), "first\n")
	write(t, filepath.Join(r.dataDir, "data/id/logs/other.log"), "not mine\n")
	if rc := r.host("stop"); rc != 0 {
		t.Fatal(rc)
	}
	if r.out.String() != "stopped; logs in "+r.runDir+"\n" {
		t.Errorf("out %q (the app.stop reply is not shown)", r.out.String())
	}
	if file(t, filepath.Join(r.runDir, "app-live.log")) != "first\nsecond\n" {
		t.Errorf("app-live.log %q", file(t, filepath.Join(r.runDir, "app-live.log")))
	}
	calls := r.calls()
	i1, i2, i3 := idxPrefix(calls, "podman exec -i "+r.name), idxPrefix(calls, "podman rm -f -t 5 "+r.name), idxPrefix(calls, "podman pod rm "+r.pod)
	if i1 < 0 || i2 < i1 || i3 < i2 {
		t.Errorf("order: app.stop, rm, pod rm: %v", calls)
	}
	for _, v := range r.stdin {
		if !strings.Contains(v, `"method": "app.stop", "params": {"appId": "app-1"}`) {
			t.Errorf("stop request %q", v)
		}
	}
}

func idxPrefix(l []string, p string) int {
	for i, x := range l {
		if strings.HasPrefix(x, p) {
			return i
		}
	}
	return -1
}

func TestPod(t *testing.T) {
	r := newRig(t)
	if rc := r.host("pod"); rc != 0 || r.out.String() != r.pod+"\n" {
		t.Errorf("pod: %d %q", rc, r.out.String())
	}
	if !contains(r.calls(), "podman pod create --name "+r.pod+" --share net -p 127.0.0.1:"+itoa(r.port)+":"+itoa(r.port)) {
		t.Errorf("%v", r.calls())
	}
	r = newRig(t)
	r.podEx = true
	r.host("pod")
	if idxPrefix(r.calls(), "podman pod create") >= 0 {
		t.Error("an existing pod is kept")
	}
	// create fails and the pod does not exist: an error
	r = newRig(t)
	r.fake.Handle = func(c sys.Cmd) int {
		if len(c.Argv) > 2 && c.Argv[1] == "pod" {
			return 1
		}
		return 0
	}
	if rc := r.host("pod"); rc == 0 || r.out.String() != "" {
		t.Errorf("pod create failed: %d %q", rc, r.out.String())
	}
}

func TestMcpExecsWalletBuild(t *testing.T) {
	r := newRig(t)
	r.host("mcp", "--x")
	if len(r.fake.Execs) != 1 || strings.Join(r.fake.Execs[0].Argv, " ") != r.root+"/dist/bin/wallet-build mcp --x" {
		t.Errorf("%v", r.fake.Execs)
	}
}

// ---- shot and trace ----

func TestShotDebug(t *testing.T) {
	r := newRig(t)
	r.started("debug", "0")
	r.screenshotPNG = bytes.Repeat([]byte("p"), 5000)
	out := filepath.Join(t.TempDir(), "sub", "x.png")
	if rc := r.host("shot", out); rc != 0 {
		t.Fatalf("exit %d %s", rc, r.errb.String())
	}
	if r.out.String() != out+" (4 KB)\n" || r.dialURI != "ws://127.0.0.1:1234/tok=/ws" {
		t.Errorf("out %q uri %q", r.out.String(), r.dialURI)
	}
	if len(file(t, out)) != 5000 {
		t.Error("png")
	}
	copies, _ := filepath.Glob(filepath.Join(r.runDir, "shot-??????.png"))
	if len(copies) != 1 {
		t.Errorf("copy in the run dir: %v", copies)
	}
	// default file
	r = newRig(t)
	r.started("debug", "0")
	r.host("shot")
	if _, err := os.Stat(filepath.Join(r.root, "dist/screens/live.png")); err != nil {
		t.Error("default dist/screens/live.png")
	}
}

func TestShotProfile(t *testing.T) {
	r := newRig(t)
	r.started("profile", "1")
	out := filepath.Join(t.TempDir(), "p.png")
	if rc := r.host("shot", out); rc != 0 || r.out.String() != out+" (0 KB)\n" {
		t.Fatalf("exit %d %q", rc, r.out.String())
	}
	if file(t, out) != "PNG-FROM-XVFB" {
		t.Error("png from the container's Xvfb")
	}
	var script string
	for _, c := range r.fake.Calls {
		if len(c.Argv) > 3 && c.Argv[1] == "exec" && c.Argv[3] == "bash" {
			script = strings.Join(c.Argv, "\x00")
			if c.Argv[2] != r.name || c.Argv[4] != "-c" || c.Argv[6] != "_" || c.Argv[7] != r.root {
				t.Errorf("exec argv %q", c.Argv)
			}
		}
	}
	if !strings.Contains(script, "XAUTHORITY=/tmp/xvfb-run") || !strings.Contains(script, `"$1/dist/bin/wallet-build" live xshot -`) {
		t.Errorf("script %q", script)
	}
	if strings.Contains(script, "python3") {
		t.Error("no python")
	}
	// profile on the desktop: no screenshot
	r = newRig(t)
	r.started("profile", "0")
	if rc := r.host("shot", out); rc != 1 || r.errb.String() != "A --profile app on the desktop has no in-app screenshot; start it with --headless for screenshots.\n" {
		t.Errorf("%d %q", rc, r.errb.String())
	}
}

func TestTrace(t *testing.T) {
	r := newRig(t)
	r.started("debug", "0")
	if rc := r.host("trace", "start"); rc != 0 || r.out.String() != "recording the timeline (Dart, Embedder, GC)\n" {
		t.Errorf("start: %d %q", rc, r.out.String())
	}
	r.out.Reset()
	r.traceEvents = []json.RawMessage{json.RawMessage(`{"name":"Animator::BeginFrame","ph":"X","ts":5,"dur":20000}`), json.RawMessage(`{"name":"GPURasterizer::Draw","ph":"X","ts":9,"dur":1000}`)}
	if rc := r.host("trace", "stop", "run1"); rc != 0 {
		t.Fatal(rc)
	}
	p := filepath.Join(r.runDir, "trace-run1.json")
	sum := file(t, filepath.Join(r.runDir, "trace-run1-summary.txt"))
	if !strings.HasPrefix(sum, "timeline: 0.0 s, 2 events, 1 frames, 1 over 16 ms") || !strings.Contains(sum, "(debug build: timings are not representative; make live-start ARGS=--profile for real numbers)") ||
		r.out.String() != sum+"saved "+p+"\n" {
		t.Errorf("summary %q out %q", sum, r.out.String())
	}
	var tr struct {
		TraceEvents []json.RawMessage `json:"traceEvents"`
		Unit        string            `json:"displayTimeUnit"`
	}
	if json.Unmarshal([]byte(file(t, p)), &tr) != nil || len(tr.TraceEvents) != 2 || tr.Unit != "ms" {
		t.Errorf("trace file %s", file(t, p))
	}
	if strings.Join(*r.conn, ",") != "trace-start,trace-stop" {
		t.Errorf("rpc %v", *r.conn)
	}
	// default name: the time
	r.host("trace", "stop")
	m, _ := filepath.Glob(filepath.Join(r.runDir, "trace-??????.json"))
	if len(m) != 1 {
		t.Errorf("default trace name: %v", m)
	}
}

func TestDialErrorsAreExit1(t *testing.T) {
	r := newRig(t)
	r.started("debug", "0")
	dial = func(string) (screenshotter, error) { return nil, errors.New("refused") }
	for _, args := range [][]string{{"shot"}, {"trace", "start"}, {"trace", "stop"}} {
		if rc := r.host(args...); rc != 1 {
			t.Errorf("%v: %d", args, rc)
		}
	}
	if !strings.Contains(r.errb.String(), "refused") {
		t.Errorf("err %q", r.errb.String())
	}
}

// ---- no quiet mode ----

func TestQuietIsIgnoredAndAFlagIsUsage(t *testing.T) {
	// the Go port of live.sh prints as the script does, whatever BW_QUIET says (see cli.go: live is exempt from quiet)
	r := newRig(t, "BW_QUIET=1")
	r.host("status")
	if r.out.String() != "not running\n" {
		t.Errorf("out %q", r.out.String())
	}
}

// ---- appLogs ----

func TestAppLogs(t *testing.T) {
	d := t.TempDir()
	write(t, filepath.Join(d, "data/a.b/logs/bw-2026-11-02.log"), "B\n")
	write(t, filepath.Join(d, "data/a.b/logs/bw-2026-11-01.log"), "A\n")
	write(t, filepath.Join(d, "data/a.b/logs/bw-.log"), "E\n")
	write(t, filepath.Join(d, "data/a.b/logs/bw-x.txt"), "no\n")
	write(t, filepath.Join(d, "data/a.b/notlogs/bw-1.log"), "no\n")
	write(t, filepath.Join(d, "docs/logs/bw-1.log"), "no\n")
	if got := string(appLogs(d)); got != "E\nA\nB\n" {
		t.Errorf("%q", got)
	}
	write(t, filepath.Join(d, "data/a.b/logs/bw-3.log"), `x app.start {"phase":"total","ms":700} y app.start {"phase":"total","ms":701}`+"\n")
	if got := strings.Join(firstFrames(d), ","); got != "700,701" {
		t.Errorf("frames %s", got)
	}
	if len(appLogs(filepath.Join(d, "nothing"))) != 0 {
		t.Error("missing folder")
	}
}

var _ = context.Background

func TestVMDispatch(t *testing.T) {
	for _, args := range [][]string{{"vm"}, {"vm", "info"}, {"vm", "bogus"}} {
		r := newRig(t)
		if rc := r.host(args...); rc != 2 {
			t.Errorf("%v: exit %d", args, rc)
		}
		if !strings.Contains(r.errb.String(), "live vm info") {
			t.Errorf("%v: usage not on stderr: %q", args, r.errb.String())
		}
	}
	r := newRig(t)
	write(t, filepath.Join(r.root, "m.jsonl"), "")
	if rc := r.host("vm", "info", filepath.Join(r.root, "m.jsonl")); rc != 0 {
		t.Errorf("vm info: exit %d", rc)
	}
}
