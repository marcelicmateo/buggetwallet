//go:build parity

package parity

import (
	"bytes"
	"compress/zlib"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// fixtures: `wallet-build fixtures <out> [all|banks|bills|generic]` (and tools/make_fixtures.py) must reproduce the committed
// packages/wallet_importer/test/fixtures byte for byte, except the PDFs (flate streams differ between zlib builds): those
// are compared by their decoded content. The two Excel files are frozen (owner 2026-11-01): the Go side never writes them.

const fixturesRel = "packages/wallet_importer/test/fixtures"

var frozenExcel = map[string]bool{"pbz_synthetic.xls": true, "revolut_synthetic.xlsx": true}

func listRel(t testing.TB, root string) []string {
	t.Helper()
	var out []string
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			rel, _ := filepath.Rel(root, p)
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(out)
	return out
}

// committed files (relative to the fixtures dir) a mode must produce.
func fixtureWant(t testing.TB, committed, what string) []string {
	var want []string
	for _, f := range listRel(t, committed) {
		if strings.HasPrefix(f, "golden/") || frozenExcel[f] {
			continue
		}
		top := !strings.Contains(f, "/")
		switch what {
		case "all":
			want = append(want, f)
		case "banks":
			if top {
				want = append(want, f)
			}
		case "bills":
			if strings.HasPrefix(f, "bills/") {
				want = append(want, f)
			}
		case "generic":
			if strings.HasPrefix(f, "generic/") {
				want = append(want, f)
			}
		}
	}
	return want
}

var (
	reLength    = regexp.MustCompile(`/Length \d+`)
	reXrefRow   = regexp.MustCompile(`\d{10} (\d{5} [nf])`)
	reStartXref = regexp.MustCompile(`startxref\n\d+`)
	reObjHead   = regexp.MustCompile(`(?s)\d+ \d+ obj\n`)
)

// normPDF turns a PDF into text that is equal for equal content: every stream is replaced by its decoded bytes (flate
// inflated; for a cross-reference stream the 4-byte offset of each 7-byte row zeroed), /Length numbers, classic xref
// offsets and the startxref offset zeroed (they depend on the compressed sizes).
func normPDF(t testing.TB, name string, data []byte) string {
	t.Helper()
	var out bytes.Buffer
	pos := 0
	for {
		i := bytes.Index(data[pos:], []byte("stream\n"))
		if i < 0 {
			out.Write(data[pos:])
			break
		}
		i += pos
		if i >= 3 && string(data[i-3:i]) == "end" { // endstream
			out.Write(data[pos : i+7])
			pos = i + 7
			continue
		}
		bodyStart := i + len("stream\n")
		end := bytes.Index(data[bodyStart:], []byte("\nendstream"))
		if end < 0 {
			t.Fatalf("%s: stream without endstream", name)
		}
		body := data[bodyStart : bodyStart+end]
		heads := reObjHead.FindAllIndex(data[:i], -1)
		dict := ""
		if len(heads) > 0 {
			dict = string(data[heads[len(heads)-1][1]:i])
		}
		out.Write(data[pos:i])
		if strings.Contains(dict, "/FlateDecode") {
			zr, err := zlib.NewReader(bytes.NewReader(body))
			if err != nil {
				t.Fatalf("%s: not a zlib stream: %v", name, err)
			}
			var dec bytes.Buffer
			if _, err := dec.ReadFrom(zr); err != nil {
				t.Fatalf("%s: inflate: %v", name, err)
			}
			body = dec.Bytes()
		}
		if strings.Contains(dict, "/XRef") {
			cp := append([]byte(nil), body...)
			for r := 0; r+7 <= len(cp); r += 7 {
				copy(cp[r+1:r+5], []byte{0, 0, 0, 0})
			}
			body = cp
		}
		fmt.Fprintf(&out, "stream[decoded %d]\n%x\n", len(body), body)
		pos = bodyStart + end + 1 // keep "endstream"
	}
	s := out.String()
	s = reLength.ReplaceAllString(s, "/Length N")
	s = reXrefRow.ReplaceAllString(s, "0000000000 $1")
	s = reStartXref.ReplaceAllString(s, "startxref\n0")
	return s
}

func runFixtures(t *testing.T, repo, impl, bin, out string, args ...string) (int, string, string) {
	t.Helper()
	var cmd *exec.Cmd
	if impl == "bash" {
		cmd = exec.Command("python3", append([]string{"-I", filepath.Join(repo, "tools", "make_fixtures.py"), out}, args...)...)
	} else {
		cmd = exec.Command(bin, append([]string{"fixtures", out}, args...)...)
	}
	cmd.Dir = t.TempDir()
	cmd.Env = append(os.Environ(), "HOME="+t.TempDir(), "LC_ALL=C.UTF-8")
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	return exitCode(t, cmd.Run()), so.String(), se.String()
}

func pyHas(mods ...string) bool {
	return exec.Command("python3", "-I", "-c", "import "+strings.Join(mods, ", ")).Run() == nil
}

func TestGO4Fixtures(t *testing.T) {
	repo := repoRoot(t)
	committed := filepath.Join(repo, fixturesRel)
	bin := ""
	if goSide() {
		if bin = wbBinary(repo); bin == "" {
			t.Skip("dist/bin/wallet-build not built (make bin, or BW_PARITY_BIN)")
		}
	}
	for _, what := range []string{"bills", "generic", "banks", "all"} {
		for _, impl := range []string{"bash", implName()} {
			if impl == "bash" && (what == "banks" || what == "all") && !pyHas("xlwt", "openpyxl") {
				continue // the old script needs xlwt/openpyxl (container only); the committed Excel files are frozen anyway
			}
			t.Run(what+"/"+impl, func(t *testing.T) {
				out := filepath.Join(t.TempDir(), "out")
				rc, so, se := runFixtures(t, repo, impl, bin, out, what)
				wantOut := "ok"
				if impl != "bash" && (what == "banks" || what == "all") { // owner decision: the Excel files are frozen
					wantOut = "pbz_synthetic.xls and revolut_synthetic.xlsx are frozen (committed as they are), not generated\nok"
				}
				if rc != 0 || strings.TrimSpace(so) != wantOut {
					t.Fatalf("exit %d, stdout %q (want %q), stderr %s", rc, so, wantOut, tail(se))
				}
				want := fixtureWant(t, committed, what)
				got := listRel(t, out)
				if impl != "bash" {
					for _, g := range got {
						if frozenExcel[g] {
							t.Errorf("%s wrote the frozen Excel fixture %s", impl, g)
						}
					}
				}
				var gotNoExcel []string
				for _, g := range got {
					if !frozenExcel[g] {
						gotNoExcel = append(gotNoExcel, g)
					}
				}
				if strings.Join(gotNoExcel, "\n") != strings.Join(want, "\n") {
					t.Fatalf("file set differs\n got: %v\nwant: %v", gotNoExcel, want)
				}
				for _, f := range want {
					a, _ := os.ReadFile(filepath.Join(committed, f))
					b, err := os.ReadFile(filepath.Join(out, f))
					if err != nil {
						t.Errorf("%s: %v", f, err)
						continue
					}
					if strings.HasSuffix(f, ".pdf") {
						if na, nb := normPDF(t, f, a), normPDF(t, f, b); na != nb {
							diffLines(t, "fixtures_"+what, f+" (decoded)", strings.Split(na, "\n"), strings.Split(nb, "\n"))
						}
						continue
					}
					if !bytes.Equal(a, b) {
						t.Errorf("%s differs from the committed file (%d vs %d bytes)", f, len(b), len(a))
					}
				}
			})
		}
	}
}

// The normalizer itself must be able to fail: a changed decoded byte, a changed text object.
func TestGO4FixturesPDFNormalizerCanFail(t *testing.T) {
	repo := repoRoot(t)
	src, err := os.ReadFile(filepath.Join(repo, fixturesRel, "bills", "hub3_printed.pdf"))
	if err != nil {
		t.Fatal(err)
	}
	base := normPDF(t, "hub3", src)
	if !strings.Contains(base, "stream[decoded") {
		t.Fatal("no stream decoded: the normalizer would pass anything")
	}
	var plain bytes.Buffer
	zw := zlib.NewWriter(&plain)
	// re-compress each stream at another level: must stay equal
	re := regexp.MustCompile(`(?s)stream\n(.*?)\nendstream`)
	other := re.ReplaceAllFunc(src, func(m []byte) []byte {
		body := m[len("stream\n") : len(m)-len("\nendstream")]
		zr, err := zlib.NewReader(bytes.NewReader(body))
		if err != nil {
			return m
		}
		var dec bytes.Buffer
		_, _ = dec.ReadFrom(zr)
		var c bytes.Buffer
		w, _ := zlib.NewWriterLevel(&c, zlib.BestSpeed)
		_, _ = w.Write(dec.Bytes())
		_ = w.Close()
		return append(append([]byte("stream\n"), c.Bytes()...), []byte("\nendstream")...)
	})
	_ = zw
	if bytes.Equal(other, src) {
		t.Log("recompression produced the same bytes (fine)")
	}
	if normPDF(t, "recompressed", other) != base {
		t.Error("recompressed streams must normalize equal")
	}
	// one text byte changed inside a decoded stream
	mut := re.ReplaceAllFunc(src, func(m []byte) []byte {
		body := m[len("stream\n") : len(m)-len("\nendstream")]
		zr, err := zlib.NewReader(bytes.NewReader(body))
		if err != nil {
			return m
		}
		var dec bytes.Buffer
		_, _ = dec.ReadFrom(zr)
		d := dec.Bytes()
		if len(d) > 5 {
			d[len(d)-5] ^= 1
		}
		var c bytes.Buffer
		w := zlib.NewWriter(&c)
		_, _ = w.Write(d)
		_ = w.Close()
		return append(append([]byte("stream\n"), c.Bytes()...), []byte("\nendstream")...)
	})
	if normPDF(t, "mutated", mut) == base {
		t.Error("a changed decoded byte must change the normalized text")
	}
}

// Go side only: usage errors, `fixtures embed`, and `all` without the frozen Excel files. (The old script has no
// usage text: with no arguments it dies with an IndexError, exit 1.)
func TestGO4FixturesGoOnly(t *testing.T) {
	repo := goOnly(t)
	bin := wbBinary(repo)
	if bin == "" {
		t.Skip("dist/bin/wallet-build not built (make bin, or BW_PARITY_BIN)")
	}
	run := func(args ...string) (int, string, string) {
		cmd := exec.Command(bin, args...)
		cmd.Dir = t.TempDir()
		cmd.Env = append(os.Environ(), "HOME="+t.TempDir())
		var so, se bytes.Buffer
		cmd.Stdout, cmd.Stderr = &so, &se
		return exitCode(t, cmd.Run()), so.String(), se.String()
	}
	t.Run("usage_no_args", func(t *testing.T) {
		if rc, _, se := run("fixtures"); rc != 2 || strings.TrimSpace(se) == "" {
			t.Errorf("fixtures with no arguments: exit %d, stderr %q; want 2 and a usage text", rc, se)
		}
	})
	t.Run("usage_unknown_kind", func(t *testing.T) {
		out := filepath.Join(t.TempDir(), "o")
		if rc, _, _ := run("fixtures", out, "nonsense"); rc != 2 {
			t.Errorf("fixtures <dir> nonsense: exit %d, want 2", rc)
		}
		if _, err := os.Stat(filepath.Join(out, "bills")); err == nil {
			t.Error("an unknown kind must not write anything")
		}
	})
	t.Run("usage_too_many_args", func(t *testing.T) {
		if rc, _, _ := run("fixtures", t.TempDir(), "bills", "extra"); rc != 2 {
			t.Errorf("fixtures <dir> bills extra: exit %d, want 2", rc)
		}
	})
	// `fixtures embed` on the committed files, in a sandbox copy of the repo layout (the binary finds its root from
	// <root>/dist/bin): the generated Dart file must equal the committed app/integration_test/support/fixtures.dart.
	t.Run("embed_equals_committed", func(t *testing.T) {
		root := evalLinks(t.TempDir())
		copyTree(t, filepath.Join(repo, fixturesRel), filepath.Join(root, fixturesRel))
		if err := os.MkdirAll(filepath.Join(root, "app", "integration_test", "support"), 0o755); err != nil {
			t.Fatal(err)
		}
		sbin := filepath.Join(root, "dist", "bin", "wallet-build")
		copyFile(t, bin, sbin, 0o755)
		cmd := exec.Command(sbin, "fixtures", "embed")
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "HOME="+t.TempDir())
		var so, se bytes.Buffer
		cmd.Stdout, cmd.Stderr = &so, &se
		if err := cmd.Run(); err != nil {
			t.Fatalf("fixtures embed: %v\nstderr: %s", err, tail(se.String()))
		}
		committed, err := os.ReadFile(filepath.Join(repo, "app", "integration_test", "support", "fixtures.dart"))
		if err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(filepath.Join(root, "app", "integration_test", "support", "fixtures.dart"))
		if err != nil { // reading: the generated text may go to stdout instead of the file
			got = []byte(so.String())
		}
		if !bytes.Equal(got, committed) {
			gl, cl := strings.Split(string(got), "\n"), strings.Split(string(committed), "\n")
			diffLines(t, "fixtures_embed", "fixtures.dart", cl, gl)
			t.Errorf("fixtures embed output (%d bytes) differs from the committed file (%d bytes)", len(got), len(committed))
		}
	})
	t.Run("embed_twice_identical", func(t *testing.T) {
		root := evalLinks(t.TempDir())
		copyTree(t, filepath.Join(repo, fixturesRel), filepath.Join(root, fixturesRel))
		_ = os.MkdirAll(filepath.Join(root, "app", "integration_test", "support"), 0o755)
		sbin := filepath.Join(root, "dist", "bin", "wallet-build")
		copyFile(t, bin, sbin, 0o755)
		var outs [2]string
		for i := range outs {
			cmd := exec.Command(sbin, "fixtures", "embed")
			cmd.Dir = root
			cmd.Env = append(os.Environ(), "HOME="+t.TempDir())
			so, _ := cmd.Output()
			b, _ := os.ReadFile(filepath.Join(root, "app", "integration_test", "support", "fixtures.dart"))
			outs[i] = string(so) + "|" + string(b)
		}
		if outs[0] != outs[1] {
			t.Error("two embed runs differ")
		}
	})
}
