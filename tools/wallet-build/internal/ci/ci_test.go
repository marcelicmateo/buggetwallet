package ci

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

const sha = "0123456789abcdef0123456789abcdef01234567"

type env struct {
	x      *CI
	fake   *sys.Fake
	out    *bytes.Buffer
	errb   *bytes.Buffer
	tables []string // successive gh api answers
	now    time.Time
}

func newEnv(t *testing.T, latest string, tables ...string) *env {
	e := &env{out: &bytes.Buffer{}, errb: &bytes.Buffer{}, tables: tables, now: time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)}
	e.fake = &sys.Fake{Handle: func(c sys.Cmd) int {
		a := strings.Join(c.Argv, " ")
		switch {
		case strings.HasPrefix(a, "git rev-parse"):
			c.Stdout.Write([]byte(sha + "\n"))
		case strings.HasPrefix(a, "git branch -r --contains"):
			c.Stdout.Write([]byte("  origin/v2\n"))
		case strings.HasPrefix(a, "gh api repos/"+Repo+"/commits/"+sha+"/check-runs"):
			tab := e.tables[0]
			if len(e.tables) > 1 {
				e.tables = e.tables[1:]
			}
			c.Stdout.Write([]byte(tab))
		case strings.HasPrefix(a, "git show origin/ci-logs:latest.txt"):
			c.Stdout.Write([]byte(latest))
		}
		return 0
	}}
	c := run.New(t.TempDir(), sys.Env{}, e.out, e.errb, e.fake)
	c.Clock = func() time.Time { return e.now }
	e.x = &CI{C: c, Sleep: func(d time.Duration) { e.now = e.now.Add(d) }}
	return e
}

func TestColumn(t *testing.T) {
	got := Column("lint\tcompleted\tsuccess\napk\tin_progress\t-\n")
	want := "lint  completed    success\napk   in_progress  -\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestStatusGreen(t *testing.T) {
	latest := "commit: " + sha + "  ref: v2  run: 1\n\nlint=ok:12.0 apk=ok:400.0\njobs ok\n"
	e := newEnv(t, latest, "lint\tcompleted\tsuccess\napk\tcompleted\tsuccess\nlinux\tcompleted\tskipped\nlog\tcompleted\tsuccess\n")
	if rc := e.x.Status(nil); rc != 0 {
		t.Fatalf("rc %d\n%s", rc, e.out)
	}
	want := "commit 0123456\nlint   completed  success\napk    completed  success\nlinux  completed  skipped\nlog    completed  success\nall green\nlint=ok:12.0 apk=ok:400.0\n"
	if e.out.String() != want {
		t.Errorf("got\n%s\nwant\n%s", e.out, want)
	}
}

func TestStatusFailedShowsFailingLines(t *testing.T) {
	var log strings.Builder
	log.WriteString("commit: " + sha + "  ref: v2  run: 1\n\nlint=ok core=failure\njobs\n")
	log.WriteString("ok line\nTest failed: x\ncontinue-on-error: true\n0 errors\nan Exception happened\n")
	e := newEnv(t, log.String(), "lint\tcompleted\tsuccess\ncore\tcompleted\tfailure\nlog\tcompleted\tsuccess\n")
	if rc := e.x.Status(nil); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	out := e.out.String()
	for _, want := range []string{"core  completed  failure", "\nlint=ok core=failure\n--- failing lines (full log: tools/ci-status.sh --log) ---\n", "6:Test failed: x\n", "9:an Exception happened\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "continue-on-error") || strings.Contains(out, "0 errors") {
		t.Errorf("noise lines shown:\n%s", out)
	}
	// the log of another commit is not shown
	e = newEnv(t, "commit: ffffffffffffffffffffffffffffffffffffffff\n", "core\tcompleted\tfailure\nlog\tcompleted\tsuccess\n")
	e.x.Status(nil)
	if !strings.Contains(e.out.String(), "ci-logs/latest.txt is for another commit") {
		t.Errorf("out %s", e.out)
	}
}

func TestStatusRunningAndEmpty(t *testing.T) {
	e := newEnv(t, "", "lint\tcompleted\tsuccess\napk\tin_progress\t-\n")
	if rc := e.x.Status(nil); rc != 2 || !strings.HasSuffix(e.out.String(), "still running\n") {
		t.Errorf("rc %d\n%s", rc, e.out)
	}
	e = newEnv(t, "", "")
	if rc := e.x.Status(nil); rc != 2 || e.out.String() != "commit 0123456\nno check runs yet\n" {
		t.Errorf("rc %d\n%s", rc, e.out)
	}
}

func TestStatusWaitPollsUntilDone(t *testing.T) {
	e := newEnv(t, "x\n\nsteps\n", "", "lint\tin_progress\t-\n", "lint\tcompleted\tsuccess\n", "lint\tcompleted\tsuccess\nlog\tcompleted\tsuccess\n")
	e.x.Sleep = func(d time.Duration) {
		if d != 20*time.Second {
			t.Errorf("poll interval %v", d)
		}
		e.now = e.now.Add(d)
	}
	if rc := e.x.Status([]string{"--wait", sha}); rc != 0 {
		t.Errorf("rc %d\n%s", rc, e.out)
	}
	polls := 0
	for _, c := range e.fake.Calls {
		if c.Argv[0] == "gh" {
			polls++
		}
	}
	if polls != 4 {
		t.Errorf("polled %d times", polls)
	}
}

func TestStatusWaitGivesUpAfter30Minutes(t *testing.T) {
	e := newEnv(t, "", "lint\tin_progress\t-\n")
	if rc := e.x.Status([]string{"--wait"}); rc != 2 {
		t.Errorf("rc %d", rc)
	}
	if e.now.Sub(time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)) < 30*time.Minute {
		t.Errorf("gave up after %v", e.now)
	}
}

func TestMainDispatch(t *testing.T) {
	e := newEnv(t, "log text\n")
	if rc, ok := e.x.Main([]string{"log"}); !ok || rc != 0 || e.out.String() != "log text\n\n" && e.out.String() != "log text\n" {
		t.Errorf("rc %d ok %v out %q", rc, ok, e.out)
	}
	if _, ok := e.x.Main(nil); ok {
		t.Error("no subcommand is a usage error")
	}
	if _, ok := e.x.Main([]string{"nope"}); ok {
		t.Error("unknown subcommand is a usage error")
	}
}

// tools/ci-status.sh --log [name] is `ci status --log [name]` as well as `ci log [name]`
func TestStatusLogFlag(t *testing.T) {
	e := newEnv(t, "the latest log\n")
	if rc := e.x.Status([]string{"--log"}); rc != 0 || e.out.String() != "the latest log\n" {
		t.Errorf("rc %d out %q", rc, e.out)
	}
	var shown []string
	e.fake.Handle = func(c sys.Cmd) int {
		if len(c.Argv) > 2 && c.Argv[0] == "git" && c.Argv[1] == "show" {
			shown = append(shown, c.Argv[2])
			c.Stdout.Write([]byte("x"))
		}
		return 0
	}
	e.x.Status([]string{"--log", "20261101-run"})
	if len(shown) != 1 || shown[0] != "origin/ci-logs:20261101-run.txt" {
		t.Errorf("shown %v", shown)
	}
}

// all jobs completed but "log" (created last) is not there yet: not green
func TestStatusNeedsTheLogCheckRun(t *testing.T) {
	e := newEnv(t, "", "lint\tcompleted\tsuccess\napk\tcompleted\tsuccess\n")
	if rc := e.x.Status(nil); rc != 2 || !strings.HasSuffix(e.out.String(), "still running\n") {
		t.Errorf("rc %d\n%s", rc, e.out)
	}
	e = newEnv(t, "", "lint\tcompleted\tsuccess\n", "lint\tcompleted\tsuccess\napk\tcompleted\tsuccess\nlog\tcompleted\tsuccess\n")
	if rc := e.x.Status([]string{"--wait"}); rc != 0 || !strings.Contains(e.out.String(), "all green") {
		t.Errorf("--wait waits for log: rc %d\n%s", rc, e.out)
	}
}
