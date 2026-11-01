package report

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/sys"
)

// The goldens in testdata/golden come from running tools/build_log.py and tools/stage_summary.py on the synthetic inputs in
// testdata (gen_golden.py); the Go port must produce the same text and history lines (only "ts" differs).

var tsRe = regexp.MustCompile(`"ts": "[^"]*"`)

func mask(s string) string { return tsRe.ReplaceAllString(s, `"ts": "T"`) }

func readFile(t *testing.T, parts ...string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(parts...))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

type fixture struct {
	cfg  Config
	data string
	logs string
	out  *strings.Builder
}

func newFixture(t *testing.T, seed bool, extra ...string) *fixture {
	t.Helper()
	time.Local = time.UTC
	d := t.TempDir()
	if err := os.MkdirAll(filepath.Join(d, "history"), 0o755); err != nil {
		t.Fatal(err)
	}
	logs := filepath.Join(d, "run")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		t.Fatal(err)
	}
	if seed {
		for _, n := range []string{"steps", "tests"} {
			if err := os.WriteFile(filepath.Join(d, "history", n+".jsonl"), []byte(readFile(t, "testdata", "hist-"+n+".jsonl")), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	env := sys.Env{"BW_SOURCE=local", "BW_WORKTREE=wt", "BW_COMMIT=abc1234", "BW_CMD=app", "BW_IMAGE=img:1", "BW_RUN_ID=20261101-100000-app-abc1234"}
	env = append(env, extra...)
	out := &strings.Builder{}
	now := func() time.Time { return time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC) }
	return &fixture{cfg: Config{Root: "/x/wt", Data: d, Logs: logs, Env: env, Now: now, Out: out}, data: d, logs: logs, out: out}
}

func (f *fixture) golden(t *testing.T, name, got string) {
	t.Helper()
	want := mask(readFile(t, "testdata", "golden", name))
	got = strings.ReplaceAll(mask(got), f.data, "DATA")
	if got != want {
		t.Errorf("%s differs from the build_log.py output\n--- got\n%s\n--- want\n%s", name, got, want)
	}
}

func (f *fixture) optional(rel string) string {
	b, err := os.ReadFile(filepath.Join(f.data, rel))
	if err != nil {
		return ""
	}
	return string(b)
}

func td(name string) string {
	p, _ := filepath.Abs(filepath.Join("testdata", name))
	return p
}

func TestTestsGoldens(t *testing.T) {
	cases := []struct {
		name  string
		files []string
	}{
		{"tests1", []string{"reporter1.json"}},
		{"tests-shards", []string{"reporter1.json", "reporter2.json"}},
		{"tests-empty", []string{"reporter-empty.json"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t, false)
			var paths []string
			for _, p := range c.files {
				paths = append(paths, td(p))
			}
			f.cfg.Tests("tests", "core", paths)
			f.golden(t, c.name+".stdout", f.out.String())
			f.golden(t, c.name+".summary", f.optional("run/tests-core-summary.txt"))
			f.golden(t, c.name+".steps", mask(f.optional("history/steps.jsonl")))
			f.golden(t, c.name+".tests", mask(f.optional("history/tests.jsonl")))
		})
	}
	t.Run("missing", func(t *testing.T) {
		f := newFixture(t, false)
		f.cfg.Tests("tests", "core", []string{"/nonexistent/x.json"})
		f.golden(t, "tests-missing.stdout", f.out.String())
		if f.optional("history/steps.jsonl") != "" {
			t.Error("a missing report must not write history")
		}
	})
}

func TestDriveGolden(t *testing.T) {
	f := newFixture(t, false)
	f.cfg.Tests("drive", "screens", []string{td("drive.log")})
	f.golden(t, "drive.stdout", f.out.String())
	f.golden(t, "drive.summary", f.optional("run/tests-screens-summary.txt"))
	f.golden(t, "drive.steps", mask(f.optional("history/steps.jsonl")))
	f.golden(t, "drive.tests", mask(f.optional("history/tests.jsonl")))
}

// A drive whose tests all skip ("All tests skipped."): result skipped, 0 failed (it used to read "1 failed", result ?).
func TestDriveSkippedGolden(t *testing.T) {
	f := newFixture(t, false)
	f.cfg.Tests("drive", "chart_dpr", []string{td("drive-skipped.log")})
	f.golden(t, "drive-skipped.stdout", f.out.String())
	f.golden(t, "drive-skipped.summary", f.optional("run/tests-chart_dpr-summary.txt"))
	f.golden(t, "drive-skipped.steps", mask(f.optional("history/steps.jsonl")))
	f.golden(t, "drive-skipped.tests", mask(f.optional("history/tests.jsonl")))
	tests, _, err := ParseDrive(td("drive-skipped.log"))
	if err != nil || len(tests) != 1 || tests[0].Result != "skipped" {
		t.Errorf("ParseDrive: %v %v", tests, err)
	}
}

func TestPerfGolden(t *testing.T) {
	f := newFixture(t, false)
	f.cfg.Perf(td("perf-records.jsonl"))
	f.golden(t, "perf.stdout", f.out.String())
	f.golden(t, "perf.summary", f.optional("run/perf-summary.txt"))
	f.golden(t, "perf.history", f.optional("history/perf.jsonl"))
}

func TestHistoryReaders(t *testing.T) {
	f := newFixture(t, true)
	run := func(name string, fn func()) {
		t.Helper()
		f.out.Reset()
		fn()
		f.golden(t, name, f.out.String())
	}
	run("order.stdout", func() {
		f.out.WriteString(strings.Join(f.cfg.Order([]string{"layout:5", "screens", "new", "other"}), "\n") + "\n")
	})
	run("times.stdout", func() { f.cfg.Times(TimesOpts{N: 10}) })
	run("times-n2.stdout", func() { f.cfg.Times(TimesOpts{N: 2, Cmd: "test"}) })
	run("times-step.stdout", func() { f.cfg.Times(TimesOpts{N: 10, Step: "core"}) })
	run("times-none.stdout", func() { f.cfg.Times(TimesOpts{N: 10, Commit: "zzz"}) })
	run("trend.stdout", func() { f.cfg.Trend(TrendOpts{N: 10, Top: 10}) })
	run("trend-top2.stdout", func() { f.cfg.Trend(TrendOpts{N: 3, Top: 2, Step: "app"}) })
}

func TestCIHistoryGolden(t *testing.T) {
	f := newFixture(t, true, "GITHUB_RUN_ID=777", "GITHUB_SHA=0123456789abcdef", "ImageOS=ubuntu24")
	f.cfg.CIHistory(td("ci-times.txt"))
	f.golden(t, "ci-history.stdout", mask(f.out.String()))
}

func TestStageSummaryGolden(t *testing.T) {
	var dirs []string
	for _, n := range []string{"reporter1.json", "reporter2.json"} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, "tests-core.json"), []byte(readFile(t, "testdata", n)), 0o644); err != nil {
			t.Fatal(err)
		}
		dirs = append(dirs, d)
	}
	dirs = append(dirs, "") // an empty line, as printf of a missing readlink gives
	f := newFixture(t, false)
	f.golden(t, "stage-summary.stdout", StageSummary(dirs))
}

func TestPyFloat(t *testing.T) {
	for in, want := range map[float64]string{0: "0.0", 1: "1.0", 12: "12.0", 1.362: "1.362", 1e-05: "1e-05", 0.0001: "0.0001", 1e16: "1e+16",
		123456789012345.0: "123456789012345.0", 1.5e-7: "1.5e-07", -2.5: "-2.5"} {
		if got := PyFloat(in); got != want {
			t.Errorf("PyFloat(%v) = %q, want %q", in, got, want)
		}
	}
}

func TestPyFloatSum(t *testing.T) {
	a, b := 0.1, 0.2
	if got := PyFloat(a + b); got != "0.30000000000000004" {
		t.Errorf("got %s", got)
	}
}

func TestPyJSONQuoting(t *testing.T) {
	got := PyJSON(Obj{{"a", "x\"y\\z\n\té\u0001"}, {"b", []any{1, 2.5, nil, true}}, {"c", Obj{}}})
	want := `{"a": "x\"y\\z\n\t` + "é" + `\u0001", "b": [1, 2.5, null, true], "c": {}}`
	if got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
}
