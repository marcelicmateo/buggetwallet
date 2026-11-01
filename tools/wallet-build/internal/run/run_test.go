package run

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"wallet-build/internal/sys"
)

const timingSh = "../../../timing.sh" // the bash implementation this port must stay compatible with

type testCtx struct {
	*Ctx
	root, data string
	out, err   *bytes.Buffer
	now        *time.Time
}

func newCtx(t *testing.T, kv ...string) *testCtx {
	t.Helper()
	root, data := t.TempDir(), t.TempDir()
	out, errb := &bytes.Buffer{}, &bytes.Buffer{}
	env := sys.Env{"HOME=" + t.TempDir(), "BW_DATA_DIR=" + data, "BW_COMMIT=abc1234", "BW_SOURCE=local", "BW_WORKTREE=wt", "BW_IMAGE=img:1"}
	env = append(env, kv...)
	c := New(root, env, out, errb, &sys.Fake{})
	now := time.Date(2026, 11, 1, 10, 13, 28, 0, time.FixedZone("", 3600))
	c.Clock = func() time.Time { return now }
	return &testCtx{Ctx: c, root: root, data: data, out: out, err: errb, now: &now}
}

func TestSecsSinceTruncates(t *testing.T) {
	c := newCtx(t)
	start := c.Us()
	for _, tc := range []struct {
		add  time.Duration
		want string
	}{{0, "0.0"}, {99 * time.Millisecond, "0.0"}, {121850 * time.Millisecond, "121.8"}, {59999 * time.Millisecond, "59.9"}} {
		now := time.Date(2026, 11, 1, 10, 13, 28, 0, time.UTC).Add(tc.add)
		c.Clock = func() time.Time { return now }
		c.Clock = func() time.Time { return now }
		s := now.Add(-tc.add).UnixMicro()
		_ = start
		if got := c.SecsSince(s); got != tc.want {
			t.Errorf("%v: got %s want %s", tc.add, got, tc.want)
		}
	}
}

// timing.sh exports BW_DATA_DIR; without it the container (another HOME) would write its history somewhere else.
func TestDataDirIsExported(t *testing.T) {
	c := New("/x/wt", sys.Env{"HOME=/home/u", "XDG_DATA_HOME=/xdg"}, io.Discard, io.Discard, &sys.Fake{})
	if c.Data != "/xdg/budget-wallet" || c.Env.Get("BW_DATA_DIR") != "/xdg/budget-wallet" {
		t.Errorf("data %s env %s", c.Data, c.Env.Get("BW_DATA_DIR"))
	}
	c = New("/x/wt", sys.Env{"HOME=/home/u"}, io.Discard, io.Discard, &sys.Fake{})
	if c.Data != "/home/u/.local/share/budget-wallet" {
		t.Errorf("data %s", c.Data)
	}
}

func TestNowISO(t *testing.T) {
	c := newCtx(t)
	if got := c.NowISO(); got != "2026-11-01T10:13:28+01:00" {
		t.Errorf("got %s", got)
	}
	c.Clock = func() time.Time { return time.Date(2026, 11, 1, 10, 13, 28, 0, time.UTC) }
	if got := c.NowISO(); got != "2026-11-01T10:13:28+00:00" {
		t.Errorf("UTC must print +00:00 like date +%%:z, got %s", got)
	}
}

func TestStepTimeoutNames(t *testing.T) {
	cases := []struct {
		name, key string
	}{{"format", "BW_TIMEOUT_FORMAT"}, {"core:one", "BW_TIMEOUT_CORE_ONE"}, {"analyze-core", "BW_TIMEOUT_ANALYZE_CORE"}, {"desktop-layout.s2", "BW_TIMEOUT_DESKTOP_LAYOUT_S2"}}
	for _, c := range cases {
		env := sys.Env{c.key + "=7", "BW_STEP_TIMEOUT=99"}
		if got := StepTimeout(env, c.name, time.Hour); got != 7*time.Second {
			t.Errorf("%s: %v", c.name, got)
		}
	}
	if got := StepTimeout(sys.Env{"BW_STEP_TIMEOUT=50"}, "core", time.Hour); got != 50*time.Second {
		t.Errorf("BW_STEP_TIMEOUT: %v", got)
	}
	if got := StepTimeout(sys.Env{"BW_STEP_TIMEOUT=0"}, "core", time.Hour); got != 0 {
		t.Errorf("0 = no limit: %v", got)
	}
	if got := StepTimeout(sys.Env{"BW_STEP_TIMEOUT=junk"}, "core", time.Hour); got != time.Hour {
		t.Errorf("junk falls back to the default: %v", got)
	}
}

func TestDefaultTimeouts(t *testing.T) {
	env := sys.Env{}
	want := map[string]time.Duration{"format": 300, "analyze-app": 300, "core:one": 300, "core": 900, "app": 900, "desktop-layout": 1200, "desktop-layout.s1": 1200,
		"perf": 1200, "linux": 1200, "web": 1200, "apk": 2400, "image": 3600, "mutate": 0, "shell": 0, "go-check": 600}
	for n, w := range want {
		if got := DefaultTimeout(env, n); got != w*time.Second {
			t.Errorf("%s: %v want %vs", n, got, w)
		}
	}
	if got := DefaultTimeout(sys.Env{"BW_HEADLESS_TIMEOUT=77"}, "desktop-x"); got != 77*time.Second {
		t.Errorf("BW_HEADLESS_TIMEOUT: %v", got)
	}
}

func TestRunStepFormats(t *testing.T) {
	c := newCtx(t, "BW_RUN_DIR="+t.TempDir(), "BW_RUN_ID=r1")
	s := NewSession(c.Ctx)
	rc := s.RunStep("demo", func(sc *StepCtx) int { sc.Printf("hello\n"); return 3 }, false)
	if rc != 3 {
		t.Fatal(rc)
	}
	log, _ := os.ReadFile(filepath.Join(s.Logs, "demo.log"))
	want := "# demo: started 2026-11-01T10:13:28+01:00\nhello\n# demo: finished 2026-11-01T10:13:28+01:00, 0.0 s, exit 3\n"
	if string(log) != want {
		t.Errorf("log:\n%q\nwant\n%q", log, want)
	}
	st, _ := os.ReadFile(filepath.Join(s.Logs, "demo.status"))
	if string(st) != "0.0 3 2026-11-01T10:13:28+01:00\n" {
		t.Errorf("status %q", st)
	}
	if c.out.Len() != 0 {
		t.Errorf("a non-live step must not print: %q", c.out)
	}
	s.RunStep("live", func(sc *StepCtx) int { sc.Printf("shown\n"); return 0 }, true)
	if c.out.String() != "shown\n" {
		t.Errorf("live output %q", c.out)
	}
}

func TestRecordWritesBashHistoryLine(t *testing.T) {
	c := newCtx(t, "BW_RUN_DIR="+t.TempDir(), "BW_RUN_ID=20261101-111328-app-9098d74-dirty", "BW_CMD=app")
	s := NewSession(c.Ctx)
	s.RunStep("app", func(sc *StepCtx) int { return 0 }, false)
	s.Record("app", false)
	got, _ := os.ReadFile(filepath.Join(c.data, "history", "steps.jsonl"))
	want := `{"ts":"2026-11-01T10:13:28+01:00","run":"20261101-111328-app-9098d74-dirty","source":"local","worktree":"wt","commit":"abc1234","cmd":"app","step":"app","seconds":0.0,"result":"ok","image":"img:1","cold":false}` + "\n"
	if string(got) != want {
		t.Errorf("got  %swant %s", got, want)
	}
}

// log_history of tools/timing.sh and LogHistory must write byte-identical lines.
func TestHistoryLineEqualsBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	c := newCtx(t, "BW_RUN=2026-11-01T10:00:00+00:00", "BW_RUN_ID=20261101-100000-app-abc1234", "BW_CMD=app", "BW_COLD=0")
	c.LogHistory("app", "121.8", "FAILED", "true", "2026-11-01T10:13:28+00:00")
	c.LogHistory("core:one", "0.0", "ok", "false", "")
	goData, _ := os.ReadFile(filepath.Join(c.data, "history", "steps.jsonl"))
	bashData := t.TempDir()
	script := `ROOT=` + c.root + `; source ` + timingSh + `
BW_RUN=2026-11-01T10:00:00+00:00; BW_RUN_ID=20261101-100000-app-abc1234; BW_CMD=app; BW_COLD=0; BW_SOURCE=local; BW_WORKTREE=wt; BW_COMMIT=abc1234; BW_IMAGE=img:1
log_history app 121.8 FAILED true 2026-11-01T10:13:28+00:00
log_history core:one 0.0 ok false 2026-11-01T10:13:28+01:00`
	cmd := exec.Command("bash", "-c", script)
	cmd.Env = append(os.Environ(), "BW_DATA_DIR="+bashData)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("bash: %v %s", err, out)
	}
	bashLines, _ := os.ReadFile(filepath.Join(bashData, "history", "steps.jsonl"))
	if string(goData) != string(bashLines) {
		t.Errorf("go:\n%s\nbash:\n%s", goData, bashLines)
	}
}

func TestBeginAndFinish(t *testing.T) {
	c := newCtx(t)
	d, err := c.Begin("app")
	if err != nil {
		t.Fatal(err)
	}
	if want := "20261101-101328-app-abc1234"; d.ID != want {
		t.Errorf("run id %s want %s", d.ID, want)
	}
	if c.Env.Get("BW_RUN_DIR") != d.Path || c.Env.Get("BW_RUN_ID") != d.ID || c.Env.Get("BW_CMD") != "app" || c.Env.Get("BW_COLD") != "0" {
		t.Errorf("env: %v", c.Env)
	}
	if _, err := os.Stat(filepath.Join(d.Path, ".running")); err != nil {
		t.Error("no .running marker")
	}
	if link, _ := os.Readlink(filepath.Join(c.root, "dist", "logs")); link != d.Path {
		t.Errorf("dist/logs -> %s", link)
	}
	if d2, _ := c.Begin("test"); d2 != nil {
		t.Error("a nested Begin must keep the outer run")
	}
	// same second, same command: -2, -3
	c2 := newCtx(t)
	c2.Data = c.Data
	c2.Env = c2.Env.With("BW_DATA_DIR", c.Data)
	d3, _ := c2.Begin("app")
	if !strings.HasSuffix(d3.ID, "-abc1234-2") {
		t.Errorf("second run in the same second: %s", d3.ID)
	}
	os.WriteFile(filepath.Join(d.Path, "app.status"), []byte("1.8 0 2026-11-01T10:00:49+00:00\n"), 0o644)
	os.WriteFile(filepath.Join(d.Path, "pub.status"), []byte("0.0 0 2026-11-01T10:00:40+00:00\n"), 0o644)
	os.WriteFile(filepath.Join(d.Path, "fmt.status"), []byte("2.5 1 2026-11-01T10:00:41+00:00\n"), 0o644)
	d.Finish(1)
	if _, err := os.Stat(filepath.Join(d.Path, ".running")); err == nil {
		t.Error(".running not removed")
	}
	last, _ := os.ReadFile(filepath.Join(d.Path, "last.status"))
	if string(last) != "pub ok 0.0\nfmt failed 2.5\napp ok 1.8\n" {
		t.Errorf("last.status %q", last)
	}
	lf, _ := os.ReadFile(filepath.Join(d.Path, "last-failed.txt"))
	if string(lf) != "fmt "+c.root+"/dist/logs/fmt.log\n" {
		t.Errorf("last-failed.txt %q", lf)
	}
}

func TestLastFailedWithoutFailedStep(t *testing.T) {
	c := newCtx(t)
	d, _ := c.Begin("shell")
	d.Finish(125)
	lf, _ := os.ReadFile(filepath.Join(d.Path, "last-failed.txt"))
	if want := "run " + d.Path + " (exit 125, no failed step recorded)\n"; string(lf) != want {
		t.Errorf("got %q want %q", lf, want)
	}
	last, _ := os.ReadFile(filepath.Join(d.Path, "last.status"))
	if len(last) != 0 {
		t.Errorf("last.status should be empty: %q", last)
	}
	// green run: both empty
	d2, _ := newCtxSharing(t, c).Begin("lint")
	d2.Finish(0)
	lf, _ = os.ReadFile(filepath.Join(d2.Path, "last-failed.txt"))
	if len(lf) != 0 {
		t.Errorf("green run: %q", lf)
	}
}

func newCtxSharing(t *testing.T, o *testCtx) *Ctx {
	c := newCtx(t)
	c.Data = o.data
	c.Env = c.Env.With("BW_DATA_DIR", o.data)
	c.Clock = func() time.Time { return time.Date(2026, 11, 1, 10, 14, 0, 0, time.UTC) }
	return c.Ctx
}

func mkRun(t *testing.T, data, name string, running bool, age time.Duration) {
	t.Helper()
	d := filepath.Join(data, "runs", name)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if running {
		f := filepath.Join(d, ".running")
		os.WriteFile(f, nil, 0o644)
		old := time.Now().Add(-age)
		os.Chtimes(f, old, old)
	}
}

func listRuns(data string) []string {
	ents, _ := os.ReadDir(filepath.Join(data, "runs"))
	var out []string
	for _, e := range ents {
		out = append(out, e.Name())
	}
	return out
}

func TestPruneKeepsNewestAndRunning(t *testing.T) {
	c := newCtx(t)
	c.Clock = time.Now
	for i := 0; i < 40; i++ {
		mkRun(t, c.data, fmt.Sprintf("20260101-0000%02d-x-c", i), false, 0)
	}
	mkRun(t, c.data, "20250101-000000-old-running", true, time.Hour)  // in progress, kept
	mkRun(t, c.data, "20250101-000001-old-stale", true, 30*time.Hour) // .running older than 24 h: finished
	c.PruneRuns()
	runs := listRuns(c.data)
	has := func(n string) bool {
		for _, r := range runs {
			if r == n {
				return true
			}
		}
		return false
	}
	if !has("20250101-000000-old-running") || has("20250101-000001-old-stale") {
		t.Errorf("running/stale handling: %v", runs)
	}
	if len(runs) != 31 || has("20260101-000000-x-c") || !has("20260101-000039-x-c") || !has("20260101-000010-x-c") {
		t.Errorf("want newest 30 finished + 1 running, got %d: %v", len(runs), runs)
	}
}

// Go and bash prune under one flock: running both at once on the same data dir must leave exactly the newest 30.
func TestPruneConcurrentWithBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("no flock")
	}
	c := newCtx(t)
	c.Clock = time.Now
	for i := 0; i < 60; i++ {
		mkRun(t, c.data, fmt.Sprintf("20260101-0000%02d-x-c", i), false, 0)
	}
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); c.PruneRuns() }()
		go func() {
			defer wg.Done()
			cmd := exec.Command("bash", "-c", "ROOT=/nonexistent; source "+timingSh+"; prune_runs")
			cmd.Env = append(os.Environ(), "BW_DATA_DIR="+c.data)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Errorf("bash prune: %v %s", err, out)
			}
		}()
	}
	wg.Wait()
	runs := listRuns(c.data)
	if len(runs) != 30 || runs[0] != "20260101-000030-x-c" || runs[29] != "20260101-000059-x-c" {
		t.Errorf("got %d runs: %v", len(runs), runs)
	}
}

// TestMain lets the test binary act as the helper process of TestConcurrentHistoryAppends.
func TestMain(m *testing.M) {
	if dir := os.Getenv("WB_HELPER_APPEND"); dir != "" {
		c := New("/x/wt", sys.Env{"BW_DATA_DIR=" + dir, "BW_RUN_ID=" + os.Getenv("WB_HELPER_ID"), "BW_SOURCE=local", "BW_WORKTREE=wt", "BW_COMMIT=c",
			"BW_CMD=test", "BW_IMAGE=i"}, io.Discard, io.Discard, &sys.Fake{})
		for i := 0; i < 500; i++ {
			c.LogHistory(fmt.Sprintf("step-%d", i), "12.0", "ok", "false", "2026-11-01T10:00:00+00:00")
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestConcurrentHistoryAppends(t *testing.T) {
	data := t.TempDir()
	var wg sync.WaitGroup
	for p := 0; p < 8; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cmd := exec.Command(os.Args[0], "-test.run=NONE")
			cmd.Env = append(os.Environ(), "WB_HELPER_APPEND="+data, fmt.Sprintf("WB_HELPER_ID=run%d", p))
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Errorf("helper %d: %v %s", p, err, out)
			}
		}()
	}
	wg.Wait()
	f, err := os.Open(filepath.Join(data, "history", "steps.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	perRun := map[string]int{}
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var rec map[string]any
		if err := json.Unmarshal(sc.Bytes(), &rec); err != nil {
			t.Fatalf("line %d is not JSON (interleaved write?): %q", n, sc.Text())
		}
		perRun[rec["run"].(string)]++
		n++
	}
	if n != 4000 || len(perRun) != 8 {
		t.Errorf("got %d lines from %d runs, want 4000 from 8", n, len(perRun))
	}
}

func TestRunStepTimeout(t *testing.T) {
	c := newCtx(t, "BW_TIMEOUT_SLOW=1", "BW_RUN_DIR="+t.TempDir())
	s := NewSession(c.Ctx)
	rc := s.RunStep("slow", func(sc *StepCtx) int {
		<-sc.Ctx.Done()
		return 143
	}, false)
	if rc != 124 {
		t.Errorf("rc %d", rc)
	}
	log, _ := os.ReadFile(filepath.Join(s.Logs, "slow.log"))
	if !strings.Contains(string(log), "# slow: timed out after 1 s\n# slow: finished ") || !strings.HasSuffix(string(log), ", exit 124\n") {
		t.Errorf("log %q", log)
	}
	st, _ := os.ReadFile(filepath.Join(s.Logs, "slow.status"))
	if f := strings.Fields(string(st)); len(f) != 3 || f[1] != "124" {
		t.Errorf("status %q", st)
	}
	s.Record("slow", false)
	if !s.Failed || s.Exit() != 1 {
		t.Error("a timed-out step must fail the run")
	}
}

func TestRedactionInLogsAndHistory(t *testing.T) {
	c := newCtx(t, "BW_KEYSTORE_PASSWORD=sup3r-secret-pw", "BW_RUN_DIR="+t.TempDir(), "BW_WORKTREE=wt-sup3r-secret-pw")
	s := NewSession(c.Ctx)
	s.RunStep("apk", func(sc *StepCtx) int {
		sc.Printf("keytool -storepass sup3r-secret-pw failed\n")
		sc.Printf("half sup3r-sec")
		sc.Printf("ret-pw\n")
		return 1
	}, true)
	s.Record("apk", false)
	c.Printf("note: sup3r-secret-pw\n")
	s.FailStep("x", "bad sup3r-secret-pw")
	err := filepath.WalkDir(c.Env.Get("BW_RUN_DIR"), func(p string, d os.DirEntry, err error) error { return err })
	if err != nil {
		t.Fatal(err)
	}
	var all []string
	all = append(all, c.out.String(), c.err.String())
	files, _ := filepath.Glob(filepath.Join(s.Logs, "*"))
	hist, _ := os.ReadFile(filepath.Join(c.data, "history", "steps.jsonl"))
	all = append(all, string(hist))
	for _, f := range files {
		b, _ := os.ReadFile(f)
		all = append(all, string(b))
	}
	for _, text := range all {
		if strings.Contains(text, "sup3r-secret-pw") || strings.Contains(text, "sup3r-sec\n") {
			t.Errorf("secret in output: %q", text)
		}
	}
	if !strings.Contains(c.out.String(), "keytool -storepass ***") || !strings.Contains(c.out.String(), "half ***") {
		t.Errorf("stdout %q", c.out.String())
	}
}

func TestBodyOf(t *testing.T) {
	cases := map[string]string{"a\nb\nc\n": "b\n", "a\nb\n": "", "a\n": "", "": "", "a\nb\nc\nd\n": "b\nc\n"}
	for in, want := range cases {
		if got := BodyOf(in); got != want {
			t.Errorf("BodyOf(%q) = %q want %q", in, got, want)
		}
	}
}

func TestStepsRunInParallelAndRecordInOrder(t *testing.T) {
	c := newCtx(t, "BW_RUN_DIR="+t.TempDir(), "BW_RUN_ID=r")
	s := NewSession(c.Ctx)
	started := make(chan string, 2)
	release := make(chan struct{})
	s.Steps(
		Spec{Name: "first", Fn: func(sc *StepCtx) int { started <- "first"; <-release; sc.Printf("one\n"); return 0 }},
		Spec{Name: "second", Fn: func(sc *StepCtx) int { started <- "second"; close(release); sc.Printf("two\n"); return 1 }},
	)
	if len(started) != 2 {
		t.Error("both steps must have started")
	}
	want := "=== first ===\none\n=== second ===\ntwo\n"
	if c.out.String() != want {
		t.Errorf("out %q", c.out.String())
	}
	if strings.Join(s.Results, " ") != "first=ok second=FAILED" {
		t.Errorf("results %v", s.Results)
	}
	c.out.Reset()
	s.Summary()
	if !strings.HasPrefix(c.out.String(), "\nstep              seconds  result\nfirst                 0.0  ok\nsecond                0.0  FAILED\ntotal                 0.0\n") {
		t.Errorf("summary %q", c.out.String())
	}
	if !strings.HasSuffix(c.out.String(), "first=ok second=FAILED\n") {
		t.Errorf("summary %q", c.out.String())
	}
}

var _ = context.Background
