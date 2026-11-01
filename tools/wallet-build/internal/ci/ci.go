// Package ci ports tools/ci-status.sh: CI results of a commit from the GitHub check runs and the ci-logs branch.
package ci

import (
	"regexp"
	"strings"
	"time"

	"wallet-build/internal/run"
)

// Repo is the GitHub repository whose check runs are read.
const Repo = "marcelicmateo/buggetwallet"

// CI reads CI results.
type CI struct {
	C     *run.Ctx
	Sleep func(time.Duration) // a variable for the tests
}

// New returns a CI with the real sleep.
func New(c *run.Ctx) *CI { return &CI{C: c, Sleep: time.Sleep} }

const (
	pollEvery = 20 * time.Second
	waitLimit = 30 * time.Minute
)

func (x *CI) git(args ...string) (string, int) {
	return x.C.Capture(x.C.Root, append([]string{"git"}, args...)...)
}

func (x *CI) gitQuiet(args ...string) (string, int) {
	return x.C.CaptureQuiet(x.C.Root, append([]string{"git"}, args...)...)
}

// Capture runs the version control tool with args in the repository (for `times --ci`).
func (x *CI) Capture(args ...string) (string, int) { return x.git(args...) }

// ShowLog is the text of <name>.txt on the ci-logs branch.
func (x *CI) ShowLog(name string) (string, int) { return x.showLog(name, x.git) }

func (x *CI) showLog(name string, git func(...string) (string, int)) (string, int) {
	if _, rc := git("fetch", "-q", "origin", "ci-logs:refs/remotes/origin/ci-logs"); rc != 0 {
		return "", rc
	}
	return git("show", "origin/ci-logs:"+name+".txt")
}

func (x *CI) checkRuns(sha string) (string, int) {
	return x.C.Capture(x.C.Root, "gh", "api", "repos/"+Repo+"/commits/"+sha+"/check-runs", "--jq",
		`.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "-")"`)
}

// Column is `column -t -s <tab>`: columns padded to their widest cell, separated by two spaces, the last one left alone.
func Column(table string) string {
	var rows [][]string
	var widths []int
	for _, line := range strings.Split(table, "\n") {
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		rows = append(rows, f)
		for i, c := range f {
			if i >= len(widths) {
				widths = append(widths, 0)
			}
			if n := len([]rune(c)); n > widths[i] {
				widths[i] = n
			}
		}
	}
	var sb strings.Builder
	for _, f := range rows {
		for i, c := range f {
			if i == len(f)-1 {
				sb.WriteString(c)
			} else {
				sb.WriteString(c + strings.Repeat(" ", widths[i]-len([]rune(c))+2))
			}
		}
		sb.WriteString("\n")
	}
	return sb.String()
}

var (
	reFail = regexp.MustCompile(`(?i)error|fail|exception|Some tests failed|\[E\]`)
	reSkip = regexp.MustCompile(`(?i)continue-on-error|0 errors`)
)

func hasCheck(table, name string) bool {
	for _, l := range strings.Split(table, "\n") {
		if strings.HasPrefix(l, name+"\t") {
			return true
		}
	}
	return false
}

// Log is `ci log [name]`.
func (x *CI) Log(args []string) int {
	name := "latest"
	if len(args) > 0 {
		name = args[0]
	}
	out, rc := x.ShowLog(name)
	if rc != 0 {
		return rc
	}
	x.C.Printf("%s\n", out)
	return 0
}

func line3(log string) string {
	l := strings.Split(log, "\n")
	if len(l) >= 3 {
		return l[2]
	}
	return ""
}

// Status is `ci status [--wait] [<sha>]`: 0 all green, 1 something failed, 2 still running.
func (x *CI) Status(args []string) int {
	c := x.C
	wait := false
	if len(args) > 0 && args[0] == "--log" { // tools/ci-status.sh --log [name]
		return x.Log(args[1:])
	}
	if len(args) > 0 && args[0] == "--wait" {
		wait, args = true, args[1:]
	}
	ref := "HEAD"
	if len(args) > 0 {
		ref = args[0]
	}
	sha, rc := x.git("rev-parse", ref)
	if rc != 0 {
		return 1
	}
	if br, _ := x.gitQuiet("branch", "-r", "--contains", sha); !strings.Contains(br, "origin/") {
		c.Eprintf("note: %s is not on GitHub yet (push it first)\n", sha[:min(7, len(sha))])
	}
	start := c.Clock()
	var table string
	pending := 0
	for {
		table, rc = x.checkRuns(sha)
		if rc != 0 {
			return 1
		}
		pending = 0
		for _, l := range strings.Split(table, "\n") {
			if f := strings.Split(l, "\t"); l != "" && len(f) > 1 && f[1] != "completed" {
				pending++
			}
		}
		elapsed := c.Clock().Sub(start)
		// the "log" job merges the others and is created last; more jobs can also appear after the first ones finish: until
		// its check run is there the commit counts as pending (all green needs it), for the whole wait
		if !hasCheck(table, "log") {
			pending++
		}
		if !wait || (table != "" && pending == 0) || elapsed >= waitLimit {
			break
		}
		x.Sleep(pollEvery)
	}
	c.Printf("commit %s\n", sha[:min(7, len(sha))])
	if table == "" {
		c.Printf("no check runs yet\n")
		return 2
	}
	c.Printf("%s", Column(table))
	failed := 0
	for _, l := range strings.Split(table, "\n") {
		f := strings.Split(l, "\t")
		if len(f) == 3 && f[1] == "completed" && f[2] != "success" && f[2] != "skipped" && f[2] != "neutral" {
			failed++
		}
	}
	latest, _ := x.showLog("latest", x.gitQuiet)
	match := strings.Contains(strings.SplitN(latest, "\n", 2)[0], sha)
	if failed > 0 {
		c.Printf("\n")
		if match {
			c.Printf("%s\n--- failing lines (full log: wallet-build ci log) ---\n", line3(latest))
			n := 0
			for i, l := range strings.Split(latest, "\n") {
				if reFail.MatchString(l) && !reSkip.MatchString(l) && n < 40 {
					c.Printf("%d:%s\n", i+1, l)
					n++
				}
			}
		} else {
			c.Printf("ci-logs/latest.txt is for another commit; see wallet-build ci log\n")
		}
		return 1
	}
	if pending > 0 {
		c.Printf("still running\n")
		return 2
	}
	c.Printf("all green\n")
	if match { // step outcomes with seconds
		c.Printf("%s\n", line3(latest))
	}
	return 0
}

// Main dispatches `ci status|log`; rc 2 with ok=false is a usage error.
func (x *CI) Main(args []string) (rc int, ok bool) {
	if len(args) == 0 {
		return 2, false
	}
	switch args[0] {
	case "status":
		return x.Status(args[1:]), true
	case "log":
		return x.Log(args[1:]), true
	}
	return 2, false
}
