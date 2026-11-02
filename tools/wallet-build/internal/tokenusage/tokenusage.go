// Package tokenusage is `wallet-build token-usage` (port of tools/token-usage.py): the tokens of the Claude Code sessions of this
// repo per day, session, model and commit, from the local transcripts under ~/.claude/projects. Only counts and ids are read,
// never message text.
package tokenusage

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"wallet-build/internal/pyfmt"
	"wallet-build/internal/report"
)

// Opts are the command line options.
type Opts struct {
	Since, Until string // YYYY-MM-DD, string comparison on the day of a request; Until "" = "9999"
	JSON         string // also write the summary here
	Home         string // $HOME: transcripts are under <Home>/.claude/projects
}

// Git runs git with args in dir (the current directory when dir is "") and returns stdout and the exit code.
type Git func(dir string, args ...string) (string, int)

type acc struct{ input, cacheWrite, cacheRead, output, requests int64 }

func (a *acc) add(r request) {
	a.input += r.input
	a.cacheWrite += r.cacheWrite
	a.cacheRead += r.cacheRead
	a.output += r.output
	a.requests++
}

func (a *acc) total() int64 { return a.input + a.cacheWrite + a.cacheRead + a.output }

// obj is dict(counter): a Counter only has the keys it was added to.
func (a *acc) obj() report.Obj {
	if a.requests == 0 {
		return report.Obj{}
	}
	return report.Obj{{K: "input", V: a.input}, {K: "cache_write", V: a.cacheWrite}, {K: "cache_read", V: a.cacheRead},
		{K: "output", V: a.output}, {K: "requests", V: a.requests}}
}

// accs is a dict of counters that keeps the order of first insertion.
type accs struct {
	keys []string
	m    map[string]*acc
}

func newAccs() *accs { return &accs{m: map[string]*acc{}} }

func (d *accs) get(k string) *acc {
	if a, ok := d.m[k]; ok {
		return a
	}
	a := &acc{}
	d.m[k] = a
	d.keys = append(d.keys, k)
	return a
}

func (d *accs) sorted() []string {
	ks := append([]string(nil), d.keys...)
	sort.Strings(ks)
	return ks
}

type request struct {
	day, model                           string
	input, cacheWrite, cacheRead, output int64
}

// ProjectDir is ~/.claude/projects/<repo path with / and . replaced by ->.
func ProjectDir(home, repo string) string {
	return home + "/.claude/projects/" + strings.NewReplacer("/", "-", ".", "-").Replace(repo)
}

func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != ""
	case json.Number:
		f, err := x.Float64()
		return err != nil || f != 0
	case map[string]any:
		return len(x) > 0
	case []any:
		return len(x) > 0
	}
	return true
}

func toInt(v any) int64 {
	if n, ok := v.(json.Number); ok {
		if i, err := n.Int64(); err == nil {
			return i
		}
		if f, err := n.Float64(); err == nil {
			return int64(f)
		}
	}
	return 0
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// orChain is a or b or c: the first truthy value, else the last.
func orChain(vs ...any) any {
	for _, v := range vs {
		if truthy(v) {
			return v
		}
	}
	return vs[len(vs)-1]
}

func truncRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// requests reads one transcript. One request is logged as several lines (one per content block); only the last has the final
// output count, so the line with the most output tokens per requestId is kept. Requests come in the order of their first line.
func requests(path string) ([]request, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	type best struct{ rec, usage map[string]any }
	var order []string
	bests := map[string]*best{}
	rd := bufio.NewReaderSize(f, 1<<20)
	for {
		line, rerr := rd.ReadBytes('\n')
		if len(line) > 0 && bytes.Contains(line, []byte(`"usage"`)) {
			dec := json.NewDecoder(bytes.NewReader(line))
			dec.UseNumber()
			var rec map[string]any
			if dec.Decode(&rec) == nil && rec != nil {
				msg, _ := rec["message"].(map[string]any)
				usage, _ := msg["usage"].(map[string]any)
				if len(usage) > 0 && str(rec["type"]) == "assistant" {
					rid := orChain(rec["requestId"], msg["id"])
					key := fmt.Sprintf("%T|%v", rid, rid)
					cur, seen := bests[key]
					if !seen {
						order = append(order, key)
						bests[key] = &best{rec, usage}
					} else if toInt(usage["output_tokens"]) > toInt(cur.usage["output_tokens"]) {
						cur.rec, cur.usage = rec, usage
					}
				}
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return nil, rerr
		}
	}
	out := make([]request, 0, len(order))
	for _, k := range order {
		b := bests[k]
		msg, _ := b.rec["message"].(map[string]any)
		u := b.usage
		out = append(out, request{
			day:        truncRunes(str(b.rec["timestamp"]), 10),
			model:      str(orChain(msg["model"], b.rec["requestedModel"], "?")),
			input:      toInt(u["input_tokens"]),
			cacheWrite: toInt(u["cache_creation_input_tokens"]),
			cacheRead:  toInt(u["cache_read_input_tokens"]),
			output:     toInt(u["output_tokens"]),
		})
	}
	return out, nil
}

func jsonlIn(dir string) []string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		n := e.Name()
		if !e.IsDir() && strings.HasSuffix(n, ".jsonl") && !strings.HasPrefix(n, ".") { // glob's * skips dot files
			out = append(out, filepath.Join(dir, n))
		}
	}
	sort.Strings(out)
	return out
}

func table(out io.Writer, title string, names []string, rows []*acc) {
	fmt.Fprintf(out, "\n%s\n", title)
	fmt.Fprintf(out, "  %s %9s %10s %12s %14s %11s %14s\n", pyfmt.PadRight("", 38), "requests", "input", "cache_wr", "cache_rd", "output", "total")
	for i, name := range names {
		a := rows[i]
		fmt.Fprintf(out, "  %s %9s %10s %12s %14s %11s %14s\n", pyfmt.PadRight(name, 38), pyfmt.Comma(a.requests), pyfmt.Comma(a.input),
			pyfmt.Comma(a.cacheWrite), pyfmt.Comma(a.cacheRead), pyfmt.Comma(a.output), pyfmt.Comma(a.total()))
	}
}

// Run prints the tables (and writes o.JSON). repo is the top level of the git repository the command runs in. It returns the
// exit code: 1 without transcripts or when the JSON file cannot be written.
func Run(o Opts, repo string, git Git, out, errw io.Writer) int {
	until := o.Until
	if until == "" {
		until = "9999"
	}
	pdir := ProjectDir(o.Home, repo)
	byDay, bySession, byModel, total := newAccs(), newAccs(), newAccs(), &acc{}
	sessions := jsonlIn(pdir)
	if len(sessions) == 0 {
		fmt.Fprintf(errw, "no transcripts in %s\n", pdir)
		return 1
	}
	for _, mainFile := range sessions {
		sid := strings.TrimSuffix(filepath.Base(mainFile), ".jsonl")
		sid8 := truncRunes(sid, 8)
		type file struct{ path, kind string }
		files := []file{{mainFile, "main"}}
		for _, p := range jsonlIn(filepath.Join(pdir, sid, "subagents")) {
			files = append(files, file{p, "agent"})
		}
		for _, fl := range files {
			reqs, err := requests(fl.path)
			if err != nil {
				fmt.Fprintf(errw, "token-usage: %v\n", err)
				return 1
			}
			for _, r := range reqs {
				if !(o.Since <= r.day && r.day <= until) {
					continue
				}
				for _, a := range []*acc{byDay.get(r.day), bySession.get(sid8 + " " + fl.kind), byModel.get(r.model), total} {
					a.add(r)
				}
			}
		}
	}

	days := byDay.sorted()
	commits := 0
	if len(days) > 0 {
		text, _ := git(repo, "log", "--oneline", fmt.Sprintf("--since=%s 00:00", days[0]), fmt.Sprintf("--until=%s 23:59:59", days[len(days)-1]))
		commits = len(strings.Split(strings.TrimRight(text, "\n"), "\n"))
		if strings.TrimSpace(text) == "" {
			commits = 0
		}
	}

	pick := func(d *accs, keys []string) []*acc {
		rows := make([]*acc, len(keys))
		for i, k := range keys {
			rows[i] = d.m[k]
		}
		return rows
	}
	table(out, "Per day", days, pick(byDay, days))
	sess := bySession.sorted()
	table(out, "Per session (main = lead, agent = subagents)", sess, pick(bySession, sess))
	models := append([]string(nil), byModel.keys...)
	sort.SliceStable(models, func(i, j int) bool { return byModel.m[models[i]].output > byModel.m[models[j]].output })
	table(out, "Per model", models, pick(byModel, models))
	table(out, "Total", []string{"all"}, []*acc{total})
	grand := total.total()
	first, last := "-", "-"
	if len(days) > 0 {
		first, last = days[0], days[len(days)-1]
	}
	fmt.Fprintf(out, "\n  commits on this branch in %s..%s: %d\n", first, last, commits)
	if commits > 0 {
		c := int64(commits)
		fmt.Fprintf(out, "  per commit: %s tokens, %s output, %s requests\n", pyfmt.Comma(grand/c), pyfmt.Comma(total.output/c), pyfmt.Comma(total.requests/c))
	}

	if o.JSON != "" {
		rng := []string{}
		if len(days) > 0 {
			rng = []string{days[0], days[len(days)-1]}
		}
		dict := func(d *accs, keys []string) report.Obj {
			o := report.Obj{}
			for _, k := range keys {
				o = append(o, report.KV{K: k, V: d.m[k].obj()})
			}
			return o
		}
		summary := report.Obj{{K: "range", V: rng}, {K: "commits", V: commits}, {K: "total", V: total.obj()},
			{K: "per_day", V: dict(byDay, days)}, {K: "per_session", V: dict(bySession, sess)}, {K: "per_model", V: dict(byModel, byModel.keys)}}
		if err := os.WriteFile(o.JSON, []byte(report.Dumper{Indent: 1, ASCII: true}.Dump(summary)), 0o644); err != nil {
			fmt.Fprintf(errw, "token-usage: %v\n", err)
			return 1
		}
		fmt.Fprintf(out, "\n  wrote %s\n", o.JSON)
	}
	return 0
}
