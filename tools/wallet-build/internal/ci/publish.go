package ci

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"wallet-build/internal/sys"
)

var reTokenURL = regexp.MustCompile(`x-access-token:[^@\s]*@`)

// scrub removes the credential from git's output: the URL form always, the token value wherever it shows up.
func scrub(s, token string) string {
	s = reTokenURL.ReplaceAllString(s, "x-access-token:***@")
	if len(token) >= 4 {
		s = strings.ReplaceAll(s, token, "***")
	}
	return s
}

const publishAttempts = 5

// remoteURL is where the ci-logs branch lives: the repository with the token, or the Remote override of the tests.
func (x *CI) remoteURL() string {
	if x.Remote != "" {
		return x.Remote
	}
	return "https://x-access-token:" + x.C.Getenv("GH_TOKEN") + "@github.com/" + x.C.Getenv("GITHUB_REPOSITORY")
}

// gitScrubbed runs git with all output scrubbed of the token and sent to our stderr.
func (x *CI) gitScrubbed(dir string, args ...string) int {
	var buf bytes.Buffer
	rc := x.C.R.Run(x.C.Ctx, sys.Cmd{Argv: append([]string{"git"}, args...), Dir: dir,
		Env: x.C.Env.With("GIT_TERMINAL_PROMPT", "0"), Stdout: &buf, Stderr: &buf})
	if buf.Len() > 0 {
		x.C.Eprintf("%s", scrub(buf.String(), x.C.Getenv("GH_TOKEN")))
	}
	return rc
}

// PublishLog is `ci publish-log <name> <logfile> [<history.jsonl>]`: pushes the log to the ci-logs branch as <name>.txt, headed
// "commit: <sha>  ref: <ref>  run: <id>" and a blank line, and appends the history lines to history.jsonl there. Up to five
// attempts (a concurrent job may push first), waiting 3, 6, 9, 12 s. A log identical to the last one is not an error.
func (x *CI) PublishLog(args []string) int {
	c := x.C
	if len(args) < 2 || len(args) > 3 || args[0] == "" {
		return 2
	}
	name, logPath, histPath := args[0], args[1], ""
	if len(args) == 3 {
		histPath = args[2]
	}
	url := x.remoteURL()
	tmp := c.Getenv("RUNNER_TEMP")
	if tmp == "" {
		tmp = "/tmp"
	}
	work := filepath.Join(tmp, "logs-"+name)
	sha := c.Getenv("GITHUB_SHA")
	header := "commit: " + sha + "  ref: " + c.Getenv("GITHUB_REF_NAME") + "  run: " + c.Getenv("GITHUB_RUN_ID") + "\n\n"
	body, _ := os.ReadFile(logPath)
	var hist []byte
	if histPath != "" {
		if st, err := os.Stat(histPath); err == nil && st.Size() > 0 {
			hist, _ = os.ReadFile(histPath)
		}
	}
	_ = os.RemoveAll(work)
	for attempt := 1; attempt <= publishAttempts; attempt++ {
		if x.gitScrubbed("", "clone", "-q", "--depth", "1", "--branch", "ci-logs", url, work) != 0 {
			c.Eprintf("clone of ci-logs failed (first run, or an error above): starting a fresh branch\n")
			_ = os.RemoveAll(work)
			if os.MkdirAll(work, 0o755) != nil || x.gitScrubbed(work, "init", "-q", "-b", "ci-logs") != 0 ||
				x.gitScrubbed(work, "remote", "add", "origin", url) != 0 {
				c.Eprintf("cannot start a fresh ci-logs branch\n")
			}
		}
		if err := os.WriteFile(filepath.Join(work, name+".txt"), append([]byte(header), body...), 0o644); err != nil {
			c.Eprintf("cannot write %s.txt: %v\n", name, err)
		}
		x.gitScrubbed(work, "config", "user.name", "ci-bot")
		x.gitScrubbed(work, "config", "user.email", "ci-bot@users.noreply.github.com")
		x.gitScrubbed(work, "add", name+".txt")
		if len(hist) > 0 {
			if f, err := os.OpenFile(filepath.Join(work, "history.jsonl"), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644); err == nil {
				_, _ = f.Write(hist)
				f.Close()
			}
			x.gitScrubbed(work, "add", "history.jsonl")
		}
		if x.gitScrubbed(work, "commit", "-q", "-m", "log "+name+" "+sha) != 0 {
			c.Eprintf("nothing to commit\n")
			return 0
		}
		if x.gitScrubbed(work, "push", "-q", "origin", "HEAD:ci-logs") == 0 {
			return 0
		}
		_ = os.RemoveAll(work)
		x.Sleep(time.Duration(attempt*3) * time.Second)
	}
	c.Eprintf("could not publish log\n")
	return 1
}
