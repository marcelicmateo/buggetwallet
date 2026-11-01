package sys

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// KillGrace is how long a timed-out or cancelled process group gets between SIGTERM and SIGKILL.
var KillGrace = 10 * time.Second

// Cmd is one process to run. Nil Stdin/Stdout/Stderr mean /dev/null; nil Env inherits the process environment.
type Cmd struct {
	Argv   []string
	Dir    string
	Env    Env
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
	// Foreground keeps the child in our process group with our terminal (interactive podman); it is not killed with the group.
	Foreground bool
}

// Runner starts processes. Real is the real thing; Fake records the argument vectors for the unit tests.
type Runner interface {
	// Run runs the command to the end and returns its exit code (127 when it cannot start, 128+n when killed by signal n).
	// When ctx ends first, the command's whole process group gets SIGTERM, then SIGKILL after KillGrace.
	Run(ctx context.Context, c Cmd) int
	// Exec replaces this process (stdio commands: lsp, mcp, image-name's podman). It returns only on failure.
	Exec(c Cmd) error
	LookPath(name string) (string, error)
}

// Real runs processes with os/exec.
type Real struct{}

func (Real) LookPath(name string) (string, error) { return exec.LookPath(name) }

func (Real) Exec(c Cmd) error {
	path, err := exec.LookPath(c.Argv[0])
	if err != nil {
		return err
	}
	env := os.Environ()
	if c.Env != nil {
		env = c.Env.Environ()
	}
	if c.Dir != "" {
		if err := os.Chdir(c.Dir); err != nil {
			return err
		}
	}
	return syscall.Exec(path, c.Argv, env)
}

func (Real) Run(ctx context.Context, c Cmd) int {
	if ctx.Err() != nil {
		return 143
	}
	cmd := exec.Command(c.Argv[0], c.Argv[1:]...)
	cmd.Dir = c.Dir
	if c.Env != nil {
		cmd.Env = c.Env.Environ()
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = c.Stdin, c.Stdout, c.Stderr
	if !c.Foreground {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	}
	cmd.WaitDelay = 3 * time.Second
	if err := cmd.Start(); err != nil {
		if c.Stderr != nil {
			fmt.Fprintf(c.Stderr, "wallet-build: %s: %v\n", c.Argv[0], err)
		}
		return 127
	}
	pid := cmd.Process.Pid
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		select {
		case <-done:
			return
		case <-ctx.Done():
		}
		if c.Foreground {
			_ = cmd.Process.Signal(syscall.SIGTERM)
		} else {
			_ = syscall.Kill(-pid, syscall.SIGTERM)
		}
		select {
		case <-done:
		case <-time.After(KillGrace):
		}
		if c.Foreground {
			_ = cmd.Process.Kill()
		} else {
			_ = syscall.Kill(-pid, syscall.SIGKILL) // the leader and anything it left behind
		}
	}()
	err := cmd.Wait()
	close(done)
	<-finished
	if err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			return 1
		}
	}
	st := cmd.ProcessState
	if ws, ok := st.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return st.ExitCode()
}

// Fake records commands instead of running them.
type Fake struct {
	mu     sync.Mutex
	Calls  []Cmd
	Execs  []Cmd
	Handle func(c Cmd) int // exit code per command; nil = 0. May write to c.Stdout/c.Stderr.
	// HandleCtx is Handle for commands that wait for their context (a timeout); it wins when set.
	HandleCtx func(ctx context.Context, c Cmd) int
	Missing   map[string]bool // LookPath fails for these names
}

func (f *Fake) Run(ctx context.Context, c Cmd) int {
	f.mu.Lock()
	f.Calls = append(f.Calls, c)
	h, hc := f.Handle, f.HandleCtx
	f.mu.Unlock()
	if hc != nil {
		return hc(ctx, c)
	}
	if h != nil {
		return h(c)
	}
	return 0
}

func (f *Fake) Exec(c Cmd) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Execs = append(f.Execs, c)
	return nil
}

func (f *Fake) LookPath(name string) (string, error) {
	if f.Missing[name] {
		return "", exec.ErrNotFound
	}
	return "/usr/bin/" + name, nil
}

// Argvs returns the recorded argument vectors, each joined by single spaces, for golden comparisons.
func (f *Fake) Argvs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, c := range f.Calls {
		out = append(out, joinArgs(c.Argv))
	}
	return out
}

func joinArgs(a []string) string {
	s := ""
	for i, x := range a {
		if i > 0 {
			s += " "
		}
		s += x
	}
	return s
}
