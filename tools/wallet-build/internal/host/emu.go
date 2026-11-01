package host

import (
	"context"
	"io"

	"wallet-build/internal/image"
	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// Init computes the dev image tag and the Flutter version and arms the secret redaction (the key's passwords never reach a
// log). It does not export BW_IMAGE: Main does, the live and emulator commands decide for themselves.
func (h *Host) Init() error {
	c := h.C
	var err error
	if h.flutter, err = image.FlutterVersion(c.Root); err != nil {
		return err
	}
	if h.Image, err = image.Tag(c.Root); err != nil {
		return err
	}
	_, envFile := h.signingPaths()
	c.Red = sys.NewRedactor(c.Env, sys.ReadSecretsFile(envFile)...)
	return nil
}

// EnsureImage builds the dev image when it is missing (build.sh image-name without the printing). The build is logged into the
// current run (image-dev.log).
func (h *Host) EnsureImage() int {
	if h.imageExists() {
		return 0
	}
	return h.buildImage("image-name")
}

// ImageExists reports whether podman has an image with that tag.
func (h *Host) ImageExists(tag string) bool {
	return h.C.R.Run(h.C.Ctx, sys.Cmd{Argv: []string{"podman", "image", "exists", tag}, Env: h.C.Env}) == 0
}

// RunPodman runs a podman command line for a container named name; SIGINT/SIGTERM and the context's deadline stop the container.
func (h *Host) RunPodman(ctx context.Context, argv []string, name string, tty bool, stdout, stderr io.Writer) int {
	return h.runPodman(ctx, argv, name, tty, stdout, stderr)
}

// TimedLogFn is TimedLog for any way of running the command: output to the log with start/end stamps, a .status next to
// it, optionally a history line, and the step's time limit (BW_TIMEOUT_<STEP>) applied through ctx.
func (h *Host) TimedLogFn(name, logPath string, split bool, cold string, history bool, fn func(ctx context.Context, stdout, stderr io.Writer) int) int {
	return h.timedLog(name, logPath, split, cold, history, fn)
}

// BeginRun starts a run directory for cmd, or joins the outer one (nil Dir). The caller calls Finish on the Dir.
func (h *Host) BeginRun(cmd string) (*run.Dir, error) { return h.C.Begin(cmd) }
