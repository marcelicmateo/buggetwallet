package webdev

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
	"wallet-build/internal/vmservice"
)

var pngBytes = []byte("\x89PNG\r\n\x1a\nfake image bytes")

// fakeChrome is the DevTools endpoint of a headless Chrome: GET /json lists one page, the page's WebSocket answers the
// commands of web-shot and records them.
type fakeChrome struct {
	srv *httptest.Server
	mu  sync.Mutex
	// methods and params are what the client sent, in order.
	methods []string
	params  []map[string]any
	// readyAfter is the number of glass-pane polls that answer false before one answers true.
	readyAfter int
	polls      int
	events     []string // JSON events sent before the reply of Runtime.enable
	noPage     bool
}

func newFakeChrome(t *testing.T) *fakeChrome {
	f := &fakeChrome{}
	mux := http.NewServeMux()
	mux.HandleFunc("/json", func(w http.ResponseWriter, r *http.Request) {
		if f.noPage {
			io.WriteString(w, `[{"type":"service_worker","webSocketDebuggerUrl":"ws://x/y"}]`)
			return
		}
		fmt.Fprintf(w, `[{"type":"background_page"},{"type":"page","webSocketDebuggerUrl":"ws://%s/devtools/page/1"}]`, r.Host)
	})
	mux.HandleFunc("/devtools/page/1", f.page)
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeChrome) port() int {
	_, p, _ := net.SplitHostPort(strings.TrimPrefix(f.srv.URL, "http://"))
	n, _ := strconv.Atoi(p)
	return n
}

func writeFrame(w io.Writer, payload []byte) {
	hdr := []byte{0x81}
	switch n := len(payload); {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n < 1<<16:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 127)
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	w.Write(append(hdr, payload...))
}

func readFrame(r *bufio.Reader) ([]byte, error) {
	var h [2]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return nil, err
	}
	n := int(h[1] & 0x7f)
	switch n {
	case 126:
		var b [2]byte
		io.ReadFull(r, b[:])
		n = int(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		io.ReadFull(r, b[:])
		n = int(binary.BigEndian.Uint64(b[:]))
	}
	var mask [4]byte
	io.ReadFull(r, mask[:])
	data := make([]byte, n)
	if _, err := io.ReadFull(r, data); err != nil {
		return nil, err
	}
	for i := range data {
		data[i] ^= mask[i%4]
	}
	if h[0]&0x0f == 8 {
		return nil, io.EOF
	}
	return data, nil
}

func (f *fakeChrome) page(w http.ResponseWriter, r *http.Request) {
	conn, brw, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	defer conn.Close()
	sum := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	fmt.Fprintf(brw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(sum[:]))
	brw.Flush()
	for {
		raw, err := readFrame(brw.Reader)
		if err != nil {
			return
		}
		var req struct {
			ID     int            `json:"id"`
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		}
		if json.Unmarshal(raw, &req) != nil {
			return
		}
		f.mu.Lock()
		f.methods = append(f.methods, req.Method)
		f.params = append(f.params, req.Params)
		result := `{}`
		switch req.Method {
		case "Runtime.enable":
			for _, e := range f.events {
				writeFrame(conn, []byte(e))
			}
		case "Runtime.evaluate":
			expr, _ := req.Params["expression"].(string)
			switch {
			case strings.HasPrefix(expr, "["):
				result = `{"result":{"type":"string","value":"1,0,42,1"}}`
			case strings.HasPrefix(expr, "!!document.querySelector('flt-glass-pane')"):
				f.polls++
				result = fmt.Sprintf(`{"result":{"type":"boolean","value":%v}}`, f.polls > f.readyAfter)
			default:
				result = `{"result":{"type":"number","value":1}}`
			}
		case "Page.captureScreenshot":
			result = fmt.Sprintf(`{"data":%q}`, base64.StdEncoding.EncodeToString(pngBytes))
		case "Bad.method":
			f.mu.Unlock()
			writeFrame(conn, []byte(fmt.Sprintf(`{"id":%d,"error":{"code":-32601,"message":"nope"}}`, req.ID)))
			continue
		}
		f.mu.Unlock()
		writeFrame(conn, []byte(fmt.Sprintf(`{"id":%d,"result":%s}`, req.ID, result)))
	}
}

type shotFixture struct {
	s     *Shot
	fake  *sys.Fake
	out   *bytes.Buffer
	err   *bytes.Buffer
	clock time.Time
	slept []time.Duration
	prof  string
}

func newShot(t *testing.T, chrome *fakeChrome, env ...string) *shotFixture {
	f := &shotFixture{out: &bytes.Buffer{}, err: &bytes.Buffer{}, clock: time.Unix(1000, 0)}
	f.fake = &sys.Fake{HandleCtx: func(ctx context.Context, c sys.Cmd) int {
		for _, a := range c.Argv {
			if v, ok := strings.CutPrefix(a, "--user-data-dir="); ok {
				f.prof = v
			}
		}
		<-ctx.Done() // Chrome runs until it is terminated
		return 143
	}}
	c := run.New(t.TempDir(), sys.Env(env), f.out, f.err, f.fake)
	port := 1
	if chrome != nil {
		port = chrome.port()
	}
	f.s = &Shot{C: c, DebugPort: port,
		Sleep: func(d time.Duration) { f.slept = append(f.slept, d); f.clock = f.clock.Add(d) },
		Now:   func() time.Time { return f.clock }}
	return f
}

func TestShotCapturesAfterFlutterDrew(t *testing.T) {
	chrome := newFakeChrome(t)
	chrome.readyAfter = 2
	chrome.events = []string{
		`{"method":"Log.entryAdded","params":{"entry":{"level":"error","text":"CSP violation"}}}`,
		`{"method":"Log.entryAdded","params":{"entry":{"level":"info","text":"ignored"}}}`,
		`{"method":"Runtime.consoleAPICalled","params":{"type":"log","args":[{"type":"string","value":"hello"},{"type":"number","value":3},{"type":"boolean","value":true},{"type":"object","description":"Foo"}]}}`,
		`{"method":"Runtime.consoleAPICalled","params":{"type":"debug","args":[{"type":"string","value":"not kept"}]}}`,
		`{"method":"Runtime.exceptionThrown","params":{"exceptionDetails":{"text":"Uncaught boom"}}}`,
	}
	f := newShot(t, chrome)
	out := filepath.Join(t.TempDir(), "o.png")
	if rc := f.s.Main([]string{"http://127.0.0.1:18080/", out, "412x915"}); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	if b, _ := os.ReadFile(out); !bytes.Equal(b, pngBytes) {
		t.Errorf("png %q", b)
	}
	// the Chrome command line
	if len(f.fake.Calls) != 1 {
		t.Fatalf("calls %v", f.fake.Argvs())
	}
	a := f.fake.Calls[0].Argv
	want := []string{"chrome-bw", "--headless=new", "--remote-debugging-port=" + strconv.Itoa(chrome.port()), "--use-angle=swiftshader", "--enable-unsafe-swiftshader"}
	if strings.Join(a[:5], " ") != strings.Join(want, " ") || a[6] != "--window-size=412,915" || a[7] != "--hide-scrollbars" || a[8] != "about:blank" ||
		!strings.HasPrefix(a[5], "--user-data-dir=") {
		t.Errorf("chrome argv %q", a)
	}
	if _, err := os.Stat(f.prof); err == nil {
		t.Error("the Chrome profile folder was left behind")
	}
	// the DevTools conversation
	wantM := []string{"Log.enable", "Runtime.enable", "Emulation.setDeviceMetricsOverride", "Page.navigate", "Runtime.evaluate", "Runtime.evaluate", "Runtime.evaluate",
		"Runtime.evaluate", "Runtime.evaluate", "Page.captureScreenshot"}
	if strings.Join(chrome.methods, " ") != strings.Join(wantM, " ") {
		t.Errorf("methods %v", chrome.methods)
	}
	m := chrome.params[2]
	if m["width"] != 412.0 || m["height"] != 915.0 || m["deviceScaleFactor"] != 1.0 || m["mobile"] != false {
		t.Errorf("metrics %v", m)
	}
	if chrome.params[3]["url"] != "http://127.0.0.1:18080/" || chrome.params[9]["format"] != "png" {
		t.Errorf("navigate %v capture %v", chrome.params[3], chrome.params[9])
	}
	// two polls false (0.5 s apart), one true, then the 3 s settle
	if len(f.slept) != 3 || f.slept[0] != 500*time.Millisecond || f.slept[1] != 500*time.Millisecond || f.slept[2] != 3*time.Second {
		t.Errorf("sleeps %v", f.slept)
	}
	wantErr := "dom canvases,semantics,textlen,panes: 1,0,42,1\n" +
		"console error: CSP violation\n" +
		"console console.log: hello 3 True Foo\n" +
		"console exception: Uncaught boom\n"
	if f.err.String() != wantErr {
		t.Errorf("stderr\n%s\nwant\n%s", f.err.String(), wantErr)
	}
}

func TestShotWarnsWhenFlutterNeverDraws(t *testing.T) {
	chrome := newFakeChrome(t)
	chrome.readyAfter = 1 << 30
	f := newShot(t, chrome, "BW_SHOT_SETTLE=0.25")
	out := filepath.Join(t.TempDir(), "o.png")
	if rc := f.s.Main([]string{"http://x/", out, "100x200", "2"}); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	if !strings.HasPrefix(f.err.String(), "warning: no flt-glass-pane after 2s\n") {
		t.Errorf("stderr %q", f.err.String())
	}
	if last := f.slept[len(f.slept)-1]; last != 250*time.Millisecond {
		t.Errorf("settle %v", last)
	}
	if len(f.slept) != 5 { // 2 s of 0.5 s polls, then the settle
		t.Errorf("sleeps %v", f.slept)
	}
	if b, _ := os.ReadFile(out); !bytes.Equal(b, pngBytes) {
		t.Error("the screenshot is taken anyway")
	}
}

func TestShotChromeDoesNotStart(t *testing.T) {
	f := newShot(t, nil)
	f.s.DebugPort = 1 // nothing listens
	if rc := f.s.Main([]string{"http://x/", filepath.Join(t.TempDir(), "o.png"), "100x200"}); rc != 1 || f.err.String() != "chrome did not start\n" {
		t.Errorf("rc %d err %q", rc, f.err.String())
	}
	if len(f.slept) != 100 {
		t.Errorf("tried %d times", len(f.slept))
	}
	// only non-page targets
	chrome := newFakeChrome(t)
	chrome.noPage = true
	f = newShot(t, chrome)
	if rc := f.s.Main([]string{"http://x/", filepath.Join(t.TempDir(), "o.png"), "100x200"}); rc != 1 || f.err.String() != "chrome did not start\n" {
		t.Errorf("no page: rc %d err %q", rc, f.err.String())
	}
}

func TestShotUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"u"}, {"u", "o"}, {"u", "o", "100"}, {"u", "o", "100x"}, {"u", "o", "100x200", "soon"}, {"u", "o", "100x200", "1", "extra"}} {
		f := newShot(t, nil)
		if rc := f.s.Main(args); rc != 2 || f.err.String() != ShotUsage || len(f.fake.Calls) != 0 {
			t.Errorf("%v: rc %d err %q", args, rc, f.err.String())
		}
	}
	f := newShot(t, nil, "BW_SHOT_SETTLE=abc")
	if rc := f.s.Main([]string{"u", "o", "100x200"}); rc != 1 || len(f.fake.Calls) != 0 {
		t.Errorf("bad settle: rc %d", rc)
	}
}

func TestDevToolsErrorReply(t *testing.T) {
	chrome := newFakeChrome(t)
	conn, err := vmservice.Dial("ws://127.0.0.1:" + strconv.Itoa(chrome.port()) + "/devtools/page/1")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	d := &cdp{conn: conn}
	if _, err := d.call("Bad.method", nil); err == nil || !strings.Contains(err.Error(), "Bad.method") || !strings.Contains(err.Error(), "nope") {
		t.Errorf("error %v", err)
	}
	// the connection is still usable afterwards, and ids keep counting
	if _, err := d.call("Log.enable", nil); err != nil || d.n != 2 {
		t.Errorf("after the error: %v (n=%d)", err, d.n)
	}
}

func TestClipAndPyStr(t *testing.T) {
	if got := clip(strings.Repeat("é", 400), 300); len([]rune(got)) != 300 {
		t.Errorf("clip %d runes", len([]rune(got)))
	}
	if clip("short", 300) != "short" {
		t.Error("short")
	}
	for in, want := range map[any]string{nil: "None", true: "True", false: "False", "s": "s", json.Number("1.5"): "1.5"} {
		if got := pyStr(in); got != want {
			t.Errorf("pyStr(%v) = %q, want %q", in, got, want)
		}
	}
	if got := pyStr([]any{1.0}); got != "[1]" {
		t.Errorf("list %q", got)
	}
}

func TestChromeArgs(t *testing.T) {
	got := strings.Join(ChromeArgs(9222, "/p", 412, 915), " ")
	want := "--headless=new --remote-debugging-port=9222 --use-angle=swiftshader --enable-unsafe-swiftshader --user-data-dir=/p --window-size=412,915 --hide-scrollbars about:blank"
	if got != want {
		t.Errorf("got %s", got)
	}
}
