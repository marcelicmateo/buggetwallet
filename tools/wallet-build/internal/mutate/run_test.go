package mutate

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"wallet-build/internal/sys"
)

const libSrc = "int f(int a, int b) {\n  return a + b;\n}\n"

func mkRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	w := func(rel, text string) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	w("packages/wallet_importer/pubspec.yaml", "name: x\n")
	w("packages/wallet_importer/lib/a.dart", libSrc)
	w("packages/wallet_importer/build/skipped.txt", "x")
	w("packages/wallet_importer/.dart_tool/package_config.json", "{}")
	w("packages/wallet_core/lib/b.dart", "int g() {\n  return 1;\n}\n")
	w("packages/sync/lib/s.dart", "")
	w("analysis_options.yaml", "linter:\n")
	if err := os.Symlink("../pubspec.yaml", filepath.Join(root, "packages/wallet_importer/lib/link.yaml")); err != nil {
		t.Fatal(err)
	}
	return root
}

func run(t *testing.T, root string, h func(sys.Cmd) int, args ...string) (int, string, string, *sys.Fake) {
	t.Helper()
	return runCtx(t, context.Background(), root, h, nil, args...)
}

func runCtx(t *testing.T, ctx context.Context, root string, h func(sys.Cmd) int, hc func(context.Context, sys.Cmd) int, args ...string) (int, string, string, *sys.Fake) {
	t.Helper()
	o, _, err := ParseArgs(args)
	if err != nil {
		t.Fatal(err)
	}
	f := &sys.Fake{Handle: h, HandleCtx: hc}
	var out, errb bytes.Buffer
	rc := Run(ctx, Env{Root: root, R: f, Env: sys.Env{}, Out: &out, Err: &errb}, o)
	return rc, out.String(), errb.String(), f
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// the tests run in the work copy: a mutant that subtracts is killed, the typed default survives
func decide(c sys.Cmd) int {
	b, err := os.ReadFile(filepath.Join(c.Dir, "lib", "a.dart"))
	if err == nil && strings.Contains(string(b), "a - b") {
		return 1
	}
	return 0
}

func TestRunEndToEnd(t *testing.T) {
	root := mkRoot(t)
	rc, out, errs, f := run(t, root, decide, "importer", "lib/a.dart", "--seed", "3")
	if rc != 0 || errs != "" {
		t.Fatalf("rc %d err %q\n%s", rc, errs, out)
	}
	lines := strings.Split(out, "\n")
	for i, want := range []string{"lib/a.dart: 2 mutants, 2 sampled", "baseline run (packages/wallet_importer) ..."} {
		if lines[i] != want {
			t.Errorf("line %d = %q, want %q", i, lines[i], want)
		}
	}
	if !strings.HasPrefix(lines[2], "baseline ") || !strings.Contains(lines[2], "s, per-mutant timeout 30s") {
		t.Errorf("baseline line %q", lines[2])
	}
	for _, want := range []string{
		"[1/2] lib/a.dart:2 survived   a + b -> 0\n",
		"[2/2] lib/a.dart:2 killed     + -> -\n",
		"\nlib/a.dart survivors:\n  lib/a.dart:2  return -> default 0  a + b -> 0  [survived]\n",
		"\nfile                     sampled killed survived timeout invalid\nlib/a.dart                     2      1        1       0       0\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	// the argv of a run: dart test in the work copy, the baseline plus one per mutant
	if len(f.Calls) != 3 {
		t.Fatalf("%d test runs, want 3", len(f.Calls))
	}
	if got := strings.Join(f.Calls[0].Argv, " "); got != "dart test --fail-fast --timeout 30s -r compact" {
		t.Errorf("argv %q", got)
	}
	if want := filepath.Join(root, "dist/mutation/work/packages/wallet_importer"); f.Calls[0].Dir != want {
		t.Errorf("dir %q, want %q", f.Calls[0].Dir, want)
	}
	// tracked files are untouched; the work copy has the pieces and skips build
	if read(t, filepath.Join(root, "packages/wallet_importer/lib/a.dart")) != libSrc {
		t.Error("the tracked file changed")
	}
	work := filepath.Join(root, "dist/mutation/work")
	if read(t, filepath.Join(work, "packages/wallet_importer/lib/a.dart")) != libSrc {
		t.Error("the work copy is not restored")
	}
	if _, err := os.Stat(filepath.Join(work, "packages/wallet_importer/build")); err == nil {
		t.Error("build/ was copied")
	}
	if l, err := os.Readlink(filepath.Join(work, "packages/wallet_importer/lib/link.yaml")); err != nil || l != "../pubspec.yaml" {
		t.Errorf("symlink not kept: %q %v", l, err)
	}
	for _, p := range []string{"packages/wallet_importer/.dart_tool/package_config.json", "packages/wallet_core/lib/b.dart", "analysis_options.yaml"} {
		if _, err := os.Stat(filepath.Join(work, p)); err != nil {
			t.Errorf("%s not in the work copy", p)
		}
	}
	want := `{
 "package": "importer",
 "file": "lib/a.dart",
 "seed": 3,
 "tests": [],
 "mutants_total": 2,
 "sampled": 2,
 "killed": 1,
 "survived": 1,
 "timeout": 0,
 "invalid": 0,
 "mutants": [
  {
   "line": 2,
   "col": 10,
   "op": "return -> default 0",
   "orig": "a + b",
   "mutant": "0",
   "status": "survived",
   "seconds": 0.0
  },
  {
   "line": 2,
   "col": 11,
   "op": "+ -> -",
   "orig": "+",
   "mutant": "-",
   "status": "killed",
   "seconds": 0.0
  }
 ]
}`
	if got := read(t, filepath.Join(root, "dist/mutation/importer-lib_a.dart.json")); got != want {
		t.Errorf("json differs:\n%s\nwant\n%s", got, want)
	}
}

func TestOnlyTestsAndDownstream(t *testing.T) {
	root := mkRoot(t)
	// core runs the sync suite too unless --tests names files
	_, out, _, f := run(t, root, func(sys.Cmd) int { return 0 }, "core", "lib/b.dart", "--max", "1")
	if !strings.Contains(out, "baseline run (packages/wallet_core, packages/sync) ...") {
		t.Errorf("no downstream suite:\n%s", out)
	}
	dirs := map[string]bool{}
	for _, c := range f.Calls {
		dirs[filepath.Base(c.Dir)] = true
	}
	if !dirs["sync"] || !dirs["wallet_core"] {
		t.Errorf("runs in %v", dirs)
	}
	_, out, _, f = run(t, root, func(sys.Cmd) int { return 0 }, "core", "lib/b.dart", "--max", "1", "--tests", "test/x_test.dart", "test/y_test.dart")
	if !strings.Contains(out, "baseline run (packages/wallet_core) ...") {
		t.Errorf("--tests must drop the downstream suite:\n%s", out)
	}
	if got := strings.Join(f.Calls[0].Argv, " "); !strings.HasSuffix(got, "-r compact test/x_test.dart test/y_test.dart") {
		t.Errorf("argv %q", got)
	}
	b, _ := os.ReadFile(filepath.Join(root, "dist/mutation/core-lib_b.dart.json"))
	if !strings.Contains(string(b), "\"tests\": [\n  \"test/x_test.dart\",\n  \"test/y_test.dart\"\n ],") {
		t.Errorf("tests not recorded:\n%s", b)
	}
}

func TestStatuses(t *testing.T) {
	root := mkRoot(t)
	n := 0
	rc, out, _, _ := run(t, root, func(c sys.Cmd) int {
		n++
		return 0
	}, "importer", "lib/a.dart")
	if rc != 0 || !strings.Contains(out, "survived") {
		t.Fatal(out)
	}
	// compile errors are invalid whatever the exit code, checked before the exit code
	calls := 0
	_, out, _, _ = run(t, root, func(c sys.Cmd) int {
		calls++
		if calls == 1 {
			return 0
		}
		c.Stdout.Write([]byte("lib/a.dart:2:3: Error: nope\n"))
		return 1
	}, "importer", "lib/a.dart")
	if !strings.Contains(out, "invalid") || !strings.Contains(out, "      0       0       2") {
		t.Errorf("invalid not counted:\n%s", out)
	}
	// a hung test is a timeout (counts as killed in spirit, listed apart)
	calls = 0
	_, out, _, _ = runCtx(t, context.Background(), root, nil, func(ctx context.Context, c sys.Cmd) int {
		calls++
		if calls == 1 {
			return 0
		}
		<-ctx.Done()
		return 143
	}, "importer", "lib/a.dart", "--timeout", "0.05")
	if !strings.Contains(out, "timeout") || !strings.Contains(out, "per-mutant timeout 0s") || !strings.Contains(out, "      0        0       2       0") {
		t.Errorf("timeouts not counted:\n%s", out)
	}
}

func TestBaselineMustPass(t *testing.T) {
	root := mkRoot(t)
	rc, out, errs, f := run(t, root, func(c sys.Cmd) int {
		c.Stdout.Write([]byte("00:01 +0 -1: Some tests failed.\n"))
		return 1
	}, "importer", "lib/a.dart")
	if rc != 1 || !strings.Contains(errs, "baseline tests do not pass (killed); nothing to mutate") || !strings.Contains(out, "Some tests failed.") || len(f.Calls) != 1 {
		t.Errorf("rc %d err %q out %q calls %d", rc, errs, out, len(f.Calls))
	}
	if _, err := os.Stat(filepath.Join(root, "dist/mutation/importer-lib_a.dart.json")); err == nil {
		t.Error("a result file for a failed baseline")
	}
}

func TestErrors(t *testing.T) {
	root := mkRoot(t)
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"importer", "lib/missing.dart"}, "not a .dart file under packages/wallet_importer/lib: lib/missing.dart"},
		{[]string{"importer", "pubspec.yaml"}, "not a .dart file under packages/wallet_importer/lib: pubspec.yaml"},
		{[]string{"importer", "lib/../../wallet_core/lib/b.dart"}, "not a .dart file under packages/wallet_importer/lib"},
		{[]string{"importer", "lib/link.yaml"}, "not a .dart file"},
	} {
		rc, _, errs, f := run(t, root, nil, tc.args...)
		if rc != 1 || !strings.Contains(errs, tc.want) || len(f.Calls) != 0 {
			t.Errorf("%v: rc %d err %q", tc.args, rc, errs)
		}
	}
	// repo-root and package-relative spellings are the same file
	for _, a := range []string{"packages/wallet_importer/lib/a.dart", "lib/a.dart", root + "/packages/wallet_importer/lib/a.dart"} {
		rc, out, _, _ := run(t, root, nil, "importer", a, "--list")
		if rc != 0 || out != "lib/a.dart: 2 mutants, 2 sampled\n" {
			t.Errorf("%s: rc %d out %q", a, rc, out)
		}
	}
	// a leftover of the old in-place mutate.py
	if err := os.MkdirAll(filepath.Join(root, "dist/mutation"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "dist/mutation/.orig-x"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	rc, _, errs, f := run(t, root, nil, "importer", "lib/a.dart")
	if rc != 1 || !strings.Contains(errs, "stale .orig-x from an older mutate.py") || len(f.Calls) != 0 {
		t.Errorf("stale guard: rc %d err %q", rc, errs)
	}
}

// SIGINT/SIGTERM: the running test is killed, the file restored, the results so far written, the table printed.
func TestCancelWritesPartialResults(t *testing.T) {
	root := mkRoot(t)
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	rc, out, _, _ := runCtx(t, ctx, root, nil, func(c context.Context, cmd sys.Cmd) int {
		calls++
		switch calls {
		case 1:
			return 0
		case 2:
			return 1
		}
		cancel() // the signal arrives while the second mutant runs
		<-c.Done()
		return 143
	}, "importer", "lib/a.dart")
	_ = rc
	if rc != 0 {
		t.Errorf("rc %d", rc)
	}
	if !strings.Contains(out, "[1/2]") || strings.Contains(out, "[2/2]") {
		t.Errorf("only the first mutant is reported:\n%s", out)
	}
	if !strings.Contains(out, "lib/a.dart                     2      1        0       0       0") {
		t.Errorf("table:\n%s", out)
	}
	if got := read(t, filepath.Join(root, "dist/mutation/work/packages/wallet_importer/lib/a.dart")); got != libSrc {
		t.Errorf("file not restored: %q", got)
	}
	if b := read(t, filepath.Join(root, "dist/mutation/importer-lib_a.dart.json")); !strings.Contains(b, `"killed": 1`) || !strings.Contains(b, `"sampled": 2`) {
		t.Errorf("partial json:\n%s", b)
	}
}

func TestParseArgs(t *testing.T) {
	o, help, err := ParseArgs([]string{"core", "lib/a.dart", "lib/b.dart", "--max=5", "--seed", "-3", "--tests", "t1", "t2", "--timeout", "1.5", "--list"})
	if err != nil || help {
		t.Fatal(err)
	}
	if o.Package != "core" || len(o.Files) != 2 || o.Max != 5 || o.Seed != -3 || len(o.Tests) != 2 || o.Timeout != 1.5 || !o.List {
		t.Errorf("%+v", o)
	}
	o, _, err = ParseArgs([]string{"sync", "--ma", "7", "lib/a.dart"}) // abbreviations, positionals on both sides of an option
	if err != nil || o.Max != 7 || o.Files[0] != "lib/a.dart" {
		t.Errorf("%+v %v", o, err)
	}
	for _, bad := range [][]string{
		nil, {"core"}, {"bogus", "x"}, {"core", "a", "--max", "x"}, {"core", "a", "--max"}, {"core", "a", "--nope"}, {"core", "a", "--t", "x"},
		{"core", "a", "--timeout", "z"}, {"core", "a.dart", "--max", "3", "b.dart"}, {"core", "a", "-x"}, {"core", "a", "--list=1"},
	} {
		if _, _, err := ParseArgs(bad); err == nil {
			t.Errorf("%v: no error", bad)
		}
	}
	if _, help, err := ParseArgs([]string{"-h"}); !help || err != nil {
		t.Error("-h")
	}
	if _, help, err := ParseArgs([]string{"core", "a", "--help"}); !help || err != nil {
		t.Error("--help")
	}
}
