// Package run holds what every command shares: the context (paths, environment, output), run directories, history lines
// and the step engine (log, status, timeouts).
package run

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"wallet-build/internal/sys"
)

// Ctx is the context of one wallet-build invocation.
type Ctx struct {
	Root string  // the repository (inside the container: /work)
	Data string  // BW_DATA: history, runs
	Env  sys.Env // the environment the tool runs with and hands to its children
	// Out and Err are our own output (summaries, step output shown live); redacted, discarded when quiet.
	Out io.Writer
	Err io.Writer
	// ChildOut and ChildErr are what child processes that talk to the terminal inherit (podman run, flutter in a shell):
	// the real stdout/stderr, nil (/dev/null) when quiet.
	ChildOut io.Writer
	ChildErr io.Writer
	R        sys.Runner
	Red      *sys.Redactor
	Clock    func() time.Time
	Ctx      context.Context // cancelled by SIGINT/SIGTERM
	Quiet    bool

	mu sync.Mutex // guards Out/Err writes from several goroutines
}

// New builds a context from the process environment. out/errw are the real stdout/stderr.
func New(root string, env sys.Env, out, errw io.Writer, r sys.Runner) *Ctx {
	c := &Ctx{Root: root, Env: env, R: r, Clock: time.Now, Ctx: context.Background(), Out: out, Err: errw, ChildOut: out, ChildErr: errw}
	c.Data = DataDir(env)
	c.Red = sys.NewRedactor(env)
	return c
}

// DataDir is BW_DATA: ${BW_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/budget-wallet}.
func DataDir(env sys.Env) string {
	if d := env.Get("BW_DATA_DIR"); d != "" {
		return d
	}
	base := env.Get("XDG_DATA_HOME")
	if base == "" {
		base = filepath.Join(env.Get("HOME"), ".local", "share")
	}
	return filepath.Join(base, "budget-wallet")
}

// SetQuiet makes all of our output (and the children's) go to /dev/null.
func (c *Ctx) SetQuiet() {
	c.Quiet = true
	c.Out, c.Err = io.Discard, io.Discard
	c.ChildOut, c.ChildErr = nil, nil
}

// Printf writes to our stdout (serialised, redacted).
func (c *Ctx) Printf(format string, a ...any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	fmt.Fprint(c.Out, c.Red.Clean(fmt.Sprintf(format, a...)))
}

// Eprintf writes to our stderr (serialised, redacted).
func (c *Ctx) Eprintf(format string, a ...any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	fmt.Fprint(c.Err, c.Red.Clean(fmt.Sprintf(format, a...)))
}

// NowISO is `date +%Y-%m-%dT%H:%M:%S%:z`.
func (c *Ctx) NowISO() string { return c.Clock().Format("2006-01-02T15:04:05-07:00") }

// Us is the clock in microseconds, for SecsSince.
func (c *Ctx) Us() int64 { return c.Clock().UnixMicro() }

// SecsSince is the seconds since start (from Us) with one decimal, truncated: bash's secs_since.
func (c *Ctx) SecsSince(startUs int64) string {
	us := c.Us() - startUs
	if us < 0 {
		us = 0
	}
	return fmt.Sprintf("%d.%d", us/1000000, us/100000%10)
}

// Getenv reads from the context's environment.
func (c *Ctx) Getenv(k string) string { return c.Env.Get(k) }

// Setenv changes the environment handed to children (and read by later steps).
func (c *Ctx) Setenv(kv ...string) { c.Env = c.Env.With(kv...) }

// Capture runs a command in dir and returns its stdout (trimmed of the final newline) and exit code.
func (c *Ctx) Capture(dir string, argv ...string) (string, int) {
	var buf bytes.Buffer
	rc := c.R.Run(c.Ctx, sys.Cmd{Argv: argv, Dir: dir, Env: c.Env, Stdout: &buf})
	return strings.TrimRight(buf.String(), "\n"), rc
}

// CommitID is the short sha, with -dirty when the tree has uncommitted changes (untracked files count); "unknown" without git.
func (c *Ctx) CommitID() string {
	sha, rc := c.Capture("", "git", "-C", c.Root, "rev-parse", "--short", "HEAD")
	if rc != 0 || sha == "" {
		return "unknown"
	}
	if st, rc := c.Capture("", "git", "-C", c.Root, "status", "--porcelain"); rc == 0 && st != "" {
		sha += "-dirty"
	}
	return sha
}

// TimingInit fills the run metadata that children read (tools/timing.sh timing_init).
func (c *Ctx) TimingInit(cmd string) {
	def := func(k, v string) {
		if _, ok := c.Env.Lookup(k); !ok || c.Env.Get(k) == "" {
			c.Setenv(k, v)
		}
	}
	def("BW_RUN", c.NowISO())
	if c.Env.Get("BW_COMMIT") == "" {
		c.Setenv("BW_COMMIT", c.CommitID())
	}
	def("BW_CMD", cmd)
	def("BW_COLD", "0")
	def("BW_SOURCE", "local")
	def("BW_WORKTREE", filepath.Base(c.Root))
}

// AppendLine appends one line with a single write on an O_APPEND file, so concurrent runs never interleave.
func AppendLine(path, line string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(line)
	return err
}

// LogHistory adds one step line to history/steps.jsonl in bash's exact format (no JSON escaping, no spaces).
func (c *Ctx) LogHistory(step, secs, result, cold, started string) {
	if c.Env.Get("BW_COLD") == "1" {
		cold = "true"
	}
	if cold == "" {
		cold = "false"
	}
	if started == "" {
		started = c.NowISO()
	}
	runID := c.Env.Get("BW_RUN_ID")
	if runID == "" {
		runID = c.Env.Get("BW_RUN")
	}
	line := fmt.Sprintf(`{"ts":"%s","run":"%s","source":"%s","worktree":"%s","commit":"%s","cmd":"%s","step":"%s","seconds":%s,"result":"%s","image":"%s","cold":%s}`+"\n",
		started, runID, c.Env.Get("BW_SOURCE"), c.Env.Get("BW_WORKTREE"), c.Env.Get("BW_COMMIT"), c.Env.Get("BW_CMD"), step, secs, result,
		c.Env.Get("BW_IMAGE"), cold)
	_ = AppendLine(filepath.Join(c.Data, "history", "steps.jsonl"), c.Red.Clean(line))
}
