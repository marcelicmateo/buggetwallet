package vmservice

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// RPCError is a JSON-RPC error response; Error() has live_vm.py's text.
type RPCError struct {
	Method, Message, Data string
}

func (e *RPCError) Error() string { return fmt.Sprintf("%s: %s %s", e.Method, e.Message, e.Data) }

// Call sends a JSON-RPC 2.0 request and waits for the response with the same id (events and other messages are skipped).
// It returns the raw "result".
func (c *Conn) Call(method string, params map[string]any) (json.RawMessage, error) {
	c.nextID++
	id := strconv.Itoa(c.nextID)
	if params == nil {
		params = map[string]any{}
	}
	req, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	if err != nil {
		return nil, err
	}
	if err := c.send(opText, req); err != nil {
		return nil, err
	}
	for {
		raw, err := c.message()
		if err != nil {
			return nil, err
		}
		var msg struct {
			ID     any             `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Message string          `json:"message"`
				Data    json.RawMessage `json:"data"`
			} `json:"error"`
		}
		if err := json.Unmarshal(raw, &msg); err != nil {
			return nil, fmt.Errorf("%s: unreadable response: %v", method, err)
		}
		if s, ok := msg.ID.(string); !ok || s != id {
			continue
		}
		if msg.Error != nil {
			return nil, &RPCError{Method: method, Message: msg.Error.Message, Data: dataText(msg.Error.Data)}
		}
		return msg.Result, nil
	}
}

// dataText is str(error.get('data', ”)): a string as it is, anything else in Python's repr.
func dataText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	v := decodeOrdered(raw)
	if s, ok := v.(string); ok {
		return s
	}
	return PyRepr(v)
}

// MainIsolate is the id of the isolate whose name starts with "main", else the first one.
func (c *Conn) MainIsolate() (string, error) {
	res, err := c.Call("getVM", nil)
	if err != nil {
		return "", err
	}
	var vm struct {
		Isolates []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"isolates"`
	}
	if err := json.Unmarshal(res, &vm); err != nil {
		return "", err
	}
	for _, i := range vm.Isolates {
		if strings.HasPrefix(i.Name, "main") {
			return i.ID, nil
		}
	}
	if len(vm.Isolates) == 0 {
		return "", errors.New("getVM: no isolates")
	}
	return vm.Isolates[0].ID, nil
}

// Screenshot is the PNG of the whole app: the widget inspector's screenshot of the root widget (debug builds), else the
// engine's rasterizer screenshot (fails with Impeller on Linux in 3.47).
func (c *Conn) Screenshot() ([]byte, error) {
	iso, err := c.MainIsolate()
	if err != nil {
		return nil, err
	}
	png, first := c.inspectorScreenshot(iso)
	if first == nil && len(png) > 0 {
		return png, nil
	}
	if first == nil {
		first = errors.New("the inspector returned no image")
	}
	res, err := c.Call("_flutter.screenshot", nil)
	if err == nil {
		var r struct {
			Screenshot string `json:"screenshot"`
		}
		if err = json.Unmarshal(res, &r); err == nil {
			return base64.StdEncoding.DecodeString(r.Screenshot)
		}
	}
	return nil, fmt.Errorf("no screenshot: %v; %v", first, err)
}

func (c *Conn) inspectorScreenshot(iso string) ([]byte, error) {
	res, err := c.Call("ext.flutter.inspector.getRootWidgetTree", map[string]any{"isolateId": iso, "groupName": "bw-shot",
		"isSummaryTree": "true", "withPreviews": "false", "fullDetails": "false"})
	if err != nil {
		return nil, err
	}
	var tree struct {
		Result struct {
			ValueID string `json:"valueId"`
		} `json:"result"`
	}
	if err := json.Unmarshal(res, &tree); err != nil {
		return nil, err
	}
	// width/height are an upper bound: the root is drawn at its own size (pixel ratio 1)
	shot, serr := c.Call("ext.flutter.inspector.screenshot", map[string]any{"isolateId": iso, "id": tree.Result.ValueID, "width": "10000",
		"height": "10000", "margin": "0", "maxPixelRatio": "1", "debugPaint": "false"})
	_, derr := c.Call("ext.flutter.inspector.disposeGroup", map[string]any{"isolateId": iso, "objectGroup": "bw-shot"})
	if serr != nil {
		return nil, serr
	}
	if derr != nil {
		return nil, derr
	}
	var img struct {
		Result string `json:"result"`
	}
	if err := json.Unmarshal(shot, &img); err != nil {
		return nil, err
	}
	if img.Result == "" {
		return nil, nil
	}
	return base64.StdEncoding.DecodeString(img.Result)
}

// TraceStart starts recording the Dart, Embedder and GC timeline streams and clears the buffer.
func (c *Conn) TraceStart() error {
	if _, err := c.Call("setVMTimelineFlags", map[string]any{"recordedStreams": []string{"Dart", "Embedder", "GC"}}); err != nil {
		return err
	}
	_, err := c.Call("clearVMTimeline", nil)
	return err
}

// TraceStop returns the recorded trace events (raw JSON) and stops recording.
func (c *Conn) TraceStop() ([]json.RawMessage, error) {
	res, err := c.Call("getVMTimeline", nil)
	if err != nil {
		return nil, err
	}
	if _, err := c.Call("setVMTimelineFlags", map[string]any{"recordedStreams": []string{}}); err != nil {
		return nil, err
	}
	var tl struct {
		TraceEvents []json.RawMessage `json:"traceEvents"`
	}
	if err := json.Unmarshal(res, &tl); err != nil {
		return nil, err
	}
	return tl.TraceEvents, nil
}

// ---- Python-style text of decoded JSON (the daemon's error replies are printed as a Python dict was) ----

type pair struct {
	k string
	v any
}

// ordered is a JSON object with its key order.
type ordered []pair

// decodeOrdered decodes JSON keeping object key order; numbers stay json.Number.
func decodeOrdered(raw []byte) any {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	v, _ := decodeValue(d)
	return v
}

func decodeValue(d *json.Decoder) (any, error) {
	t, err := d.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := t.(json.Delim); ok {
		switch delim {
		case '{':
			var o ordered
			for d.More() {
				kt, err := d.Token()
				if err != nil {
					return o, err
				}
				v, err := decodeValue(d)
				if err != nil {
					return o, err
				}
				o = append(o, pair{kt.(string), v})
			}
			_, err = d.Token()
			return o, err
		case '[':
			l := []any{}
			for d.More() {
				v, err := decodeValue(d)
				if err != nil {
					return l, err
				}
				l = append(l, v)
			}
			_, err = d.Token()
			return l, err
		}
	}
	return t, nil
}

// PyRepr is Python's repr() of a value from decodeOrdered: dicts in key order, single-quoted strings, True/False/None.
func PyRepr(v any) string {
	switch x := v.(type) {
	case nil:
		return "None"
	case bool:
		if x {
			return "True"
		}
		return "False"
	case string:
		return pyStr(x)
	case json.Number:
		s := x.String()
		if strings.ContainsAny(s, ".eE") {
			f, err := strconv.ParseFloat(s, 64)
			if err != nil {
				return s
			}
			r := strconv.FormatFloat(f, 'g', -1, 64)
			if !strings.ContainsAny(r, ".eEIN") {
				r += ".0"
			}
			return r
		}
		return s
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = PyRepr(e)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case ordered:
		parts := make([]string, len(x))
		for i, p := range x {
			parts[i] = pyStr(p.k) + ": " + PyRepr(p.v)
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return fmt.Sprint(v)
}

func pyStr(s string) string {
	q := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		q = '"'
	}
	var b strings.Builder
	b.WriteByte(q)
	for _, r := range s {
		switch {
		case r == rune(q) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte(q)
	return b.String()
}
