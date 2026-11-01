// Package report ports tools/build_log.py and tools/stage_summary.py: test-report parsing, summaries, history lines.
package report

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

// KV is one key/value of an ordered JSON object.
type KV struct {
	K string
	V any
}

// Obj is a JSON object that keeps its key order, as Python dicts do.
type Obj []KV

// Get returns the value of k.
func (o Obj) Get(k string) (any, bool) {
	for _, kv := range o {
		if kv.K == k {
			return kv.V, true
		}
	}
	return nil, false
}

// Merge is {**o, **other}: other's values replace in place, new keys are appended.
func (o Obj) Merge(other Obj) Obj {
	out := append(Obj(nil), o...)
	for _, kv := range other {
		found := false
		for i := range out {
			if out[i].K == kv.K {
				out[i].V = kv.V
				found = true
				break
			}
		}
		if !found {
			out = append(out, kv)
		}
	}
	return out
}

// PyJSON encodes like Python's json.dumps(v, ensure_ascii=False): ", " and ": " separators, floats as Python's repr.
func PyJSON(v any) string {
	var sb strings.Builder
	encode(&sb, v)
	return sb.String()
}

func encode(sb *strings.Builder, v any) {
	switch x := v.(type) {
	case nil:
		sb.WriteString("null")
	case bool:
		sb.WriteString(strconv.FormatBool(x))
	case string:
		quote(sb, x)
	case int:
		sb.WriteString(strconv.Itoa(x))
	case int64:
		sb.WriteString(strconv.FormatInt(x, 10))
	case float64:
		sb.WriteString(PyFloat(x))
	case json.Number:
		sb.WriteString(NumRepr(x))
	case Obj:
		sb.WriteByte('{')
		for i, kv := range x {
			if i > 0 {
				sb.WriteString(", ")
			}
			quote(sb, kv.K)
			sb.WriteString(": ")
			encode(sb, kv.V)
		}
		sb.WriteByte('}')
	case []any:
		sb.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				sb.WriteString(", ")
			}
			encode(sb, e)
		}
		sb.WriteByte(']')
	default:
		fmt.Fprintf(sb, "%v", x)
	}
}

func quote(sb *strings.Builder, s string) {
	sb.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString(`\"`)
		case '\\':
			sb.WriteString(`\\`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		case '\b':
			sb.WriteString(`\b`)
		case '\f':
			sb.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(sb, `\u%04x`, r)
			} else if r == utf8.RuneError {
				sb.WriteString(`�`)
			} else {
				sb.WriteRune(r)
			}
		}
	}
	sb.WriteByte('"')
}

// NumRepr is what Python prints for a number read from JSON: integers as written, floats as repr(float).
func NumRepr(n json.Number) string {
	s := n.String()
	if !strings.ContainsAny(s, ".eE") {
		return s
	}
	f, err := n.Float64()
	if err != nil {
		return s
	}
	return PyFloat(f)
}

// PyFloat is Python's repr(float).
func PyFloat(f float64) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	case f == 0:
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	e := strconv.FormatFloat(math.Abs(f), 'e', -1, 64) // d.ddde±XX, shortest digits
	mant, expS, _ := strings.Cut(e, "e")
	exp, _ := strconv.Atoi(expS)
	digits := strings.Replace(mant, ".", "", 1)
	sign := ""
	if f < 0 {
		sign = "-"
	}
	if exp < -4 || exp >= 16 {
		m := digits[:1]
		if len(digits) > 1 {
			m += "." + digits[1:]
		}
		es := "+"
		if exp < 0 {
			es = "-"
			exp = -exp
		}
		return fmt.Sprintf("%s%se%s%02d", sign, m, es, exp)
	}
	if exp >= 0 {
		for len(digits) < exp+1 {
			digits += "0"
		}
		frac := digits[exp+1:]
		if frac == "" {
			frac = "0"
		}
		return sign + digits[:exp+1] + "." + frac
	}
	return sign + "0." + strings.Repeat("0", -exp-1) + digits
}

// ParseObj decodes one JSON object keeping key order; numbers stay json.Number.
func ParseObj(line string) (Obj, error) {
	dec := json.NewDecoder(strings.NewReader(line))
	dec.UseNumber()
	v, err := parseValue(dec)
	if err != nil {
		return nil, err
	}
	o, ok := v.(Obj)
	if !ok {
		return nil, fmt.Errorf("not an object")
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing data")
	}
	return o, nil
}

func parseValue(dec *json.Decoder) (any, error) {
	t, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch x := t.(type) {
	case json.Delim:
		switch x {
		case '{':
			var o Obj
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				o = append(o, KV{kt.(string), v})
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			if o == nil {
				o = Obj{}
			}
			return o, nil
		case '[':
			arr := []any{}
			for dec.More() {
				v, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				arr = append(arr, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return arr, nil
		}
	}
	return t, nil
}

// Str is Python's str() of a decoded JSON value.
func Str(v any) string {
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
		return NumRepr(x)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return PyFloat(x)
	}
	return fmt.Sprint(v)
}

// Num returns v as a float64 (ok false for non-numbers; bools count as numbers like in Python).
func Num(v any) (float64, bool) {
	switch x := v.(type) {
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case bool:
		if x {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}
