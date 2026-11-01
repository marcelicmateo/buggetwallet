package mutate

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"wallet-build/internal/sys"
)

type goldenEntry struct {
	Total  int                `json:"total"`
	All    [][]any            `json:"all"`
	Sample map[string][][]any `json:"sample"`
}

func loadGolden(t *testing.T) map[string]goldenEntry {
	t.Helper()
	raw, err := os.ReadFile("testdata/golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var g map[string]goldenEntry
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	return g
}

// row is the golden's [line, col, start, end, op, orig, mutant, text].
func row(m Mutant) []any {
	return []any{float64(m.Line), float64(m.Col), float64(m.Start), float64(m.End), m.Op, m.Orig, m.Mutant, m.Text}
}

func rows(ms []Mutant) [][]any {
	out := make([][]any, len(ms))
	for i, m := range ms {
		out[i] = row(m)
	}
	return out
}

// The golden is what the real tools/mutate.py finds in the same files (python 3.12 in the build container, see
// testdata/gen_golden.py): the same mutants in the same order, and the same shuffled sample for seeds 1 and 7.
func TestMutantsAndSamplesMatchPython(t *testing.T) {
	g := loadGolden(t)
	if len(g) < 8 {
		t.Fatalf("golden has %d files", len(g))
	}
	for file, want := range g {
		_, ms, err := MutantsOf(filepath.Join("testdata", strings.TrimPrefix(file, "")))
		if err != nil {
			t.Fatal(err)
		}
		if len(ms) != want.Total {
			t.Errorf("%s: %d mutants, want %d", file, len(ms), want.Total)
		}
		if got := rows(ms); !reflect.DeepEqual(got, want.All) {
			for i := range got {
				if i >= len(want.All) || !reflect.DeepEqual(got[i], want.All[i]) {
					t.Errorf("%s: mutant %d is %v, want %v", file, i, got[i], safeAt(want.All, i))
					break
				}
			}
		}
		for key, wantSample := range want.Sample {
			var seed int64
			var mx int
			fmt.Sscanf(key, "%d/%d", &seed, &mx)
			if got := rows(sampleOf(ms, mx, seed)); !reflect.DeepEqual(got, wantSample) {
				t.Errorf("%s seed %d max %d: sample differs:\n got %v\nwant %v", file, seed, mx, got, wantSample)
			}
		}
	}
}

func safeAt(a [][]any, i int) any {
	if i < len(a) {
		return a[i]
	}
	return nil
}

// The --list output (the lines of mutate.py --list) for two real files and the seeds 1 and 7, written by the real script.
func TestListOutputMatchesPython(t *testing.T) {
	root := t.TempDir()
	for _, f := range []struct{ pkg, name string }{{"packages/wallet_importer", "csv_generic.dart"}, {"packages/wallet_core", "periods.dart"}} {
		raw, err := os.ReadFile(filepath.Join("testdata", "real", f.name))
		if err != nil {
			t.Fatal(err)
		}
		dst := filepath.Join(root, f.pkg, "lib", "src", f.name)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dst, raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want := map[string]string{
		"importer lib/src/csv_generic.dart": "lib/src/csv_generic.dart: 247 mutants, 60 sampled\n",
		"core lib/src/periods.dart":         "lib/src/periods.dart: 138 mutants, 60 sampled\n",
	}
	for _, seed := range []string{"1", "7"} {
		for args, line := range want {
			var out, errb bytes.Buffer
			fields := strings.Fields(args)
			o, _, err := ParseArgs(append(fields, "--seed", seed, "--list"))
			if err != nil {
				t.Fatal(err)
			}
			rc := Run(context.Background(), Env{Root: root, R: &sys.Fake{}, Env: sys.Env{}, Out: &out, Err: &errb}, o)
			if rc != 0 || out.String() != line || errb.Len() != 0 {
				t.Errorf("%s seed %s: rc %d out %q err %q, want %q", args, seed, rc, out.String(), errb.String(), line)
			}
		}
	}
}

// The files are read like Python's text mode: CRLF and CR become LF, so the positions are the same.
func TestCRLFSourceGivesTheSameMutants(t *testing.T) {
	raw, err := os.ReadFile("testdata/sample.dart")
	if err != nil {
		t.Fatal(err)
	}
	crlf := filepath.Join(t.TempDir(), "s.dart")
	if err := os.WriteFile(crlf, bytes.ReplaceAll(raw, []byte("\n"), []byte("\r\n")), 0o644); err != nil {
		t.Fatal(err)
	}
	_, a, _ := MutantsOf("testdata/sample.dart")
	_, b, _ := MutantsOf(crlf)
	if !reflect.DeepEqual(a, b) || len(a) == 0 {
		t.Errorf("CRLF source gives %d mutants, LF %d", len(b), len(a))
	}
}

func TestMaskSkipsCommentsAndStrings(t *testing.T) {
	src := []rune("a + b // c + d\n'x + y' r'p + q' \"\"\"m + n\"\"\" /* e + f */ g + h")
	n := 0
	for _, m := range Mutants(src) {
		if m.Op == "+ -> -" {
			n++
		}
	}
	if n != 2 {
		t.Errorf("%d '+' mutants, want 2 (outside comments and strings)", n)
	}
}

func TestSampleCut(t *testing.T) {
	ms := make([]Mutant, 10)
	for i := range ms {
		ms[i] = Mutant{Line: i + 1, Col: 1}
	}
	if got := len(sampleOf(ms, 0, 1)); got != 0 {
		t.Errorf("max 0: %d", got)
	}
	if got := len(sampleOf(ms, 99, 1)); got != 10 {
		t.Errorf("max 99: %d", got)
	}
	if got := len(sampleOf(ms, -3, 1)); got != 7 { // Python's ms[:-3]
		t.Errorf("max -3: %d", got)
	}
	s := sampleOf(ms, 4, 1)
	for i := 1; i < len(s); i++ {
		if s[i].Line < s[i-1].Line {
			t.Errorf("sample is not sorted by line: %v", s)
		}
	}
}
