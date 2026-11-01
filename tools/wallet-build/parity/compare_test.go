//go:build parity

package parity

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

var (
	reSecsField = regexp.MustCompile(`^\d+\.\d$`)
	reISOOnly   = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2}|Z)$`)
	reBucket    = regexp.MustCompile(`^\s+(<10 ms|10-50 ms|50-100 ms|100-500 ms|0\.5-1 s|1-5 s|>5 s)\s`)
	reSumHead   = regexp.MustCompile(`^--- (\S+): (\d+) tests, (\d+) failed`)
	reSlowRow   = regexp.MustCompile(`^\s+\d+ ms\s+.*?(\[\w+\])?$`)
	reStageRow  = regexp.MustCompile(`^(\S+)\s+[\d.]+ s\s+(ok|FAILED)\b`)
)

// environment-dependent files: the pub step only runs when package resolution is stale, which the first of the two
// runs may clear for the second. They are ignored on both sides (documented in README.md).
func envDependent(name string) bool {
	return name == "pub.log" || name == "pub.status"
}

func runFiles(dir string) []string {
	var out []string
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		r, _ := filepath.Rel(dir, p)
		if !envDependent(r) {
			out = append(out, r)
		}
		return nil
	})
	sort.Strings(out)
	return out
}

func read(p string) (string, bool) {
	b, err := os.ReadFile(p)
	return string(b), err == nil
}

func compareRun(t *testing.T, c Case, a, b *side, i int) {
	t.Helper()
	da, db := a.runs[i], b.runs[i]
	label := "runs/" + maskRunName(filepath.Base(da)) + "/"
	cn := c.Name
	fa, fb := runFiles(da), runFiles(db)
	if !diffLines(t, cn, label+" file names", fa, fb) {
		return
	}
	// last.status
	la, lb := lastStatus(t, cn, a, da), lastStatus(t, cn, b, db)
	if c.Unordered {
		la, lb = sorted(la), sorted(lb)
	}
	diffLines(t, cn, label+"last.status (step ok|failed, order)", la, lb)
	// last-failed.txt
	xa, _ := read(filepath.Join(da, "last-failed.txt"))
	xb, _ := read(filepath.Join(db, "last-failed.txt"))
	diffLines(t, cn, label+"last-failed.txt", a.m.table(xa), b.m.table(xb))
	// <step>.status and stamp lines of the logs that belong to a status
	for _, f := range fa {
		if !strings.HasSuffix(f, ".status") || f == "last.status" || strings.Contains(f, "/") {
			continue
		}
		sa, _ := read(filepath.Join(da, f))
		sb, _ := read(filepath.Join(db, f))
		diffLines(t, cn, label+f+" (exit field)", statusFields(t, cn, f, sa), statusFields(t, cn, f, sb))
		lg := strings.TrimSuffix(f, ".status") + ".log"
		ga, okA := read(filepath.Join(da, lg))
		gb, okB := read(filepath.Join(db, lg))
		if okA && okB {
			diffLines(t, cn, label+lg+" (first and last stamp line)", ends(a.m, ga), ends(b.m, gb))
		}
	}
	// summaries
	for _, f := range fa {
		switch {
		case strings.HasPrefix(f, "tests-") && strings.HasSuffix(f, "-summary.txt"):
			sa, _ := read(filepath.Join(da, f))
			sb, _ := read(filepath.Join(db, f))
			diffLines(t, cn, label+f+" (structure)", summaryStructure(a.m, sa), summaryStructure(b.m, sb))
		case f == "stage-summary.txt":
			sa, _ := read(filepath.Join(da, f))
			sb, _ := read(filepath.Join(db, f))
			diffLines(t, cn, label+f+" (structure)", stageStructure(a.m, sa), stageStructure(b.m, sb))
		}
	}
}

// lastStatus: "<step> ok|failed" per line in file order; the seconds field must look like 12.3 on both sides.
func lastStatus(t *testing.T, cn string, s *side, dir string) []string {
	raw, _ := read(filepath.Join(dir, "last.status"))
	var out []string
	for _, ln := range lines(raw) {
		f := strings.Fields(ln)
		if len(f) != 3 || (f[1] != "ok" && f[1] != "failed") || !reSecsField.MatchString(f[2]) {
			t.Errorf("parity[%s] %s last.status: line %q is not '<step> ok|failed <secs, one decimal>'", cn, s.impl, ln)
		}
		if len(f) > 0 && f[0] == "pub" {
			continue
		}
		out = append(out, strings.Join(f[:min(2, len(f))], " "))
	}
	return out
}

// statusFields: "<secs one decimal> <exit> <iso start>"; the exit field is compared (desktop merges write `bad`).
func statusFields(t *testing.T, cn, file, raw string) []string {
	f := strings.Fields(raw)
	if len(f) != 3 || !(reSecsField.MatchString(f[0])) || !reISOOnly.MatchString(f[2]) {
		t.Errorf("parity[%s] %s: %q is not '<secs one decimal> <exit> <iso start>'", cn, file, strings.TrimSpace(raw))
		return []string{"<malformed>"}
	}
	return []string{"exit=" + f[1]}
}

func ends(m *masker, log string) []string {
	ls := lines(log)
	if len(ls) == 0 {
		return []string{"<empty log>"}
	}
	return []string{m.text(ls[0]), m.text(ls[len(ls)-1])}
}

// summaryStructure keeps the header (suite, test count, failures), the bucket labels, the slowest rows' count and
// their [result] marks; every number that is a time or a histogram count is dropped.
func summaryStructure(m *masker, txt string) []string {
	var out []string
	for _, ln := range lines(txt) {
		switch {
		case reSumHead.MatchString(ln):
			g := reSumHead.FindStringSubmatch(ln)
			out = append(out, fmt.Sprintf("header %s tests=%s failed=%s", g[1], g[2], g[3]))
		case reBucket.MatchString(ln):
			out = append(out, "bucket "+reBucket.FindStringSubmatch(ln)[1])
		case strings.TrimSpace(ln) == "slowest:":
			out = append(out, "slowest:")
		case reSlowRow.MatchString(ln):
			out = append(out, "row "+reSlowRow.FindStringSubmatch(ln)[1])
		default:
			out = append(out, m.text(ln))
		}
	}
	return out
}

// stageStructure: step rows keep name and result; the slowest-tests list after its header is dropped (timing only).
func stageStructure(m *masker, txt string) []string {
	var out []string
	for _, ln := range lines(txt) {
		if g := reStageRow.FindStringSubmatch(ln); g != nil {
			out = append(out, "step "+g[1]+" "+g[2])
			continue
		}
		out = append(out, m.text(ln))
		if strings.HasPrefix(ln, "--- slowest") {
			break
		}
	}
	return out
}

// ---- history ----

type jline struct {
	raw     string
	keys    []string
	vals    map[string]string
	spaced  bool // json.dumps spacing (Python lines) instead of the compact bash lines
	failure string
}

var reSpacedStart = regexp.MustCompile(`^\{"[^"]+": `)

func parseJL(raw string) jline {
	j := jline{raw: raw, vals: map[string]string{}, spaced: reSpacedStart.MatchString(raw)}
	dec := json.NewDecoder(strings.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		j.failure = "not a JSON object"
		return j
	}
	for dec.More() {
		k, err := dec.Token()
		if err != nil {
			j.failure = err.Error()
			return j
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			j.failure = err.Error()
			return j
		}
		ks := k.(string)
		j.keys = append(j.keys, ks)
		j.vals[ks] = string(bytes.TrimSpace(v))
	}
	return j
}

// fields whose values are times, ids or load dependent: compared for presence and order only.
func maskedKey(file, key string) bool {
	switch key {
	case "ts", "run", "seconds", "time":
		return true
	}
	switch file {
	case "steps.jsonl":
		switch key {
		case "total_ms", "p50", "p90", "p99", "max", "slowest", "slowest_ms":
			return true
		}
	case "tests.jsonl":
		return key == "ms"
	case "perf.jsonl":
		return strings.HasSuffix(key, "_ms") || strings.HasPrefix(key, "missed_") || key == "frame_count" || key == "ok" || key == "shader_events"
	}
	return false
}

func historyLines(s *side, file string) []jline {
	raw, _ := read(filepath.Join(s.data, "history", file))
	var out []jline
	for _, ln := range lines(raw) {
		j := parseJL(ln)
		if file == "steps.jsonl" && j.vals["step"] == `"pub"` {
			continue // environment dependent, see envDependent
		}
		out = append(out, j)
	}
	return out
}

func compareHistory(t *testing.T, c Case, a, b *side) {
	t.Helper()
	for _, file := range []string{"steps.jsonl", "tests.jsonl", "perf.jsonl"} {
		ja, jb := historyLines(a, file), historyLines(b, file)
		na, nb := render(a, file, ja), render(b, file, jb)
		// within a suite the test order follows completion; steps of parallel units finish in any order
		if file == "tests.jsonl" || (c.Unordered && file != "perf.jsonl") {
			sort.Strings(na)
			sort.Strings(nb)
		}
		for _, x := range []struct {
			s  *side
			js []jline
		}{{a, ja}, {b, jb}} {
			for i, j := range x.js {
				if j.failure != "" {
					t.Errorf("parity[%s] %s history/%s line %d: %s: %q", c.Name, x.s.impl, file, i+1, j.failure, j.raw)
				}
				if s, ok := j.vals["seconds"]; ok && !reSecsField.MatchString(s) {
					t.Errorf("parity[%s] %s history/%s line %d: seconds %s is not one decimal (12.0 style)", c.Name, x.s.impl, file, i+1, s)
				}
			}
		}
		diffLines(t, c.Name, "history/"+file, na, nb)
	}
}

// render: key order, spacing style and every unmasked value on one comparable line.
func render(s *side, file string, js []jline) []string {
	var out []string
	for _, j := range js {
		var sb strings.Builder
		if j.spaced {
			sb.WriteString("[json.dumps spacing] ")
		} else {
			sb.WriteString("[compact] ")
		}
		for _, k := range j.keys {
			v := j.vals[k]
			if maskedKey(file, k) {
				v = "<masked>"
			} else {
				v = s.m.text(v)
			}
			fmt.Fprintf(&sb, "%s=%s ", k, v)
		}
		out = append(out, strings.TrimSpace(sb.String()))
	}
	return out
}
