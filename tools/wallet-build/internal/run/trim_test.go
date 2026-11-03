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
	a.Finish(1)
	got, _ := os.ReadFile(filepath.Join(c.root, "dist", "last-failed.test.txt"))
	if want := "app " + a.Path + "/app.log\n"; string(got) != want {
		t.Errorf("last-failed.test.txt %q want %q", got, want)
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
		fmt.Fprintf(&seed, "{\"ts\":\"%s\",\"n\":\"old%d\"}\n{\"ts\":\"%s\",\"n\":\"seed%d\"}\n", old, i, cur, i)
	}
	os.WriteFile(p, []byte(seed.String()), 0o644)
	bak := filepath.Join(h, "x.bak-1")
	os.WriteFile(bak, nil, 0o644)
	os.Chtimes(bak, time.Now().AddDate(0, 0, -40), time.Now().AddDate(0, 0, -40))
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
	if n := strings.Count(s, "\"seed"); n != 20000 {
		t.Errorf("seed lines %d", n)
	}
	if _, err := os.Stat(bak); err == nil {
		t.Error("old .bak kept")
	}
}
