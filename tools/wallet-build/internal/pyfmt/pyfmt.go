// Package pyfmt has the few Python formatting rules the ported helpers need to print the same text as the scripts:
// thousands separators ({:,}), str() and repr() of decoded JSON values, and nearest-rank percentiles.
package pyfmt

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"wallet-build/internal/report"
)

// Comma is f"{n:,}": thousands separators.
func Comma(n int64) string {
	s := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	var out []byte
	for i := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, s[i])
	}
	if neg {
		return "-" + string(out)
	}
	return string(out)
}

// PadRight is s.ljust(w) (width in runes).
func PadRight(s string, w int) string {
	if n := utf8.RuneCountInString(s); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

// PadLeft is s.rjust(w).
func PadLeft(s string, w int) string {
	if n := utf8.RuneCountInString(s); n < w {
		return strings.Repeat(" ", w-n) + s
	}
	return s
}

// Rank is the nearest-rank percentile of an ascending list: the element at ceil(p/100 * n), 1-based.
func Rank(sorted []float64, p float64) (float64, bool) {
	if len(sorted) == 0 {
		return 0, false
	}
	k := int(math.Max(1, math.Ceil(p/100*float64(len(sorted)))))
	if k > len(sorted) {
		k = len(sorted)
	}
	return sorted[k-1], true
}

// Sum is Python's sum() of numbers: Neumaier-compensated for floats (CPython 3.12+).
func Sum(xs []float64) float64 {
	var f, c float64
	for _, x := range xs {
		t := f + x
		if math.Abs(f) >= math.Abs(x) {
			c += (f - t) + x
		} else {
			c += (x - t) + f
		}
		f = t
	}
	if c != 0 && !math.IsInf(c, 0) && !math.IsNaN(c) {
		f += c
	}
	return f
}

// Str is str(v) of a value decoded from JSON (nil, bool, string, json.Number, report.Obj, []any).
func Str(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return Repr(v)
}

// Repr is repr(v) of a decoded JSON value.
func Repr(v any) string {
	switch x := v.(type) {
	case nil:
		return "None"
	case bool:
		if x {
			return "True"
		}
		return "False"
	case string:
		return ReprString(x)
	case json.Number:
		s := report.NumRepr(x)
		if s == "-0" {
			s = "0"
		}
		return s
	case float64:
		return report.PyFloat(x)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case report.Obj: // json.loads(..., object_pairs_hook=OrderedDict) makes every object an OrderedDict (repr of Python 3.12+)
		if len(x) == 0 {
			return "OrderedDict()"
		}
		parts := make([]string, len(x))
		for i, kv := range x {
			parts[i] = ReprString(kv.K) + ": " + Repr(kv.V)
		}
		return "OrderedDict({" + strings.Join(parts, ", ") + "})"
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = Repr(e)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	}
	return fmt.Sprint(v)
}

// ReprString is repr(s) of a str: single quotes unless the text has a ' and no ", backslash escapes, \xNN, \uNNNN, \UNNNNNNNN
// for what is not printable.
func ReprString(s string) string {
	q := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		q = '"'
	}
	var sb strings.Builder
	sb.WriteByte(q)
	for _, r := range s {
		switch {
		case r == rune(q) || r == '\\':
			sb.WriteByte('\\')
			sb.WriteRune(r)
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case r == '\t':
			sb.WriteString(`\t`)
		case r == ' ' || (r < 0x7f && r > ' '):
			sb.WriteRune(r)
		case r < 0x100 && !printable(r):
			fmt.Fprintf(&sb, `\x%02x`, r)
		case !printable(r):
			if r > 0xffff {
				fmt.Fprintf(&sb, `\U%08x`, r)
			} else {
				fmt.Fprintf(&sb, `\u%04x`, r)
			}
		default:
			sb.WriteRune(r)
		}
	}
	sb.WriteByte(q)
	return sb.String()
}

func printable(r rune) bool { return r != utf8.RuneError && unicode.IsPrint(r) }
