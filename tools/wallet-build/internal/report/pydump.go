package report

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// Dumper encodes like Python's json.dumps/json.dump for the options the tools use. PyJSON (", " and ": ", no indent,
// ensure_ascii=False) stays the encoder of the history lines; this one adds the other shapes:
//
//	Dumper{Indent: 1}                          json.dump(v, f, ensure_ascii=False, indent=1)   (fixtures)
//	Dumper{Indent: 1, ASCII: true}             json.dump(v, f, indent=1)                       (mutate, token-usage)
//	Dumper{Compact: true}                      json.dumps(v, ensure_ascii=False, separators=(',', ':'))  (log-summary)
//
// Indent > 0 puts every element on its own line, Indent spaces per level, "," at the line end and ": " after keys; empty
// containers are "[]" and "{}". Without Indent the separators are ", " and ": " (Compact: "," and ":"). There is no
// trailing newline, as with Python.
type Dumper struct {
	Indent  int
	Compact bool
	ASCII   bool
}

// Dump encodes v: nil, bool, string, int, int64, float64, json.Number, Obj, []any, []string, []int.
func (d Dumper) Dump(v any) string {
	var sb strings.Builder
	d.enc(&sb, v, 0)
	return sb.String()
}

func (d Dumper) str(sb *strings.Builder, s string) {
	if d.ASCII {
		quoteASCII(sb, s)
	} else {
		quote(sb, s)
	}
}

func (d Dumper) open(sb *strings.Builder, b byte, level int) {
	sb.WriteByte(b)
	if d.Indent > 0 {
		sb.WriteByte('\n')
		sb.WriteString(strings.Repeat(" ", d.Indent*(level+1)))
	}
}

func (d Dumper) next(sb *strings.Builder, level int) {
	switch {
	case d.Indent > 0:
		sb.WriteString(",\n")
		sb.WriteString(strings.Repeat(" ", d.Indent*(level+1)))
	case d.Compact:
		sb.WriteByte(',')
	default:
		sb.WriteString(", ")
	}
}

func (d Dumper) close(sb *strings.Builder, b byte, level int) {
	if d.Indent > 0 {
		sb.WriteByte('\n')
		sb.WriteString(strings.Repeat(" ", d.Indent*level))
	}
	sb.WriteByte(b)
}

func (d Dumper) enc(sb *strings.Builder, v any, level int) {
	switch x := v.(type) {
	case nil:
		sb.WriteString("null")
	case bool:
		sb.WriteString(strconv.FormatBool(x))
	case string:
		d.str(sb, x)
	case int:
		sb.WriteString(strconv.Itoa(x))
	case int64:
		sb.WriteString(strconv.FormatInt(x, 10))
	case float64:
		sb.WriteString(PyFloat(x))
	case json.Number:
		s := NumRepr(x)
		if s == "-0" {
			s = "0" // Python's int has no negative zero
		}
		sb.WriteString(s)
	case Obj:
		if len(x) == 0 {
			sb.WriteString("{}")
			return
		}
		d.open(sb, '{', level)
		for i, kv := range x {
			if i > 0 {
				d.next(sb, level)
			}
			d.str(sb, kv.K)
			if d.Compact {
				sb.WriteByte(':')
			} else {
				sb.WriteString(": ")
			}
			d.enc(sb, kv.V, level+1)
		}
		d.close(sb, '}', level)
	case []any:
		d.list(sb, len(x), level, func(i int) { d.enc(sb, x[i], level+1) })
	case []string:
		d.list(sb, len(x), level, func(i int) { d.str(sb, x[i]) })
	case []int:
		d.list(sb, len(x), level, func(i int) { sb.WriteString(strconv.Itoa(x[i])) })
	default:
		panic(fmt.Sprintf("report.Dumper: unsupported %T", v))
	}
}

func (d Dumper) list(sb *strings.Builder, n, level int, elem func(i int)) {
	if n == 0 {
		sb.WriteString("[]")
		return
	}
	d.open(sb, '[', level)
	for i := 0; i < n; i++ {
		if i > 0 {
			d.next(sb, level)
		}
		elem(i)
	}
	d.close(sb, ']', level)
}

// quoteASCII is json's ensure_ascii=True string: everything outside space..~ becomes \uXXXX (surrogate pairs above the BMP).
func quoteASCII(sb *strings.Builder, s string) {
	sb.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		i += size
		switch {
		case r == '"':
			sb.WriteString(`\"`)
		case r == '\\':
			sb.WriteString(`\\`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case r == '\t':
			sb.WriteString(`\t`)
		case r == '\b':
			sb.WriteString(`\b`)
		case r == '\f':
			sb.WriteString(`\f`)
		case r >= ' ' && r <= '~':
			sb.WriteRune(r)
		case r > 0xffff:
			r1, r2 := utf16.EncodeRune(r)
			fmt.Fprintf(sb, `\u%04x\u%04x`, r1, r2)
		default:
			fmt.Fprintf(sb, `\u%04x`, r)
		}
	}
	sb.WriteByte('"')
}
