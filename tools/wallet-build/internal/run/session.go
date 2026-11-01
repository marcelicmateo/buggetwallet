package run

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"wallet-build/internal/sys"
)

// Spec is one step: a name, what it does, and whether it counts as a cold start in the history.
type Spec struct {
	Name string
	Fn   func(sc *StepCtx) int
	Cold bool
}

// Timing is one row of the end-of-run table.
type Timing struct{ Name, Secs, Result string }

// Session is the container side of a run: the logs folder, the records of the steps run so far.
type Session struct {
	C       *Ctx
	Logs    string
	Start   int64
	Results []string
	Timings []Timing
	Failed  bool
	mu      sync.Mutex
}

// NewSession starts the container-side bookkeeping. Logs is the run dir, or plain dist/logs natively.
func NewSession(c *Ctx) *Session {
	logs := c.Env.Get("BW_RUN_DIR")
	if logs == "" {
		logs = filepath.Join(c.Root, "dist", "logs")
	}
	if st, err := os.Lstat(logs); err == nil && st.Mode()&os.ModeSymlink != 0 {
		if _, err := os.Stat(logs); err != nil { // a run-dir link that doesn't resolve here
			_ = os.Remove(logs)
		}
	}
	_ = os.MkdirAll(logs, 0o755)
	return &Session{C: c, Logs: logs, Start: c.Us()}
}

// StepCtx is what a step function gets: where its output goes, its deadline, and helpers to run commands.
type StepCtx struct {
	C    *Ctx
	S    *Session
	Name string
	Out  io.Writer       // the step log (and our stdout when the step is live), redacted
	Ctx  context.Context // ends at the step's timeout
	Env  sys.Env         // the environment for commands of this step
}

// Cmd runs argv in dir (relative to the repo root; "" = root) with the step's environment and output.
func (sc *StepCtx) Cmd(dir string, argv ...string) int {
	return sc.CmdEnv(dir, nil, argv...)
}

// CmdEnv is Cmd with extra KEY, VALUE pairs in the environment.
func (sc *StepCtx) CmdEnv(dir string, kv []string, argv ...string) int {
	return sc.Do(sys.Cmd{Argv: argv, Dir: dir, Env: sc.Env.With(kv...), Stdout: sc.Out, Stderr: sc.Out})
}

// Do runs a prepared command; Dir is relative to the root unless absolute.
func (sc *StepCtx) Do(c sys.Cmd) int {
	switch {
	case c.Dir == "":
		c.Dir = sc.C.Root
	case !filepath.IsAbs(c.Dir):
		c.Dir = filepath.Join(sc.C.Root, c.Dir)
	}
	if c.Env == nil {
		c.Env = sc.Env
	}
	return sc.C.R.Run(sc.Ctx, c)
}

// Printf writes to the step's output.
func (sc *StepCtx) Printf(format string, a ...any) { fmt.Fprintf(sc.Out, format, a...) }

// LockedFile is a log file several goroutines write to.
type LockedFile struct {
	mu sync.Mutex
	f  *os.File
}

// NewLockedFile wraps f.
func NewLockedFile(f *os.File) *LockedFile { return &LockedFile{f: f} }

func (l *LockedFile) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.f.Write(p)
}

// StepTimeout is the step's time limit: BW_TIMEOUT_<STEP>, else BW_STEP_TIMEOUT, else the default. Seconds; 0 = none.
func StepTimeout(env sys.Env, name string, def time.Duration) time.Duration {
	key := "BW_TIMEOUT_" + strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r - 32
		case r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		}
		return '_'
	}, name)
	for _, k := range []string{key, "BW_STEP_TIMEOUT"} {
		if v := env.Get(k); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n >= 0 {
				return time.Duration(n) * time.Second
			}
		}
	}
	return def
}

// DefaultTimeout is the table of §2: lint and analyze 300 s, full suites and :one 900 s, desktop and perf 1200 s
// (BW_HEADLESS_TIMEOUT), linux and web 1200 s, apk 2400 s, image 3600 s; mutate, shell and the rest none.
func DefaultTimeout(env sys.Env, name string) time.Duration {
	sec := func(n int) time.Duration { return time.Duration(n) * time.Second }
	switch {
	case strings.HasPrefix(name, "analyze"):
		return sec(300)
	case strings.HasPrefix(name, "desktop-") && name != "desktop-smoke", name == "perf":
		if n, err := strconv.Atoi(env.Get("BW_HEADLESS_TIMEOUT")); err == nil && n > 0 {
			return sec(n)
		}
		return sec(1200)
	}
	switch name {
	case "format", "shellcheck", "actionlint", "hook-selftest", "env-selftest", "deploy-selftest", "native-units", "apk-signature":
		return sec(300)
	case "importer", "core", "sync", "relay", "app", "pub", "web-test", "relay-bin",
		"importer:one", "core:one", "sync:one", "relay:one", "app:one": // app:one took 321.6 s on 2026-10-22: same limit as a suite
		return sec(900)
	case "go-check", "outdated":
		return sec(600)
	case "linux", "web", "desktop-smoke":
		return sec(1200)
	case "apk":
		return sec(2400)
	case "image":
		return sec(3600)
	}
	return 0
}

// RunStep runs one step: output in <Logs>/<name>.log between start/end stamps, "<seconds> <exit> <started>" in <name>.status.
// live also shows the output on stdout. Returns the exit code (124 after a timeout).
func (s *Session) RunStep(name string, fn func(sc *StepCtx) int, live bool) int {
	return s.RunStepEnv(name, fn, live, nil)
}

// RunStepEnv is RunStep with extra KEY, VALUE pairs in the step's environment (a desktop worker's display and app copy).
func (s *Session) RunStepEnv(name string, fn func(sc *StepCtx) int, live bool, kv []string) int {
	c := s.C
	startUs, started := c.Us(), c.NowISO()
	f, err := os.OpenFile(filepath.Join(s.Logs, name+".log"), os.O_WRONLY|os.O_CREATE|os.O_TRUNC|os.O_APPEND, 0o644)
	if err != nil {
		c.Eprintf("cannot write the log of %s: %v\n", name, err)
		// a status all the same, or the step would be recorded as ok
		_ = os.WriteFile(filepath.Join(s.Logs, name+".status"), []byte(fmt.Sprintf("0.0 1 %s\n", started)), 0o644)
		return 1
	}
	lf := NewLockedFile(f)
	fmt.Fprintf(lf, "# %s: started %s\n", name, started)
	var dst io.Writer = lf
	if live {
		dst = io.MultiWriter(lf, &lockedWriter{c: c})
	}
	out := c.Red.Writer(dst)
	timeout := StepTimeout(c.Env, name, DefaultTimeout(c.Env, name))
	ctx, cancel := c.Ctx, context.CancelFunc(func() {})
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(c.Ctx, timeout)
	}
	sc := &StepCtx{C: c, S: s, Name: name, Out: out, Ctx: ctx, Env: c.Env.With(kv...)}
	rc := fn(sc)
	timedOut := ctx.Err() == context.DeadlineExceeded
	cancel()
	_ = out.Close()
	if timedOut {
		fmt.Fprintf(lf, "# %s: timed out after %d s\n", name, int(timeout/time.Second))
		rc = 124
	}
	secs := c.SecsSince(startUs)
	fmt.Fprintf(lf, "# %s: finished %s, %s s, exit %d\n", name, c.NowISO(), secs, rc)
	_ = f.Close()
	_ = os.WriteFile(filepath.Join(s.Logs, name+".status"), []byte(fmt.Sprintf("%s %d %s\n", secs, rc, started)), 0o644)
	return rc
}

// lockedWriter is our stdout as a writer (serialised with the other prints).
type lockedWriter struct{ c *Ctx }

func (w *lockedWriter) Write(p []byte) (int, error) {
	w.c.mu.Lock()
	defer w.c.mu.Unlock()
	return w.c.Out.Write(p)
}

// ReadStatus reads "<secs> <exit> <started>" of a step.
func (s *Session) ReadStatus(name string) (secs string, rc int, started string, ok bool) {
	b, err := os.ReadFile(filepath.Join(s.Logs, name+".status"))
	if err != nil {
		return "", 0, "", false
	}
	f := strings.Fields(string(b))
	if len(f) < 3 {
		return "", 0, "", false
	}
	n, err := strconv.Atoi(f[1])
	if err != nil {
		n = 1
	}
	return f[0], n, f[2], true
}

// Record adds a finished step to the results, the timing table and history.
func (s *Session) Record(name string, cold bool) {
	secs, rc, started, ok := s.ReadStatus(name)
	if !ok { // no readable status: the step did not finish properly
		secs, rc, started = "0.0", 1, s.C.NowISO()
	}
	result := "ok"
	s.mu.Lock()
	if rc != 0 {
		result = "FAILED"
		s.Failed = true
	}
	s.Results = append(s.Results, name+"="+result)
	s.Timings = append(s.Timings, Timing{name, secs, result})
	s.mu.Unlock()
	s.C.LogHistory(name, secs, result, strconv.FormatBool(cold), started)
}

// FailStep is a step that could not even start (bad argument, missing key): the message to stderr and the step's log, a
// failed status, and the usual record, so last-failed.txt names it.
func (s *Session) FailStep(name, msg string) {
	c := s.C
	c.Eprintf("%s\n", msg)
	now := c.NowISO()
	_ = os.WriteFile(filepath.Join(s.Logs, name+".log"),
		[]byte(fmt.Sprintf("# %s: started %s\n%s\n# %s: finished %s, 0.0 s, exit 1\n", name, now, c.Red.Clean(msg), name, c.NowISO())), 0o644)
	_ = os.WriteFile(filepath.Join(s.Logs, name+".status"), []byte(fmt.Sprintf("0.0 1 %s\n", c.NowISO())), 0o644)
	s.Record(name, false)
}

// Step runs one step with its output shown as it runs, then records it.
func (s *Session) Step(sp Spec) {
	s.C.Printf("=== %s ===\n", sp.Name)
	s.RunStep(sp.Name, sp.Fn, true)
	s.Record(sp.Name, sp.Cold)
}

// LogBody is the log without the first and the last line (sed '1d;$d').
func (s *Session) LogBody(name string) string {
	b, err := os.ReadFile(filepath.Join(s.Logs, name+".log"))
	if err != nil {
		return ""
	}
	return BodyOf(string(b))
}

// BodyOf drops the first and the last line of text.
func BodyOf(text string) string {
	lines := strings.SplitAfter(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) <= 2 {
		return ""
	}
	return strings.Join(lines[1:len(lines)-1], "")
}

// Steps runs the steps at the same time, then shows each log in order and records it.
func (s *Session) Steps(specs ...Spec) {
	done := make([]chan struct{}, len(specs))
	for i, sp := range specs {
		done[i] = make(chan struct{})
		go func() {
			defer close(done[i])
			s.RunStep(sp.Name, sp.Fn, false)
		}()
	}
	for i, sp := range specs {
		<-done[i]
		s.C.Printf("=== %s ===\n%s", sp.Name, s.LogBody(sp.Name))
		s.Record(sp.Name, sp.Cold)
	}
}

// Summary prints the end-of-run table: seconds per step, test headlines, total, the results line.
func (s *Session) Summary() {
	c := s.C
	c.Printf("\n%-16s %8s  %s\n", "step", "seconds", "result")
	for _, t := range s.Timings {
		c.Printf("%-16s %8s  %s\n", t.Name, t.Secs, t.Result)
	}
	c.Printf("%-16s %8s\n", "total", c.SecsSince(s.Start))
	for _, t := range s.Timings { // suites delete old summaries first, so these are from this run
		if b, err := os.ReadFile(filepath.Join(s.Logs, "tests-"+t.Name+"-summary.txt")); err == nil {
			first, _, _ := strings.Cut(string(b), "\n")
			c.Printf("%s\n", first)
		}
	}
	if b, err := os.ReadFile(filepath.Join(s.Logs, "perf-summary.txt")); err == nil {
		c.Printf("%s", b)
	}
	c.Printf("%s\n", strings.Join(s.Results, " "))
}

// Exit is the exit code of the run: 1 when a step failed.
func (s *Session) Exit() int {
	if s.Failed {
		return 1
	}
	return 0
}
