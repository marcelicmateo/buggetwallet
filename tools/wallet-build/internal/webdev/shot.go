package webdev

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
	"wallet-build/internal/vmservice"
)

// ShotUsage is what `web-shot` prints for a wrong command line.
const ShotUsage = "usage: wallet-build web-shot <url> <out.png> <width>x<height> [wait-seconds]\n"

// Shot is `web-shot <url> <out.png> <W>x<H> [wait=20]` (runs in the build container; used by `web shot`): a screenshot of a
// Flutter web page with headless Chrome. Chrome's own --screenshot fires at the load event, before Flutter has drawn
// anything, so this drives Chrome over the DevTools protocol, waits until Flutter's <flt-glass-pane> exists plus a settle time
// (BW_SHOT_SETTLE seconds, default 3), and captures then.
type Shot struct {
	C *run.Ctx
	// DebugPort is Chrome's remote debugging port.
	DebugPort int
	// Sleep is a variable for the tests.
	Sleep func(time.Duration)
	// Now is the clock of the page-ready deadline.
	Now func() time.Time
}

// NewShot returns a Shot with the real clock and Chrome's usual port 9222.
func NewShot(c *run.Ctx) *Shot {
	return &Shot{C: c, DebugPort: 9222, Sleep: time.Sleep, Now: time.Now}
}

// ChromeArgs are the flags of the headless Chrome (chrome-bw is the image's wrapper).
func ChromeArgs(port int, profile string, w, h int) []string {
	return []string{"--headless=new", "--remote-debugging-port=" + strconv.Itoa(port), "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
		"--user-data-dir=" + profile, fmt.Sprintf("--window-size=%d,%d", w, h), "--hide-scrollbars", "about:blank"}
}

type cdp struct {
	conn   *vmservice.Conn
	n      int
	events []event
}

type event struct{ level, text string }

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

// pyStr is Python's str() of a decoded JSON value, for the console arguments.
func pyStr(v any) string {
	switch x := v.(type) {
	case nil:
		return "None"
	case bool:
		if x {
			return "True"
		}
		return "False"
	case string:
		return x
	case json.Number:
		return x.String()
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func (d *cdp) event(raw []byte) {
	var m struct {
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	switch m.Method {
	case "Log.entryAdded":
		var p struct {
			Entry struct{ Level, Text string }
		}
		if json.Unmarshal(m.Params, &p) == nil && (p.Entry.Level == "error" || p.Entry.Level == "warning") {
			d.events = append(d.events, event{p.Entry.Level, clip(p.Entry.Text, 300)})
		}
	case "Runtime.consoleAPICalled":
		var p struct {
			Type string
			Args []map[string]any
		}
		dec := json.NewDecoder(strings.NewReader(string(m.Params)))
		dec.UseNumber()
		if dec.Decode(&p) == nil && (p.Type == "error" || p.Type == "warning" || p.Type == "log") {
			var parts []string
			for _, a := range p.Args {
				v, ok := a["value"]
				if !ok {
					v = a["description"]
					if v == nil {
						v = ""
					}
				}
				parts = append(parts, pyStr(v))
			}
			d.events = append(d.events, event{"console." + p.Type, clip(strings.Join(parts, " "), 300)})
		}
	case "Runtime.exceptionThrown":
		var p struct {
			ExceptionDetails struct{ Text string }
		}
		if json.Unmarshal(m.Params, &p) == nil {
			d.events = append(d.events, event{"exception", clip(p.ExceptionDetails.Text, 300)})
		}
	}
}

// call sends one DevTools command and waits for its reply; the events that arrive meanwhile are collected.
func (d *cdp) call(method string, params map[string]any) (json.RawMessage, error) {
	d.n++
	if params == nil {
		params = map[string]any{}
	}
	req, _ := json.Marshal(map[string]any{"id": d.n, "method": method, "params": params})
	if err := d.conn.WriteText(req); err != nil {
		return nil, err
	}
	for {
		raw, err := d.conn.ReadMessage()
		if err != nil {
			return nil, err
		}
		d.event(raw)
		var msg struct {
			ID     *int            `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if json.Unmarshal(raw, &msg) != nil || msg.ID == nil || *msg.ID != d.n {
			continue
		}
		if len(msg.Error) > 0 && string(msg.Error) != "null" {
			return nil, fmt.Errorf("%s: %s", method, msg.Error)
		}
		return msg.Result, nil
	}
}

// evaluate runs a JavaScript expression and returns the value of the result (as JSON).
func (d *cdp) evaluate(expr string) (json.RawMessage, error) {
	res, err := d.call("Runtime.evaluate", map[string]any{"expression": expr, "returnByValue": true})
	if err != nil {
		return nil, err
	}
	var r struct {
		Result struct {
			Value json.RawMessage `json:"value"`
		} `json:"result"`
	}
	if err := json.Unmarshal(res, &r); err != nil {
		return nil, err
	}
	return r.Result.Value, nil
}

func (s *Shot) fail(format string, a ...any) int {
	s.C.Eprintf(format+"\n", a...)
	return 1
}

// Main runs the command; 0 when the PNG was written, 1 on any failure (Chrome did not start, a DevTools error).
func (s *Shot) Main(args []string) int {
	c := s.C
	if len(args) < 3 || len(args) > 4 {
		c.Eprintf("%s", ShotUsage)
		return 2
	}
	url, out, size := args[0], args[1], args[2]
	wait := 20.0
	if len(args) == 4 {
		v, err := strconv.ParseFloat(args[3], 64)
		if err != nil {
			c.Eprintf("%s", ShotUsage)
			return 2
		}
		wait = v
	}
	var w, h int
	if _, err := fmt.Sscanf(size, "%dx%d", &w, &h); err != nil || !reSize.MatchString(size) {
		c.Eprintf("%s", ShotUsage)
		return 2
	}
	settle := 3.0
	if v := c.Getenv("BW_SHOT_SETTLE"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return s.fail("BW_SHOT_SETTLE is not a number: %s", v)
		}
		settle = f
	}
	prof, err := os.MkdirTemp("", "web-shot-profile")
	if err != nil {
		return s.fail("%v", err)
	}
	defer os.RemoveAll(prof)
	ctx, cancel := context.WithCancel(c.Ctx)
	done := make(chan int, 1)
	go func() {
		done <- c.R.Run(ctx, sys.Cmd{Argv: append([]string{"chrome-bw"}, ChromeArgs(s.DebugPort, prof, w, h)...), Env: c.Env})
	}()
	defer func() { // chrome.terminate()
		cancel()
		<-done
	}()
	return s.drive(url, out, w, h, wait, settle)
}

func (s *Shot) drive(url, out string, w, h int, wait, settle float64) int {
	c := s.C
	base := "http://127.0.0.1:" + strconv.Itoa(s.DebugPort)
	var wsURL string
	cl := &http.Client{Timeout: 5 * time.Second}
	for i := 0; i < 100 && wsURL == ""; i++ {
		if resp, err := cl.Get(base + "/json"); err == nil {
			var tabs []struct {
				Type string `json:"type"`
				WS   string `json:"webSocketDebuggerUrl"`
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if json.Unmarshal(body, &tabs) == nil {
				for _, t := range tabs {
					if t.Type == "page" && t.WS != "" {
						wsURL = t.WS
						break
					}
				}
			}
		}
		if wsURL == "" {
			s.Sleep(200 * time.Millisecond)
		}
	}
	if wsURL == "" {
		return s.fail("chrome did not start")
	}
	conn, err := vmservice.Dial(wsURL)
	if err != nil {
		return s.fail("%v", err)
	}
	defer conn.Close()
	d := &cdp{conn: conn}
	for _, step := range []struct {
		method string
		params map[string]any
	}{
		{"Log.enable", nil}, {"Runtime.enable", nil},
		{"Emulation.setDeviceMetricsOverride", map[string]any{"width": w, "height": h, "deviceScaleFactor": 1, "mobile": false}},
		{"Page.navigate", map[string]any{"url": url}},
	} {
		if _, err := d.call(step.method, step.params); err != nil {
			return s.fail("%v", err)
		}
	}
	deadline := s.Now().Add(time.Duration(wait * float64(time.Second)))
	ready := false
	for s.Now().Before(deadline) {
		v, err := d.evaluate("!!document.querySelector('flt-glass-pane')")
		if err != nil {
			return s.fail("%v", err)
		}
		if string(v) == "true" {
			ready = true
			break
		}
		s.Sleep(500 * time.Millisecond)
	}
	if !ready {
		c.Eprintf("warning: no flt-glass-pane after %ds\n", int(wait))
	}
	s.Sleep(time.Duration(settle * float64(time.Second))) // fonts and first frames
	if _, err := d.evaluate("1"); err != nil {            // reads pending events
		return s.fail("%v", err)
	}
	v, err := d.evaluate("[document.querySelectorAll('canvas').length, document.querySelectorAll('flt-semantics').length," +
		" (document.body.innerText||'').length, document.querySelectorAll('flt-glass-pane').length].join(',')")
	if err != nil {
		return s.fail("%v", err)
	}
	var dom string
	_ = json.Unmarshal(v, &dom)
	c.Eprintf("dom canvases,semantics,textlen,panes: %s\n", dom)
	for _, e := range d.events {
		c.Eprintf("console %s: %s\n", e.level, e.text)
	}
	res, err := d.call("Page.captureScreenshot", map[string]any{"format": "png"})
	if err != nil {
		return s.fail("%v", err)
	}
	var shot struct{ Data string }
	if err := json.Unmarshal(res, &shot); err != nil {
		return s.fail("%v", err)
	}
	png, err := base64.StdEncoding.DecodeString(shot.Data)
	if err != nil {
		return s.fail("%v", err)
	}
	if err := os.WriteFile(out, png, 0o644); err != nil {
		return s.fail("%v", err)
	}
	return 0
}
