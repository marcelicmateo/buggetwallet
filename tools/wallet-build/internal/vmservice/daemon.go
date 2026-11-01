package vmservice

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
	"time"
	"unicode/utf8"
)

// Events are the JSON messages flutter run printed. Each line is `[{...}]`; other lines are skipped, a missing file is no events.
func Events(path string) []map[string]any {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []map[string]any
	r := bufio.NewReaderSize(f, 1<<20)
	for {
		line, err := r.ReadString('\n')
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[{") && strings.HasSuffix(line, "}]") {
			var msgs []map[string]any
			if json.Unmarshal([]byte(line), &msgs) == nil {
				out = append(out, msgs...)
			}
		}
		if err != nil {
			break
		}
	}
	return out
}

// KV is one key=value of the info output.
type KV struct{ K, V string }

// State is flutter run's state as `live_vm.py info` prints it, in the order the keys first appeared.
type State []KV

// Get returns the value of k ("" when absent).
func (s State) Get(k string) string {
	for _, kv := range s {
		if kv.K == k {
			return kv.V
		}
	}
	return ""
}

func (s State) has(k string) bool {
	for _, kv := range s {
		if kv.K == k {
			return true
		}
	}
	return false
}

func (s *State) set(k, v string) {
	for i := range *s {
		if (*s)[i].K == k {
			(*s)[i].V = v
			return
		}
	}
	*s = append(*s, KV{k, v})
}

func (s *State) setDefault(k, v string) {
	if !s.has(k) {
		*s = append(*s, KV{k, v})
	}
}

func str(m map[string]any, k string) string {
	v, ok := m[k]
	if !ok || v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case string:
		return x != ""
	case bool:
		return x
	case float64:
		return x != 0
	case []any:
		return len(x) > 0
	case map[string]any:
		return len(x) > 0
	}
	return true
}

// firstLine is str(v).splitlines()[0][:200].
func firstLine(s string) string {
	line := s
	if i := strings.IndexAny(s, "\n\r"); i >= 0 {
		line = s[:i]
	}
	if utf8.RuneCountInString(line) > 200 {
		line = string([]rune(line)[:200])
	}
	return line
}

// Info reads flutter-run.jsonl: state (starting, building, started, stopped), app, mode, vm, dtd, devtools, error.
func Info(path string) State {
	out := State{{"state", "starting"}}
	for _, e := range Events(path) {
		p, _ := e["params"].(map[string]any)
		switch ev, _ := e["event"].(string); ev {
		case "app.start":
			out.set("state", "building")
			out.set("app", str(p, "appId"))
			out.set("mode", str(p, "mode"))
		case "app.debugPort":
			out.set("vm", str(p, "wsUri"))
		case "app.dtd":
			out.set("dtd", str(p, "uri"))
		case "app.devTools":
			out.set("devtools", str(p, "uri"))
		case "app.started":
			out.set("state", "started")
		case "app.stop":
			out.set("state", "stopped")
			if truthy(p["error"]) {
				out.set("error", firstLine(str(p, "error")))
			}
		case "daemon.log":
			if truthy(p["error"]) {
				l := ""
				if truthy(p["log"]) {
					l = firstLine(str(p, "log"))
				}
				out.setDefault("error", l)
			}
		case "daemon.connected":
			if !out.has("dtd") && truthy(p["dtdUri"]) {
				out.set("dtd", str(p, "dtdUri"))
			}
		}
	}
	// DevTools opened on this VM service (DevTools server started by flutter run, or the public one by URL)
	if dt, vm := out.Get("devtools"), out.Get("vm"); out.has("devtools") && vm != "" && !strings.Contains(dt, "?") {
		out.set("devtools", strings.TrimRight(dt, "/")+"/?uri="+quote(vm))
	}
	return out
}

// quote is urllib.parse.quote(s, safe=”): everything but letters, digits and _.-~ is percent-encoded.
func quote(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_', c == '.', c == '-', c == '~':
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// Request is one daemon request line for flutter run's stdin (formatted like Python's json.dumps). app.restart takes full.
func Request(id int, method, app string, full bool) string {
	q := func(s string) string { // Python's json.dumps does not escape <, > and &
		var b strings.Builder
		e := json.NewEncoder(&b)
		e.SetEscapeHTML(false)
		_ = e.Encode(s)
		return strings.TrimRight(b.String(), "\n")
	}
	params := `{"appId": ` + q(app)
	if method == "app.restart" {
		params += fmt.Sprintf(`, "fullRestart": %t, "pause": false, "reason": "manual"`, full)
	}
	params += "}"
	return fmt.Sprintf(`[{"id": %d, "method": %s, "params": %s}]`, id, q(method), params)
}

// Reply waits up to secs for the response to request id and prints its message to out. It returns the exit code: 0 ok,
// 1 on an error, a non-zero result code or a timeout. Polls the file every 100 ms like the Python version.
func Reply(path string, id int, secs float64, out io.Writer, sleep func(time.Duration), now func() time.Time) int {
	end := now().Add(time.Duration(secs * float64(time.Second)))
	for now().Before(end) {
		for _, e := range Events(path) {
			idv, ok := e["id"].(float64)
			if _, isEvent := e["event"]; !ok || idv != float64(id) || isEvent {
				continue
			}
			if errv, has := e["error"]; has {
				fmt.Fprintf(out, "error: %s\n", PyRepr(reencode(errv)))
				return 1
			}
			code, msg := 0.0, ""
			if r, ok := e["result"].(map[string]any); ok {
				if c, ok := r["code"].(float64); ok {
					code = c
				}
				msg, _ = r["message"].(string)
			}
			if msg == "" {
				msg = "done"
			}
			fmt.Fprintln(out, msg)
			if code == 0 || math.IsNaN(code) {
				return 0
			}
			return 1
		}
		sleep(100 * time.Millisecond)
	}
	fmt.Fprintln(out, "timed out waiting for flutter run")
	return 1
}

// reencode turns a decoded map back into the ordered form PyRepr prints (the keys come out sorted: Go maps keep no order).
func reencode(v any) any {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return decodeOrdered(b)
}
