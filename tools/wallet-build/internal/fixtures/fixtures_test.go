package fixtures

import (
	"bytes"
	"compress/zlib"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const repoFixtures = "../../../../packages/wallet_importer/test/fixtures"

func read(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// JSON, XML and CSV are byte-identical to the committed files (which the Python script wrote).
func TestTextFixturesByteIdentical(t *testing.T) {
	dir := t.TempDir()
	if rc := Run(io.Discard, os.Stderr, []string{dir, "all"}); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	for _, rel := range []string{
		"bills/codes.json", "bills/pdfs.json", "bills/invoice_telekom.xml", "bills/invoice_servis.xml",
		"generic/bom_semicolon.csv", "generic/hr_cp1250.csv", "generic/en_comma.csv", "generic/positive_tab.csv", "revolut_synthetic.csv",
	} {
		if got, want := read(t, filepath.Join(dir, rel)), read(t, filepath.Join(repoFixtures, rel)); !bytes.Equal(got, want) {
			t.Errorf("%s differs from the committed file (%d vs %d bytes)", rel, len(got), len(want))
		}
	}
}

// The Excel files are frozen: nothing writes them, and the run says so.
func TestExcelFilesAreNotWritten(t *testing.T) {
	dir := t.TempDir()
	var out strings.Builder
	if rc := Run(&out, os.Stderr, []string{dir}); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	for _, name := range []string{"pbz_synthetic.xls", "revolut_synthetic.xlsx"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s was written", name)
		}
	}
	if !strings.Contains(out.String(), FrozenNote+"\nok\n") {
		t.Errorf("output %q lacks the frozen note", out.String())
	}
}

func TestSubsets(t *testing.T) {
	for _, tc := range []struct {
		what   string
		exists []string
		absent []string
		out    string
	}{
		{"bills", []string{"bills/codes.json"}, []string{"generic", "revolut_synthetic.csv"}, "ok\n"},
		{"generic", []string{"generic/en_comma.csv"}, []string{"bills", "revolut_synthetic.csv"}, "ok\n"},
		{"banks", []string{"revolut_synthetic.csv"}, []string{"bills", "generic"}, FrozenNote + "\nok\n"},
	} {
		dir := t.TempDir()
		var out strings.Builder
		if rc := Run(&out, os.Stderr, []string{dir, tc.what}); rc != 0 {
			t.Fatalf("%s: exit %d", tc.what, rc)
		}
		if out.String() != tc.out {
			t.Errorf("%s: output %q, want %q", tc.what, out.String(), tc.out)
		}
		for _, p := range tc.exists {
			if _, err := os.Stat(filepath.Join(dir, p)); err != nil {
				t.Errorf("%s: %s missing", tc.what, p)
			}
		}
		for _, p := range tc.absent {
			if _, err := os.Stat(filepath.Join(dir, p)); err == nil {
				t.Errorf("%s: %s must not exist", tc.what, p)
			}
		}
	}
}

func TestUsageErrors(t *testing.T) {
	for _, args := range [][]string{nil, {"x", "pdfs"}, {"a", "b", "c"}} {
		var errb strings.Builder
		if rc := Run(io.Discard, &errb, args); rc != 2 || errb.Len() == 0 {
			t.Errorf("%v: exit %d, stderr %q", args, rc, errb.String())
		}
	}
}

var (
	reLength    = regexp.MustCompile(`/Length \d+`)
	reXrefEntry = regexp.MustCompile(`\d{10} 00000 n `)
	reStartxref = regexp.MustCompile(`startxref\n\d+`)
	reStream    = regexp.MustCompile(`(?s)(<<[^>]*?/FlateDecode[^>]*?>>)\nstream\n(.*?)\nendstream`)
)

// normalizePDF inflates every FlateDecode stream in place and blanks what depends on the compressed sizes: the /Length
// values, the classic xref entries and startxref, and the offsets in an xref stream.
func normalizePDF(t *testing.T, pdf []byte) string {
	t.Helper()
	s := reStream.ReplaceAllStringFunc(string(pdf), func(m string) string {
		sub := reStream.FindStringSubmatch(m)
		zr, err := zlib.NewReader(strings.NewReader(sub[2]))
		if err != nil {
			t.Fatalf("not a zlib stream: %v", err)
		}
		raw, err := io.ReadAll(zr)
		if err != nil {
			t.Fatalf("inflate: %v", err)
		}
		if strings.Contains(sub[1], "/Type /XRef") { // rows of /W [1 4 2]: zero the offset of the in-use entries
			for i := 0; i+7 <= len(raw); i += 7 {
				if raw[i] == 1 {
					copy(raw[i+1:i+5], []byte{0, 0, 0, 0})
				}
			}
		}
		return sub[1] + "\nstream\n" + string(raw) + "\nendstream"
	})
	s = reLength.ReplaceAllString(s, "/Length N")
	s = reXrefEntry.ReplaceAllString(s, "0000000000 00000 n ")
	return reStartxref.ReplaceAllString(s, "startxref\n0")
}

// The PDFs were regenerated once with Go's zlib: testdata/old holds the files the Python script wrote; the new ones must
// have the same decoded content (streams inflated, sizes and offsets blanked).
func TestPDFsMatchOldContent(t *testing.T) {
	dir := t.TempDir()
	if err := Bills(dir); err != nil {
		t.Fatal(err)
	}
	pdfs, _ := filepath.Glob(filepath.Join("testdata", "old", "*.pdf.old"))
	if len(pdfs) != 4 {
		t.Fatalf("testdata/old has %d PDFs, want 4", len(pdfs))
	}
	if n := normalizePDF(t, read(t, filepath.Join("testdata", "old", "receipt_type0.pdf.old"))); !strings.Contains(n, "/CIDInit /ProcSet") || !strings.Contains(n, "BT /F1 11 Tf") {
		t.Fatal("the normalizer did not inflate the streams, the comparison below would prove nothing")
	}
	for _, old := range pdfs {
		name := strings.TrimSuffix(filepath.Base(old), ".old")
		want := normalizePDF(t, read(t, old))
		for label, got := range map[string][]byte{"generated": read(t, filepath.Join(dir, name)), "committed": read(t, filepath.Join(repoFixtures, "bills", name))} {
			if n := normalizePDF(t, got); n != want {
				t.Errorf("%s (%s): decoded content differs from the old file", name, label)
			}
		}
	}
}

// Every offset in the generated PDFs points at its object, whatever the compressed sizes.
func TestPDFOffsetsAreRight(t *testing.T) {
	dir := t.TempDir()
	if err := Bills(dir); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"bill_winansi.pdf", "encrypted_stub.pdf", "hub3_printed.pdf"} {
		pdf := read(t, filepath.Join(dir, name))
		x := regexp.MustCompile(`startxref\n(\d+)`).FindSubmatch(pdf)
		if x == nil {
			t.Fatalf("%s: no startxref", name)
		}
		var off int
		for _, c := range x[1] {
			off = off*10 + int(c-'0')
		}
		if !bytes.HasPrefix(pdf[off:], []byte("xref\n0 ")) {
			t.Errorf("%s: startxref does not point at the xref table", name)
		}
		for i, m := range reXrefEntry.FindAll(pdf[off:], -1) {
			var o int
			for _, c := range m[:10] {
				o = o*10 + int(c-'0')
			}
			if !bytes.Contains(pdf[o:min(o+12, len(pdf))], []byte(" 0 obj")) {
				t.Errorf("%s: xref entry %d points at %q", name, i+1, pdf[o:min(o+12, len(pdf))])
			}
		}
	}
}

// Same seed, same files: the generator is deterministic.
func TestDeterministic(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	for _, d := range []string{a, b} {
		if rc := Run(io.Discard, os.Stderr, []string{d, "all"}); rc != 0 {
			t.Fatal(rc)
		}
	}
	for _, rel := range []string{"bills/codes.json", "bills/receipt_type0.pdf", "bills/hub3_printed.pdf"} {
		if !bytes.Equal(read(t, filepath.Join(a, rel)), read(t, filepath.Join(b, rel))) {
			t.Errorf("%s differs between two runs", rel)
		}
	}
}

// `embed` writes exactly the committed Dart file for the committed bank files, and a changed file changes it.
func TestEmbedMatchesCommittedFile(t *testing.T) {
	root := t.TempDir()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, FixturesDir), 0o755))
	must(os.MkdirAll(filepath.Join(root, filepath.Dir(EmbedFile)), 0o755))
	for _, f := range embedFiles {
		must(os.WriteFile(filepath.Join(root, FixturesDir, f.file), read(t, filepath.Join(repoFixtures, f.file)), 0o644))
	}
	var out strings.Builder
	if rc := RunEmbed(root, &out, os.Stderr); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	want := read(t, "../../../../"+EmbedFile)
	if got := read(t, filepath.Join(root, EmbedFile)); !bytes.Equal(got, want) {
		t.Errorf("embed output differs from %s (%d vs %d bytes)", EmbedFile, len(got), len(want))
	}
	must(os.WriteFile(filepath.Join(root, FixturesDir, "revolut_synthetic.csv"), []byte("x"), 0o644))
	if rc := RunEmbed(root, io.Discard, os.Stderr); rc != 0 || bytes.Equal(read(t, filepath.Join(root, EmbedFile)), want) {
		t.Error("a changed fixture must change the Dart file")
	}
}

func TestEmbedMissingFile(t *testing.T) {
	var errb strings.Builder
	if rc := RunEmbed(t.TempDir(), io.Discard, &errb); rc != 1 || !strings.Contains(errb.String(), "fixtures embed") {
		t.Errorf("exit %d, stderr %q", rc, errb.String())
	}
}
