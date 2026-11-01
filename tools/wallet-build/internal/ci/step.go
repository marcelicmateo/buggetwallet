package ci

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// syncWriter serialises writes (a command's stdout and stderr share one writer, like a shell's 2>&1).
type syncWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (s *syncWriter) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

// consoleWriter shows output on our stdout (nothing when quiet).
type consoleWriter struct{ c *run.Ctx }

func (w *consoleWriter) Write(p []byte) (int, error) {
	_, err := w.c.Out.Write(p)
	return len(p), err
}

// tempDir is $RUNNER_TEMP, or the system temp directory outside Actions.
func (x *CI) tempDir() string {
	if d := x.C.Getenv("RUNNER_TEMP"); d != "" {
		return d
	}
	return os.TempDir()
}

// Step is `ci step <name> -- <cmd…>` (what timed.sh did): prints "=== name ===" to $LOG and the console, runs the command with
// stdout and stderr appended to $LOG and shown live, records "<name> <seconds> <exit>" in $RUNNER_TEMP/times.txt and returns
// the command's exit code (124 after an explicit time limit, see run.StepTimeout). No pipe, no pipefail needed.
func (x *CI) Step(args []string) (rc int, ok bool) {
	c := x.C
	if len(args) < 3 || args[1] != "--" || args[0] == "" {
		return 2, false
	}
	name, argv := args[0], args[2:]
	var logw io.Writer = io.Discard
	if p := c.Getenv("LOG"); p != "" {
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
		if err != nil {
			c.Eprintf("ci step: cannot open $LOG: %v\n", err)
			return 1, true
		}
		defer f.Close()
		logw = f
	}
	red := c.Red.Writer(&syncWriter{w: io.MultiWriter(logw, &consoleWriter{c: c})})
	_, _ = io.WriteString(red, "=== "+name+" ===\n")
	start := c.Clock().Unix()
	// no default limit: the wrapped wallet-build step has its own (run.DefaultTimeout); only BW_TIMEOUT_<NAME> or BW_STEP_TIMEOUT cap this
	timeout := run.StepTimeout(c.Env, name, 0)
	ctx := c.Ctx
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	rc = c.R.Run(ctx, sys.Cmd{Argv: argv, Env: c.Env, Stdout: red, Stderr: red})
	if ctx.Err() == context.DeadlineExceeded {
		_, _ = io.WriteString(red, "wallet-build: step "+name+" timed out after "+strconv.Itoa(int(timeout/time.Second))+" s\n")
		rc = 124
	}
	_ = red.Close()
	line := name + " " + strconv.FormatInt(c.Clock().Unix()-start, 10) + " " + strconv.Itoa(rc) + "\n"
	if err := run.AppendLine(filepath.Join(x.tempDir(), "times.txt"), line); err != nil {
		c.Eprintf("ci step: cannot write times.txt: %v\n", err)
	}
	return rc, true
}
