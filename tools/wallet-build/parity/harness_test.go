//go:build parity

package parity

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"
)

const heavyEnv = "BW_PARITY_HEAVY"

// implName is the implementation compared against bash. BW_PARITY_IMPL=bash makes it bash-vs-bash (harness proof).
func implName() string {
	if v := os.Getenv("BW_PARITY_IMPL"); v != "" {
		return v
	}
	return "go"
}

func goSide() bool { return implName() != "bash" }

func repoRoot(t testing.TB) string {
	t.Helper()
	if v := os.Getenv("BW_PARITY_REPO"); v != "" {
		return v
	}
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for d := dir; ; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "tools", "build.sh")); err == nil {
			return d
		}
		if d == filepath.Dir(d) {
			t.Fatalf("no tools/build.sh above %s (set BW_PARITY_REPO)", dir)
		}
	}
}

// Case is one parity case: the same tools/build.sh arguments run once with BW_IMPL=bash and once with the impl.
type Case struct {
	Name string
	Args []string
	Env  []string // extra KEY=VALUE for both runs
	// Setup prepares the repo before both runs (e.g. an unformatted file) and returns its cleanup.
	Setup func(t *testing.T, repo string) func()
	Heavy bool // skipped unless BW_PARITY_HEAVY=1
	// Quiet: stdout and stderr must be empty for both implementations.
	Quiet bool
	// CmpStderr also compares stderr (usage errors); stdout is always compared.
	CmpStderr bool
	// Unordered: steps may finish in any order (parallel suites): last.status and steps.jsonl compared as sets.
	Unordered bool
	// Artifacts are repo-relative paths removed before each run and listed (names only) after it.
	Artifacts []string
	// WantExit, when >= 0, is also asserted for both implementations (a contract check on top of parity).
	WantExit int
	// Check runs extra assertions on each side (run dir, stdout, ...).
	Check func(t *testing.T, s *side)
	// Loose: the variable under test changes behaviour on one side only (bash forwards BW_TIMEOUT_* but applies no
	// timeout), so only the run dir list, file names and step names are compared.
	Loose bool
	// Custom replaces the whole run-and-compare flow: it returns comparable lines per implementation.
	Custom func(t *testing.T, repo, impl string) []string
	// SkipIf returns a skip reason, or "".
	SkipIf func(t *testing.T, repo string) string
}

type side struct {
	impl           string
	args           []string
	exit           int
	stdout, stderr string
	data           string
	repo           string
	runs           []string // absolute run dirs, chronological
	artifacts      []string
	m              *masker
}

func (s *side) file(run int, name string) string {
	b, err := os.ReadFile(filepath.Join(s.runs[run], name))
	if err != nil {
		return ""
	}
	return string(b)
}

func runCase(t *testing.T, c Case) {
	t.Helper()
	if c.Heavy && os.Getenv(heavyEnv) != "1" {
		t.Skipf("heavy case (minutes of CPU/RAM on the shared laptop): set %s=1 to run it", heavyEnv)
	}
	repo := repoRoot(t)
	if c.SkipIf != nil {
		if why := c.SkipIf(t, repo); why != "" {
			t.Skip(why)
		}
	}
	if c.Custom != nil {
		a := c.Custom(t, repo, "bash")
		b := c.Custom(t, repo, implName())
		diffLines(t, c.Name, "result", a, b)
		return
	}
	if c.Setup != nil {
		defer c.Setup(t, repo)()
	}
	bash := execSide(t, repo, "bash", c)
	other := execSide(t, repo, implName(), c)
	for _, s := range []*side{bash, other} {
		if c.WantExit >= 0 && s.exit != c.WantExit {
			t.Errorf("[%s] %s: exit code %d, want %d\nstderr: %s", c.Name, s.impl, s.exit, c.WantExit, tail(s.stderr))
		}
		if c.Quiet && (len(s.stdout) != 0 || len(s.stderr) != 0) {
			t.Errorf("[%s] %s: quiet mode wrote %d bytes to stdout and %d to stderr, want 0 and 0", c.Name, s.impl, len(s.stdout), len(s.stderr))
		}
		if c.Check != nil {
			c.Check(t, s)
		}
	}
	compareSides(t, c, bash, other)
}

func tail(s string) string {
	if len(s) > 600 {
		return "..." + s[len(s)-600:]
	}
	return s
}

// buildEnv: the parent environment without BW_* (so a developer's settings cannot leak in), plus the case's.
func buildEnv(data, impl string, extra []string) []string {
	var env []string
	for _, e := range os.Environ() {
		if strings.HasPrefix(e, "BW_") {
			continue
		}
		env = append(env, e)
	}
	env = append(env, "BW_DATA_DIR="+data, "BW_IMPL="+impl)
	if v := os.Getenv("BW_SIGNING_DIR"); v != "" { // the same key for the build and for the secret grep
		env = append(env, "BW_SIGNING_DIR="+v)
	}
	return append(env, extra...)
}

func execSide(t *testing.T, repo, impl string, c Case) *side {
	t.Helper()
	for _, a := range c.Artifacts {
		if err := os.RemoveAll(filepath.Join(repo, a)); err != nil {
			t.Fatal(err)
		}
	}
	data := t.TempDir()
	s := &side{impl: impl, args: c.Args, data: data, repo: repo}
	timeout := 20 * time.Minute
	if c.Heavy {
		timeout = 90 * time.Minute
	}
	var out, errb bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(repo, "tools", "build.sh"), c.Args...)
	cmd.Dir = repo
	cmd.Env = buildEnv(data, impl, c.Env)
	cmd.Stdout, cmd.Stderr = &out, &errb
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 15 * time.Second
	err := cmd.Run()
	s.exit = exitCode(t, err)
	s.stdout, s.stderr = out.String(), errb.String()
	s.runs = listRuns(data)
	s.m = newMasker(t, repo, data, s.runs)
	for _, a := range c.Artifacts {
		s.artifacts = append(s.artifacts, listFiles(filepath.Join(repo, a), repo)...)
	}
	return s
}

func exitCode(t testing.TB, err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ee.ExitCode() == -1 { // killed by signal
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				return 128 + int(ws.Signal())
			}
		}
		return ee.ExitCode()
	}
	t.Fatalf("cannot run tools/build.sh: %v", err)
	return -1
}

func listRuns(data string) []string {
	ents, _ := os.ReadDir(filepath.Join(data, "runs"))
	var out []string
	for _, e := range ents {
		if e.IsDir() {
			out = append(out, filepath.Join(data, "runs", e.Name()))
		}
	}
	sort.Strings(out)
	return out
}

func listFiles(root, rel string) []string {
	var out []string
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		r, _ := filepath.Rel(rel, p)
		out = append(out, r)
		return nil
	})
	sort.Strings(out)
	return out
}

// ---- masking ----

type masker struct {
	lits [][2]string
}

var (
	reISO     = regexp.MustCompile(`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2}|Z)`)
	reTmp     = regexp.MustCompile(`/tmp/tmp\.[A-Za-z0-9]+`)
	reSecs    = regexp.MustCompile(`\b\d+(?:\.\d+)? s\b`)
	reMs      = regexp.MustCompile(`\b\d+ ms\b`)
	reTenths  = regexp.MustCompile(`(^|\s)\d+\.\d(\s|$)`)
	reSpaces  = regexp.MustCompile(`[ \t]+`)
	reRunName = regexp.MustCompile(`\b\d{8}-\d{6}-([A-Za-z0-9:_.-]+?)-(?:[0-9a-f]{7,40}|unknown)(?:-dirty)?(-\d+)?\b`)
)

func newMasker(t testing.TB, repo, data string, runs []string) *masker {
	m := &masker{}
	add := func(lit, tok string) {
		if lit != "" {
			m.lits = append(m.lits, [2]string{lit, tok})
		}
	}
	for _, r := range runs {
		add(filepath.Base(r), maskRunName(filepath.Base(r)))
	}
	for _, d := range []string{data, evalLinks(data)} {
		add(d, "<DATA>")
	}
	for _, d := range []string{repo, evalLinks(repo)} {
		add(d, "<ROOT>")
	}
	if out, err := exec.Command("git", "-C", repo, "rev-parse", "--short", "HEAD").Output(); err == nil {
		h := strings.TrimSpace(string(out))
		add(h+"-dirty", "<COMMIT>")
		add(h, "<COMMIT>")
	}
	sort.SliceStable(m.lits, func(i, j int) bool { return len(m.lits[i][0]) > len(m.lits[j][0]) })
	return m
}

func evalLinks(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

// maskRunName turns 20261101-111328-app-9098d74-dirty into <TS>-app-<COMMIT> (a -2 collision suffix is kept).
func maskRunName(n string) string {
	return reRunName.ReplaceAllString(n, "<TS>-$1-<COMMIT>$2")
}

// text masks timestamps, run ids, temp paths, seconds and the commit in one string.
func (m *masker) text(s string) string {
	for _, l := range m.lits {
		s = strings.ReplaceAll(s, l[0], l[1])
	}
	s = maskRunName(s)
	s = reISO.ReplaceAllString(s, "<TS>")
	s = reTmp.ReplaceAllString(s, "<TMP>")
	s = reSecs.ReplaceAllString(s, "<S> s")
	s = reMs.ReplaceAllString(s, "<N> ms")
	return s
}

// table masks a stdout step table: also bare "12.3" seconds columns, and collapses runs of blanks (column width follows
// the number's width).
func (m *masker) table(s string) []string {
	var out []string
	for _, ln := range strings.Split(strings.TrimRight(m.text(s), "\n"), "\n") {
		ln = reTenths.ReplaceAllString(ln, "${1}<S>${2}")
		ln = reTenths.ReplaceAllString(ln, "${1}<S>${2}")
		out = append(out, strings.TrimRight(reSpaces.ReplaceAllString(ln, " "), " "))
	}
	return out
}

func lines(s string) []string {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// ---- diffs ----

// diffLines reports the first differing line of two line lists. The message names the case, the file and the line.
func diffLines(t testing.TB, cas, file string, bash, other []string) bool {
	t.Helper()
	n := max(len(bash), len(other))
	for i := 0; i < n; i++ {
		var a, b string = "<missing>", "<missing>"
		if i < len(bash) {
			a = bash[i]
		}
		if i < len(other) {
			b = other[i]
		}
		if a != b {
			t.Errorf("parity[%s] %s: first difference at line %d (%d vs %d lines)\n  bash:  %q\n  %s: %q", cas, file, i+1, len(bash), len(other), a, implName(), b)
			return false
		}
	}
	return true
}

func sorted(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

func compareSides(t *testing.T, c Case, a, b *side) {
	t.Helper()
	cn := c.Name
	if a.exit != b.exit {
		t.Errorf("parity[%s] exit code: bash=%d %s=%d\n  %s stderr: %s", cn, a.exit, implName(), b.exit, implName(), tail(b.stderr))
	}
	diffLines(t, cn, "stdout (step table)", stepTable(a), stepTable(b))
	if c.CmpStderr {
		diffLines(t, cn, "stderr", a.m.table(a.stderr), b.m.table(b.stderr))
	}
	diffLines(t, cn, "artifact names", a.artifacts, b.artifacts)
	var an, bn []string
	for _, r := range a.runs {
		an = append(an, maskRunName(filepath.Base(r)))
	}
	for _, r := range b.runs {
		bn = append(bn, maskRunName(filepath.Base(r)))
	}
	if !diffLines(t, cn, "run dir list (runs/)", an, bn) {
		return
	}
	if c.Loose {
		for i := range a.runs {
			fa, fb := runFiles(a.runs[i]), runFiles(b.runs[i])
			diffLines(t, cn, "run dir file names", fa, fb)
			diffLines(t, cn, "last.status step names", sorted(stepNames(a, i)), sorted(stepNames(b, i)))
		}
		return
	}
	for i := range a.runs {
		compareRun(t, c, a, b, i)
	}
	compareHistory(t, c, a, b)
}

var reHeader = regexp.MustCompile(`(?m)^step +seconds +result$`)

// stepTable: the summary printed at the end of a run (header, one row per step, total, suite heads, results line).
// Live step output before it (pub resolution, dart format timings) is environment dependent and not compared; the
// `pub` row and `pub=ok` result are dropped for the same reason. Output without a table (usage, image-name) is
// compared whole.
func stepTable(s *side) []string {
	out := s.stdout
	if loc := reHeader.FindStringIndex(out); loc != nil {
		out = out[loc[0]:]
	}
	var res []string
	for _, ln := range s.m.table(out) {
		if strings.HasPrefix(ln, "pub ") {
			continue
		}
		ln = strings.ReplaceAll(ln, "pub=ok ", "")
		ln = strings.TrimPrefix(ln, "pub=ok")
		res = append(res, strings.TrimSpace(ln))
	}
	return res
}

func stepNames(s *side, run int) []string {
	var out []string
	for _, ln := range lines(s.file(run, "last.status")) {
		if f := strings.Fields(ln); len(f) > 0 && f[0] != "pub" {
			out = append(out, f[0])
		}
	}
	return out
}

// TestMain removes the unformatted file of a killed earlier run (a panic on -timeout or SIGKILL skips cleanups).
func TestMain(m *testing.M) {
	dir, _ := os.Getwd()
	for d := dir; ; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "tools", "build.sh")); err == nil {
			old, _ := filepath.Glob(filepath.Join(d, "app", "lib", "zz_*unformatted*.dart"))
			for _, f := range old {
				_ = os.Remove(f)
			}
			break
		}
		if d == filepath.Dir(d) {
			break
		}
	}
	os.Exit(m.Run())
}
