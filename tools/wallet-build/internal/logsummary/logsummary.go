// Package logsummary is `wallet-build log-summary` (port of tools/log-summary.py): a summary of a Budget Wallet app log (Plan >
// Diagnostics > Save logs, or dist/logs/app-emulator.log). Counts per level and logger, every WARNING/SEVERE record, a perf table
// per timed operation, frame windows, memory, startup phases and the last lifecycle states. The logs hold no amounts or
// descriptions (see the package CLAUDE.md files); this tool only counts and times.
package logsummary

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"wallet-build/internal/pyfmt"
	"wallet-build/internal/report"
)

// Usage is what no arguments and -h print (the docstring of the script), with exit code 2.
const Usage = `Summary of a Budget Wallet log (Plan > Diagnostics > Save logs, or dist/logs/app-emulator.log).

    wallet-build log-summary <logfile> [more logfiles...]

Prints counts per level and logger, every WARNING/SEVERE record, a perf table per timed operation (bw.perf),
frame windows (bw.frames), memory (bw.mem) and startup phases (app.start).

Line format (wallet_core formatLogRecord):
    2026-10-16T19:01:02.123+02:00 DEBUG bw.import import.done {"rows":312,"dupes":4,"ms":41}
followed by optional "  error: ..." and two-space indented stack lines.`

var (
	reLine     = regexp.MustCompile(`^(\d{4}-\d\d-\d\dT[\d:.]+[+-]\d\d:\d\d) (\S+) (\S+) (\S+)(?: (\{.*\}))?$`)
	levelOrder = []string{"FINEST", "FINER", "DEBUG", "FINE", "CONFIG", "INFO", "WARNING", "SEVERE", "SHOUT"}
)

type record struct {
	time, level, logger, event string
	fields                     report.Obj
	extra                      []string
}

func (r *record) line() string {
	f := ""
	if len(r.fields) > 0 {
		f = " " + report.Dumper{Compact: true}.Dump(r.fields)
	}
	return fmt.Sprintf("%s %s %s %s%s", r.time, r.level, r.logger, r.event, f)
}

func (r *record) get(k string) (any, bool) { return r.fields.Get(k) }

// dedupe makes duplicate keys behave like OrderedDict(pairs): the first position, the last value.
func dedupe(v any) any {
	switch x := v.(type) {
	case report.Obj:
		out := report.Obj{}
		for _, kv := range x {
			val := dedupe(kv.V)
			found := false
			for i := range out {
				if out[i].K == kv.K {
					out[i].V, found = val, true
					break
				}
			}
			if !found {
				out = append(out, report.KV{K: kv.K, V: val})
			}
		}
		return out
	case []any:
		for i := range x {
			x[i] = dedupe(x[i])
		}
	}
	return v
}

// readText reads a file like Python's text mode with errors="replace": invalid bytes become U+FFFD, \r\n and \r become \n.
func readText(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var sb strings.Builder
	for len(b) > 0 {
		r, size := utf8.DecodeRune(b)
		if r == utf8.RuneError && size == 1 {
			sb.WriteRune(utf8.RuneError)
		} else {
			sb.Write(b[:size])
		}
		b = b[size:]
	}
	s := strings.ReplaceAll(sb.String(), "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	lines := strings.Split(s, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines, nil
}

func parse(paths []string) (records []*record, unparsed int, err error) {
	for _, path := range paths {
		lines, err := readText(path)
		if err != nil {
			return nil, 0, err
		}
		for _, raw := range lines {
			if strings.HasPrefix(raw, "  ") && len(records) > 0 {
				last := records[len(records)-1]
				last.extra = append(last.extra, raw[2:])
				continue
			}
			m := reLine.FindStringSubmatch(raw)
			if m == nil {
				if strings.TrimSpace(raw) != "" {
					unparsed++
				}
				continue
			}
			fields := report.Obj{}
			if m[5] != "" {
				if o, err := report.ParseObj(m[5]); err == nil {
					fields = dedupe(o).(report.Obj)
				}
			}
			records = append(records, &record{time: m[1], level: m[2], logger: m[3], event: m[4], fields: fields})
		}
	}
	return records, unparsed, nil
}

// number is a JSON number as Python holds it: int or float.
type number struct {
	v     float64
	float bool
}

func asNum(v any) (number, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return number{}, false
	}
	f, err := n.Float64()
	if err != nil {
		return number{}, false
	}
	return number{f, strings.ContainsAny(n.String(), ".eE")}, true
}

func numOf(r *record, k string) (number, bool) {
	v, ok := r.get(k)
	if !ok {
		return number{}, false
	}
	return asNum(v)
}

// orZero is `num(x) or 0`.
func orZero(n number, ok bool) number {
	if !ok || n.v == 0 {
		return number{}
	}
	return n
}

func (a number) plus(b number) number { return number{a.v + b.v, a.float || b.float} }

// String is str() of the number.
func (a number) String() string {
	if a.float {
		return report.PyFloat(a.v)
	}
	return strconv.FormatFloat(a.v, 'f', 0, 64)
}

// fmtFloat is the script's fmt() for numbers: whole values without decimals, others with one.
func fmtFloat(f float64) string {
	if f == math.Trunc(f) && !math.IsInf(f, 0) {
		return strconv.FormatFloat(f, 'f', 0, 64)
	}
	return strconv.FormatFloat(f, 'f', 1, 64)
}

func fmtAny(v any, ok bool) string {
	if !ok || v == nil {
		return "-"
	}
	if n, isNum := v.(json.Number); isNum {
		if !strings.ContainsAny(n.String(), ".eE") {
			return pyfmt.Repr(n)
		}
		if f, err := n.Float64(); err == nil {
			return fmtFloat(f)
		}
	}
	return pyfmt.Str(v)
}

func section(out io.Writer, title string) { fmt.Fprintf(out, "\n== %s ==\n", title) }

func table(out io.Writer, rows [][]string, header []string) {
	all := append([][]string{header}, rows...)
	widths := make([]int, len(header))
	for _, r := range all {
		for i, c := range r {
			if n := utf8.RuneCountInString(c); n > widths[i] {
				widths[i] = n
			}
		}
	}
	for _, r := range all {
		parts := make([]string, len(r))
		for i, c := range r {
			if i == 0 {
				parts[i] = pyfmt.PadRight(c, widths[i])
			} else {
				parts[i] = pyfmt.PadLeft(c, widths[i])
			}
		}
		fmt.Fprintf(out, "  %s\n", strings.Join(parts, "  "))
	}
}

// ordered counts keys in order of first appearance.
type ordered struct {
	keys []string
	n    map[string]int
}

func newOrdered() *ordered { return &ordered{n: map[string]int{}} }

func (o *ordered) inc(k string) {
	if _, ok := o.n[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.n[k]++
}

// Run summarises the logs named in args. It returns 2 (usage), 1 (no records, unreadable file) or 0.
func Run(args []string, out, errw io.Writer) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprintln(out, Usage)
		return 2
	}
	records, unparsed, err := parse(args)
	if err != nil {
		fmt.Fprintf(errw, "log-summary: %v\n", err)
		return 1
	}
	if len(records) == 0 {
		fmt.Fprintln(out, "no log records found")
		return 1
	}
	more := ""
	if unparsed > 0 {
		more = fmt.Sprintf(", %d unparsed lines", unparsed)
	}
	fmt.Fprintf(out, "%d records, %s .. %s%s\n", len(records), records[0].time, records[len(records)-1].time, more)

	section(out, "Levels")
	levels, loggers := newOrdered(), newOrdered()
	for _, r := range records {
		levels.inc(r.level)
		loggers.inc(r.logger)
	}
	rankOf := func(lv string) int {
		for i, l := range levelOrder {
			if l == lv {
				return i
			}
		}
		return 99
	}
	ks := append([]string(nil), levels.keys...)
	sort.SliceStable(ks, func(i, j int) bool { return rankOf(ks[i]) < rankOf(ks[j]) })
	parts := make([]string, len(ks))
	for i, k := range ks {
		parts[i] = fmt.Sprintf("%s=%d", k, levels.n[k])
	}
	fmt.Fprintf(out, "  %s\n", strings.Join(parts, "  "))

	section(out, "Loggers")
	names := append([]string(nil), loggers.keys...)
	sort.Slice(names, func(i, j int) bool {
		if loggers.n[names[i]] != loggers.n[names[j]] {
			return loggers.n[names[i]] > loggers.n[names[j]]
		}
		return names[i] < names[j]
	})
	for _, n := range names {
		fmt.Fprintf(out, "  %6d  %s\n", loggers.n[n], n)
	}

	section(out, "App")
	for _, r := range records {
		if r.event == "app.info" {
			kv := make([]string, len(r.fields))
			for i, f := range r.fields {
				kv[i] = f.K + "=" + pyfmt.Str(f.V)
			}
			fmt.Fprintf(out, "  %s\n", strings.Join(kv, ", "))
		}
	}

	section(out, "Startup (app.start, ms)")
	type run struct {
		time   string
		phases []string // "phase value"
		index  map[string]int
	}
	var runs []*run
	var cur *run
	for _, r := range records {
		if r.event != "app.start" {
			continue
		}
		var phaseV any = "?"
		if v, ok := r.get("phase"); ok {
			phaseV = v
		}
		phase := pyfmt.Repr(phaseV)
		seen := false
		if cur != nil {
			_, seen = cur.index[phase]
		}
		if cur == nil || phase == "'logs'" || seen {
			cur = &run{time: r.time, index: map[string]int{}}
			runs = append(runs, cur)
		}
		var extra []string
		for _, f := range r.fields {
			if f.K != "phase" && f.K != "ms" {
				extra = append(extra, f.K+"="+pyfmt.Str(f.V))
			}
		}
		msV, msOK := r.get("ms")
		val := fmtAny(msV, msOK)
		if len(extra) > 0 {
			val += " (" + strings.Join(extra, ", ") + ")"
		}
		entry := pyfmt.Str(phaseV) + " " + val
		if i, ok := cur.index[phase]; ok {
			cur.phases[i] = entry
		} else {
			cur.index[phase] = len(cur.phases)
			cur.phases = append(cur.phases, entry)
		}
	}
	if len(runs) == 0 {
		fmt.Fprintln(out, "  none")
	}
	for _, r := range runs {
		fmt.Fprintf(out, "  %s: %s\n", r.time, strings.Join(r.phases, " | "))
	}

	section(out, "Warnings and errors")
	var bad []*record
	for _, r := range records {
		if r.level == "WARNING" || r.level == "SEVERE" || r.level == "SHOUT" {
			bad = append(bad, r)
		}
	}
	if len(bad) == 0 {
		fmt.Fprintln(out, "  none")
	}
	for _, r := range bad {
		fmt.Fprintf(out, "  %s\n", r.line())
		for i := 0; i < len(r.extra) && i < 4; i++ {
			fmt.Fprintf(out, "      %s\n", r.extra[i])
		}
		if len(r.extra) > 4 {
			fmt.Fprintf(out, "      ... %d more lines\n", len(r.extra)-4)
		}
	}

	section(out, "Perf (bw.perf, ms)")
	perf := map[string][]float64{}
	var perfOrder []string
	warns := map[string]int{}
	for _, r := range records {
		if r.logger != "bw.perf" {
			continue
		}
		if n, ok := numOf(r, "ms"); ok {
			if _, seen := perf[r.event]; !seen {
				perfOrder = append(perfOrder, r.event)
			}
			perf[r.event] = append(perf[r.event], n.v)
			if r.level == "WARNING" {
				warns[r.event]++
			}
		}
	}
	if len(perf) == 0 {
		fmt.Fprintln(out, "  none")
	} else {
		sort.SliceStable(perfOrder, func(i, j int) bool { return pyfmt.Sum(perf[perfOrder[i]]) > pyfmt.Sum(perf[perfOrder[j]]) })
		var rows [][]string
		for _, name := range perfOrder {
			s := append([]float64(nil), perf[name]...)
			sort.Float64s(s)
			p50, _ := pyfmt.Rank(s, 50)
			p90, _ := pyfmt.Rank(s, 90)
			warn := ""
			if warns[name] > 0 {
				warn = strconv.Itoa(warns[name])
			}
			rows = append(rows, []string{name, strconv.Itoa(len(s)), fmtFloat(p50), fmtFloat(p90), fmtFloat(s[len(s)-1]), fmtFloat(pyfmt.Sum(s)), warn})
		}
		table(out, rows, []string{"name", "count", "p50", "p90", "max", "total", "warn"})
	}

	section(out, "Frames (bw.frames)")
	var windows, slow []*record
	for _, r := range records {
		switch r.event {
		case "frames.window":
			windows = append(windows, r)
		case "frames.slow":
			slow = append(slow, r)
		}
	}
	if len(windows) == 0 {
		fmt.Fprintln(out, "  no frame windows")
	} else {
		var frames, janky number
		maxOf := func(key string) float64 {
			m := 0.0
			for _, r := range windows {
				if n := orZero(numOf(r, key)); n.v > m {
					m = n.v
				}
			}
			return m
		}
		for _, r := range windows {
			frames = frames.plus(orZero(numOf(r, "frames")))
			janky = janky.plus(orZero(numOf(r, "janky")))
		}
		pct := 0.0
		if frames.v != 0 {
			pct = 100.0 * janky.v / frames.v
		}
		fmt.Fprintf(out, "  %d windows, %s frames, %s janky (%.1f%%)\n", len(windows), frames, janky, pct)
		fmt.Fprintf(out, "  worst p99: build %s ms, raster %s ms; max: build %s ms, raster %s ms\n",
			fmtFloat(maxOf("build_p99_ms")), fmtFloat(maxOf("raster_p99_ms")), fmtFloat(maxOf("build_max_ms")), fmtFloat(maxOf("raster_max_ms")))
		type tab struct{ frames, janky number }
		tabs := map[string]*tab{}
		var tabOrder []string
		for _, r := range windows {
			var tv any = "?"
			if v, ok := r.get("tab"); ok {
				tv = v
			}
			k := pyfmt.Str(tv)
			t, ok := tabs[k]
			if !ok {
				t = &tab{}
				tabs[k] = t
				tabOrder = append(tabOrder, k)
			}
			t.frames = t.frames.plus(orZero(numOf(r, "frames")))
			t.janky = t.janky.plus(orZero(numOf(r, "janky")))
		}
		tp := make([]string, len(tabOrder))
		for i, k := range tabOrder {
			tp[i] = fmt.Sprintf("%s %s frames/%s janky", k, tabs[k].frames, tabs[k].janky)
		}
		fmt.Fprintf(out, "  by tab: %s\n", strings.Join(tp, ", "))
	}
	fmt.Fprintf(out, "  slow frames (>100 ms): %d\n", len(slow))
	for i := 0; i < len(slow) && i < 10; i++ {
		fmt.Fprintf(out, "    %s\n", slow[i].line())
	}

	section(out, "Memory (bw.mem, MB)")
	var rss, peak []float64
	for _, r := range records {
		if r.event != "mem" {
			continue
		}
		if n, ok := numOf(r, "rss_mb"); ok {
			rss = append(rss, n.v)
		}
		if n, ok := numOf(r, "max_rss_mb"); ok {
			peak = append(peak, n.v)
		}
	}
	if len(rss) > 0 {
		lo, hi := rss[0], rss[0]
		for _, x := range rss {
			lo, hi = math.Min(lo, x), math.Max(hi, x)
		}
		peakS := "-"
		if len(peak) > 0 {
			p := peak[0]
			for _, x := range peak {
				p = math.Max(p, x)
			}
			peakS = fmtFloat(p)
		}
		fmt.Fprintf(out, "  rss min %s, max %s, last %s (%d samples); peak max_rss %s\n", fmtFloat(lo), fmtFloat(hi), fmtFloat(rss[len(rss)-1]), len(rss), peakS)
	} else {
		fmt.Fprintln(out, "  none")
	}

	section(out, "Lifecycle")
	var states []string
	for _, r := range records {
		if r.event == "lifecycle" {
			v, ok := r.get("state")
			if !ok {
				v = nil
			}
			states = append(states, pyfmt.Str(v))
		}
	}
	if len(states) == 0 {
		fmt.Fprintln(out, "  none")
	} else {
		if len(states) > 20 {
			states = states[len(states)-20:]
		}
		fmt.Fprintf(out, "  %s\n", strings.Join(states, " > "))
	}
	return 0
}
