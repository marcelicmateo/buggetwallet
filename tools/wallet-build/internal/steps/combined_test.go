package steps

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// the combined CI entry imports every file under a prefixed alias (`import` is a Dart keyword) and runs each main() in its own group
func TestWriteCombined(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app", "integration_test"), 0o755); err != nil {
		t.Fatal(err)
	}
	p, err := writeCombined(root, []string{"import", "screens"})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	got := string(b)
	for _, want := range []string{"import 'import_test.dart' as f_import;", "import 'screens_test.dart' as f_screens;", "group('import', () {",
		"f_screens.main();", "cfg.screensSubdir = 'screens';", "await Harness.beginFile(st);"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	if filepath.Base(p) != "combined.dart" {
		t.Errorf("name %s: it must not match *_test.dart (the per-file glob)", p)
	}
}

func TestLastTestFile(t *testing.T) {
	rep := `{"test":{"id":3,"name":"loading x"},"type":"testStart","time":0}
{"test":{"id":5,"name":"tags Tags: the tx sheet"},"type":"testStart","time":9}
{"test":{"id":6,"name":"layout layout: small"},"type":"testStart","time":19}
{"testID":6,"type":"testDone"}
`
	if got := LastTestFile([]byte(rep), []string{"tags", "layout", "plan"}); got != "layout" {
		t.Errorf("got %s", got)
	}
	if got := LastTestFile(nil, []string{"tags"}); got != "unknown" {
		t.Errorf("got %s", got)
	}
}

// each file starts clean: the wallet is wiped and the log cleared before the file's tests, and its app log is kept after them
func TestCombinedFilesStartClean(t *testing.T) {
	root := t.TempDir()
	_ = os.MkdirAll(filepath.Join(root, "app", "integration_test"), 0o755)
	p, _ := writeCombined(root, []string{"a", "b"})
	b, _ := os.ReadFile(p)
	s := string(b)
	i, j := strings.Index(s, "group('b'"), strings.Index(s, "Harness.beginFile(st)")
	if strings.Count(s, "Harness.beginFile(st)") != 2 || strings.Count(s, "Harness.endFile(") != 2 || i < 0 || j < 0 {
		t.Errorf("every file needs beginFile (wipe + clear log + empty-wallet assertions) and endFile:\n%s", s)
	}
}

func TestDartFilesSkipsStaleCombined(t *testing.T) {
	root := t.TempDir()
	d := filepath.Join(root, "app", "integration_test")
	_ = os.MkdirAll(d, 0o755)
	_ = os.WriteFile(filepath.Join(d, "combined.dart"), []byte("x"), 0o644)
	_ = os.WriteFile(filepath.Join(d, "a_test.dart"), []byte("x"), 0o644)
	got := DartFiles(root)
	if len(got) != 1 || !strings.HasSuffix(got[0], "a_test.dart") {
		t.Errorf("%v", got)
	}
}
