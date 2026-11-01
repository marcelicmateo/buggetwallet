package vmservice

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"wallet-build/internal/sys"
)

// Usage is the help of `wallet-build live vm` (the subcommands of tools/live_vm.py).
const Usage = `  live vm info <machine.jsonl>                 key=value lines: state, app, mode, vm, dtd, devtools, error
  live vm request <id> <method> <app> [full]   one daemon request line for flutter run's stdin
  live vm reply <machine.jsonl> <id> <secs>    wait for the daemon's reply to <id>; exit 1 on error/timeout
  live vm shot <ws uri> <file.png>             screenshot of the app (widget inspector: debug builds only)
  live vm xshot <file.png | ->                 screenshot of the X display in $DISPLAY (Xvfb), in the container
  live vm trace-start <ws uri>                 record the Dart, Embedder and GC timeline streams from now on
  live vm trace-stop <ws uri> <out.json> [mode]  save the timeline and <out>-summary.txt
  live vm summary <trace.json>                 the summary of a saved trace
  live vm forward <port>                       in the container: forward <port> on the pod's own addresses to 127.0.0.1:<port>
`

// Main runs one live_vm.py subcommand; it returns 2 for a usage error.
func Main(ctx context.Context, args []string, env sys.Env, out, errw io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(errw, Usage)
		return 2
	}
	cmd, a := args[0], args[1:]
	need := func(n int) bool {
		if len(a) < n {
			fmt.Fprint(errw, Usage)
			return false
		}
		return true
	}
	switch cmd {
	case "info":
		if !need(1) {
			return 2
		}
		for _, kv := range Info(a[0]) {
			fmt.Fprintf(out, "%s=%s\n", kv.K, kv.V)
		}
		return 0
	case "request":
		if !need(3) {
			return 2
		}
		id, err := strconv.Atoi(a[0])
		if err != nil {
			fmt.Fprint(errw, Usage)
			return 2
		}
		fmt.Fprintln(out, Request(id, a[1], a[2], len(a) > 3 && a[3] == "full"))
		return 0
	case "reply":
		if !need(3) {
			return 2
		}
		id, err1 := strconv.Atoi(a[1])
		secs, err2 := strconv.ParseFloat(a[2], 64)
		if err1 != nil || err2 != nil {
			fmt.Fprint(errw, Usage)
			return 2
		}
		return Reply(a[0], id, secs, out, time.Sleep, time.Now)
	case "summary":
		if !need(1) {
			return 2
		}
		b, err := os.ReadFile(a[0])
		if err != nil {
			fmt.Fprintln(errw, err)
			return 1
		}
		var t struct {
			TraceEvents []json.RawMessage `json:"traceEvents"`
		}
		if err := json.Unmarshal(b, &t); err != nil {
			fmt.Fprintln(errw, err)
			return 1
		}
		fmt.Fprint(out, Summary(ParseTrace(t.TraceEvents), ""))
		return 0
	case "forward":
		if !need(1) {
			return 2
		}
		port, err := strconv.Atoi(a[0])
		if err != nil {
			fmt.Fprint(errw, Usage)
			return 2
		}
		if err := Forward(ctx, "/proc/net/fib_trie", port); err != nil {
			fmt.Fprintln(errw, err)
			return 1
		}
		return 0
	case "xshot":
		if !need(1) {
			return 2
		}
		data, err := XShot(XOpts{Display: env.Get("DISPLAY"), Xauth: env.Get("XAUTHORITY"), Home: env.Get("HOME")})
		if err != nil {
			fmt.Fprintln(errw, "xshot:", err)
			return 1
		}
		if a[0] == "-" {
			_, _ = out.Write(data)
		} else if err := os.WriteFile(a[0], data, 0o644); err != nil {
			fmt.Fprintln(errw, err)
			return 1
		}
		return 0
	case "shot", "trace-start", "trace-stop":
		if !need(1) || (cmd != "trace-start" && !need(2)) {
			return 2
		}
		c, err := Dial(a[0])
		if err != nil {
			fmt.Fprintln(errw, err)
			return 1
		}
		defer c.Close()
		return vmCommand(c, cmd, a, out, errw)
	}
	fmt.Fprint(errw, Usage)
	return 2
}

func vmCommand(c *Conn, cmd string, a []string, out, errw io.Writer) int {
	fail := func(err error) int { fmt.Fprintln(errw, err); return 1 }
	switch cmd {
	case "shot":
		data, err := c.Screenshot()
		if err != nil {
			return fail(err)
		}
		if err := os.WriteFile(a[1], data, 0o644); err != nil {
			return fail(err)
		}
		fmt.Fprintf(out, "%s (%d KB)\n", a[1], len(data)/1024)
	case "trace-start":
		if err := c.TraceStart(); err != nil {
			return fail(err)
		}
		fmt.Fprintln(out, "recording the timeline (Dart, Embedder, GC)")
	case "trace-stop":
		raw, err := c.TraceStop()
		if err != nil {
			return fail(err)
		}
		mode := ""
		if len(a) > 2 {
			mode = a[2]
		}
		if err := SaveTrace(a[1], raw, mode, out); err != nil {
			return fail(err)
		}
	}
	return 0
}

// SaveTrace writes <out>.json ({"traceEvents": …, "displayTimeUnit": "ms"}) and <out minus .json>-summary.txt, prints the summary and
// "saved <out>".
func SaveTrace(path string, raw []json.RawMessage, mode string, out io.Writer) error {
	if raw == nil {
		raw = []json.RawMessage{}
	}
	events, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(append([]byte(`{"traceEvents": `), events...), []byte(`, "displayTimeUnit": "ms"}`)...), 0o644); err != nil {
		return err
	}
	text := Summary(ParseTrace(raw), mode)
	if err := os.WriteFile(strings.TrimSuffix(path, filepath.Ext(path))+"-summary.txt", []byte(text), 0o644); err != nil {
		return err
	}
	fmt.Fprint(out, text)
	fmt.Fprintf(out, "saved %s\n", path)
	return nil
}
