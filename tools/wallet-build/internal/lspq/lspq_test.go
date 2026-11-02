package lspq

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// fakeServer speaks LSP framing on a pair of pipes. handler gets every client message and returns the frames to send back.
type fakeServer struct {
	t       *testing.T
	mu      sync.Mutex
	seen    []map[string]any
	handler func(msg map[string]any) []map[string]any
	raw     []string // frames that bypass the JSON (headers, garbage)
}

func (f *fakeServer) start() (*Server, error) {
	// OS pipes buffer like a real server's stdio; io.Pipe is synchronous and deadlocks when both sides write at once
	cin, sin, err := os.Pipe() // client stdin = server reads
	if err != nil {
		return nil, err
	}
	sout, cout, err := os.Pipe() // server stdout = client reads
	if err != nil {
		return nil, err
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer cout.Close()
		rd := bufio.NewReader(cin)
		for {
			length := -1
			for {
				line, err := rd.ReadString('\n')
				if err != nil {
					return
				}
				line = strings.TrimSpace(line)
				if line == "" {
					break
				}
				if v, ok := strings.CutPrefix(line, "Content-Length: "); ok {
					length, _ = strconv.Atoi(v)
				}
			}
			body := make([]byte, length)
			if _, err := io.ReadFull(rd, body); err != nil {
				return
			}
			var msg map[string]any
			if err := json.Unmarshal(body, &msg); err != nil {
				f.t.Errorf("client sent bad JSON: %s", body)
				return
			}
			f.mu.Lock()
			f.seen = append(f.seen, msg)
			f.mu.Unlock()
			for _, out := range f.handler(msg) {
				b, _ := json.Marshal(out)
				fmt.Fprintf(cout, "Content-Length: %d\r\n\r\n%s", len(b), b)
			}
			if msg["method"] == "exit" {
				return
			}
		}
	}()
	return &Server{In: sin, Out: sout, Wait: func() error { <-done; return nil }, Kill: func() {}}, nil
}

func (f *fakeServer) methods() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, m := range f.seen {
		if s, ok := m["method"].(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func result(msg map[string]any, res any) []map[string]any {
	return []map[string]any{{"jsonrpc": "2.0", "id": msg["id"], "result": res}}
}

func loc(uri string, line, col int) map[string]any {
	return map[string]any{"uri": uri, "range": map[string]any{"start": map[string]any{"line": line, "character": col}, "end": map[string]any{"line": line, "character": col + 3}}}
}

func setup(t *testing.T) (root, file string) {
	root = t.TempDir()
	file = filepath.Join(root, "lib", "a.dart")
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("class A {}\r\nclass B {}\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return
}

func TestRefsAndDefinitions(t *testing.T) {
	root, file := setup(t)
	other := filepath.Join(root, "lib", "z b.dart") // a space: the URI is percent-encoded
	f := &fakeServer{t: t}
	f.handler = func(msg map[string]any) []map[string]any {
		switch msg["method"] {
		case "initialize":
			return append([]map[string]any{
				{"jsonrpc": "2.0", "id": 99, "method": "workspace/configuration", "params": map[string]any{"items": []any{1, 2}}}, // server request first
				{"jsonrpc": "2.0", "method": "window/logMessage", "params": map[string]any{}},                                     // a notification
			}, result(msg, map[string]any{"capabilities": map[string]any{}})...)
		case "textDocument/references":
			return result(msg, []any{loc(uriOf(other), 4, 2), loc(uriOf(file), 1, 6), loc(uriOf(file), 1, 6), loc("file:///elsewhere/x.dart", 0, 0)})
		case "textDocument/definition":
			pos := msg["params"].(map[string]any)["position"].(map[string]any)
			switch pos["line"].(float64) {
			case 0: // a LocationLink
				return result(msg, []any{map[string]any{"targetUri": uriOf(file), "targetSelectionRange": loc("", 1, 6)["range"]}})
			case 1: // a single Location
				return result(msg, loc(uriOf(file), 1, 0))
			}
			return result(msg, nil) // nothing found
		case "shutdown":
			return result(msg, nil)
		}
		return nil
	}
	var out, errb bytes.Buffer
	rc := Main([]string{"refs", "lib/a.dart:1:7"}, root, f.start, &out, &errb)
	want := "../../elsewhere/x.dart:1:1\nlib/a.dart:2:7\nlib/z b.dart:5:3\n"
	if strings.HasPrefix("/elsewhere", root) {
		t.Fatal("test root clashes")
	}
	want = "/elsewhere/x.dart:1:1\nlib/a.dart:2:7\nlib/z b.dart:5:3\n" // outside the repo: printed as the absolute path
	if rc != 0 || out.String() != want || errb.Len() != 0 {
		t.Errorf("rc %d\nout %q\nwant %q\nerr %q", rc, out.String(), want, errb.String())
	}
	ms := f.methods()
	wantMs := []string{"initialize", "initialized", "textDocument/didOpen", "textDocument/references", "shutdown", "exit"}
	if strings.Join(ms, ",") != strings.Join(wantMs, ",") {
		t.Errorf("client methods %v, want %v", ms, wantMs)
	}
	// the answer to the server's configuration request: one null per item
	var reply map[string]any
	for _, m := range f.seen {
		if m["id"] == float64(99) {
			reply = m
		}
	}
	if r, ok := reply["result"].([]any); !ok || len(r) != 2 || r[0] != nil {
		t.Errorf("configuration reply %v", reply)
	}
	// the file is opened with LF line ends (Python's text mode), positions are 0-based
	for _, m := range f.seen {
		switch m["method"] {
		case "textDocument/didOpen":
			td := m["params"].(map[string]any)["textDocument"].(map[string]any)
			if td["text"] != "class A {}\nclass B {}\n" || td["languageId"] != "dart" || td["uri"] != "file://"+quote(file) {
				t.Errorf("didOpen %v", td)
			}
		case "textDocument/references":
			p := m["params"].(map[string]any)
			pos := p["position"].(map[string]any)
			if pos["line"] != float64(0) || pos["character"] != float64(6) || p["context"].(map[string]any)["includeDeclaration"] != true {
				t.Errorf("references params %v", p)
			}
		case "initialize":
			p := m["params"].(map[string]any)
			if p["rootUri"] != "file://"+quote(root) || p["processId"] != float64(os.Getpid()) {
				t.Errorf("initialize params %v", p)
			}
		}
	}

	// several positions: blocks headed by the position; an empty answer makes the exit code 1
	out.Reset()
	rc = Main([]string{"def", "lib/a.dart:1:1", "lib/a.dart:2:1", file + ":3:1"}, root, f.start, &out, &errb)
	want = "# lib/a.dart:1:1\nlib/a.dart:2:7\n# lib/a.dart:2:1\nlib/a.dart:2:1\n# lib/a.dart:3:1\n"
	if rc != 1 || out.String() != want {
		t.Errorf("rc %d\nout %q\nwant %q", rc, out.String(), want)
	}
	if n := countOf(f.methods(), "textDocument/didOpen"); n != 2 { // one file opened once per call
		t.Errorf("didOpen %d times in two calls", n)
	}
}

func countOf(s []string, v string) int {
	n := 0
	for _, x := range s {
		if x == v {
			n++
		}
	}
	return n
}

func TestServerErrorAndEarlyClose(t *testing.T) {
	root, _ := setup(t)
	f := &fakeServer{t: t}
	f.handler = func(msg map[string]any) []map[string]any {
		switch msg["method"] {
		case "initialize":
			return result(msg, map[string]any{})
		case "textDocument/references":
			return []map[string]any{{"jsonrpc": "2.0", "id": msg["id"], "error": map[string]any{"code": -32001, "message": "no analysis yet"}}}
		case "shutdown":
			return result(msg, nil)
		}
		return nil
	}
	var out, errb bytes.Buffer
	rc := Main([]string{"refs", "lib/a.dart:1:1", "lib/a.dart:2:1"}, root, f.start, &out, &errb)
	if rc != 1 || out.Len() != 0 || !strings.Contains(errb.String(), "textDocument/references: no analysis yet") {
		t.Errorf("rc %d out %q err %q", rc, out.String(), errb.String())
	}
	// the server dies right away
	dead := func() (*Server, error) {
		in := nopWriteCloser{io.Discard}
		return &Server{In: in, Out: strings.NewReader("")}, nil
	}
	errb.Reset()
	rc = Main([]string{"def", "lib/a.dart:1:1"}, root, dead, &out, &errb)
	if rc != 1 || !strings.Contains(errb.String(), "language server closed the connection") {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
	// a header without Content-Length
	bad := func() (*Server, error) {
		return &Server{In: nopWriteCloser{io.Discard}, Out: strings.NewReader("X-Other: 1\r\n\r\n")}, nil
	}
	errb.Reset()
	rc = Main([]string{"def", "lib/a.dart:1:1"}, root, bad, &out, &errb)
	if rc != 1 || !strings.Contains(errb.String(), "header without Content-Length") {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
	// the server cannot be started
	errb.Reset()
	rc = Main([]string{"def", "lib/a.dart:1:1"}, root, func() (*Server, error) { return nil, fmt.Errorf("exec: not found") }, &out, &errb)
	if rc != 1 || !strings.Contains(errb.String(), "not found") {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
}

type nopWriteCloser struct{ io.Writer }

func (nopWriteCloser) Close() error { return nil }

func TestArgumentErrors(t *testing.T) {
	root, _ := setup(t)
	never := func() (*Server, error) { t.Error("the server must not start"); return nil, nil }
	for _, tc := range []struct {
		args []string
		rc   int
		out  string
		err  string
	}{
		{nil, 2, "wallet-build lsp-query refs", ""},
		{[]string{"refs"}, 2, "wallet-build lsp-query refs", ""},
		{[]string{"-h"}, 0, "wallet-build lsp-query refs", ""},
		{[]string{"--help", "x"}, 0, "wallet-build lsp-query refs", ""},
		{[]string{"find", "a:1:1"}, 2, "wallet-build lsp-query refs", ""},
		{[]string{"refs", "nocolons"}, 1, "", "bad position 'nocolons': expected <path>:<line>:<col>"},
		{[]string{"refs", "a.dart:x:1"}, 1, "", "bad position 'a.dart:x:1'"},
		{[]string{"refs", "lib/a.dart:1:1", "a.dart:1:z"}, 1, "", "bad position"},
		{[]string{"def", "lib/missing.dart:1:1"}, 1, "", "no such file: " + filepath.Join(root, "lib/missing.dart")},
		{[]string{"def", "lib:1:1"}, 1, "", "no such file: " + filepath.Join(root, "lib")},
	} {
		var out, errb bytes.Buffer
		rc := Main(tc.args, root, never, &out, &errb)
		if rc != tc.rc || !strings.Contains(out.String(), tc.out) || !strings.Contains(errb.String(), tc.err) {
			t.Errorf("%v: rc %d out %q err %q", tc.args, rc, out.String(), errb.String())
		}
	}
}

func TestURIs(t *testing.T) {
	p := "/home/u/my proj/lib/ü€.dart"
	u := uriOf(p)
	if u != "file:///home/u/my%20proj/lib/%C3%BC%E2%82%AC.dart" {
		t.Errorf("%s", u)
	}
	if got := pathOf(u); got != p {
		t.Errorf("pathOf = %q", got)
	}
	if got := pathOf("file://host/a/b%23c?x#y"); got != "/a/b#c" {
		t.Errorf("pathOf = %q", got)
	}
	if quote("a_b-c.d~e/f") != "a_b-c.d~e/f" {
		t.Error("unreserved characters must stay")
	}
}

// Python's rsplit(":", 2): a colon inside the path is fine.
func TestPositionWithColonInPath(t *testing.T) {
	p, err := parsePos("/r", "a:b/c.dart:12:3")
	if err != nil || p.path != "/r/a:b/c.dart" || p.line != 12 || p.col != 3 {
		t.Errorf("%+v %v", p, err)
	}
}
