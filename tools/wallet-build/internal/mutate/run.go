package mutate

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"wallet-build/internal/pyrand"
	"wallet-build/internal/report"
	"wallet-build/internal/sys"
)

// PkgDir are the packages mutate.py knows.
var PkgDir = map[string]string{"importer": "packages/wallet_importer", "core": "packages/wallet_core", "sync": "packages/sync"}

// Downstream are the packages whose whole suite also runs for a mutant (without --tests): core's sync and blob tests moved
// to packages/sync in J4, so a core mutant only they catch (repo_blobs, backup, vault) would otherwise look like a survivor.
var Downstream = map[string][]string{"core": {"packages/sync"}}

// Usage is the help text (the docstring of mutate.py).
const Usage = `usage: mutate <importer|core|sync> <lib file>... [--max N] [--seed S] [--tests <test file>...] [--timeout SECS] [--list]

Mutation testing for the pure Dart packages. Normally started as
  tools/build.sh mutate <importer|core|sync> <lib file>... [options]      (make mutate ARGS="...")
which runs it in the build container.

Per target file it lists simple one-token mutants (+/-, * and ~/, < <=, > >=, == !=, && ||, integer literals, true/false,
a trivially typed ` + "`return x;`" + ` replaced by a default), skipping comments, strings, imports and assert lines. A seeded sample
of --max mutants (default 60 per file) is then run serially: the mutant is written into a copy of the packages under
dist/mutation/work/ (the tracked files are never touched), ` + "`dart test --fail-fast`" + ` runs (the whole package suite plus the
suites of packages built on it; or only --tests), and the file is restored. A mutant is killed (a test failed), survived
(all passed), timeout (counts as killed, e.g. an endless loop) or invalid (does not compile; not counted).
Result: dist/mutation/<package>-<file>.json and a table on stdout.

positional arguments:
  package            importer, core or sync
  files              lib files, relative to the repo root or the package

options:
  -h, --help         show this help message and exit
  --max MAX          mutants per file (sampled with --seed) (default 60)
  --seed SEED        (default 1)
  --tests [TESTS ...]  test files/dirs relative to the package (default: the whole suite and the downstream suites)
  --timeout TIMEOUT  seconds per mutant (default: 3x the baseline run, at least 30)
  --list             only list how many mutants each file has
`

// Opts are the parsed arguments.
type Opts struct {
	Package string
	Files   []string
	Max     int
	Seed    int64
	Tests   []string
	Timeout float64
	List    bool
}

var longOpts = []string{"--max", "--seed", "--tests", "--timeout", "--list", "--help"}

// ParseArgs is the argparse of mutate.py. help is true for -h/--help; an error is an argparse usage error (exit 2).
func ParseArgs(args []string) (o Opts, help bool, err error) {
	o = Opts{Max: 60, Seed: 1}
	var chunks [][]string // runs of positionals between options
	var cur []string
	flush := func() {
		if len(cur) > 0 {
			chunks = append(chunks, cur)
			cur = nil
		}
	}
	isOpt := func(a string) bool {
		if !strings.HasPrefix(a, "-") || a == "-" {
			return false
		}
		if _, e := strconv.ParseFloat(a, 64); e == nil { // negative numbers are values, as argparse does without numeric-looking options
			return false
		}
		return true
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			cur = append(cur, args[i+1:]...)
			break
		}
		if !isOpt(a) {
			cur = append(cur, a)
			continue
		}
		flush()
		name, val, hasVal := strings.Cut(a, "=")
		if !strings.HasPrefix(name, "--") {
			if name == "-h" {
				return o, true, nil
			}
			return o, false, fmt.Errorf("unrecognized arguments: %s", a)
		}
		var matches []string
		for _, l := range longOpts {
			if l == name {
				matches = []string{l}
				break
			}
			if strings.HasPrefix(l, name) {
				matches = append(matches, l)
			}
		}
		if len(matches) == 0 {
			return o, false, fmt.Errorf("unrecognized arguments: %s", a)
		}
		if len(matches) > 1 {
			return o, false, fmt.Errorf("ambiguous option: %s could match %s", name, strings.Join(matches, ", "))
		}
		name = matches[0]
		next := func() (string, error) {
			if hasVal {
				return val, nil
			}
			if i+1 >= len(args) || isOpt(args[i+1]) {
				return "", fmt.Errorf("argument %s: expected one argument", name)
			}
			i++
			return args[i], nil
		}
		switch name {
		case "--help":
			return o, true, nil
		case "--list":
			if hasVal {
				return o, false, fmt.Errorf("argument --list: ignored explicit argument %q", val)
			}
			o.List = true
		case "--max", "--seed":
			s, e := next()
			if e != nil {
				return o, false, e
			}
			n, e := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
			if e != nil {
				return o, false, fmt.Errorf("argument %s: invalid int value: %s", name, pyRepr(s))
			}
			if name == "--max" {
				o.Max = int(n)
			} else {
				o.Seed = n
			}
		case "--timeout":
			s, e := next()
			if e != nil {
				return o, false, e
			}
			f, e := strconv.ParseFloat(strings.TrimSpace(s), 64)
			if e != nil {
				return o, false, fmt.Errorf("argument --timeout: invalid float value: %s", pyRepr(s))
			}
			o.Timeout = f
		case "--tests": // nargs="*": every following non-option argument; a second --tests replaces the first
			o.Tests = nil
			if hasVal {
				o.Tests = append(o.Tests, val)
			}
			for i+1 < len(args) && !isOpt(args[i+1]) && args[i+1] != "--" {
				i++
				o.Tests = append(o.Tests, args[i])
			}
		}
	}
	flush()
	if len(chunks) == 0 {
		return o, false, fmt.Errorf("the following arguments are required: package, files")
	}
	first := chunks[0]
	if _, ok := PkgDir[first[0]]; !ok {
		return o, false, fmt.Errorf("argument package: invalid choice: %s (choose from 'core', 'importer', 'sync')", pyRepr(first[0]))
	}
	o.Package = first[0]
	rest := chunks[1:]
	if len(first) > 1 {
		o.Files = first[1:]
	} else if len(rest) > 0 {
		o.Files, rest = rest[0], rest[1:]
	} else {
		return o, false, fmt.Errorf("the following arguments are required: files")
	}
	if len(rest) > 0 {
		var extra []string
		for _, c := range rest {
			extra = append(extra, c...)
		}
		return o, false, fmt.Errorf("unrecognized arguments: %s", strings.Join(extra, " "))
	}
	return o, false, nil
}

func pyRepr(s string) string {
	q := "'"
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		q = `"`
	}
	return q + strings.ReplaceAll(s, q, `\`+q) + q
}

// Env is what Run needs from the outside.
type Env struct {
	Root string
	R    sys.Runner
	Env  sys.Env
	Out  io.Writer // stdout lines
	Err  io.Writer // the message of a fatal error
	Now  func() time.Time
}

type plan struct {
	file   string
	src    []rune
	total  int
	sample []Mutant
}

var reInvalid = regexp.MustCompile(`\.dart:\d+:\d+: Error:|Compilation failed`)

// sampleOf is the shuffle and cut of mutate.py: random.Random(seed).shuffle(ms), the first max, sorted by (line, col).
func sampleOf(ms []Mutant, max int, seed int64) []Mutant {
	s := append([]Mutant(nil), ms...)
	pyrand.New(seed).Shuffle(len(s), func(i, j int) { s[i], s[j] = s[j], s[i] })
	end := max
	if max < 0 { // Python slicing: ms[:-n]
		end = len(s) + max
	}
	if end < 0 {
		end = 0
	}
	if end > len(s) {
		end = len(s)
	}
	s = s[:end]
	sort.SliceStable(s, func(a, b int) bool {
		if s[a].Line != s[b].Line {
			return s[a].Line < s[b].Line
		}
		return s[a].Col < s[b].Col
	})
	return s
}

// ResolveTargets maps the lib arguments to paths relative to the package (exit 1 message when one is not a lib file).
func ResolveTargets(root, pkg string, files []string) ([]string, error) {
	pkgDir := filepath.Join(root, PkgDir[pkg])
	realPkg, err := filepath.EvalSymlinks(pkgDir)
	if err != nil {
		realPkg = filepath.Clean(pkgDir)
	}
	var out []string
	for _, f := range files {
		if strings.HasPrefix(f, root+"/") {
			f = f[len(root)+1:]
		}
		if strings.HasPrefix(f, PkgDir[pkg]+"/") {
			f = f[len(PkgDir[pkg])+1:]
		}
		joined := f
		if !filepath.IsAbs(f) {
			joined = filepath.Join(pkgDir, f)
		}
		full, err := filepath.EvalSymlinks(joined)
		if err != nil {
			full = filepath.Clean(joined)
		}
		st, serr := os.Stat(full)
		if !strings.HasPrefix(full, filepath.Join(realPkg, "lib")+string(filepath.Separator)) || !strings.HasSuffix(full, ".dart") || serr != nil || !st.Mode().IsRegular() {
			return nil, fmt.Errorf("not a .dart file under %s/lib: %s", PkgDir[pkg], f)
		}
		rel, _ := filepath.Rel(realPkg, full)
		out = append(out, rel)
	}
	return out, nil
}

// Run is mutate.py's main. ctx ends on SIGINT/SIGTERM (or the step timeout): the running test is killed, the file restored and
// the results so far written. The return value is the exit code (1 for what mutate.py reported with sys.exit(message)).
func Run(ctx context.Context, e Env, o Opts) int {
	if e.Now == nil {
		e.Now = time.Now
	}
	fatal := func(format string, a ...any) int {
		fmt.Fprintf(e.Err, format+"\n", a...)
		return 1
	}
	pkgDir := filepath.Join(e.Root, PkgDir[o.Package])
	targets, err := ResolveTargets(e.Root, o.Package, o.Files)
	if err != nil {
		return fatal("%v", err)
	}
	var plans []plan
	for _, f := range targets {
		src, ms, err := MutantsOf(filepath.Join(pkgDir, f))
		if err != nil {
			return fatal("%v", err)
		}
		sample := sampleOf(ms, o.Max, o.Seed)
		fmt.Fprintf(e.Out, "%s: %d mutants, %d sampled\n", f, len(ms), len(sample))
		plans = append(plans, plan{f, src, len(ms), sample})
	}
	if o.List {
		return 0
	}

	outDir := filepath.Join(e.Root, "dist", "mutation")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return fatal("%v", err)
	}
	if ents, err := os.ReadDir(outDir); err == nil {
		for _, en := range ents {
			if strings.HasPrefix(en.Name(), ".orig-") {
				return fatal("stale %s from an older mutate.py that edited lib in place: restore the file by hand (checkout of "+
					"packages/*/lib), then delete dist/mutation/.orig-*", en.Name())
			}
		}
	}

	// The tracked files are never touched: mutants are written into a copy of the packages (same layout, so the relative
	// path dependencies and .dart_tool/package_config.json keep working) and the tests run there.
	work := filepath.Join(outDir, "work")
	_ = os.RemoveAll(work)
	for _, rel := range []string{"packages/wallet_importer", "packages/wallet_core", "packages/sync", "relay"} {
		if st, err := os.Stat(filepath.Join(e.Root, rel)); err == nil && st.IsDir() {
			if err := copyTree(filepath.Join(e.Root, rel), filepath.Join(work, rel)); err != nil {
				return fatal("copying %s: %v", rel, err)
			}
		}
	}
	if b, err := os.ReadFile(filepath.Join(e.Root, "analysis_options.yaml")); err == nil {
		if err := os.WriteFile(filepath.Join(work, "analysis_options.yaml"), b, 0o644); err != nil {
			return fatal("%v", err)
		}
	}
	wpkg := filepath.Join(work, PkgDir[o.Package])
	stopped := func() bool { return ctx.Err() != nil }

	suites := []string{wpkg}
	if len(o.Tests) == 0 {
		for _, d := range Downstream[o.Package] {
			suites = append(suites, filepath.Join(work, d))
		}
	}

	runTests := func(dir string, tests []string, timeout time.Duration) (string, time.Duration, string) {
		argv := append([]string{"dart", "test", "--fail-fast", "--timeout", "30s", "-r", "compact"}, tests...)
		var buf bytes.Buffer
		t0 := e.Now()
		rctx, cancel := context.WithTimeout(ctx, timeout)
		rc := e.R.Run(rctx, sys.Cmd{Argv: argv, Dir: dir, Env: e.Env, Stdout: &buf, Stderr: &buf})
		timedOut := rctx.Err() == context.DeadlineExceeded && ctx.Err() == nil
		cancel()
		dt := e.Now().Sub(t0)
		switch {
		case timedOut:
			return "timeout", dt, ""
		case reInvalid.MatchString(buf.String()): // does not compile: checked before test failures
			return "invalid", dt, buf.String()
		case rc == 0:
			return "survived", dt, buf.String()
		}
		return "killed", dt, buf.String()
	}
	runAll := func(timeout time.Duration) (string, time.Duration, string) { // the first suite that does not pass decides; seconds add up
		var total time.Duration
		out := ""
		for _, d := range suites {
			var tests []string
			if d == wpkg {
				tests = o.Tests
			}
			st, dt, o2 := runTests(d, tests, timeout)
			total += dt
			out = o2
			if st != "survived" || stopped() {
				return st, total, out
			}
		}
		return "survived", total, out
	}

	var rels []string
	for _, d := range suites {
		r, _ := filepath.Rel(work, d)
		rels = append(rels, r)
	}
	fmt.Fprintf(e.Out, "baseline run (%s) ...\n", strings.Join(rels, ", "))
	st, base, out := runAll(1800 * time.Second)
	if st != "survived" {
		tail := []rune(out)
		if len(tail) > 3000 {
			tail = tail[len(tail)-3000:]
		}
		fmt.Fprintln(e.Out, string(tail))
		return fatal("baseline tests do not pass (%s); nothing to mutate", st)
	}
	timeout := o.Timeout
	if timeout == 0 {
		timeout = math.Max(30.0, 3*base.Seconds())
	}
	fmt.Fprintf(e.Out, "baseline %.1fs, per-mutant timeout %.0fs\n", base.Seconds(), timeout)
	perMutant := time.Duration(timeout * float64(time.Second))

	put := func(path string, text []rune) error { // whole file via a temp file and rename: never a half-written source
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, []byte(string(text)), 0o644); err != nil {
			return err
		}
		return os.Rename(tmp, path)
	}

	type total struct {
		file   string
		n      int
		counts map[string]int
	}
	var totals []total
	for _, p := range plans {
		if stopped() {
			break
		}
		path := filepath.Join(wpkg, p.file)
		var rows []any
		var statuses []string
		for i, m := range p.sample {
			if stopped() {
				break
			}
			mutated := append(append(append([]rune{}, p.src[:m.Start]...), []rune(m.Text)...), p.src[m.End:]...)
			if err := put(path, mutated); err != nil {
				return fatal("%v", err)
			}
			st, dt, _ := runAll(perMutant)
			if stopped() {
				break
			}
			rows = append(rows, report.Obj{{K: "line", V: m.Line}, {K: "col", V: m.Col}, {K: "op", V: m.Op}, {K: "orig", V: m.Orig},
				{K: "mutant", V: m.Mutant}, {K: "status", V: st}, {K: "seconds", V: round1(dt.Seconds())}})
			statuses = append(statuses, st)
			fmt.Fprintf(e.Out, "[%d/%d] %s:%d %-10s %s -> %s\n", i+1, len(p.sample), p.file, m.Line, st, m.Orig, m.Mutant)
		}
		if err := put(path, p.src); err != nil {
			return fatal("%v", err)
		}
		counts := map[string]int{}
		for _, s := range statuses {
			counts[s]++
		}
		name := fmt.Sprintf("%s-%s.json", o.Package, strings.ReplaceAll(p.file, "/", "_"))
		if rows == nil {
			rows = []any{}
		}
		testsList := o.Tests
		if testsList == nil {
			testsList = []string{}
		}
		doc := report.Obj{{K: "package", V: o.Package}, {K: "file", V: p.file}, {K: "seed", V: o.Seed}, {K: "tests", V: testsList},
			{K: "mutants_total", V: p.total}, {K: "sampled", V: len(p.sample)}, {K: "killed", V: counts["killed"]}, {K: "survived", V: counts["survived"]},
			{K: "timeout", V: counts["timeout"]}, {K: "invalid", V: counts["invalid"]}, {K: "mutants", V: rows}}
		if err := os.WriteFile(filepath.Join(outDir, name), []byte(report.Dumper{Indent: 1, ASCII: true}.Dump(doc)), 0o644); err != nil {
			return fatal("%v", err)
		}
		totals = append(totals, total{p.file, len(p.sample), counts})
		fmt.Fprintf(e.Out, "\n%s survivors:\n", p.file)
		for k, r := range rows {
			if statuses[k] == "survived" {
				m := r.(report.Obj)
				get := func(key string) any { v, _ := m.Get(key); return v }
				fmt.Fprintf(e.Out, "  %s:%d  %s  %s -> %s  [%s]\n", p.file, get("line"), get("op"), get("orig"), get("mutant"), statuses[k])
			}
		}
	}
	fmt.Fprint(e.Out, "\nfile                     sampled killed survived timeout invalid\n")
	for _, t := range totals {
		fmt.Fprintf(e.Out, "%-24s %7d %6d %8d %7d %7d\n", t.file, t.n, t.counts["killed"], t.counts["survived"], t.counts["timeout"], t.counts["invalid"])
	}
	return 0
}

// round1 is Python's round(x, 1): the correctly rounded decimal of the binary value, as a float.
func round1(x float64) float64 {
	f, _ := strconv.ParseFloat(strconv.FormatFloat(x, 'f', 1, 64), 64)
	return f
}

// copyTree is shutil.copytree(src, dst, symlinks=True, ignore=ignore_patterns("build", "ephemeral", ".symlinks")): symlinks
// stay symlinks, modes and modification times are kept.
func copyTree(src, dst string) error {
	skip := map[string]bool{"build": true, "ephemeral": true, ".symlinks": true}
	type dirTimes struct {
		path string
		mode fs.FileMode
		mod  time.Time
	}
	var dirs []dirTimes
	err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if rel != "." && skip[d.Name()] {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		case d.IsDir():
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			dirs = append(dirs, dirTimes{target, info.Mode().Perm(), info.ModTime()})
			return nil
		case info.Mode().IsRegular():
			in, err := os.Open(p)
			if err != nil {
				return err
			}
			defer in.Close()
			out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode().Perm())
			if err != nil {
				return err
			}
			if _, err := io.Copy(out, in); err != nil {
				out.Close()
				return err
			}
			if err := out.Close(); err != nil {
				return err
			}
			return os.Chtimes(target, info.ModTime(), info.ModTime())
		}
		return nil
	})
	for i := len(dirs) - 1; i >= 0; i-- { // directory modes and times last, children first
		_ = os.Chmod(dirs[i].path, dirs[i].mode)
		_ = os.Chtimes(dirs[i].path, dirs[i].mod, dirs[i].mod)
	}
	return err
}
