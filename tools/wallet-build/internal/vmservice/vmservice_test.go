package vmservice

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"wallet-build/internal/sys"
)

// ---- a WebSocket server for the client tests ----

type frame struct {
	fin    bool
	op     byte
	masked bool
	data   []byte
}

type srvConn struct {
	t  *testing.T
	c  net.Conn
	br *bufio.Reader
}

func (s *srvConn) read() (frame, error) {
	var h [2]byte
	if _, err := io.ReadFull(s.br, h[:]); err != nil {
		return frame{}, err
	}
	f := frame{fin: h[0]&0x80 != 0, op: h[0] & 0x0F, masked: h[1]&0x80 != 0}
	n := uint64(h[1] & 0x7F)
	switch n {
	case 126:
		var b [2]byte
		io.ReadFull(s.br, b[:])
		n = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		io.ReadFull(s.br, b[:])
		n = binary.BigEndian.Uint64(b[:])
	}
	var mask [4]byte
	if f.masked {
		io.ReadFull(s.br, mask[:])
	}
	f.data = make([]byte, n)
	if _, err := io.ReadFull(s.br, f.data); err != nil {
		return f, err
	}
	for i := range f.data {
		f.data[i] ^= mask[i%4]
	}
	return f, nil
}

// write sends an unmasked server frame.
func (s *srvConn) write(fin bool, op byte, data []byte) {
	b0 := op
	if fin {
		b0 |= 0x80
	}
	hdr := []byte{b0}
	switch n := len(data); {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n < 1<<16:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 127)
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	s.c.Write(append(hdr, data...))
}

// request reads the next text frame and decodes the JSON-RPC request in it.
func (s *srvConn) request() (id, method string, params map[string]any) {
	s.t.Helper()
	f, err := s.read()
	if err != nil {
		if !errors.Is(err, io.EOF) { // EOF = the client is done
			s.t.Errorf("server read: %v", err)
		}
		return
	}
	if f.op != opText || !f.fin || !f.masked {
		s.t.Errorf("client frame: op %d fin %v masked %v (clients must send masked, final text frames)", f.op, f.fin, f.masked)
	}
	var r struct {
		JSONRPC string         `json:"jsonrpc"`
		ID      string         `json:"id"`
		Method  string         `json:"method"`
		Params  map[string]any `json:"params"`
	}
	if err := json.Unmarshal(f.data, &r); err != nil || r.JSONRPC != "2.0" {
		s.t.Errorf("bad request %q: %v", f.data, err)
	}
	return r.ID, r.Method, r.Params
}

func (s *srvConn) reply(id string, result any) {
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	s.write(true, opText, b)
}

func (s *srvConn) fail(id string, code int, msg string, data any) {
	e := map[string]any{"code": code, "message": msg}
	if data != nil {
		e["data"] = data
	}
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "error": e})
	s.write(true, opText, b)
}

// wsServer runs handle for the first connection after a correct handshake. The server URL is returned as ws://.
func wsServer(t *testing.T, handle func(s *srvConn)) string {
	t.Helper()
	var wg sync.WaitGroup
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Upgrade") != "websocket" || r.Header.Get("Sec-WebSocket-Version") != "13" {
			t.Errorf("handshake headers: %v", r.Header)
		}
		key := r.Header.Get("Sec-WebSocket-Key")
		if raw, err := base64.StdEncoding.DecodeString(key); err != nil || len(raw) != 16 {
			t.Errorf("Sec-WebSocket-Key %q", key)
		}
		sum := sha1.Sum([]byte(key + wsGUID))
		hj := w.(http.Hijacker)
		c, brw, err := hj.Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		wg.Add(1)
		defer wg.Done()
		defer c.Close()
		fmt.Fprintf(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
			base64.StdEncoding.EncodeToString(sum[:]))
		handle(&srvConn{t: t, c: c, br: brw.Reader})
	}))
	t.Cleanup(func() { srv.Close(); wg.Wait() })
	return "ws" + strings.TrimPrefix(srv.URL, "http") + "/TOKEN=/ws"
}

func dial(t *testing.T, uri string) *Conn {
	t.Helper()
	c, err := Dial(uri)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

// ---- WebSocket client ----

func TestCallMasksAndLengthForms(t *testing.T) {
	sizes := []int{10, 200, 70000} // 7-bit, 16-bit and 64-bit payload lengths
	uri := wsServer(t, func(s *srvConn) {
		for range sizes {
			id, method, params := s.request()
			s.reply(id, map[string]any{"method": method, "n": len(params["blob"].(string))})
		}
	})
	c := dial(t, uri)
	for _, n := range sizes {
		res, err := c.Call("echo", map[string]any{"blob": strings.Repeat("x", n)})
		if err != nil {
			t.Fatal(err)
		}
		var r struct {
			Method string
			N      int
		}
		json.Unmarshal(res, &r)
		if r.Method != "echo" || r.N != n {
			t.Errorf("size %d: got %+v", n, r)
		}
	}
}

func TestCallIDsCountUpAsStrings(t *testing.T) {
	var got []string
	uri := wsServer(t, func(s *srvConn) {
		for i := 0; i < 3; i++ {
			id, _, _ := s.request()
			got = append(got, id)
			s.reply(id, 1)
		}
	})
	c := dial(t, uri)
	for i := 0; i < 3; i++ {
		if _, err := c.Call("m", nil); err != nil {
			t.Fatal(err)
		}
	}
	if strings.Join(got, ",") != "1,2,3" {
		t.Errorf("ids %v", got)
	}
}

func TestFragmentsPingPongAndForeignMessages(t *testing.T) {
	var pong frame
	uri := wsServer(t, func(s *srvConn) {
		id, _, _ := s.request()
		// an event first, a message for another id, then the reply in three fragments with a ping and a pong between
		s.write(true, opText, []byte(`{"jsonrpc":"2.0","method":"streamNotify","params":{"streamId":"Timeline"}}`))
		s.write(true, opText, []byte(`{"jsonrpc":"2.0","id":"99","result":{"other":true}}`))
		full, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"v": "joined"}})
		third := len(full) / 3
		s.write(false, opText, full[:third])
		s.write(true, opPing, []byte("hi"))
		s.write(true, opPong, []byte("ignored"))
		s.write(false, opCont, full[third:2*third])
		var err error
		pong, err = s.read()
		if err != nil {
			t.Errorf("reading pong: %v", err)
		}
		s.write(true, opCont, full[2*third:])
	})
	c := dial(t, uri)
	res, err := c.Call("m", nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `{"v":"joined"}` {
		t.Errorf("result %s", res)
	}
	if pong.op != opPong || string(pong.data) != "hi" || !pong.masked {
		t.Errorf("pong %+v", pong)
	}
}

func TestBinaryFramesCount(t *testing.T) {
	uri := wsServer(t, func(s *srvConn) {
		id, _, _ := s.request()
		b, _ := json.Marshal(map[string]any{"id": id, "result": 5})
		s.write(true, opBin, b)
	})
	if res, err := dial(t, uri).Call("m", nil); err != nil || string(res) != "5" {
		t.Errorf("%s %v", res, err)
	}
}

func TestCloseFrameAndEOF(t *testing.T) {
	uri := wsServer(t, func(s *srvConn) {
		s.request()
		s.write(true, opClose, []byte{0x03, 0xe8})
	})
	if _, err := dial(t, uri).Call("m", nil); !errors.Is(err, ErrClosed) {
		t.Errorf("close frame: %v", err)
	}
	uri = wsServer(t, func(s *srvConn) {
		s.request()
		s.c.Write([]byte{0x81}) // half a header, then EOF
	})
	if _, err := dial(t, uri).Call("m", nil); !errors.Is(err, ErrClosed) {
		t.Errorf("eof: %v", err)
	}
}

func TestRPCErrorText(t *testing.T) {
	uri := wsServer(t, func(s *srvConn) {
		id, _, _ := s.request()
		s.fail(id, -32601, "Method not found", map[string]any{"details": "it's gone", "n": 2})
		id, _, _ = s.request()
		s.fail(id, -32000, "boom", nil)
		id, _, _ = s.request()
		s.fail(id, -32000, "boom", "plain text")
	})
	c := dial(t, uri)
	_, err := c.Call("getVM", nil)
	var re *RPCError
	if !errors.As(err, &re) || err.Error() != `getVM: Method not found {'details': "it's gone", 'n': 2}` {
		t.Errorf("error %v", err)
	}
	if _, err = c.Call("x", nil); err == nil || err.Error() != "x: boom " {
		t.Errorf("error without data %q", err)
	}
	if _, err = c.Call("y", nil); err == nil || err.Error() != "y: boom plain text" {
		t.Errorf("error with string data %q", err)
	}
}

func TestHandshakeRefused(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "no", 403) }))
	defer srv.Close()
	_, err := Dial("ws" + strings.TrimPrefix(srv.URL, "http") + "/x/ws")
	if err == nil || !strings.Contains(err.Error(), "refused the WebSocket: HTTP/1.1 403") {
		t.Errorf("error %v", err)
	}
	if _, err := Dial("ws://127.0.0.1:1/ws"); err == nil {
		t.Error("connection refused expected")
	}
}

func TestIOTimeout(t *testing.T) {
	old := IOTimeout
	IOTimeout = 200 * time.Millisecond
	defer func() { IOTimeout = old }()
	uri := wsServer(t, func(s *srvConn) {
		s.request()
		time.Sleep(time.Second) // never answers in time
	})
	start := time.Now()
	if _, err := dial(t, uri).Call("m", nil); err == nil || time.Since(start) > 900*time.Millisecond {
		t.Errorf("want a timeout, got %v after %v", err, time.Since(start))
	}
}

// ---- RPCs ----

func TestScreenshotInspector(t *testing.T) {
	var calls []string
	uri := wsServer(t, func(s *srvConn) {
		for {
			id, method, params := s.request()
			if method == "" {
				return
			}
			calls = append(calls, method)
			switch method {
			case "getVM":
				s.reply(id, map[string]any{"isolates": []any{map[string]any{"id": "isolates/1", "name": "other"}, map[string]any{"id": "isolates/2", "name": "main"}}})
			case "ext.flutter.inspector.getRootWidgetTree":
				if params["isolateId"] != "isolates/2" || params["groupName"] != "bw-shot" || params["isSummaryTree"] != "true" {
					t.Errorf("tree params %v", params)
				}
				s.reply(id, map[string]any{"type": "x", "result": map[string]any{"valueId": "inspector-7"}})
			case "ext.flutter.inspector.screenshot":
				if params["id"] != "inspector-7" || params["width"] != "10000" || params["maxPixelRatio"] != "1" || params["debugPaint"] != "false" {
					t.Errorf("screenshot params %v", params)
				}
				s.reply(id, map[string]any{"type": "x", "result": base64.StdEncoding.EncodeToString([]byte("PNGDATA"))})
			case "ext.flutter.inspector.disposeGroup":
				if params["objectGroup"] != "bw-shot" {
					t.Errorf("dispose params %v", params)
				}
				s.reply(id, map[string]any{"type": "Success"})
			}
		}
	})
	data, err := dial(t, uri).Screenshot()
	if err != nil || string(data) != "PNGDATA" {
		t.Fatalf("%q %v", data, err)
	}
	want := "getVM,ext.flutter.inspector.getRootWidgetTree,ext.flutter.inspector.screenshot,ext.flutter.inspector.disposeGroup"
	if strings.Join(calls, ",") != want {
		t.Errorf("calls %v", calls)
	}
}

func TestScreenshotFallbackAndFailure(t *testing.T) {
	serve := func(fallbackOK bool) string {
		return wsServer(t, func(s *srvConn) {
			for {
				id, method, _ := s.request()
				switch method {
				case "":
					return
				case "getVM":
					s.reply(id, map[string]any{"isolates": []any{map[string]any{"id": "isolates/1", "name": "main.dart"}}})
				case "ext.flutter.inspector.getRootWidgetTree":
					s.fail(id, -32601, "no inspector", nil)
				case "_flutter.screenshot":
					if fallbackOK {
						s.reply(id, map[string]any{"type": "Screenshot", "screenshot": base64.StdEncoding.EncodeToString([]byte("RASTER"))})
					} else {
						s.fail(id, -32000, "Impeller", nil)
					}
				}
			}
		})
	}
	data, err := dial(t, serve(true)).Screenshot()
	if err != nil || string(data) != "RASTER" {
		t.Errorf("fallback: %q %v", data, err)
	}
	_, err = dial(t, serve(false)).Screenshot()
	if err == nil || err.Error() != "no screenshot: ext.flutter.inspector.getRootWidgetTree: no inspector ; _flutter.screenshot: Impeller " {
		t.Errorf("both failed: %v", err)
	}
}

func TestScreenshotEmptyInspectorImageFallsBack(t *testing.T) {
	uri := wsServer(t, func(s *srvConn) {
		for {
			id, method, _ := s.request()
			switch method {
			case "":
				return
			case "getVM":
				s.reply(id, map[string]any{"isolates": []any{}})
			}
		}
	})
	if _, err := dial(t, uri).Screenshot(); err == nil || !strings.Contains(err.Error(), "no isolates") {
		t.Errorf("no isolates: %v", err)
	}
}

func TestTrace(t *testing.T) {
	var seq []string
	uri := wsServer(t, func(s *srvConn) {
		for {
			id, method, params := s.request()
			if method == "" {
				return
			}
			b, _ := json.Marshal(params["recordedStreams"])
			seq = append(seq, method+" "+string(b))
			if method == "getVMTimeline" {
				s.reply(id, map[string]any{"traceEvents": []any{map[string]any{"name": "a", "ph": "X", "ts": 1, "dur": 2}}})
				continue
			}
			s.reply(id, map[string]any{"type": "Success"})
		}
	})
	c := dial(t, uri)
	if err := c.TraceStart(); err != nil {
		t.Fatal(err)
	}
	ev, err := c.TraceStop()
	if err != nil || len(ev) != 1 {
		t.Fatalf("%v %v", ev, err)
	}
	want := []string{`setVMTimelineFlags ["Dart","Embedder","GC"]`, `clearVMTimeline null`, `getVMTimeline null`, `setVMTimelineFlags []`}
	if strings.Join(seq, "|") != strings.Join(want, "|") {
		t.Errorf("rpc sequence\n got %v\nwant %v", seq, want)
	}
}

func TestSaveTrace(t *testing.T) {
	dir := t.TempDir()
	raw := []json.RawMessage{json.RawMessage(`{"name":"Animator::BeginFrame","ph":"X","ts":1,"dur":20000}`)}
	var out bytes.Buffer
	if err := SaveTrace(filepath.Join(dir, "trace-x.json"), raw, "debug", &out); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "trace-x.json"))
	var back struct {
		TraceEvents     []map[string]any `json:"traceEvents"`
		DisplayTimeUnit string           `json:"displayTimeUnit"`
	}
	if json.Unmarshal(b, &back) != nil || len(back.TraceEvents) != 1 || back.DisplayTimeUnit != "ms" {
		t.Errorf("trace file %s", b)
	}
	sum, _ := os.ReadFile(filepath.Join(dir, "trace-x-summary.txt"))
	if !strings.HasPrefix(string(sum), "timeline: 0.0 s, 1 events, 1 frames, 1 over 16 ms") || !strings.HasSuffix(out.String(), "saved "+filepath.Join(dir, "trace-x.json")+"\n") ||
		!strings.HasPrefix(out.String(), string(sum)) {
		t.Errorf("summary %q\nout %q", sum, out.String())
	}
}

// ---- daemon ----

func golden(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func infoText(s State) string {
	var sb strings.Builder
	for _, kv := range s {
		fmt.Fprintf(&sb, "%s=%s\n", kv.K, kv.V)
	}
	return sb.String()
}

func TestInfoMatchesLiveVm(t *testing.T) {
	// goldens made by `python3 -I tools/live_vm.py info` on the same synthetic files
	if got := infoText(Info("testdata/flutter-run.jsonl")); got != golden(t, "info.txt") {
		t.Errorf("info\n got %q\nwant %q", got, golden(t, "info.txt"))
	}
	if got := infoText(Info("testdata/flutter-run.stopped.jsonl")); got != golden(t, "info.stopped.txt") {
		t.Errorf("info stopped\n got %q\nwant %q", got, golden(t, "info.stopped.txt"))
	}
}

func TestInfoMissingAndPartialFiles(t *testing.T) {
	if got := infoText(Info(filepath.Join(t.TempDir(), "none.jsonl"))); got != "state=starting\n" {
		t.Errorf("missing file: %q", got)
	}
	p := filepath.Join(t.TempDir(), "f.jsonl")
	// a half-written last line, an empty error, daemon.connected without a dtd, an app.stop without error
	os.WriteFile(p, []byte("[{\"event\":\"app.start\",\"params\":{\"appId\":\"a\",\"mode\":\"debug\"}}]\n[{\"event\":\"app.stop\",\"params\":{\"appId\":\"a\",\"error\":\"\"}}]\n[{\"event\":\"app.sta"), 0o644)
	if got := infoText(Info(p)); got != "state=stopped\napp=a\nmode=debug\n" {
		t.Errorf("partial: %q", got)
	}
	// a devtools URL that already has a query is left alone; none without a vm address
	os.WriteFile(p, []byte("[{\"event\":\"app.devTools\",\"params\":{\"uri\":\"http://x/?uri=y\"}}]\n"), 0o644)
	if got := Info(p).Get("devtools"); got != "http://x/?uri=y" {
		t.Errorf("devtools %q", got)
	}
	long := strings.Repeat("é", 300)
	os.WriteFile(p, []byte(`[{"event":"app.stop","params":{"error":"`+long+`\nsecond"}}]`+"\n"), 0o644)
	if got := Info(p).Get("error"); got != strings.Repeat("é", 200) {
		t.Errorf("error cut at 200 characters: %d runes", len([]rune(got)))
	}
}

func TestRequestMatchesLiveVm(t *testing.T) {
	// made by `python3 -I tools/live_vm.py request …`
	cases := []struct {
		id     int
		method string
		app    string
		full   bool
		want   string
	}{
		{123456789, "app.restart", "abc<1>", true, `[{"id": 123456789, "method": "app.restart", "params": {"appId": "abc<1>", "fullRestart": true, "pause": false, "reason": "manual"}}]`},
		{7, "app.restart", "a", false, `[{"id": 7, "method": "app.restart", "params": {"appId": "a", "fullRestart": false, "pause": false, "reason": "manual"}}]`},
		{12, "app.stop", "abc", false, `[{"id": 12, "method": "app.stop", "params": {"appId": "abc"}}]`},
	}
	for _, c := range cases {
		if got := Request(c.id, c.method, c.app, c.full); got != c.want {
			t.Errorf("got %s\nwant %s", got, c.want)
		}
	}
}

func TestReply(t *testing.T) {
	p := filepath.Join(t.TempDir(), "run.jsonl")
	clock := time.Unix(1000, 0)
	now := func() time.Time { return clock }
	sleep := func(d time.Duration) { clock = clock.Add(d) }
	reply := func(content string, id int, secs float64) (int, string) {
		os.WriteFile(p, []byte(content), 0o644)
		var out bytes.Buffer
		rc := Reply(p, id, secs, &out, sleep, now)
		return rc, out.String()
	}
	if rc, out := reply(golden(t, "flutter-run.jsonl"), 5, 1); rc != 0 || out != "Reloaded 3 libraries\n" {
		t.Errorf("ok: %d %q", rc, out)
	}
	if rc, out := reply(`[{"id":6,"result":{"code":0}}]`+"\n", 6, 1); rc != 0 || out != "done\n" {
		t.Errorf("no message: %d %q", rc, out)
	}
	if rc, out := reply(`[{"id":6,"result":{"code":1,"message":"Hot reload failed"}}]`+"\n", 6, 1); rc != 1 || out != "Hot reload failed\n" {
		t.Errorf("code: %d %q", rc, out)
	}
	if rc, out := reply(`[{"id":6,"error":"bad app id"}]`+"\n", 6, 1); rc != 1 || out != "error: 'bad app id'\n" {
		t.Errorf("error: %d %q", rc, out)
	}
	if rc, out := reply(`[{"id":6,"event":"x","params":{}}]`+"\n"+`[{"id":7,"result":{}}]`+"\n", 6, 0.5); rc != 1 || out != "timed out waiting for flutter run\n" {
		t.Errorf("events and other ids don't answer: %d %q", rc, out)
	}
	// the reply arrives while waiting
	clock = time.Unix(1000, 0)
	os.WriteFile(p, nil, 0o644)
	n := 0
	var out bytes.Buffer
	rc := Reply(p, 9, 5, &out, func(d time.Duration) {
		sleep(d)
		if n++; n == 3 {
			os.WriteFile(p, []byte(`[{"id":9,"result":{"message":"late"}}]`+"\n"), 0o644)
		}
	}, now)
	if rc != 0 || out.String() != "late\n" || n != 3 {
		t.Errorf("late reply: %d %q after %d polls", rc, out.String(), n)
	}
}

func TestPyRepr(t *testing.T) {
	// compare `python3 -c "print({...})"`
	v := decodeOrdered([]byte(`{"code": -32000, "message": "it's", "data": [1, 2.0, null, true, "x"], "n": {"b": 1, "a": "q\"u\nx"}}`))
	want := `{'code': -32000, 'message': "it's", 'data': [1, 2.0, None, True, 'x'], 'n': {'b': 1, 'a': 'q"u\nx'}}`
	if got := PyRepr(v); got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
}

// ---- timeline summary ----

func traceEvents(t *testing.T) []TraceEvent {
	t.Helper()
	var tr struct {
		TraceEvents []json.RawMessage `json:"traceEvents"`
	}
	if err := json.Unmarshal([]byte(golden(t, "trace.json")), &tr); err != nil {
		t.Fatal(err)
	}
	return ParseTrace(tr.TraceEvents)
}

func TestSummaryMatchesLiveVm(t *testing.T) {
	// goldens made once by `python3 -I tools/live_vm.py summary` (and summary(trace, mode)) on the synthetic trace
	ev := traceEvents(t)
	for _, c := range []struct{ file, mode string }{{"trace.summary.txt", ""}, {"trace.summary.txt", "profile"}, {"trace.summary.debug.txt", "debug"}} {
		if got := Summary(ev, c.mode); got != golden(t, c.file) {
			t.Errorf("mode %q\n got %q\nwant %q", c.mode, got, golden(t, c.file))
		}
	}
	if got := Summary(nil, "profile"); got != golden(t, "trace.summary.empty.txt") {
		t.Errorf("empty trace: %q", got)
	}
}

func TestPctRoundsHalfToEven(t *testing.T) {
	v := []float64{1, 2, 3, 4, 5, 6} // p50 -> index round(2.5) = 2 (Python rounds half to even)
	if got := Pct(v, 50); got != 3 {
		t.Errorf("p50 %v", got)
	}
	if got := Pct([]float64{5, 1, 3}, 90); got != 5 {
		t.Errorf("p90 %v", got)
	}
	if got := Pct(nil, 90); got != 0 {
		t.Errorf("empty %v", got)
	}
}

// ---- forwarder ----

func TestLocalAddrs(t *testing.T) {
	p := filepath.Join(t.TempDir(), "fib_trie")
	os.WriteFile(p, []byte(`Main:
  +-- 0.0.0.0/0 3 0 5
     |-- 0.0.0.0
        /0 universe UNICAST
     +-- 10.88.0.0/16 2 0 2
        |-- 10.88.0.0
           /16 link UNICAST
        |-- 10.88.0.7
           /32 host LOCAL
     +-- 127.0.0.0/8 2 0 2
        |-- 127.0.0.1
           /32 host LOCAL
        |-- 192.168.1.5
           /32 host LOCAL
  |-- 10.88.0.7
     /32 host LOCAL
`), 0o644)
	got, err := LocalAddrs(p)
	if err != nil || strings.Join(got, ",") != "10.88.0.7,192.168.1.5" {
		t.Errorf("%v %v", got, err)
	}
	if _, err := LocalAddrs(filepath.Join(t.TempDir(), "none")); err == nil {
		t.Error("missing file")
	}
}

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func TestForwardAddrsOnLoopback(t *testing.T) {
	port := freePort(t)
	up, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port)) // "DDS"
	if err != nil {
		t.Fatal(err)
	}
	defer up.Close()
	go func() {
		for {
			c, err := up.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }() // echo
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- ForwardAddrs(ctx, []string{"127.0.0.2", "127.0.0.3"}, port, "127.0.0.1") }()
	var conn net.Conn
	for i := 0; i < 100; i++ {
		if conn, err = net.Dial("tcp", fmt.Sprintf("127.0.0.2:%d", port)); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("forwarder not listening: %v", err)
	}
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write([]byte("hello dds"))
	buf := make([]byte, 9)
	if _, err := io.ReadFull(conn, buf); err != nil || string(buf) != "hello dds" {
		t.Errorf("echo through the forwarder: %q %v", buf, err)
	}
	conn.Close()
	// the second address works too
	c2, err := net.Dial("tcp", fmt.Sprintf("127.0.0.3:%d", port))
	if err != nil {
		t.Errorf("second address: %v", err)
	} else {
		c2.Close()
	}
	cancel()
	if err := <-done; err != nil {
		t.Error(err)
	}
	if _, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.2:%d", port), time.Second); err == nil {
		t.Error("listener should be closed after cancel")
	}
}

func TestForwardAddrsListenError(t *testing.T) {
	l, _ := net.Listen("tcp", "127.0.0.2:0")
	defer l.Close()
	port := l.Addr().(*net.TCPAddr).Port
	if err := ForwardAddrs(context.Background(), []string{"127.0.0.3", "127.0.0.2"}, port, "127.0.0.1"); err == nil {
		t.Error("address in use should fail")
	}
}

func TestForwardUpstreamDownClosesConnection(t *testing.T) {
	port := freePort(t) // nothing listens on 127.0.0.1:port
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ForwardAddrs(ctx, []string{"127.0.0.2"}, port, "127.0.0.1")
	var conn net.Conn
	var err error
	for i := 0; i < 100; i++ {
		if conn, err = net.Dial("tcp", fmt.Sprintf("127.0.0.2:%d", port)); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); err != io.EOF {
		t.Errorf("want EOF, got %v", err)
	}
}

// ---- X11 screenshot ----

type xauthEntry struct {
	family                uint16
	addr, num, name, data string
}

func xauth(entries ...xauthEntry) []byte {
	var b []byte
	for _, e := range entries {
		b = binary.BigEndian.AppendUint16(b, e.family)
		for _, f := range []string{e.addr, e.num, e.name, e.data} {
			b = binary.BigEndian.AppendUint16(b, uint16(len(f)))
			b = append(b, f...)
		}
	}
	return b
}

// fakeX is an X server for one connection: it checks the setup request, serves a 3x2 root window and one GetImage.
func fakeX(t *testing.T, dir string, display string, wantCookie string, getImageError bool) (width, height int, pixels []byte) {
	t.Helper()
	width, height = 3, 2
	for i := 0; i < width*height; i++ { // BGRX
		pixels = append(pixels, byte(10+i), byte(20+i), byte(30+i), 0)
	}
	l, err := net.Listen("unix", filepath.Join(dir, "X"+display))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		var h [12]byte
		io.ReadFull(c, h[:])
		nameLen, dataLen := int(binary.LittleEndian.Uint16(h[6:8])), int(binary.LittleEndian.Uint16(h[8:10]))
		pad := func(n int) int { return n + (4-n%4)%4 }
		rest := make([]byte, pad(nameLen)+pad(dataLen))
		io.ReadFull(c, rest)
		if h[0] != 0x6C || binary.LittleEndian.Uint16(h[2:4]) != 11 {
			t.Errorf("setup header %v", h)
		}
		if got := string(rest[pad(nameLen) : pad(nameLen)+dataLen]); got != wantCookie {
			t.Errorf("cookie %q, want %q", got, wantCookie)
		}
		// setup reply: 8 byte head + body (32 byte fixed part, vendor "Xvfb!" padded, 2 formats, one screen)
		vendor := []byte("Xvfb!")
		body := make([]byte, 32)
		binary.LittleEndian.PutUint16(body[16:18], uint16(len(vendor)))
		body[20], body[21] = 1, 2
		body = append(body, vendor...)
		body = append(body, make([]byte, (4-len(vendor)%4)%4)...)
		body = append(body, make([]byte, 16)...) // two pixmap formats
		screen := make([]byte, 40)
		binary.LittleEndian.PutUint32(screen[0:4], 0x1234)
		binary.LittleEndian.PutUint16(screen[20:22], uint16(width))
		binary.LittleEndian.PutUint16(screen[22:24], uint16(height))
		body = append(body, screen...)
		head := make([]byte, 8)
		head[0] = 1
		binary.LittleEndian.PutUint16(head[6:8], uint16(len(body)/4))
		c.Write(append(head, body...))
		req := make([]byte, 20)
		if _, err := io.ReadFull(c, req); err != nil {
			t.Errorf("GetImage request: %v", err)
			return
		}
		if req[0] != 73 || req[1] != 2 || binary.LittleEndian.Uint32(req[4:8]) != 0x1234 ||
			binary.LittleEndian.Uint16(req[12:14]) != uint16(width) || binary.LittleEndian.Uint16(req[14:16]) != uint16(height) ||
			binary.LittleEndian.Uint32(req[16:20]) != 0xFFFFFFFF {
			t.Errorf("GetImage request %v", req)
		}
		reply := make([]byte, 32)
		if getImageError {
			reply[0], reply[1] = 0, 8
			c.Write(reply)
			return
		}
		reply[0] = 1
		binary.LittleEndian.PutUint32(reply[4:8], uint32(len(pixels)/4))
		c.Write(append(reply, pixels...))
	}()
	return
}

func TestXShot(t *testing.T) {
	dir := t.TempDir()
	w, h, pix := fakeX(t, dir, "99", "secret-cookie-16", false)
	xa := filepath.Join(dir, "xauth")
	os.WriteFile(xa, xauth(
		xauthEntry{256, "host", "7", "MIT-MAGIC-COOKIE-1", "other-cookie-xxxx"},
		xauthEntry{256, "host", "99", "XDM-AUTHORIZATION-1", "nope"},
		xauthEntry{256, "host", "99", "MIT-MAGIC-COOKIE-1", "secret-cookie-16"},
	), 0o600)
	data, err := XShot(XOpts{Display: ":99.0", Xauth: xa, SocketDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("not a PNG: %v", err)
	}
	if img.Bounds().Dx() != w || img.Bounds().Dy() != h {
		t.Fatalf("size %v", img.Bounds())
	}
	for i := 0; i < w*h; i++ { // BGRX -> RGB
		r, g, b, a := img.At(i%w, i/w).RGBA()
		if byte(r>>8) != pix[i*4+2] || byte(g>>8) != pix[i*4+1] || byte(b>>8) != pix[i*4] || a != 0xffff {
			t.Errorf("pixel %d: %d %d %d %d", i, r>>8, g>>8, b>>8, a>>8)
		}
	}
}

func TestXShotNoAuthFileSendsEmptyCookieAndGetImageError(t *testing.T) {
	dir := t.TempDir()
	fakeX(t, dir, "5", "", true)
	_, err := XShot(XOpts{Display: ":5", Home: t.TempDir(), SocketDir: dir})
	if err == nil || err.Error() != "GetImage failed (X error 8)" {
		t.Errorf("error %v", err)
	}
	if _, err := XShot(XOpts{Display: "nocolon", SocketDir: dir}); !errors.Is(err, ErrNoDisplay) {
		t.Errorf("display %v", err)
	}
	if _, err := XShot(XOpts{Display: ":77", SocketDir: dir}); err == nil {
		t.Error("no socket")
	}
}

func TestXShotRefused(t *testing.T) {
	dir := t.TempDir()
	l, _ := net.Listen("unix", filepath.Join(dir, "X1"))
	defer l.Close()
	go func() {
		c, _ := l.Accept()
		defer c.Close()
		io.ReadFull(c, make([]byte, 12))
		reason := "No protocol specified"
		body := append([]byte(reason), make([]byte, (4-len(reason)%4)%4)...)
		head := []byte{0, byte(len(reason)), 11, 0, 0, 0, byte(len(body) / 4), 0}
		c.Write(append(head, body...))
	}()
	_, err := XShot(XOpts{Display: ":1", SocketDir: dir, Home: t.TempDir()})
	if err == nil || err.Error() != "X server refused the connection: No protocol specified" {
		t.Errorf("error %v", err)
	}
}

func TestCookieIgnoresTruncatedFile(t *testing.T) {
	dir := t.TempDir()
	full := xauth(xauthEntry{256, "h", "9", "MIT-MAGIC-COOKIE-1", "abcdefgh"})
	os.WriteFile(filepath.Join(dir, "x"), full[:len(full)-3], 0o600)
	// the truncated data is cut short; no panic
	cookie(XOpts{Xauth: filepath.Join(dir, "x")}, "9")
	os.WriteFile(filepath.Join(dir, "y"), full[:10], 0o600)
	if n, d := cookie(XOpts{Xauth: filepath.Join(dir, "y")}, "9"); n != nil || d != nil {
		t.Errorf("%q %q", n, d)
	}
	// an entry with an empty number matches every display
	os.WriteFile(filepath.Join(dir, "z"), xauth(xauthEntry{256, "h", "", "MIT-MAGIC-COOKIE-1", "any-display"}), 0o600)
	if _, d := cookie(XOpts{Xauth: filepath.Join(dir, "z")}, "42"); string(d) != "any-display" {
		t.Errorf("%q", d)
	}
}

// ---- command line ----

func TestMainUsageIsTwo(t *testing.T) {
	for _, args := range [][]string{nil, {"bogus"}, {"info"}, {"request", "1", "m"}, {"request", "x", "m", "a"}, {"reply", "f", "1"}, {"reply", "f", "x", "1"},
		{"summary"}, {"forward"}, {"forward", "x"}, {"xshot"}, {"shot", "ws://x"}, {"trace-start"}, {"trace-stop", "ws://x"}} {
		var out, errw bytes.Buffer
		if rc := Main(context.Background(), args, sys.Env{}, &out, &errw); rc != 2 {
			t.Errorf("%v: exit %d", args, rc)
		}
	}
}

func TestMainSubcommands(t *testing.T) {
	var out, errw bytes.Buffer
	if rc := Main(context.Background(), []string{"info", "testdata/flutter-run.jsonl"}, nil, &out, &errw); rc != 0 || out.String() != golden(t, "info.txt") {
		t.Errorf("info: %d %q", rc, out.String())
	}
	out.Reset()
	if rc := Main(context.Background(), []string{"request", "12", "app.stop", "abc"}, nil, &out, &errw); rc != 0 || out.String() != `[{"id": 12, "method": "app.stop", "params": {"appId": "abc"}}]`+"\n" {
		t.Errorf("request: %d %q", rc, out.String())
	}
	out.Reset()
	if rc := Main(context.Background(), []string{"summary", "testdata/trace.json"}, nil, &out, &errw); rc != 0 || out.String() != golden(t, "trace.summary.txt") {
		t.Errorf("summary: %d %q", rc, out.String())
	}
	out.Reset()
	if rc := Main(context.Background(), []string{"reply", "testdata/flutter-run.jsonl", "5", "1"}, nil, &out, &errw); rc != 0 || out.String() != "Reloaded 3 libraries\n" {
		t.Errorf("reply: %d %q", rc, out.String())
	}
	uri := wsServer(t, func(s *srvConn) {
		id, _, _ := s.request()
		s.reply(id, map[string]any{"type": "Success"})
		id, _, _ = s.request()
		s.reply(id, map[string]any{"type": "Success"})
	})
	out.Reset()
	if rc := Main(context.Background(), []string{"trace-start", uri}, nil, &out, &errw); rc != 0 || out.String() != "recording the timeline (Dart, Embedder, GC)\n" {
		t.Errorf("trace-start: %d %q %q", rc, out.String(), errw.String())
	}
	if rc := Main(context.Background(), []string{"trace-start", "ws://127.0.0.1:1/x"}, nil, &out, &errw); rc != 1 {
		t.Errorf("unreachable service: %d", rc)
	}
}
