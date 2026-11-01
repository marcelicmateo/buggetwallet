package ci

import (
	"os"
	"path/filepath"
	"strings"

	"wallet-build/internal/report"
)

// flagValues reads "--name value" and "--name=value" pairs; ok is false for an unknown flag, a missing value or stray words.
func flagValues(args []string, names ...string) (map[string]string, bool) {
	vals := map[string]string{}
	known := map[string]bool{}
	for _, n := range names {
		known[n] = true
	}
	for i := 0; i < len(args); i++ {
		k, v, hasV := strings.Cut(args[i], "=")
		if !known[k] {
			return nil, false
		}
		if !hasV {
			if i+1 >= len(args) {
				return nil, false
			}
			i++
			v = args[i]
		}
		vals[k] = v
	}
	return vals, true
}

// timesColumn2 is the awk of the old job-log action: "(<secs>s)" for every line of times.txt whose first word is step.
func timesColumn2(times, step string) string {
	var sb strings.Builder
	for _, l := range strings.Split(times, "\n") {
		if f := strings.Fields(l); len(f) >= 2 && f[0] == step {
			sb.WriteString("(" + f[1] + "s)")
		}
	}
	return sb.String()
}

// JobLog is `ci job-log --job J --outcomes "step=outcome …"`: the body of the job-log action. It writes
// $RUNNER_TEMP/joblog/{outcome.txt,times.txt,ci.log,history.jsonl}, which the action then uploads as ci-log-<job>.
// outcome.txt is the outcomes with the seconds of each step from times.txt, e.g. "signing=success apk=success(412s)".
func (x *CI) JobLog(args []string) int {
	c := x.C
	v, ok := flagValues(args, "--job", "--outcomes")
	if !ok || v["--job"] == "" {
		return 2
	}
	tmp := x.tempDir()
	d := filepath.Join(tmp, "joblog")
	if err := os.MkdirAll(d, 0o755); err != nil {
		c.Eprintf("ci job-log: %v\n", err)
		return 1
	}
	timesPath := filepath.Join(tmp, "times.txt")
	if f, err := os.OpenFile(timesPath, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644); err == nil { // touch
		f.Close()
	}
	times, _ := os.ReadFile(timesPath)
	var parts []string
	for _, kv := range strings.Fields(v["--outcomes"]) {
		name, _, _ := strings.Cut(kv, "=")
		parts = append(parts, kv+timesColumn2(string(times), name))
	}
	write := func(name string, b []byte) bool {
		if err := os.WriteFile(filepath.Join(d, name), b, 0o644); err != nil {
			c.Eprintf("ci job-log: %v\n", err)
			return false
		}
		return true
	}
	if !write("outcome.txt", []byte(strings.Join(parts, " ")+"\n")) || !write("times.txt", times) {
		return 1
	}
	if p := c.Getenv("LOG"); p != "" { // cp "$LOG" ci.log 2>/dev/null || true
		if b, err := os.ReadFile(p); err == nil {
			write("ci.log", b)
		}
	}
	h, err := os.Create(filepath.Join(d, "history.jsonl"))
	if err != nil {
		c.Eprintf("ci job-log: %v\n", err)
		return 1
	}
	defer h.Close()
	cfg := report.FromCtx(c, filepath.Join(c.Root, "dist", "logs"))
	cfg.Out = h
	cfg.CIHistory(timesPath)
	return 0
}
