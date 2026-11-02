package report

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

// Config is where the report commands read and write (tools/build_log.py's ROOT, DATA, LOGS and environment).
type Config struct {
	Root string
	Data string
	Logs string // the run dir, or dist/logs
	Env  sys.Env
	Now  func() time.Time
	Out  io.Writer
}

// FromCtx builds the report config of a run context.
func FromCtx(c *run.Ctx, logs string) Config {
	return Config{Root: c.Root, Data: c.Data, Logs: logs, Env: c.Env, Now: c.Clock, Out: c.Out}
}

func (c Config) steps() string { return filepath.Join(c.Data, "history", "steps.jsonl") }
func (c Config) tests() string { return filepath.Join(c.Data, "history", "tests.jsonl") }
func (c Config) perf() string  { return filepath.Join(c.Data, "history", "perf.jsonl") }

func (c Config) now() string { return c.Now().Format("2006-01-02T15:04:05-07:00") }

func (c Config) pr(format string, a ...any) { fmt.Fprintf(c.Out, format, a...) }

// meta is build_log.py meta(): the fields every history line starts with.
func (c Config) meta() Obj {
	runID := c.Env.Get("BW_RUN_ID")
	if runID == "" {
		runID = c.Env.Get("BW_RUN")
	}
	if runID == "" {
		runID = c.now()
	}
	or := func(k, d string) string {
		if v, ok := c.Env.Lookup(k); ok {
			return v
		}
		return d
	}
	return Obj{
		{"ts", c.now()},
		{"run", runID},
		{"source", or("BW_SOURCE", "local")},
		{"worktree", or("BW_WORKTREE", filepath.Base(c.Root))},
		{"commit", or("BW_COMMIT", "unknown")},
		{"cmd", or("BW_CMD", "?")},
		{"image", c.Env.Get("BW_IMAGE")},
		{"cold", c.Env.Get("BW_COLD") == "1"},
	}
}

func appendObjs(path string, objs []Obj) {
	for _, o := range objs {
		_ = run.AppendLine(path, PyJSON(o)+"\n")
	}
}

// readObjs reads a JSON-lines file, skipping lines that are not objects.
func readObjs(path string) []Obj {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []Obj
	sc := bufio.NewReaderSize(f, 1<<20)
	for {
		line, err := sc.ReadString('\n')
		if strings.TrimSpace(line) != "" {
			if o, perr := ParseObj(line); perr == nil {
				out = append(out, o)
			}
		}
		if err != nil {
			break
		}
	}
	return out
}

// readTestObjs reads history/tests.jsonl (hundreds of MB) with the fast decoder: only the fields `trend` uses.
func readTestObjs(path string) []Obj {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []Obj
	r := bufio.NewReaderSize(f, 1<<20)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 1 {
			var row struct {
				TS    string      `json:"ts"`
				Run   string      `json:"run"`
				Suite string      `json:"suite"`
				Test  string      `json:"test"`
				MS    json.Number `json:"ms"`
			}
			d := json.NewDecoder(strings.NewReader(string(line)))
			d.UseNumber()
			if d.Decode(&row) == nil && row.Run != "" {
				out = append(out, Obj{{"ts", row.TS}, {"run", row.Run}, {"suite", row.Suite}, {"test", row.Test}, {"ms", row.MS}})
			}
		}
		if err != nil {
			break
		}
	}
	return out
}

func get(o Obj, k string) any { v, _ := o.Get(k); return v }

func str(o Obj, k, def string) string {
	v, ok := o.Get(k)
	if !ok {
		return def
	}
	return Str(v)
}

// ---- test reports ----

// Test is one test result: name, milliseconds, result.
type Test struct {
	Name   string
	MS     int64
	Result string
}

type event struct {
	Type string `json:"type"`
	Test *struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"test"`
	Time        *int64  `json:"time"`
	TestID      *int    `json:"testID"`
	Hidden      bool    `json:"hidden"`
	Skipped     bool    `json:"skipped"`
	Result      *string `json:"result"`
	MessageType string  `json:"messageType"`
	Message     string  `json:"message"`
}

// scanEvents calls fn for each JSON line of a package:test reporter file that parses as an event.
func scanEvents(path string, fn func(e *event)) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	r := bufio.NewReaderSize(f, 1<<20)
	for {
		line, err := r.ReadBytes('\n')
		if len(strings.TrimSpace(string(line))) > 0 {
			var e event
			if json.Unmarshal(line, &e) == nil {
				fn(&e)
			}
		}
		if err != nil {
			return nil
		}
	}
}

// ParseReporter is parse_reporter_json: the tests of a JSON reporter file (hidden entries skipped) and the "done" time.
func ParseReporter(path string) (tests []Test, total *int64, err error) {
	type start struct {
		name string
		t    int64
	}
	starts := map[int]start{}
	err = scanEvents(path, func(e *event) {
		switch e.Type {
		case "testStart":
			if e.Test != nil {
				var t int64
				if e.Time != nil {
					t = *e.Time
				}
				starts[e.Test.ID] = start{e.Test.Name, t}
			}
		case "testDone":
			if e.Hidden || e.TestID == nil {
				return
			}
			s, ok := starts[*e.TestID]
			if !ok {
				s = start{"?", 0}
			}
			var t int64
			if e.Time != nil {
				t = *e.Time
			}
			res := "?"
			if e.Result != nil {
				res = *e.Result
			}
			if e.Skipped {
				res = "skipped"
			}
			tests = append(tests, Test{s.name, t - s.t, res})
		case "done":
			total = e.Time
		}
	})
	return
}

var driveLine = regexp.MustCompile(`I/flutter \(\s*\d+\): (\d+):(\d+) \+(\d+)(?: ~(\d+))?(?: -(\d+))?: (.*)$`)

// ParseDrive is parse_drive_log: per-test durations from the compact reporter lines `flutter drive` relays (1 s resolution).
func ParseDrive(path string) (tests []Test, total *int64, err error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	type ev struct {
		sec, ok, bad, skip int
		name               string
	}
	var events []ev
	for _, line := range strings.Split(strings.ToValidUTF8(string(b), "�"), "\n") {
		line = strings.TrimRight(line, "\r")
		m := driveLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		mi, _ := strconv.Atoi(m[1])
		s, _ := strconv.Atoi(m[2])
		ok, _ := strconv.Atoi(m[3])
		skip, _ := strconv.Atoi(m[4])
		bad, _ := strconv.Atoi(m[5])
		events = append(events, ev{mi*60 + s, ok, bad, skip, m[6]})
	}
	for i := 0; i+1 < len(events); i++ {
		e, nxt := events[i], events[i+1]
		if strings.HasPrefix(e.name, "(") || strings.Contains(e.name, "tests passed") || strings.Contains(e.name, "tests failed") || strings.Contains(e.name, "tests skipped") {
			continue
		}
		res := "?"
		if nxt.ok > e.ok {
			res = "success"
		} else if nxt.bad > e.bad {
			res = "failure"
		} else if nxt.skip > e.skip { // "All tests skipped." and skipped tests: the ~N counter went up
			res = "skipped"
		}
		tests = append(tests, Test{e.name, int64(nxt.sec-e.sec) * 1000, res})
	}
	if len(events) > 0 {
		t := int64(events[len(events)-1].sec) * 1000
		total = &t
	}
	return tests, total, nil
}

type bucket struct {
	hi    int64
	label string
}

var buckets = []bucket{{10, "<10 ms"}, {50, "10-50 ms"}, {100, "50-100 ms"}, {500, "100-500 ms"}, {1000, "0.5-1 s"}, {5000, "1-5 s"}, {math.MaxInt64, ">5 s"}}

// pct is the nearest-rank percentile of sorted values.
func pct(sorted []int64, p int) int64 {
	if len(sorted) == 0 {
		return 0
	}
	k := (p*len(sorted)+99)/100 - 1
	if k < 0 {
		k = 0
	}
	if k > len(sorted)-1 {
		k = len(sorted) - 1
	}
	return sorted[k]
}

// Stats are the per-suite numbers of a history line.
type Stats struct {
	Count, Failed int
	TotalMS       int64
	P50, P90, P99 int64
	Max           int64
	Slowest       string
	SlowestMS     int64
}

func (s Stats) obj() Obj {
	return Obj{{"count", s.Count}, {"failed", s.Failed}, {"total_ms", s.TotalMS}, {"p50", s.P50}, {"p90", s.P90}, {"p99", s.P99},
		{"max", s.Max}, {"slowest", s.Slowest}, {"slowest_ms", s.SlowestMS}}
}

// Summarise is summarise(): the stats and the printed summary (no final newline).
func Summarise(suite string, tests []Test, total *int64) (Stats, string) {
	ms := make([]int64, len(tests))
	failed := 0
	for i, t := range tests {
		ms[i] = t.MS
		if t.Result != "success" && t.Result != "skipped" {
			failed++
		}
	}
	sort.Slice(ms, func(i, j int) bool { return ms[i] < ms[j] })
	st := Stats{Count: len(tests), Failed: failed, P50: pct(ms, 50), P90: pct(ms, 90), P99: pct(ms, 99)}
	if total != nil {
		st.TotalMS = *total
	} else {
		for _, v := range ms {
			st.TotalMS += v
		}
	}
	if len(ms) > 0 {
		st.Max = ms[len(ms)-1]
	}
	slow := append([]Test(nil), tests...)
	sort.SliceStable(slow, func(i, j int) bool { return slow[i].MS > slow[j].MS })
	if len(slow) > 10 {
		slow = slow[:10]
	}
	if len(slow) > 0 {
		st.Slowest, st.SlowestMS = slow[0].Name, slow[0].MS
	}
	var lines []string
	lines = append(lines, fmt.Sprintf("--- %s: %d tests, %d failed, total %.1f s; per test p50 %d ms, p90 %d ms, p99 %d ms, max %d ms",
		suite, st.Count, st.Failed, float64(st.TotalMS)/1000, st.P50, st.P90, st.P99, st.Max))
	counts := make([]int, len(buckets))
	for _, v := range ms {
		for i, b := range buckets {
			if v < b.hi {
				counts[i]++
				break
			}
		}
	}
	width := 0
	for _, c := range counts {
		if c > width {
			width = c
		}
	}
	if width == 0 {
		width = 1
	}
	for i, b := range buckets {
		lines = append(lines, fmt.Sprintf("  %10s %5d  %s", b.label, counts[i],
			strings.Repeat("#", int(math.RoundToEven(40*float64(counts[i])/float64(width))))))
	}
	lines = append(lines, "  slowest:")
	for _, t := range slow {
		tail := ""
		if t.Result != "success" {
			tail = "  [" + t.Result + "]"
		}
		lines = append(lines, fmt.Sprintf("  %8d ms  %s%s", t.MS, t.Name, tail))
	}
	return st, strings.Join(lines, "\n")
}

// RecordSuite prints the summary, writes tests-<suite>-summary.txt and appends the suite and test history lines.
func (c Config) RecordSuite(suite string, tests []Test, total *int64, kind string) {
	st, text := Summarise(suite, tests, total)
	c.pr("%s\n", text)
	_ = os.MkdirAll(c.Logs, 0o755)
	_ = os.WriteFile(filepath.Join(c.Logs, "tests-"+suite+"-summary.txt"), []byte(text+"\n"), 0o644)
	m := c.meta()
	rec := append(append(Obj{}, m...), KV{"step", suite}, KV{"kind", kind})
	rec = append(rec, st.obj()...)
	appendObjs(c.steps(), []Obj{rec})
	lines := make([]Obj, 0, len(tests))
	for _, t := range tests {
		lines = append(lines, Obj{{"ts", get(m, "ts")}, {"run", get(m, "run")}, {"source", get(m, "source")}, {"commit", get(m, "commit")},
			{"suite", suite}, {"test", t.Name}, {"ms", t.MS}, {"result", t.Result}})
	}
	appendObjs(c.tests(), lines)
}

// Tests is `build_log.py tests|drive <suite> <paths…>`: several reporter files are shards of one suite.
func (c Config) Tests(kind, suite string, paths []string) {
	var found []string
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			found = append(found, p)
		}
	}
	if len(found) == 0 {
		first := ""
		if len(paths) > 0 {
			first = paths[0]
		}
		c.pr("--- %s: no test report at %s\n", suite, first)
		return
	}
	var all []Test
	var total *int64
	for _, p := range found {
		var t []Test
		var tt *int64
		var err error
		if kind == "tests" {
			t, tt, err = ParseReporter(p)
		} else {
			t, tt, err = ParseDrive(p)
		}
		if err != nil {
			continue
		}
		all = append(all, t...)
		if tt != nil {
			v := *tt
			if total != nil {
				v += *total
			}
			total = &v
		}
	}
	c.RecordSuite(suite, all, total, kind)
}

// ---- tables ----

func runeLen(s string) int { return utf8.RuneCountInString(s) }

func pad(s string, w int, left bool) string {
	n := w - runeLen(s)
	if n <= 0 {
		return s
	}
	if left {
		return s + strings.Repeat(" ", n)
	}
	return strings.Repeat(" ", n) + s
}

// Table is table(): columns separated by two spaces, the first left-aligned, the rest right-aligned.
func Table(rows [][]string, header []string) string {
	all := append([][]string{header}, rows...)
	widths := make([]int, len(header))
	for _, r := range all {
		for i := range header {
			if i < len(r) && runeLen(r[i]) > widths[i] {
				widths[i] = runeLen(r[i])
			}
		}
	}
	var sb strings.Builder
	for _, r := range all {
		for i := range header {
			if i > 0 {
				sb.WriteString("  ")
			}
			cell := ""
			if i < len(r) {
				cell = r[i]
			}
			sb.WriteString(pad(cell, widths[i], i == 0))
		}
		sb.WriteString("\n")
	}
	return sb.String()
}

func trunc(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

// ---- perf ----

// Perf is `build_log.py perf <records>`: the table (perf-summary.txt) and history/perf.jsonl.
func (c Config) Perf(path string) {
	recs := readObjs(path)
	if len(recs) == 0 {
		c.pr("--- perf: no records at %s\n", path)
		return
	}
	m := c.meta()
	keep := Obj{{"run", get(m, "run")}, {"source", get(m, "source")}, {"worktree", get(m, "worktree")}}
	var lines []Obj
	for _, r := range recs {
		lines = append(lines, keep.Merge(r))
	}
	appendObjs(c.perf(), lines)
	f1 := func(r Obj, k string) string {
		v, _ := Num(get(r, k))
		return fmt.Sprintf("%.1f", v)
	}
	var rows [][]string
	for _, r := range recs {
		okS := "OVER"
		if v, ok := Num(get(r, "ok")); ok && v != 0 {
			okS = "ok"
		}
		shader := ""
		if v, ok := r.Get("shader_events"); ok {
			shader = Str(v)
		}
		rows = append(rows, []string{str(r, "action", ""), str(r, "frame_count", "0"), f1(r, "build_p90_ms"), f1(r, "build_max_ms"),
			f1(r, "raster_p90_ms"), f1(r, "raster_max_ms"), str(r, "missed_build_frames", "0"), str(r, "missed_raster_frames", "0"), shader, okS})
	}
	header := []string{"perf action", "frames", "build p90", "build max", "raster p90", "raster max", "missed b", "missed r", "shader ev", ""}
	text := Table(rows, header)
	c.pr("%s", text)
	_ = os.MkdirAll(c.Logs, 0o755)
	_ = os.WriteFile(filepath.Join(c.Logs, "perf-summary.txt"), []byte(text), 0o644)
}

// ---- order ----

func median(v []float64) float64 {
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// Order is `build_log.py order`: desktop-test units "name:index:total", slowest first by recent history.
func (c Config) Order(specs []string) []string {
	secs := map[string][]float64{}
	for _, r := range readObjs(c.steps()) {
		step := str(r, "step", "")
		if !strings.HasPrefix(step, "desktop-") {
			continue
		}
		if k, ok := r.Get("kind"); ok && k != nil {
			continue
		}
		if f, ok := Num(get(r, "seconds")); ok {
			secs[step[len("desktop-"):]] = append(secs[step[len("desktop-"):]], f)
		}
	}
	type unit struct {
		weight float64
		name   string
		i, n   int
	}
	var units []unit
	for _, spec := range specs {
		name, n, _ := strings.Cut(spec, ":")
		shards := 1
		if v, err := strconv.Atoi(n); err == nil && v > 1 {
			shards = v
		}
		w := math.Inf(1)
		if h, ok := secs[name]; ok {
			if len(h) > 5 {
				h = h[len(h)-5:]
			}
			w = median(h) / float64(shards)
		}
		for i := 0; i < shards; i++ {
			units = append(units, unit{w, name, i, shards})
		}
	}
	sort.SliceStable(units, func(a, b int) bool { return units[a].weight > units[b].weight })
	out := make([]string, len(units))
	for i, u := range units {
		out[i] = fmt.Sprintf("%s:%d:%d", u.name, u.i, u.n)
	}
	return out
}

// ---- times and trend ----

// when is the step start in local time (containers write UTC).
func when(r Obj) string {
	ts := str(r, "ts", "")
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05"} {
		var t time.Time
		var err error
		if layout == time.RFC3339 {
			t, err = time.Parse(layout, ts)
		} else {
			t, err = time.ParseInLocation(layout, ts, time.Local)
		}
		if err == nil {
			return t.Local().Format("2006-01-02 15:04")
		}
	}
	return trunc(ts, 16)
}

// TimesOpts are the flags of `times`.
type TimesOpts struct {
	N       int
	Cmd     string
	Step    string
	Commit  string
	Source  string
	CIFiles []string
}

func tailN[T any](s []T, n int) []T {
	// Python s[-n:]
	start := len(s) - n
	if n <= 0 {
		start = -n
		if n == 0 {
			start = 0
		}
	}
	if start < 0 {
		start = 0
	}
	if start > len(s) {
		start = len(s)
	}
	return s[start:]
}

func isSuiteKind(r Obj) bool {
	k := str(r, "kind", "")
	return k == "tests" || k == "drive"
}

// Times is `build_log.py times`.
func (c Config) Times(o TimesOpts) {
	hist := readObjs(c.steps())
	for _, p := range o.CIFiles {
		hist = append(hist, readObjs(p)...)
	}
	var keep []Obj
	for _, r := range hist {
		if o.Cmd != "" && str(r, "cmd", "None") != o.Cmd {
			continue
		}
		if o.Commit != "" && !strings.HasPrefix(str(r, "commit", ""), o.Commit) {
			continue
		}
		if o.Source != "" && str(r, "source", "local") != o.Source {
			continue
		}
		keep = append(keep, r)
	}
	hist = keep
	type key struct{ source, run string }
	type runT struct {
		key key
		rs  []Obj
	}
	var runs []*runT
	idx := map[key]*runT{}
	for _, r := range hist {
		if _, has := r.Get("seconds"); isSuiteKind(r) || !has {
			continue
		}
		k := key{str(r, "source", "local"), str(r, "run", "None")}
		if idx[k] == nil {
			idx[k] = &runT{key: k}
			runs = append(runs, idx[k])
		}
		idx[k].rs = append(idx[k].rs, r)
	}
	if o.Step != "" {
		var f []*runT
		for _, rt := range runs {
			for _, r := range rt.rs {
				if str(r, "step", "") == o.Step {
					f = append(f, rt)
					break
				}
			}
		}
		runs = f
	}
	runs = tailN(runs, o.N)
	if len(runs) == 0 {
		suffix := ""
		if len(o.CIFiles) > 0 {
			suffix = " or the CI history"
		}
		c.pr("no matching history in %s%s\n", c.steps(), suffix)
		return
	}
	var names []string
	if o.Step != "" {
		names = []string{o.Step}
	} else {
		seen := map[string]bool{}
		for _, rt := range runs {
			for _, r := range rt.rs {
				if s := str(r, "step", ""); !seen[s] {
					seen[s] = true
					names = append(names, s)
				}
			}
		}
	}
	var rows [][]string
	for _, rt := range runs {
		by := map[string]Obj{}
		cold := false
		for _, r := range rt.rs {
			by[str(r, "step", "")] = r
			if b, ok := get(r, "cold").(bool); ok && b {
				cold = true
			}
		}
		row := []string{when(rt.rs[0]), rt.key.source, str(rt.rs[0], "cmd", ""), str(rt.rs[0], "commit", ""), ""}
		if cold {
			row[4] = "cold"
		}
		for _, n := range names {
			r, ok := by[n]
			if !ok {
				row = append(row, "")
				continue
			}
			s, _ := Num(get(r, "seconds"))
			cell := fmt.Sprintf("%.1f", s)
			if str(r, "result", "None") != "ok" {
				cell += "!"
			}
			row = append(row, cell)
		}
		rows = append(rows, row)
	}
	c.pr("last %d runs, seconds per step (! = failed):\n", len(runs))
	c.pr("%s", Table(rows, append([]string{"started", "source", "cmd", "commit", ""}, names...)))
	c.pr("\nmedian seconds per step (successful, not cold):\n")
	var med [][]string
	var sources []string
	seenSrc := map[string]bool{}
	for _, rt := range runs {
		if !seenSrc[rt.key.source] {
			seenSrc[rt.key.source] = true
			sources = append(sources, rt.key.source)
		}
	}
	for _, n := range names {
		for _, src := range sources {
			var vals []float64
			for _, rt := range runs {
				if rt.key.source != src {
					continue
				}
				for _, r := range rt.rs {
					cold, _ := get(r, "cold").(bool)
					if str(r, "step", "") == n && str(r, "result", "None") == "ok" && !cold {
						s, _ := Num(get(r, "seconds"))
						vals = append(vals, s)
					}
				}
			}
			if len(vals) > 0 {
				med = append(med, []string{n, src, fmt.Sprintf("%.1f", median(vals)), strconv.Itoa(len(vals))})
			}
		}
	}
	c.pr("%s", Table(med, []string{"step", "source", "median", "runs"}))
	runIDs := map[string]bool{}
	for _, rt := range runs {
		runIDs[rt.key.run] = true
	}
	var srows [][]string
	for _, r := range hist {
		if !isSuiteKind(r) || !runIDs[str(r, "run", "None")] || (o.Step != "" && str(r, "step", "") != o.Step) {
			continue
		}
		srows = append(srows, []string{when(r), str(r, "source", "local"), str(r, "step", ""), str(r, "count", "None"), str(r, "p50", "None"),
			str(r, "p90", "None"), str(r, "p99", "None"), str(r, "max", "None"),
			str(r, "slowest_ms", "None") + " " + trunc(str(r, "slowest", "None"), 60)})
	}
	if len(srows) > 0 {
		c.pr("\ntest suites (per-test ms):\n")
		c.pr("%s", Table(srows, []string{"started", "source", "suite", "tests", "p50", "p90", "p99", "max", "slowest"}))
	}
}

// TrendOpts are the flags of `trend`.
type TrendOpts struct {
	N    int
	Top  int
	Step string
}

// Trend is `build_log.py trend`: the slowest tests over the last runs.
func (c Config) Trend(o TrendOpts) {
	var hist []Obj
	for _, r := range readTestObjs(c.tests()) {
		if o.Step == "" || str(r, "suite", "") == o.Step {
			hist = append(hist, r)
		}
	}
	var allRuns []string
	seen := map[string]bool{}
	for _, r := range hist {
		if s := str(r, "run", ""); !seen[s] {
			seen[s] = true
			allRuns = append(allRuns, s)
		}
	}
	runs := tailN(allRuns, o.N)
	if len(runs) == 0 {
		c.pr("no history in %s\n", c.tests())
		return
	}
	inRuns := map[string]bool{}
	for _, r := range runs {
		inRuns[r] = true
	}
	type tk struct{ suite, test string }
	type entry struct {
		key tk
		by  map[string]float64
		raw map[string]string
	}
	var entries []*entry
	idx := map[tk]*entry{}
	started := map[string]string{}
	for _, r := range hist {
		run := str(r, "run", "")
		if !inRuns[run] {
			continue
		}
		k := tk{str(r, "suite", ""), str(r, "test", "")}
		e := idx[k]
		if e == nil {
			e = &entry{key: k, by: map[string]float64{}, raw: map[string]string{}}
			idx[k] = e
			entries = append(entries, e)
		}
		v, _ := Num(get(r, "ms"))
		e.by[run] = v
		e.raw[run] = str(r, "ms", "")
		if _, ok := started[run]; !ok {
			started[run] = when(r)[5:]
		}
	}
	maxOf := func(e *entry) float64 {
		m := math.Inf(-1)
		for _, v := range e.by {
			m = math.Max(m, v)
		}
		return m
	}
	sort.SliceStable(entries, func(a, b int) bool { return maxOf(entries[a]) > maxOf(entries[b]) })
	if o.Top >= 0 && len(entries) > o.Top {
		entries = entries[:o.Top]
	}
	c.pr("slowest %d tests over the last %d runs (ms, oldest -> newest):\n", len(entries), len(runs))
	header := []string{"test"}
	for _, r := range runs {
		header = append(header, started[r])
	}
	var rows [][]string
	for _, e := range entries {
		row := []string{trunc(e.key.suite+": "+e.key.test, 70)}
		for _, r := range runs {
			row = append(row, e.raw[r])
		}
		rows = append(rows, row)
	}
	c.pr("%s", Table(rows, header))
}

// ---- CI history ----

// CIHistory is `build_log.py ci-history <times.txt>`: JSON lines for the ci-logs branch.
func (c Config) CIHistory(timesPath string) {
	sha := c.Env.Get("GITHUB_SHA")
	if sha == "" {
		sha = "unknown"
	}
	meta := Obj{{"ts", c.now()}, {"run", orStr(c.Env.Get("GITHUB_RUN_ID"), "?")}, {"source", "ci"}, {"worktree", ""},
		{"commit", trunc(sha, 7)}, {"cmd", "ci"}, {"image", c.Env.Get("ImageOS")}, {"cold", false}}
	var out []Obj
	if b, err := os.ReadFile(timesPath); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			p := strings.Fields(line)
			if len(p) != 3 {
				continue
			}
			f, err := strconv.ParseFloat(p[1], 64)
			if err != nil {
				continue
			}
			res := "FAILED"
			if p[2] == "0" {
				res = "ok"
			}
			out = append(out, meta.Merge(Obj{{"step", p[0]}, {"seconds", f}, {"result", res}}))
		}
	}
	var override Obj
	for _, k := range []string{"run", "source", "worktree", "commit", "cmd"} {
		override = append(override, KV{k, get(meta, k)})
	}
	for _, r := range readObjs(c.steps()) {
		if str(r, "kind", "") == "tests" {
			out = append(out, r.Merge(override))
		}
	}
	for _, r := range out {
		c.pr("%s\n", PyJSON(r))
	}
}

func orStr(s, d string) string {
	if s == "" {
		return d
	}
	return s
}
