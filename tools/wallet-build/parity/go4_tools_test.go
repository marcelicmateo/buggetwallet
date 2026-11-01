//go:build parity

package parity

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// ---------------- token-usage ----------------

type tuLine struct {
	typ, ts, rid, msgID, model, reqModel string
	in, cw, cr, out                      int
	nullOut                              bool
}

func (l tuLine) json() string {
	usage := map[string]any{"input_tokens": l.in, "cache_creation_input_tokens": l.cw, "cache_read_input_tokens": l.cr, "output_tokens": l.out}
	if l.nullOut {
		usage["output_tokens"] = nil
	}
	msg := map[string]any{"usage": usage}
	if l.msgID != "" {
		msg["id"] = l.msgID
	}
	if l.model != "" {
		msg["model"] = l.model
	}
	rec := map[string]any{"type": l.typ, "timestamp": l.ts, "message": msg}
	if l.rid != "" {
		rec["requestId"] = l.rid
	}
	if l.reqModel != "" {
		rec["requestedModel"] = l.reqModel
	}
	return jsonLine(rec)
}

func tuA(ts, rid, model string, in, cw, cr, out int) tuLine {
	return tuLine{typ: "assistant", ts: ts, rid: rid, model: model, in: in, cw: cw, cr: cr, out: out}
}

// tuTranscripts writes synthetic Claude Code transcripts for the sandbox repo under the sandbox HOME.
func tuTranscripts(t *testing.T, sb *sandbox) {
	dash := strings.NewReplacer("/", "-", ".", "-").Replace(sb.repo)
	pd := filepath.Join(sb.home, ".claude", "projects", dash)
	cat := func(ls ...string) string { return strings.Join(ls, "") }
	sid1 := "aaaaaaaa-1111-4111-8111-111111111111"
	sid2 := "bbbbbbbb-2222-4222-8222-222222222222"
	// main session 1: duplicate request ids (a request is logged once per content block, the last has the final count)
	main1 := cat(
		tuA("2026-03-01T08:00:00.000Z", "r1", "model-a", 100, 5, 7, 10).json(),
		tuA("2026-03-01T08:00:01.000Z", "r1", "model-a", 100, 5, 7, 250).json(), // most output tokens wins
		tuA("2026-03-01T08:00:02.000Z", "r1", "model-a", 100, 5, 7, 40).json(),  // later but lower: ignored
		tuA("2026-03-01T09:00:00.000Z", "r2", "model-b", 1000, 0, 123456, 20).json(),
		tuA("2026-03-01T10:00:00.000Z", "r3", "model-a", 100, 0, 0, 30).json(), // tie: the first line stays
		tuA("2026-03-01T10:00:01.000Z", "r3", "model-a", 999, 1, 1, 30).json(),
		tuLine{typ: "user", ts: "2026-03-01T10:30:00.000Z", rid: "r9", model: "model-a", in: 5000, out: 5000}.json(), // not assistant
		"this is not json but mentions \"usage\"\n",
		"{\"type\":\"summary\"}\n",
		tuLine{typ: "assistant", ts: "2026-03-01T11:00:00.000Z", msgID: "msg_x", model: "model-b", in: 7, out: 3}.json(), // no requestId: message id
		tuLine{typ: "assistant", ts: "2026-03-01T11:30:00.000Z", rid: "r4", reqModel: "model-c", in: 2, out: 1}.json(),   // requestedModel fallback
		tuLine{typ: "assistant", ts: "2026-03-01T11:45:00.000Z", rid: "r5", in: 4, out: 2}.json(),                        // no model at all: "?"
		tuLine{typ: "assistant", ts: "2026-03-01T11:50:00.000Z", rid: "r6", model: "model-a", in: 1, nullOut: true}.json(),
		tuA("2026-03-02T00:00:00.000Z", "r7", "model-a", 10, 20, 30, 40).json(), // exactly midnight UTC: day 2026-03-02
		tuA("2026-03-01T23:59:59.999Z", "r8", "model-b", 11, 22, 33, 44).json(),
	)
	main2 := cat(
		tuA("2026-03-02T09:00:00.000Z", "r1", "model-a", 3, 3, 3, 3).json(), // same request id as in session 1: counted again
		tuA("2026-03-03T09:00:00.000Z", "r2", "model-b", 1_234_567, 0, 8_000_000, 99_999).json(),
	)
	ag1 := cat(tuA("2026-03-02T12:00:00.000Z", "g1", "model-a", 50, 60, 70, 80).json(), tuA("2026-03-02T12:00:05.000Z", "g1", "model-a", 50, 60, 70, 85).json())
	ag2 := cat(tuA("2026-03-04T12:00:00.000Z", "g2", "model-c", 5, 6, 7, 8).json())
	sb.write(filepath.Join(pd, sid1+".jsonl"), main1)
	sb.write(filepath.Join(pd, sid2+".jsonl"), main2)
	sb.write(filepath.Join(pd, sid1, "subagents", "agent-a1.jsonl"), ag1)
	sb.write(filepath.Join(pd, sid1, "subagents", "agent-a2.jsonl"), ag2)
	sb.write(filepath.Join(pd, sid1, "subagents", "notes.txt"), tuA("2026-03-01T01:00:00.000Z", "zz", "model-z", 9, 9, 9, 9).json()) // not .jsonl
	sb.write(filepath.Join(pd, sid2, "subagents", "agent-b1.jsonl"), "")
	// commits around the day borders (git log --since/--until are local time = TZ UTC here)
	for _, d := range []string{"2026-02-28T23:59:59+0000", "2026-03-01T12:00:00+0000", "2026-03-02T09:00:00+0000", "2026-03-02T23:59:59+0000",
		"2026-03-03T00:00:00+0000", "2026-03-04T10:00:00+0000"} {
		sb.git(d, "commit", "-q", "--allow-empty", "-m", "c "+d)
	}
}

func tuCase(name string, extra ...string) g4 {
	c := g4mk(name, append([]string{"tools/token-usage.py"}, extra...), append([]string{"token-usage"}, extra...))
	c.sbRepo, c.git, c.tools = true, true, []string{"token-usage.py"}
	c.prep = tuTranscripts
	c.want = 0
	return c
}

func TestGO4TokenUsage(t *testing.T) {
	jsonCase := tuCase("token_usage_json", "--json", "{WORK}/summary.json")
	jsonCase.files = []string{"work/summary.json"}
	jsonCase.mask = func(s string) string { return s }
	jsonRange := tuCase("token_usage_json_range", "--since", "2026-03-02", "--until", "2026-03-03", "--json", "{WORK}/s.json")
	jsonRange.files = []string{"work/s.json"}
	noCommits := tuCase("token_usage_no_commits_in_range", "--since", "2026-03-05")
	noCommits.want = 0
	empty := tuCase("token_usage_nothing_in_range", "--since", "2030-01-01", "--json", "{WORK}/e.json")
	empty.files = []string{"work/e.json"}
	noTranscripts := tuCase("token_usage_no_transcripts")
	noTranscripts.prep = func(t *testing.T, sb *sandbox) { sb.git(day1, "commit", "-q", "--allow-empty", "-m", "x") }
	noTranscripts.want = 1
	badFlag := tuCase("token_usage_bad_flag", "--sinse", "2026")
	badFlag.want, badFlag.exitOnly = 2, true
	for _, c := range []g4{
		tuCase("token_usage_all"),
		tuCase("token_usage_since", "--since", "2026-03-02"),
		tuCase("token_usage_until", "--until", "2026-03-01"),
		tuCase("token_usage_since_until_same_day", "--since", "2026-03-02", "--until", "2026-03-02"),
		jsonCase, jsonRange, noCommits, empty, noTranscripts, badFlag,
	} {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}

// ---------------- log-summary ----------------

func lsLog(parts ...string) string { return strings.Join(parts, "\n") + "\n" }

func lsRec(sec int, level, logger, event, fields string) string {
	return fmt.Sprintf("2026-10-16T19:%02d:%02d.123+02:00 %s %s %s%s", sec/60, sec%60, level, logger, event, ifs(fields != "", " "+fields))
}

func ifs(c bool, s string) string {
	if c {
		return s
	}
	return ""
}

func lsFullLogs() (string, string) {
	var l []string
	l = append(l, "  stray indented line before any record is ignored")
	l = append(l, lsRec(1, "INFO", "bw.app", "app.info", `{"version":"1.2.3","platform":"linux","cores":8}`))
	// startup: two runs; a repeated phase and the "logs" phase start a new one
	l = append(l, lsRec(2, "DEBUG", "bw.app", "app.start", `{"phase":"logs","ms":3}`))
	l = append(l, lsRec(3, "DEBUG", "bw.app", "app.start", `{"phase":"db","ms":41.5,"rows":300}`))
	l = append(l, lsRec(4, "DEBUG", "bw.app", "app.start", `{"phase":"ui","ms":120.0}`))
	l = append(l, lsRec(5, "DEBUG", "bw.app", "app.start", `{"phase":"db","ms":7}`))
	l = append(l, lsRec(6, "DEBUG", "bw.app", "app.start", `{"phase":"first_frame"}`))
	// warnings: error line and a long stack (> 4 lines)
	l = append(l, lsRec(10, "WARNING", "bw.import", "import.slow", `{"rows":312,"ms":1.0,"x":1e3,"name":"Ćevapi \"A\"","nested":{"a":[1,2.50,true,null]},"tiny":0.10}`))
	l = append(l, "  error: Bad state: no element")
	for i := 1; i <= 6; i++ {
		l = append(l, fmt.Sprintf("  #%d  frame (package:wallet_core/src/x.dart:%d:1)", i, i))
	}
	l = append(l, lsRec(11, "SEVERE", "bw.sync", "sync.failed", ""))
	l = append(l, "  error: SocketException")
	l = append(l, lsRec(12, "SHOUT", "bw.sync", "sync.shout", `{"k":"v"}`))
	l = append(l, lsRec(13, "NOTICE", "bw.odd", "odd.level", `{"k":1}`)) // a level that is not in the list
	l = append(l, "this line does not parse")
	l = append(l, "")
	l = append(l, lsRec(14, "INFO", "bw.import", "import.done", `{"rows":312,"dupes":4,"ms":41}`))
	l = append(l, lsRec(15, "FINE", "bw.import", "import.bad_json", `{"rows":`)) // bad JSON: fields stay empty
	// perf: percentiles at the edges (n = 1, 2, 10, 11, 100) and values that are not numbers
	add := func(op string, n int, f func(i int) string, level string) {
		for i := 1; i <= n; i++ {
			l = append(l, lsRec(20+i%30, ifs(level != "", level)+ifs(level == "", "DEBUG"), "bw.perf", op, fmt.Sprintf(`{"ms":%s}`, f(i))))
		}
	}
	add("p.one", 1, func(i int) string { return "7" }, "")
	add("p.two", 2, func(i int) string { return fmt.Sprint(i * 10) }, "")
	add("p.ten", 10, func(i int) string { return fmt.Sprint(i) }, "")
	add("p.eleven", 11, func(i int) string { return fmt.Sprint(i * 2) }, "WARNING")
	add("p.hundred", 100, func(i int) string { return fmt.Sprintf("%d.5", 101-i) }, "")
	add("p.float", 3, func(i int) string { return []string{"2.0", "3.25", "0.04"}[i-1] }, "")
	l = append(l, lsRec(55, "DEBUG", "bw.perf", "p.junk", `{"ms":"fast"}`), lsRec(55, "DEBUG", "bw.perf", "p.bool", `{"ms":true}`),
		lsRec(55, "DEBUG", "bw.perf", "p.nomil", `{"rows":3}`))
	// frames
	l = append(l,
		lsRec(30, "DEBUG", "bw.frames", "frames.window", `{"tab":"spending","frames":600,"janky":12,"build_p99_ms":14.2,"raster_p99_ms":9,"build_max_ms":40,"raster_max_ms":22.5}`),
		lsRec(31, "DEBUG", "bw.frames", "frames.window", `{"tab":"plan","frames":300,"janky":0,"build_p99_ms":5,"raster_p99_ms":11.3,"build_max_ms":7,"raster_max_ms":60}`),
		lsRec(32, "DEBUG", "bw.frames", "frames.window", `{"tab":"spending","frames":100,"janky":1,"build_p99_ms":20,"raster_p99_ms":2,"build_max_ms":33,"raster_max_ms":2}`),
		lsRec(33, "DEBUG", "bw.frames", "frames.window", `{"frames":"x","janky":null}`))
	for i := 1; i <= 12; i++ {
		l = append(l, lsRec(34, "WARNING", "bw.frames", "frames.slow", fmt.Sprintf(`{"ms":%d,"tab":"plan"}`, 100+i)))
	}
	// memory
	l = append(l, lsRec(40, "DEBUG", "bw.mem", "mem", `{"rss_mb":120.5,"max_rss_mb":130}`), lsRec(41, "DEBUG", "bw.mem", "mem", `{"rss_mb":100,"max_rss_mb":200.25}`),
		lsRec(42, "DEBUG", "bw.mem", "mem", `{"rss_mb":150}`))
	// lifecycle: 25 transitions, the last 20 are listed
	states := []string{"resumed", "inactive", "paused", "resumed"}
	for i := 0; i < 25; i++ {
		l = append(l, lsRec(45, "DEBUG", "bw.app", "lifecycle", fmt.Sprintf(`{"state":"%s%d"}`, states[i%4], i)))
	}
	second := lsLog(
		lsRec(1, "INFO", "bw.app", "app.info", `{"version":"1.2.4"}`),
		lsRec(2, "DEBUG", "bw.app", "app.start", `{"phase":"logs","ms":2}`),
		lsRec(3, "DEBUG", "bw.app", "app.start", `{"phase":"db","ms":30}`),
		lsRec(4, "WARNING", "bw.sync", "sync.retry", `{"n":2}`),
		lsRec(5, "DEBUG", "bw.perf", "p.one", `{"ms":9}`),
		lsRec(6, "DEBUG", "bw.mem", "mem", `{"rss_mb":99,"max_rss_mb":99}`),
		lsRec(7, "DEBUG", "bw.app", "lifecycle", `{"state":"detached"}`),
	)
	return lsLog(l...), second
}

func TestGO4LogSummary(t *testing.T) {
	first, second := lsFullLogs()
	mk := func(name string, files map[string]string, args ...string) g4 {
		c := g4mk(name, append([]string{"tools/log-summary.py"}, args...), append([]string{"log-summary"}, args...))
		c.prep = func(t *testing.T, sb *sandbox) {
			for n, body := range files {
				sb.write(filepath.Join(sb.work, n), body)
			}
		}
		return c
	}
	one := mk("log_summary_all_sections", map[string]string{"a.log": first}, "a.log")
	one.want = 0
	two := mk("log_summary_two_files", map[string]string{"a.log": first, "b.log": second}, "a.log", "b.log")
	two.want = 0
	small := mk("log_summary_info_only", map[string]string{"s.log": lsLog(lsRec(1, "INFO", "bw.app", "app.info", `{"a":1}`))}, "s.log")
	small.want = 0
	empty := mk("log_summary_no_records", map[string]string{"e.log": "garbage\n  indented\n"}, "e.log")
	empty.want = 1
	zero := mk("log_summary_empty_file", map[string]string{"z.log": ""}, "z.log")
	zero.want = 1
	crlf := mk("log_summary_unicode_and_blank_lines", map[string]string{"u.log": "\n\n" + lsRec(1, "WARNING", "bw.x", "x.y", `{"naïve":"žćčđš","emoji":"\u00e9\ud83d\ude00"}`) + "\n\n"}, "u.log")
	crlf.want = 0
	noArgs := mk("log_summary_usage_no_args", nil)
	noArgs.want, noArgs.exitOnly = 2, true
	help := mk("log_summary_usage_help", nil, "-h")
	help.want, help.exitOnly = 2, true
	missing := mk("log_summary_missing_file", nil, "nope.log")
	missing.exitOnly = true // a Python traceback vs the Go message; both must fail the same way
	missing.check = func(t *testing.T, sb *sandbox, r *g4res) {
		if r.exit == 0 {
			t.Errorf("%s: a missing log file must not exit 0", sb.impl)
		}
	}
	for _, c := range []g4{one, two, small, empty, zero, crlf, noArgs, help, missing} {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}

// ---------------- lsp-query ----------------

func TestGO4LspQuery(t *testing.T) {
	mk := func(name string, want int, exitOnly bool, args ...string) g4 {
		c := g4mk(name, append([]string{"tools/lsp.py"}, args...), append([]string{"lsp-query"}, args...))
		c.inRepo, c.want, c.exitOnly = true, want, exitOnly
		return c
	}
	for _, c := range []g4{
		mk("lsp_query_usage_no_args", 2, true),
		mk("lsp_query_usage_unknown_kind", 2, true, "bogus", "a.dart:1:1"),
		mk("lsp_query_usage_kind_without_position", 2, true, "refs"),
		mk("lsp_query_bad_position_text", 1, false, "refs", "foo"),
		mk("lsp_query_bad_position_numbers", 1, false, "def", "packages/wallet_core/lib/src/dates.dart:x:y"),
		mk("lsp_query_missing_file", 1, false, "refs", "no/such/file.dart:1:1"),
		mk("lsp_query_bad_second_position", 1, false, "refs", "packages/wallet_core/lib/src/dates.dart:4:8", "oops"),
	} {
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
	// Heavy: the real server in the build container. `isoDate` is declared at dates.dart:4:8.
	dates := "packages/wallet_core/lib/src/dates.dart"
	for _, kind := range []string{"refs", "def"} {
		c := g4mk("lsp_query_"+kind+"_isoDate", []string{"tools/lsp.py", kind, dates + ":4:8"}, []string{"lsp-query", kind, dates + ":4:8"})
		c.inRepo, c.heavy, c.want, c.timeout = true, true, 0, 10*60*1e9
		c.check = func(t *testing.T, sb *sandbox, r *g4res) {
			if !strings.Contains(r.out, dates+":4:8") {
				t.Errorf("%s %s: output lacks the declaration %s:4:8:\n%s", sb.impl, kind, dates, tail(r.out))
			}
		}
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
	c := g4mk("lsp_query_two_positions_isoDate", []string{"tools/lsp.py", "def", dates + ":4:8", dates + ":8:36"},
		[]string{"lsp-query", "def", dates + ":4:8", dates + ":8:36"})
	c.inRepo, c.heavy, c.timeout = true, true, 10*60*1e9
	t.Run(c.name, func(t *testing.T) { runG4(t, c) })
}

// ---------------- mutate ----------------

func TestGO4MutateList(t *testing.T) {
	type pkg struct {
		name  string
		files []string
	}
	pkgs := []pkg{
		{"importer", []string{"lib/src/ids.dart", "lib/src/csv_reader.dart"}},
		{"core", []string{"lib/src/dates.dart", "lib/src/periods.dart"}},
		{"sync", []string{"lib/src/sync_digest.dart", "lib/src/blob_store.dart"}},
	}
	// The new side runs mutate through its host path (which starts the build container): heavy unless old vs old.
	for _, p := range pkgs {
		for _, seed := range []string{"1", "7"} {
			args := append(append([]string{p.name}, p.files...), "--list", "--seed", seed, "--max", "9")
			c := g4mk(fmt.Sprintf("mutate_list_%s_seed%s", p.name, seed), append([]string{"tools/mutate.py"}, args...), append([]string{"mutate"}, args...))
			c.inRepo, c.want, c.newContainer = true, 0, true
			c.check = func(t *testing.T, sb *sandbox, r *g4res) {
				for _, f := range p.files {
					if !strings.Contains(r.out, f+": ") || !strings.Contains(r.out, " mutants, ") {
						t.Errorf("%s: no '<file>: N mutants, M sampled' line for %s:\n%s", sb.impl, f, tail(r.out))
					}
				}
			}
			t.Run(c.name, func(t *testing.T) { runG4(t, c) })
		}
	}
	// Other spellings of the same file, the default sample size and the absolute path.
	for _, sp := range []struct{ name, file string }{
		{"repo_relative_path", "packages/wallet_core/lib/src/dates.dart"},
		{"absolute_path", "{REAL}/packages/wallet_core/lib/src/dates.dart"},
	} {
		c := g4mk("mutate_list_"+sp.name, []string{"tools/mutate.py", "core", sp.file, "--list"}, []string{"mutate", "core", sp.file, "--list"})
		c.inRepo, c.want, c.newContainer = true, 0, true
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
	// Usage errors do not need the container on the new side.
	for _, sp := range []struct {
		name string
		want int
		args []string
	}{
		{"usage_no_args", 2, nil},
		{"usage_package_only", 2, []string{"core"}},
		{"usage_unknown_package", 2, []string{"bogus", "lib/src/x.dart"}},
		{"usage_bad_seed", 2, []string{"core", "lib/src/dates.dart", "--seed", "x", "--list"}},
		{"usage_unknown_flag", 2, []string{"core", "lib/src/dates.dart", "--frobnicate"}},
	} {
		c := g4mk("mutate_"+sp.name, append([]string{"tools/mutate.py"}, sp.args...), append([]string{"mutate"}, sp.args...))
		c.inRepo, c.want, c.exitOnly = true, sp.want, true
		c.newContainer = true // wallet-build mutate builds the image before it checks usage (reported): do not start podman in cheap runs
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
	for _, sp := range []struct {
		name string
		args []string
	}{
		{"not_a_dart_file", []string{"core", "lib/src/nope.dart", "--list"}},
		{"outside_lib", []string{"core", "pubspec.yaml", "--list"}},
		{"other_package_file", []string{"core", "packages/sync/lib/src/sync_digest.dart", "--list"}},
	} {
		c := g4mk("mutate_"+sp.name, append([]string{"tools/mutate.py"}, sp.args...), append([]string{"mutate"}, sp.args...))
		c.inRepo, c.want, c.newContainer = true, 1, true
		t.Run(c.name, func(t *testing.T) { runG4(t, c) })
	}
}
