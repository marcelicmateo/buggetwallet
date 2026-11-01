package pyfmt

import (
	"encoding/json"
	"testing"

	"wallet-build/internal/report"
)

// The pairs are Python's repr(s) for the same strings (gen_cases.py).
func TestReprString(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"abc", "'abc'"},
		{"it's", "\"it's\""},
		{"say \"hi\"", "'say \"hi\"'"},
		{"both ' and \"", "'both \\' and \"'"},
		{"tab\there", "'tab\\there'"},
		{"nl\nx", "'nl\\nx'"},
		{"cr\r", "'cr\\r'"},
		{"back\\slash", "'back\\\\slash'"},
		{"é č ž €", "'é č ž €'"},
		{"\u0000\u0001\u007f", "'\\x00\\x01\\x7f'"},
		{"\u00a0nb", "'\\xa0nb'"},
		{"\u00ad", "'\\xad'"},
		{"😀", "'😀'"},
		{"\u2028", "'\\u2028'"},
		{"\ufeff", "'\\ufeff'"},
		{"", "''"},
		{" ", "' '"},
	} {
		if got := ReprString(c.in); got != c.want {
			t.Errorf("ReprString(%q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestComma(t *testing.T) {
	for n, want := range map[int64]string{0: "0", 7: "7", 999: "999", 1000: "1,000", -1234: "-1,234", 1234567890: "1,234,567,890", -999: "-999"} {
		if got := Comma(n); got != want {
			t.Errorf("Comma(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestRank(t *testing.T) {
	xs := []float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	for p, want := range map[float64]float64{50: 5, 90: 9, 99: 10, 100: 10, 1: 1, 0: 1} {
		if got, _ := Rank(xs, p); got != want {
			t.Errorf("Rank(%v) = %v, want %v", p, got, want)
		}
	}
	if _, ok := Rank(nil, 50); ok {
		t.Error("an empty list has no rank")
	}
}

func TestSumIsCompensated(t *testing.T) {
	// CPython 3.12+: sum([0.1] * 10) == 1.0, not 0.9999999999999999
	xs := make([]float64, 10)
	for i := range xs {
		xs[i] = 0.1
	}
	if got := Sum(xs); got != 1.0 {
		t.Errorf("Sum = %v", got)
	}
}

func TestReprOfDecodedJSON(t *testing.T) {
	o, err := report.ParseObj(`{"a":[1,2.5,"x",null,true,{"k":"v"}],"b":{},"c":1e22}`)
	if err != nil {
		t.Fatal(err)
	}
	want := "OrderedDict({'a': [1, 2.5, 'x', None, True, OrderedDict({'k': 'v'})], 'b': OrderedDict(), 'c': 1e+22})"
	if got := Repr(o); got != want {
		t.Errorf("%s", got)
	}
	if got := Str(json.Number("-0")); got != "0" {
		t.Errorf("%s", got)
	}
}
