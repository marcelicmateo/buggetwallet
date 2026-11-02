package fixtures

import (
	"bytes"
	"compress/zlib"
	"fmt"
	"sort"
)

// pdfObj is one numbered object body.
type pdfObj struct {
	num  int
	body []byte
}

// pdfObjects is the header plus the numbered objects in the given order; it returns the bytes and the offset of each object.
func pdfObjects(objs []pdfObj) ([]byte, map[int]int) {
	out := []byte("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
	offs := map[int]int{}
	for _, o := range objs {
		offs[o.num] = len(out)
		out = fmt.Appendf(out, "%d 0 obj\n", o.num)
		out = append(out, o.body...)
		out = append(out, "\nendobj\n"...)
	}
	return out, offs
}

func maxKey(m map[int]int) int {
	keys := make([]int, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	return keys[len(keys)-1]
}

// pdfFile is a classic PDF: header, objects in the given order, xref table, trailer.
func pdfFile(objs []pdfObj, root int, trailerExtra string) []byte {
	out, offs := pdfObjects(objs)
	xref := len(out)
	size := maxKey(offs) + 1
	out = fmt.Appendf(out, "xref\n0 %d\n0000000000 65535 f \n", size)
	for i := 1; i < size; i++ {
		if off, ok := offs[i]; ok {
			out = fmt.Appendf(out, "%010d 00000 n \n", off)
		} else {
			out = append(out, "0000000000 65535 f \n"...)
		}
	}
	out = fmt.Appendf(out, "trailer\n<< /Size %d /Root %d 0 R %s>>\nstartxref\n%d\n%%%%EOF\n", size, root, trailerExtra, xref)
	return out
}

// deflate is zlib.compress(data): the zlib container, Go's deflate at the default level (6 like Python's).
func deflate(data []byte) []byte {
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	_, _ = w.Write(data)
	_ = w.Close()
	return buf.Bytes()
}

// pdfStream is a stream object; flate compresses the data and adds the filter entry.
func pdfStream(dict string, data []byte, flate bool) []byte {
	if flate {
		data = deflate(data)
		dict += " /Filter /FlateDecode"
	}
	out := []byte("<< " + dict)
	out = fmt.Appendf(out, " /Length %d >>\nstream\n", len(data))
	out = append(out, data...)
	return append(out, "\nendstream"...)
}

// pdfLiteral is a PDF literal string: parentheses and backslash escaped, other control and high bytes as octal.
func pdfLiteral(bs []byte) []byte {
	out := []byte("(")
	for _, c := range bs {
		switch {
		case c == '(' || c == ')' || c == '\\':
			out = append(out, '\\', c)
		case c >= 0x80 || c < 0x20:
			out = fmt.Appendf(out, "\\%03o", c)
		default:
			out = append(out, c)
		}
	}
	return append(out, ')')
}

// winAnsi maps the characters of the fixtures to WinAnsi bytes (plus the /Differences of bill_winansi.pdf for č ć đ Č Ć Đ).
var winAnsi = map[rune]byte{'€': 0x80, 'Š': 0x8A, 'Ž': 0x8E, 'š': 0x9A, 'ž': 0x9E, '–': 0x96, 'Ć': 198, 'Č': 200, 'Đ': 208, 'ć': 230, 'č': 232, 'đ': 240}

func win(s string) []byte {
	var out []byte
	for _, r := range s {
		if b, ok := winAnsi[r]; ok {
			out = append(out, b)
		} else if r < 256 {
			out = append(out, byte(r))
		} else {
			panic(fmt.Sprintf("fixtures: no WinAnsi byte for %q", r))
		}
	}
	return out
}
