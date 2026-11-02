package live

import (
	"context"
	"os"
	"path/filepath"
	"strconv"

	"golang.org/x/sys/unix"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
	"wallet-build/internal/vmservice"
)

// Container runs one live command inside the container (BW_NATIVE=1): `serve` is flutter run; `xshot` and `forward` are the
// helpers that tools/live_vm.py had.
func Container(c *run.Ctx, args []string) int {
	cmd := ""
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "serve":
		return serve(c)
	case "xshot", "forward":
		return vmservice.Main(c.Ctx, args, c.Env, c.Out, c.Err)
	}
	return usage(c)
}

// serve is flutter run with a private D-Bus session, on Xvfb or the host's display. It returns flutter run's exit code.
func serve(c *run.Ctx) int {
	dir, runDir := c.Getenv("BW_LIVE_DIR"), c.Getenv("BW_RUN_DIR")
	port, err := strconv.Atoi(c.Getenv("BW_LIVE_PORT"))
	if dir == "" || runDir == "" || err != nil {
		c.Eprintf("live serve: BW_LIVE_DIR, BW_RUN_DIR and BW_LIVE_PORT must be set\n")
		return 1
	}
	runtimeDir := runtimeDirPath
	for _, d := range []string{filepath.Join(dir, "data"), filepath.Join(dir, "docs"), runtimeDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			c.Eprintf("%v\n", err)
			return 1
		}
	}
	_ = os.Chmod(runtimeDir, 0o700)
	// path_provider: support folder = $XDG_DATA_HOME/<app id> (wallet, key file, logs), Documents = XDG_DOCUMENTS_DIR
	env := c.Env.With("XDG_DATA_HOME", filepath.Join(dir, "data"), "XDG_DOCUMENTS_DIR", filepath.Join(dir, "docs"), "XDG_RUNTIME_DIR", runtimeDir, "NO_AT_BRIDGE", "1")
	// File pickers (file_picker -> xdg-desktop-portal FileChooser): the portal and its GTK backend are started on demand by the
	// private D-Bus session below, not by anything on the host. Host folders it can browse: /files (live-files), the repo, this
	// run's log folder and history/.
	home := c.Getenv("HOME")
	for _, d := range []string{filepath.Join(home, ".config", "xdg-desktop-portal"), filepath.Join(home, ".config", "gtk-3.0")} {
		_ = os.MkdirAll(d, 0o755)
	}
	_ = os.WriteFile(filepath.Join(home, ".config", "xdg-desktop-portal", "portals.conf"), []byte("[preferred]\ndefault=gtk\n"), 0o644)
	_ = os.WriteFile(filepath.Join(home, ".config", "gtk-3.0", "bookmarks"), []byte("file:///files Test files\n"), 0o644)
	// Own build folder: wallet-build mounts the repo at /work, and CMake's cache is tied to the source path
	if rc := c.R.Run(c.Ctx, sys.Cmd{Argv: []string{"flutter", "config", "--build-dir=build/live"}, Dir: c.Root, Env: env, Stderr: c.Err}); rc != 0 {
		return rc
	}
	args := []string{"flutter", "run", "-d", "linux", "--machine", "--print-dtd", "--dds-port", strconv.Itoa(port)}
	if c.Getenv("BW_LIVE_MODE") == "profile" {
		args = append(args, "--profile")
	}
	if t := c.Getenv("BW_LIVE_TARGET"); t != "" {
		args = append(args, "-t", t)
	}
	// Headless: the bus is started outside Xvfb, so tell it the display for the portal's GTK backend
	if c.Getenv("BW_LIVE_HEADLESS") == "1" {
		args = append([]string{"xvfb-run", "-a", "-s", "-screen 0 1280x720x24", "bash", "-c", `dbus-update-activation-environment DISPLAY XAUTHORITY; exec "$@"`, "_"}, args...)
	}
	// DDS listens on 127.0.0.1 only; the published port arrives on the pod's other address
	fctx, stopFwd := context.WithCancel(c.Ctx)
	defer stopFwd()
	fwd := forward
	go func() {
		if err := fwd(fctx, "/proc/net/fib_trie", port); err != nil {
			c.Eprintf("forward: %v\n", err)
		}
	}()
	_ = os.Remove(fifoPath)
	if err := unix.Mkfifo(fifoPath, 0o600); err != nil {
		c.Eprintf("mkfifo: %v\n", err)
		return 1
	}
	fifo, err := os.OpenFile(fifoPath, os.O_RDWR, 0) // read-write, so flutter run never sees end of input
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	defer fifo.Close()
	out, err := os.Create(filepath.Join(runDir, "flutter-run.jsonl"))
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	defer out.Close()
	errf, err := os.Create(filepath.Join(runDir, "flutter-run.err"))
	if err != nil {
		c.Eprintf("%v\n", err)
		return 1
	}
	defer errf.Close()
	return c.R.Run(c.Ctx, sys.Cmd{Argv: append([]string{"dbus-run-session", "--"}, args...), Dir: filepath.Join(c.Root, "app"), Env: env, Stdin: fifo, Stdout: out, Stderr: errf})
}
