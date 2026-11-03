package run

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestRecoveryFileSurvivesLaterRun(t *testing.T) {
	c := newCtx(t)
	a, _ := c.Begin("test")
	os.WriteFile(filepath.Join(a.Path, "app.status"), []byte("1.0 1 2026-11-01T10:00:41+00:00\n"), 0o644)
	// run B starts in the same worktree before A finishes and re-points dist/logs
	c.Env = c.Env.With("BW_RUN_DIR", "")
	c.Clock = func() time.Time { return time.Date(2026, 11, 1, 10, 20, 0, 0, time.UTC) }
	b, _ := c.Begin("lint")
	b.Finish(0)
	a.Cmd = "emulator-test"
	a.Finish(1)
	got, _ := os.ReadFile(filepath.Join(c.root, "dist", "last-failed.emulator-test.txt"))
	if want := "app " + a.Path + "/app.log\n"; string(got) != want {
		t.Errorf("last-failed.emulator-test.txt %q want %q", got, want)
	}
	if lf, _ := os.ReadFile(filepath.Join(c.root, "dist", "last-failed.lint.txt")); len(lf) != 0 {
		t.Errorf("lint is green: %q", lf)
	}
}

func TestTrimHistoryKeepsConcurrentAppends(t *testing.T) {
	c := newCtx(t)
	c.Clock = time.Now
	h := filepath.Join(c.Data, "history")
	os.MkdirAll(h, 0o755)
	p := filepath.Join(h, "tests.jsonl")
	old := time.Now().AddDate(0, 0, -40).UTC().Format("2006-01-02T15:04:05Z")
	cur := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	var seed strings.Builder
	for i := 0; i < 20000; i++ {
		// PyJSON puts a space after the colon; perf rows use "time"
		fmt.Fprintf(&seed, "{\"ts\": \"%s\", \"n\": \"old%d\"}\n{\"ts\": \"%s\", \"n\": \"seed%d\"}\n", old, i, cur, i)
	}
	fmt.Fprintf(&seed, "{\"run\": \"r\", \"time\": \"%s\", \"n\": \"oldperf\"}\n{\"run\": \"r\", \"time\": \"%s\", \"n\": \"seedperf\"}\n", old[:19], cur[:19])
	os.WriteFile(p, []byte(seed.String()), 0o644)
	bak := filepath.Join(h, "x.bak-1")
	os.WriteFile(bak, nil, 0o644)
	os.Chtimes(bak, time.Now().AddDate(0, 0, -40), time.Now().AddDate(0, 0, -40))
	stale := filepath.Join(h, ".trim-crashed")
	os.WriteFile(stale, []byte("x"), 0o644)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 2000; i++ {
			AppendLine(p, fmt.Sprintf("{\"ts\":\"%s\",\"n\":\"live%d\"}\n", cur, i))
		}
	}()
	for i := 0; i < 5; i++ {
		c.TrimHistory(30)
	}
	wg.Wait()
	b, _ := os.ReadFile(p)
	s := string(b)
	if strings.Contains(s, "\"old") {
		t.Error("old rows kept")
	}
	if n := strings.Count(s, "\"live"); n != 2000 {
		t.Errorf("live lines %d want 2000", n)
	}
	if n := strings.Count(s, "\"seed"); n != 20001 { // 20000 + the perf row
		t.Errorf("seed lines %d", n)
	}
	if strings.Contains(s, "oldperf") || !strings.Contains(s, "seedperf") {
		t.Error("perf rows (time key) not trimmed correctly")
	}
	if _, err := os.Stat(stale); err == nil {
		t.Error("stale .trim-* kept")
	}
	if _, err := os.Stat(bak); err == nil {
		t.Error("old .bak kept")
	}
}

func TestMarkIncompleteThenFinish(t *testing.T) {
	c := newCtx(t)
	c.MarkIncomplete("lint")
	p := filepath.Join(c.root, "dist", "last-failed.lint.txt")
	if b, _ := os.ReadFile(p); !strings.HasPrefix(string(b), "lint incomplete") {
		t.Errorf("got %q", b)
	}
	d, _ := c.Begin("lint")
	d.Finish(0)
	if b, _ := os.ReadFile(p); len(b) != 0 {
		t.Errorf("green finish should empty it: %q", b)
	}
}
