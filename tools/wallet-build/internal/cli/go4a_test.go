package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"wallet-build/internal/fixtures"
	"wallet-build/internal/sys"
)

func TestFixturesCommand(t *testing.T) {
	out := filepath.Join(t.TempDir(), "fx")
	r := runCLI(t, opts{}, "fixtures", out, "bills")
	if r.code != 0 || r.out != "ok\n" || len(r.calls) != 0 {
		t.Fatalf("code %d out %q calls %v err %q", r.code, r.out, r.calls, r.err)
	}
	if _, err := os.Stat(filepath.Join(out, "bills", "codes.json")); err != nil {
		t.Error(err)
	}
	if r := runCLI(t, opts{}, "fixtures", out, "nonsense"); r.code != 2 {
		t.Errorf("unknown set: code %d", r.code)
	}
	if r := runCLI(t, opts{}, "fixtures"); r.code != 2 {
		t.Errorf("no args: code %d", r.code)
	}
	// quiet: nothing at all
	if r := runCLI(t, opts{}, "-q", "fixtures", out, "generic"); r.code != 0 || r.out != "" || r.err != "" {
		t.Errorf("quiet: %d %q %q", r.code, r.out, r.err)
	}
}

func TestFixturesEmbedWritesTheDartFile(t *testing.T) {
	root := mkRepo(t)
	write(t, filepath.Join(root, fixtures.FixturesDir, "pbz_synthetic.xls"), "xls")
	write(t, filepath.Join(root, fixtures.FixturesDir, "revolut_synthetic.xlsx"), "xlsx")
	write(t, filepath.Join(root, fixtures.FixturesDir, "revolut_synthetic.csv"), "a,b\n")
	os.MkdirAll(filepath.Join(root, "app/integration_test/support"), 0o755)
	r := runCLI(t, opts{root: root}, "fixtures", "embed")
	if r.code != 0 || !strings.Contains(r.out, fixtures.EmbedFile) {
		t.Fatalf("code %d out %q err %q", r.code, r.out, r.err)
	}
	b, err := os.ReadFile(filepath.Join(root, fixtures.EmbedFile))
	if err != nil || !strings.Contains(string(b), "const _revolutCsvFile =\n    'YSxiCg==';\n") || !strings.Contains(string(b), "const _pbzXls =\n    'eGxz';\n") {
		t.Errorf("%v\n%s", err, b)
	}
}

func TestLogSummaryCommand(t *testing.T) {
	log := filepath.Join(t.TempDir(), "a.log")
	write(t, log, "2026-10-16T19:01:02.123+02:00 INFO bw.app lifecycle {\"state\":\"resumed\"}\n")
	r := runCLI(t, opts{}, "log-summary", log)
	if r.code != 0 || !strings.Contains(r.out, "1 records, 2026-10-16T19:01:02.123+02:00 .. 2026-10-16T19:01:02.123+02:00") || !strings.Contains(r.out, "resumed") {
		t.Errorf("code %d\n%s%s", r.code, r.out, r.err)
	}
	if r := runCLI(t, opts{}, "log-summary"); r.code != 2 || !strings.Contains(r.out, "log-summary <logfile>") {
		t.Errorf("no args: %d %q", r.code, r.out)
	}
	write(t, log, "not a record\n")
	if r := runCLI(t, opts{}, "log-summary", log); r.code != 1 || r.out != "no log records found\n" {
		t.Errorf("%d %q", r.code, r.out)
	}
}

func TestTokenUsageCommand(t *testing.T) {
	home := t.TempDir()
	repo := "/some/repo.x"
	proj := filepath.Join(home, ".claude", "projects", "-some-repo-x")
	write(t, filepath.Join(proj, "abcdef012345.jsonl"),
		`{"type":"assistant","requestId":"r","timestamp":"2026-10-20T10:00:00Z","message":{"model":"m1","usage":{"input_tokens":1000,"output_tokens":2500}}}`+"\n")
	var gitArgs []string
	h := func(c sys.Cmd) int {
		a := strings.Join(c.Argv, " ")
		gitArgs = append(gitArgs, a)
		switch {
		case strings.HasPrefix(a, "git rev-parse"):
			c.Stdout.Write([]byte(repo + "\n"))
		case strings.HasPrefix(a, "git log"):
			c.Stdout.Write([]byte("abc one\ndef two\n"))
		}
		return 0
	}
	jsonOut := filepath.Join(t.TempDir(), "o.json")
	r := runCLI(t, opts{env: []string{"HOME=" + home}, handle: h}, "token-usage", "--since", "2026-10-01", "--json", jsonOut)
	if r.code != 0 {
		t.Fatalf("code %d\n%s%s", r.code, r.out, r.err)
	}
	for _, want := range []string{"Per day", "2026-10-20", "abcdef01 main", "m1", "3,500", "commits on this branch in 2026-10-20..2026-10-20: 2", "per commit: 1,750 tokens", "wrote " + jsonOut} {
		if !strings.Contains(r.out, want) {
			t.Errorf("output lacks %q:\n%s", want, r.out)
		}
	}
	if len(gitArgs) != 2 || gitArgs[1] != "git log --oneline --since=2026-10-20 00:00 --until=2026-10-20 23:59:59" {
		t.Errorf("git calls %q", gitArgs)
	}
	if b, err := os.ReadFile(jsonOut); err != nil || !strings.Contains(string(b), "\"commits\": 2") {
		t.Errorf("%v %s", err, b)
	}
	for _, bad := range [][]string{{"--bogus"}, {"stray"}, {"--since"}} {
		if r := runCLI(t, opts{env: []string{"HOME=" + home}, handle: h}, append([]string{"token-usage"}, bad...)...); r.code != 2 {
			t.Errorf("%v: code %d", bad, r.code)
		}
	}
	if r := runCLI(t, opts{env: []string{"HOME=" + t.TempDir()}, handle: h}, "token-usage"); r.code != 1 || !strings.Contains(r.err, "no transcripts in") {
		t.Errorf("no transcripts: %d %q", r.code, r.err)
	}
}

func TestLspQueryUsage(t *testing.T) {
	r := runCLI(t, opts{}, "lsp-query")
	if r.code != 2 || !strings.Contains(r.out, "lsp-query refs") || len(r.calls) != 0 {
		t.Errorf("%d %q", r.code, r.out)
	}
	if r := runCLI(t, opts{}, "lsp-query", "refs", "nocolon"); r.code != 1 || !strings.Contains(r.err, "bad position") {
		t.Errorf("%d %q", r.code, r.err)
	}
}

// mutate runs inside wallet-build now, not as `python3 tools/mutate.py`.
func TestMutateRunsInProcess(t *testing.T) {
	r := native(t, opts{}, "mutate", "core", "lib/x.dart", "--max", "5")
	if r.code != 1 || !strings.Contains(r.out+r.err, "not a .dart file under packages/wallet_core/lib: lib/x.dart") {
		t.Errorf("code %d\n%s%s", r.code, r.out, r.err)
	}
	for _, c := range r.calls {
		if strings.Contains(c, "python3") || strings.Contains(c, "mutate.py") {
			t.Errorf("python called: %s", c)
		}
	}
	if b, err := os.ReadFile(filepath.Join(r.logs, "mutate.status")); err != nil || !strings.Contains(string(b), " 1 ") {
		t.Errorf("mutate.status %q %v", b, err)
	}
	// argparse errors are usage errors (2) before any step runs
	for _, args := range [][]string{{"mutate", "core", "lib/x.dart", "--max", "x"}, {"mutate", "bogus", "lib/x.dart"}, {"mutate", "core", "lib/x.dart", "--nope"}} {
		r := native(t, opts{}, args...)
		if r.code != 2 || !strings.Contains(r.err, "mutate: error:") {
			t.Errorf("%v: code %d err %q", args, r.code, r.err)
		}
	}
	// a real (tiny) run through the CLI: the lib file is mutated in the work copy, dart is the fake runner
	root := mkRepo(t)
	write(t, filepath.Join(root, "packages/wallet_core/lib/m.dart"), "bool f(int a) {\n  return a == 1;\n}\n")
	r = native(t, opts{root: root}, "mutate", "core", "lib/m.dart", "--list")
	if r.code != 0 || !strings.Contains(r.out, "lib/m.dart: 4 mutants, 4 sampled") {
		t.Errorf("code %d\n%s%s", r.code, r.out, r.err)
	}
}
