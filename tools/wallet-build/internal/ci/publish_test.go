package ci

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/sys"
)

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = []string{"PATH=" + pathEnv(), "HOME=" + t.TempDir(), "GIT_CONFIG_NOSYSTEM=1"}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func pathEnv() string {
	p, _ := exec.LookPath("git")
	return filepath.Dir(p)
}

// bareRemote is an empty bare repository; file:// makes --depth work like on GitHub.
func bareRemote(t *testing.T) (dir, url string) {
	need(t, "git")
	dir = filepath.Join(t.TempDir(), "remote.git")
	git(t, filepath.Dir(dir), "init", "-q", "--bare", "-b", "ci-logs", dir)
	return dir, "file://" + dir
}

func showFile(t *testing.T, bare, name string) string { return git(t, bare, "show", "ci-logs:"+name) }

func TestPublishLogFirstRunAndAppend(t *testing.T) {
	bare, url := bareRemote(t)
	h := newHX(t, sys.Real{})
	h.x.Remote = url
	logf, hist := filepath.Join(h.tmp, "ci.txt"), filepath.Join(h.tmp, "history.jsonl")
	write(t, logf, "lint=ok(1s)\njob:lint=success \n\nstep seconds exit\n")
	write(t, hist, `{"step":"lint"}`+"\n")
	if rc := h.x.PublishLog([]string{"latest", logf, hist}); rc != 0 {
		t.Fatalf("rc %d: %s", rc, h.errb)
	}
	want := "commit: 0123456789abcdef0123456789abcdef01234567  ref: v2  run: 77\n\n" + "lint=ok(1s)\njob:lint=success \n\nstep seconds exit\n"
	if got := showFile(t, bare, "latest.txt"); got != want {
		t.Errorf("latest.txt\n%q\nwant\n%q", got, want)
	}
	if got := showFile(t, bare, "history.jsonl"); got != `{"step":"lint"}`+"\n" {
		t.Errorf("history %q", got)
	}
	if !strings.Contains(h.errb.String(), "starting a fresh branch") {
		t.Errorf("first run should say so: %q", h.errb)
	}
	// second run (another log name, more history) appends and keeps the first log
	write(t, logf, "second\n")
	write(t, hist, `{"step":"apk"}`+"\n")
	if rc := h.x.PublishLog([]string{"release-android-linux", logf, hist}); rc != 0 {
		t.Fatalf("rc %d: %s", rc, h.errb)
	}
	if got := showFile(t, bare, "history.jsonl"); got != `{"step":"lint"}`+"\n"+`{"step":"apk"}`+"\n" {
		t.Errorf("history %q", got)
	}
	if got := showFile(t, bare, "latest.txt"); got != want {
		t.Error("latest.txt changed")
	}
	if !strings.HasSuffix(showFile(t, bare, "release-android-linux.txt"), "\n\nsecond\n") {
		t.Error("release log missing")
	}
	msgs := git(t, bare, "log", "--format=%an <%ae> %s", "ci-logs")
	if msgs != "ci-bot <ci-bot@users.noreply.github.com> log release-android-linux 0123456789abcdef0123456789abcdef01234567\n"+
		"ci-bot <ci-bot@users.noreply.github.com> log latest 0123456789abcdef0123456789abcdef01234567\n" {
		t.Errorf("commits:\n%s", msgs)
	}
}

func TestPublishLogWithoutHistoryAndMissingLog(t *testing.T) {
	bare, url := bareRemote(t)
	h := newHX(t, sys.Real{})
	h.x.Remote = url
	if rc := h.x.PublishLog([]string{"latest", filepath.Join(h.tmp, "missing.txt")}); rc != 0 {
		t.Fatalf("rc %d: %s", rc, h.errb)
	}
	if got := showFile(t, bare, "latest.txt"); got != "commit: 0123456789abcdef0123456789abcdef01234567  ref: v2  run: 77\n\n" {
		t.Errorf("got %q", got)
	}
	if out := git(t, bare, "ls-tree", "--name-only", "ci-logs"); out != "latest.txt\n" {
		t.Errorf("tree %q", out)
	}
}

func TestPublishLogNothingToCommitIsOK(t *testing.T) {
	_, url := bareRemote(t)
	h := newHX(t, sys.Real{})
	h.x.Remote = url
	logf := filepath.Join(h.tmp, "ci.txt")
	write(t, logf, "same\n")
	if rc := h.x.PublishLog([]string{"latest", logf}); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	h.errb.Reset()
	if rc := h.x.PublishLog([]string{"latest", logf}); rc != 0 {
		t.Fatalf("rc %d: %s", rc, h.errb)
	}
	if !strings.Contains(h.errb.String(), "nothing to commit") {
		t.Errorf("stderr %q", h.errb)
	}
}

// A push that loses against another job is retried after a growing wait.
func TestPublishLogRetriesWithBackoff(t *testing.T) {
	bare, url := bareRemote(t)
	h := newHX(t, sys.Real{})
	h.x.Remote = url
	logf := filepath.Join(h.tmp, "ci.txt")
	write(t, logf, "log\n")
	pushes := 0
	h.x.C.R = pushFailer{Real: sys.Real{}, failFirst: 2, count: &pushes}
	var waits []time.Duration
	h.x.Sleep = func(d time.Duration) { waits = append(waits, d) }
	if rc := h.x.PublishLog([]string{"latest", logf}); rc != 0 {
		t.Fatalf("rc %d: %s", rc, h.errb)
	}
	if pushes != 3 || len(waits) != 2 || waits[0] != 3*time.Second || waits[1] != 6*time.Second {
		t.Errorf("pushes %d waits %v", pushes, waits)
	}
	if !strings.Contains(showFile(t, bare, "latest.txt"), "\n\nlog\n") {
		t.Error("log not published after the retries")
	}
}

type pushFailer struct {
	sys.Real
	failFirst int
	count     *int
}

func (p pushFailer) Run(ctx context.Context, c sys.Cmd) int {
	if len(c.Argv) > 1 && c.Argv[0] == "git" && c.Argv[1] == "push" {
		*p.count++
		if *p.count <= p.failFirst {
			if c.Stderr != nil {
				_, _ = c.Stderr.Write([]byte("! [rejected] HEAD -> ci-logs (fetch first)\n"))
			}
			return 1
		}
	}
	return p.Real.Run(ctx, c)
}

// Five failed attempts give up with exit 1, and the token appears nowhere in what is printed.
func TestPublishLogGivesUpAndScrubsToken(t *testing.T) {
	need(t, "git")
	const token = "ghs_SECRETTOKEN1234567890"
	h := newHX(t, sys.Real{}, "GH_TOKEN="+token, "GITHUB_REPOSITORY=owner/repo")
	h.x.Remote = "https://x-access-token:" + token + "@127.0.0.1:1/owner/repo.git" // refuses the connection at once
	logf := filepath.Join(h.tmp, "ci.txt")
	write(t, logf, "log\n")
	var waits []time.Duration
	h.x.Sleep = func(d time.Duration) { waits = append(waits, d) }
	if rc := h.x.PublishLog([]string{"latest", logf}); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	all := h.out.String() + h.errb.String()
	if strings.Contains(all, token) || strings.Contains(all, "SECRETTOKEN") {
		t.Errorf("token leaked:\n%s", all)
	}
	if !strings.Contains(all, "could not publish log") {
		t.Errorf("no failure message: %s", all)
	}
	if len(waits) != 5 || waits[4] != 15*time.Second {
		t.Errorf("waits %v", waits)
	}
}

func TestScrub(t *testing.T) {
	got := scrub("fatal: unable to access 'https://x-access-token:abcd1234@github.com/o/r/': 403\nTOKEN=abcd1234", "abcd1234")
	if strings.Contains(got, "abcd1234") || !strings.Contains(got, "x-access-token:***@github.com") {
		t.Errorf("got %q", got)
	}
	if scrub("short ab", "ab") != "short ab" {
		t.Error("a token shorter than 4 bytes must not blank out ordinary text")
	}
}

func TestRemoteURLFromEnvironment(t *testing.T) {
	h := newHX(t, &sys.Fake{}, "GH_TOKEN=tok", "GITHUB_REPOSITORY=o/r")
	if got := h.x.remoteURL(); got != "https://x-access-token:tok@github.com/o/r" {
		t.Errorf("got %q", got)
	}
}

func TestPublishLogUsage(t *testing.T) {
	h := newHX(t, &sys.Fake{})
	for _, a := range [][]string{nil, {"latest"}, {"", "f"}, {"a", "b", "c", "d"}} {
		if rc := h.x.PublishLog(a); rc != 2 {
			t.Errorf("%v: rc %d", a, rc)
		}
	}
}

func TestMainDispatchesNewSubcommands(t *testing.T) {
	h := newHX(t, &sys.Fake{})
	for _, sub := range []string{"step", "job-log", "merge", "publish-log"} {
		if rc, ok := h.x.Main([]string{sub}); ok || rc != 2 {
			t.Errorf("%s without arguments: rc %d ok %v (want a usage error)", sub, rc, ok)
		}
	}
	// a step whose command exits 2 is not a usage error
	h2 := newHX(t, &sys.Fake{Handle: func(sys.Cmd) int { return 2 }})
	if rc, ok := h2.x.Main([]string{"step", "x", "--", "false"}); !ok || rc != 2 {
		t.Errorf("exit code of the command: rc %d ok %v", rc, ok)
	}
}
