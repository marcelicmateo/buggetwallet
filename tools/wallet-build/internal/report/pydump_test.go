package report

import (
	"os"
	"path/filepath"
	"testing"
)

// The goldens are Python's json output for the same value (testdata/gen_dump_golden.py).
func TestDumperMatchesPython(t *testing.T) {
	v := Obj{
		{"s", "čćž \"q\" \\ \n\r\t\b\f \x01 \x7f é 😀"},
		{"i", []any{1, -2, 0}},
		{"f", []any{1.5, 0.0, 1e22, 2.5e-7, negZero()}},
		{"n", nil},
		{"b", []any{true, false}},
		{"e", Obj{{"x", []any{}}, {"y", Obj{}}}},
		{"nested", []any{[]any{1, []any{2}}, Obj{{"k", []any{Obj{{"a", 1}}}}}}},
	}
	for file, d := range map[string]Dumper{
		"dump-indent1.json":       {Indent: 1},
		"dump-indent1-ascii.json": {Indent: 1, ASCII: true},
		"dump-compact.json":       {Compact: true},
	} {
		want, err := os.ReadFile(filepath.Join("testdata", "golden", file))
		if err != nil {
			t.Fatal(err)
		}
		if got := d.Dump(v); got != string(want) {
			t.Errorf("%s differs:\n got: %q\nwant: %q", file, got, want)
		}
	}
}

func negZero() float64 {
	z := 0.0
	return -z
}
