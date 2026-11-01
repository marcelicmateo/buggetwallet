// Package emulator ports tools/emulator.sh: the Android emulator in a rootless Podman container (host side: image, volumes,
// containers; container side: setup, boot and `flutter drive` runs).
package emulator

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"wallet-build/internal/host"
	"wallet-build/internal/image"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

//go:embed usage.txt
var usageText string

// Names and settings that tools/emulator.sh fixes.
const (
	// ContainerName is the long-lived emulator container (`start`).
	ContainerName = "bw-emulator"
	// Serial is the adb serial of the emulator.
	Serial = "emulator-5554"
	// SysImg is the system image installed into the volume.
	SysImg = "system-images;android-35;google_apis;x86_64"
	// SetupID changes with the AVD settings: a different value sets the volumes up again on the next run.
	SetupID = "1 " + SysImg + " pixel_6 hw.keyboard=yes hw.ramSize=3072 disk.dataPartition.size=6G lavapipe"
	// AppID is the application id uninstalled before each integration test file.
	AppID = "hr.marcelic.budget_wallet"
	// Inner is the command the container runs (the static binary in the mounted repo).
	Inner = "dist/bin/wallet-build"
)

// EmuArgs are the emulator's own arguments (lavapipe = Mesa software Vulkan: SwiftShader GLES segfaults and SwANGLE hits
// illegal instructions in containers, emulator 37.x).
var EmuArgs = []string{"-avd", "bw", "-no-audio", "-no-boot-anim", "-gpu", "lavapipe", "-accel", "on", "-no-metrics"}

// Volumes hold the emulator, the system image and the AVD, so rebuilding the build image never downloads them again.
var Volumes = []string{"bw-emulator:/opt/android-sdk/emulator", "bw-emulator-image:/opt/android-sdk/system-images", "bw-emulator-avd:/opt/avd"}

// sleep is the pause between polls; the tests replace it.
var sleep = time.Sleep

// StartPolls is how many one-second polls `start` waits for "emulator booted".
const StartPolls = 180

func usage(c *run.Ctx) int {
	fmt.Fprint(c.Out, usageText)
	return 2
}

// Host runs one emulator command on the machine that has Podman. args[0] is the command (default screens).
func Host(h *host.Host, args []string) (code int) {
	c := h.C
	cmd := "screens"
	if len(args) > 0 && args[0] != "" {
		cmd = args[0]
	}
	switch cmd {
	case "screens", "test", "start", "install", "shot", "adb", "stop", "reset":
	default:
		return usage(c)
	}
	return (&hostSide{h: h, c: c}).dispatch(cmd, args)
}

type hostSide struct {
	h     *host.Host
	c     *run.Ctx
	img   string
	built bool // an image was built in this run: the run counts as a cold start
}

func (e *hostSide) dispatch(cmd string, args []string) (code int) {
	c := e.c
	rest := []string{}
	if len(args) > 1 {
		rest = args[1:]
	}
	begin := func(name string) (*run.Dir, bool) {
		d, err := e.h.BeginRun(name)
		if err != nil {
			c.Eprintf("%v\n", err)
			return nil, false
		}
		return d, true
	}
	switch cmd {
	case "screens", "test":
		d, ok := begin(cmd)
		if !ok {
			return 1
		}
		defer func() { d.Finish(code) }()
		return e.screensOrTest(cmd, rest)
	case "start":
		if e.running() {
			c.Printf("already running\n")
			return 0
		}
		c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "rm", "-f", ContainerName}, Env: c.Env})
		d, ok := begin("start")
		if !ok {
			return 1
		}
		defer func() { d.Finish(code) }()
		return e.start(rest)
	case "install":
		if !e.needRunning() {
			return 1
		}
		apk := "dist/BudgetWallet-android.apk"
		if len(rest) > 0 && rest[0] != "" {
			apk = rest[0]
		}
		if !strings.HasPrefix(apk, "/") {
			apk = "/work/" + apk
		}
		d, ok := begin("install")
		if !ok {
			return 1
		}
		defer func() { d.Finish(code) }()
		return e.h.TimedLog("emulator-install", filepath.Join(c.Getenv("BW_RUN_DIR"), "emulator-install.log"), true, "false", true,
			[]string{"podman", "exec", ContainerName, "adb", "install", "-r", apk})
	case "shot":
		if !e.needRunning() {
			return 1
		}
		if len(rest) == 0 || rest[0] == "" {
			return usage(c)
		}
		dir := filepath.Join(c.Root, "dist", "screens")
		_ = os.MkdirAll(dir, 0o755)
		f, err := os.Create(filepath.Join(dir, rest[0]+".png"))
		if err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
		rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "exec", ContainerName, "adb", "exec-out", "screencap", "-p"}, Env: c.Env, Stdout: f, Stderr: c.ChildErr})
		f.Close()
		if rc != 0 {
			return rc
		}
		c.Printf("dist/screens/%s.png\n", rest[0])
		return 0
	case "adb":
		if !e.needRunning() {
			return 1
		}
		return c.R.Run(c.Ctx, sys.Cmd{Argv: append([]string{"podman", "exec", ContainerName, "adb"}, rest...), Env: c.Env, Stdout: c.ChildOut, Stderr: c.ChildErr})
	case "stop":
		return e.stop()
	case "reset":
		if e.running() {
			c.Eprintf("Stop the running emulator first: tools/emulator.sh stop\n")
			return 1
		}
		if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "volume", "rm", "-f", "bw-emulator", "bw-emulator-image", "bw-emulator-avd"}, Env: c.Env, Stderr: c.ChildErr}); rc != 0 {
			return rc
		}
		c.Printf("emulator volumes deleted\n")
		return 0
	}
	return usage(c)
}

func (e *hostSide) running() bool {
	c := e.c
	if c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "container", "exists", ContainerName}, Env: c.Env}) != 0 {
		return false
	}
	out, _ := c.CaptureQuiet("", "podman", "inspect", "-f", "{{.State.Running}}", ContainerName)
	return out == "true"
}

func (e *hostSide) needRunning() bool {
	if e.running() {
		return true
	}
	e.c.Eprintf("No emulator running. Start one with: tools/emulator.sh start\n")
	return false
}

func orDefault(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

// name is a container name for a helper container of this run.
func (e *hostSide) name(kind string) string {
	c := e.c
	return image.ContainerName(orDefault(c.Getenv("BW_WORKTREE"), filepath.Base(c.Root)), orDefault(c.Getenv("BW_RUN_ID"), "emulator")+"-"+kind)
}

// EmuTag is localhost/budget-wallet-emu:<8 hex of sha256 over the base tag, a newline and dev/Containerfile.emulator>.
func EmuTag(base string, containerfile []byte) string {
	sum := sha256.Sum256(append([]byte(base+"\n"), containerfile...))
	return fmt.Sprintf("localhost/budget-wallet-emu:%x", sum[:])[:len("localhost/budget-wallet-emu:")+8]
}

// emuImage makes sure the dev image and the emulator image on top of it exist and returns the emulator image's tag.
func (e *hostSide) emuImage() (string, int) {
	c := e.c
	base := e.h.Image
	if !e.h.ImageExists(base) {
		e.built = true
		if rc := e.h.EnsureImage(); rc != 0 {
			return "", rc
		}
	}
	cf := filepath.Join(c.Root, "dev", "Containerfile.emulator")
	b, err := os.ReadFile(cf)
	if err != nil {
		c.Eprintf("%v\n", err)
		return "", 1
	}
	tag := EmuTag(base, b)
	if !e.h.ImageExists(tag) {
		e.built = true
		rc := e.h.TimedLog("emulator-image", filepath.Join(c.Getenv("BW_RUN_DIR"), "image-emulator.log"), false, "true", true,
			[]string{"podman", "build", "--build-arg", "BASE=" + base, "-f", cf, "-t", tag, filepath.Join(c.Root, "dev")})
		if rc != 0 {
			return "", rc
		}
	}
	return tag, 0
}

// runMounts and runEnv make the container write into the same run and history (tools/timing.sh run_mounts, run_env).
func (e *hostSide) runArgs() []string {
	out := []string{"-v", e.c.Data + ":" + e.c.Data + ":z"}
	for _, v := range image.RunEnv {
		out = append(out, "-e", v)
	}
	return out
}

// prepare makes the images and the volumes ready (the setup is a no-op after the first run); sets e.img.
func (e *hostSide) prepare() int {
	c := e.c
	if err := e.h.Init(); err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	t := c.Us()
	img, rc := e.emuImage()
	if rc != 0 {
		return rc
	}
	e.img = img
	c.Setenv("BW_IMAGE", img)
	logPath := filepath.Join(c.Getenv("BW_RUN_DIR"), "image-emulator-setup.log")
	f, err := os.Create(logPath)
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	defer f.Close()
	argv := []string{"podman", "run", "--rm", "--init", "--name", e.name("setup"), "--device", "/dev/kvm", "--shm-size=2g"}
	for _, v := range Volumes {
		argv = append(argv, "-v", v)
	}
	argv = append(argv, e.runArgs()...)
	argv = append(argv, "-v", c.Root+":/work:z", "-e", "BW_NATIVE=1", "-w", "/work", img, Inner, "emulator", "setup")
	var seen bytes.Buffer
	w := c.Red.Writer(io.MultiWriter(f, &seen, c.Err))
	rc = e.h.RunPodman(c.Ctx, argv, e.name("setup"), false, w, w)
	_ = w.Close()
	if rc != 0 {
		return rc
	}
	// cold: an image was built or the volumes were set up
	if e.built || strings.Contains(seen.String(), "Setting up") {
		c.Setenv("BW_COLD", "1")
	}
	c.LogHistory("prepare", c.SecsSince(t), "ok", "false", "")
	return 0
}

// common are the arguments of every container that runs a command: the repo, caches, the SDK volumes read-only (a run only reads
// them; the AVD stays writable for the emulator's lock files, `-read-only` keeps the device state itself out of it), the run.
func (e *hostSide) common() []string {
	c := e.c
	a := []string{"--device", "/dev/kvm", "--shm-size=2g", "-e", "BW_DRIVE_ARGS", "-v", c.Root + ":/work:z", "-v", "bw-pub-cache:/cache/pub",
		"-v", "bw-gradle-cache:/cache/gradle", "-v", "bw-android-user:/cache/android", "-e", "BW_NATIVE=1", "-w", "/work",
		"-v", Volumes[0] + ":ro", "-v", Volumes[1] + ":ro", "-v", Volumes[2]}
	return append(a, e.runArgs()...)
}

func (e *hostSide) screensOrTest(cmd string, rest []string) int {
	c := e.c
	t0 := c.Us()
	if rc := e.prepare(); rc != 0 {
		return rc
	}
	runDir := c.Getenv("BW_RUN_DIR")
	name := e.name(cmd)
	argv := append([]string{"podman", "run", "--rm", "--init", "--name", name}, e.common()...)
	argv = append(argv, e.img, Inner, "emulator", cmd)
	argv = append(argv, rest...)
	// output to the terminal and to emulator-<cmd>.log (+ .status), no history line (the phases and total are there)
	rc := e.h.TimedLogFn("emulator-"+cmd, filepath.Join(runDir, "emulator-"+cmd+".log"), true, "true", false,
		func(ctx context.Context, stdout, stderr io.Writer) int {
			return e.h.RunPodman(ctx, argv, name, false, stdout, stderr)
		})
	screens := filepath.Join(c.Root, "dist", "screens")
	if cmd == "screens" {
		pngs, _ := filepath.Glob(filepath.Join(screens, "*.png"))
		for _, p := range pngs {
			_ = copyFile(p, filepath.Join(runDir, filepath.Base(p)))
		}
	} else {
		_ = os.MkdirAll(filepath.Join(runDir, "screens"), 0o755)
		ents, _ := os.ReadDir(screens)
		for _, ent := range ents {
			if info, err := os.Stat(filepath.Join(screens, ent.Name())); err == nil && info.IsDir() {
				_ = copyTree(filepath.Join(screens, ent.Name()), filepath.Join(runDir, "screens", ent.Name()))
			}
		}
	}
	res := "ok"
	if rc != 0 {
		res = "FAILED"
	}
	c.LogHistory("total", c.SecsSince(t0), res, "false", "")
	return rc
}

func (e *hostSide) start(rest []string) int {
	c := e.c
	if rc := e.prepare(); rc != 0 {
		return rc
	}
	var win []string
	flag := ""
	if len(rest) > 0 && rest[0] == "--window" {
		flag = "window"
		display := orDefault(c.Getenv("DISPLAY"), ":0")
		win = []string{"-e", "DISPLAY=" + display, "-e", "QT_QPA_PLATFORM=xcb", "-v", "/tmp/.X11-unix:/tmp/.X11-unix:ro"}
		if xa := c.Getenv("XAUTHORITY"); xa != "" {
			win = append(win, "-e", "XAUTHORITY=/tmp/xauth", "-v", xa+":/tmp/xauth:ro")
		}
		win = append(win, "--security-opt", "label=disable")
	}
	// The label tells `stop` where to save the emulator's log
	argv := []string{"podman", "run", "-d", "--init", "--name", ContainerName, "--label", "bw.run=" + c.Getenv("BW_RUN_DIR")}
	argv = append(argv, e.common()...)
	argv = append(argv, win...)
	argv = append(argv, e.img, Inner, "emulator", "boot")
	if flag != "" {
		argv = append(argv, flag)
	}
	if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: argv, Env: c.Env, Stderr: c.ChildErr}); rc != 0 {
		return rc
	}
	c.Printf("booting…\n")
	for i := 0; i < StartPolls; i++ {
		var logs bytes.Buffer
		c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "logs", ContainerName}, Env: c.Env, Stdout: &logs, Stderr: &logs})
		if strings.Contains(logs.String(), "emulator booted") {
			c.Printf("ready (%s)\n", Serial)
			return 0
		}
		if !e.running() {
			e.tailLogs()
			return 1
		}
		if c.Ctx.Err() != nil {
			return 1
		}
		sleep(time.Second)
	}
	c.Printf("timed out\n")
	e.tailLogs()
	return 1
}

// tailLogs prints the last 30 lines of the container's output.
func (e *hostSide) tailLogs() {
	c := e.c
	var out bytes.Buffer
	c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "logs", ContainerName}, Env: c.Env, Stdout: &out, Stderr: c.ChildErr})
	lines := strings.SplitAfter(out.String(), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > 30 {
		lines = lines[len(lines)-30:]
	}
	c.Printf("%s", strings.Join(lines, ""))
}

func (e *hostSide) stop() int {
	c := e.c
	if c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "container", "exists", ContainerName}, Env: c.Env}) != 0 {
		c.Printf("not running\n")
		return 0
	}
	dir, _ := c.CaptureQuiet("", "podman", "inspect", "-f", `{{index .Config.Labels "bw.run"}}`, ContainerName)
	if st, err := os.Stat(dir); err == nil && st.IsDir() {
		c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "cp", ContainerName + ":/tmp/emulator.log", filepath.Join(dir, "emulator.log")}, Env: c.Env})
	}
	if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"podman", "rm", "-f", "-t", "0", ContainerName}, Env: c.Env, Stderr: c.ChildErr}); rc != 0 {
		return rc
	}
	c.Printf("stopped\n")
	return 0
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func copyTree(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(src, p)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		if info.Mode().IsRegular() {
			return copyFile(p, filepath.Join(dst, rel))
		}
		return nil
	})
}
