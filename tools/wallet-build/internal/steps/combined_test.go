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
		"f_screens.main();", "cfg.screensSubdir = 'screens';", "Harness.useRegistered(st);"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	if filepath.Base(p) != "combined.dart" {
		t.Errorf("name %s: it must not match *_test.dart (the per-file glob)", p)
	}
}
