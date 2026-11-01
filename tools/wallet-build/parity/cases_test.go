//go:build parity

package parity

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const unformattedRel = "app/lib/zz_parity_unformatted.dart"

var lintSteps = []string{"format", "shellcheck", "actionlint", "hook-selftest", "env-selftest", "deploy-selftest", "native-units"}

func mk(name string, want int, args ...string) Case {
	return Case{Name: name, Args: args, WantExit: want}
}

// withUnformatted writes a badly formatted Dart file (tools/test_quiet.sh case 2, other file name so both can coexist).
func withUnformatted(t *testing.T, repo string) func() {
	p := filepath.Join(repo, unformattedRel)
	if err := os.WriteFile(p, []byte("void   main( ) {  }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(p) }) // also runs when a case fails; TestMain removes leftovers of a killed run
	return func() { _ = os.Remove(p) }
}

// checkUnformatted is the contract of test_quiet.sh case 2 plus the run-dir files it names.
func checkUnformatted(t *testing.T, s *side) {
	t.Helper()
	if len(s.runs) != 1 {
		t.Errorf("%s: want exactly one run dir, got %d", s.impl, len(s.runs))
		return
	}
	if s.exit != 1 {
		t.Errorf("%s: exit %d, want 1 (a step failed)", s.impl, s.exit)
	}
	lf := strings.TrimSpace(s.m.text(s.file(0, "last-failed.txt")))
	if lf != "format <ROOT>/dist/logs/format.log" {
		t.Errorf("%s last-failed.txt = %q, want 'format <ROOT>/dist/logs/format.log'", s.impl, lf)
	}
	if !strings.Contains(s.file(0, "last.status"), "format failed") {
		t.Errorf("%s last.status has no 'format failed' line:\n%s", s.impl, s.file(0, "last.status"))
	}
	if !strings.Contains(s.file(0, "format.log"), "zz_parity_unformatted.dart") {
		t.Errorf("%s format.log does not name the unformatted file", s.impl)
	}
}

// checkLintClean: all seven LINT steps present and ok, nothing failed.
func checkLintClean(t *testing.T, s *side) {
	t.Helper()
	if len(s.runs) != 1 {
		t.Errorf("%s: want exactly one run dir, got %d", s.impl, len(s.runs))
		return
	}
	got := map[string]string{}
	for _, ln := range lines(s.file(0, "last.status")) {
		if f := strings.Fields(ln); len(f) >= 2 {
			got[f[0]] = f[1]
		}
	}
	// go-check (host step, first) runs in both implementations; its own failure must not hide the seven others
	if gc := got["go-check"]; gc != "ok" && gc != "failed" {
		t.Errorf("%s last.status: step go-check is %q, want ok or failed", s.impl, gc)
	}
	for _, st := range lintSteps {
		if got[st] != "ok" {
			t.Errorf("%s last.status: step %q is %q, want ok (all of %v)", s.impl, st, got[st], lintSteps)
		}
	}
	if lf := strings.TrimSpace(s.file(0, "last-failed.txt")); lf != "" && !(got["go-check"] == "failed" && strings.HasPrefix(lf, "go-check ")) {
		t.Errorf("%s last-failed.txt is not empty on a green run (only a go-check line is tolerated): %q", s.impl, lf)
	}
	if strings.TrimSpace(s.file(0, "format.log")) == "" {
		t.Errorf("%s format.log is empty", s.impl)
	}
}

func checkNoRunDir(t *testing.T, s *side) {
	t.Helper()
	if len(s.runs) != 0 {
		t.Errorf("%s created a run dir, a usage error must not: %v", s.impl, s.runs)
	}
}

func smallestFile(t *testing.T, dir, suffix string) string {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("no %s: %v", dir, err)
	}
	var best string
	var bestSize int64 = -1
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), suffix) {
			continue
		}
		if fi, err := e.Info(); err == nil && (bestSize < 0 || fi.Size() < bestSize) {
			best, bestSize = e.Name(), fi.Size()
		}
	}
	if best == "" {
		t.Fatalf("no %s files in %s", suffix, dir)
	}
	return best
}

// smallDesktopTests: the n smallest integration tests by file size, without the slow or special ones.
func smallDesktopTests(t *testing.T, repo string, n int) []string {
	t.Helper()
	skip := map[string]bool{"layout": true, "perf": true, "screens": true, "big_wallet": true, "relay_sync": true}
	ents, err := os.ReadDir(filepath.Join(repo, "app", "integration_test"))
	if err != nil {
		t.Logf("no integration tests: %v", err)
		return nil
	}
	type nf struct {
		name string
		size int64
	}
	var all []nf
	for _, e := range ents {
		name, ok := strings.CutSuffix(e.Name(), "_test.dart")
		if !ok || skip[name] {
			continue
		}
		if fi, err := e.Info(); err == nil {
			all = append(all, nf{name, fi.Size()})
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].size < all[j].size })
	if len(all) < n {
		t.Logf("fewer than %d small integration tests", n)
		return nil
	}
	var out []string
	for _, x := range all[:n] {
		out = append(out, x.name)
	}
	return out
}

func requireSigning(t *testing.T, repo string) string {
	dir := os.Getenv("BW_SIGNING_DIR")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config", "budget-wallet")
	}
	return dir
}

func cheapCases(t *testing.T, repo string) []Case {
	smallCore := "test/" + smallestFile(t, filepath.Join(repo, "packages", "wallet_core", "test"), "_test.dart")
	lintClean := mk("lint_clean", 0, "lint")
	lintClean.Check = checkLintClean
	lintBad := mk("lint_unformatted", 1, "lint")
	lintBad.Setup = withUnformatted
	lintBad.Check = checkUnformatted

	qClean := mk("quiet_lint_clean", 0, "-q", "lint")
	qClean.Quiet = true
	qClean.Check = checkLintClean
	qBad := mk("quiet_env_lint_unformatted", 1, "lint")
	qBad.Env = []string{"BW_QUIET=1"}
	qBad.Quiet = true
	qBad.Setup = withUnformatted
	qBad.Check = checkUnformatted
	qUnknown := mk("quiet_unknown_command", 2, "-q", "no-such-command")
	qUnknown.Quiet = true
	qLong := mk("quiet_long_flag_unknown_command", 2, "--quiet", "no-such-command")
	qLong.Quiet = true
	qMut := mk("quiet_mutate_usage", 2, "-q", "mutate")
	qMut.Quiet = true

	usage := func(name string, args ...string) Case {
		c := mk(name, 2, args...)
		c.CmpStderr = true
		return c
	}
	core := mk("core_one_file", 0, "core", smallCore)
	core.Check = func(t *testing.T, s *side) {
		for _, f := range []string{"core:one.log", "core:one.status", "tests-core:one.json", "tests-core:one-summary.txt"} {
			if _, err := os.Stat(filepath.Join(s.runs[0], f)); err != nil {
				t.Errorf("%s: run dir lacks %s (:one run)", s.impl, f)
			}
		}
	}
	shellExit := mk("shell_c_exit_3", 3, "shell", "-c", "exit 3")
	imageName := mk("image_name", 0, "image-name")
	imageName.Check = func(t *testing.T, s *side) {
		if !regexpImage.MatchString(strings.TrimSpace(s.stdout)) {
			t.Errorf("%s image-name printed %q, want localhost/budget-wallet-dev:<flutter version>-<8 hex>", s.impl, s.stdout)
		}
		checkNoRunDir(t, s)
	}
	// A limit that never fires: both sides must behave the same with the variable set (the Go-only step_timeout
	// case proves a firing limit; TestHostForwardsTimeoutEnv proves the -e forwarding).
	fwd := mk("forwarded_timeout_env_lint", 0, "lint")
	fwd.Env = []string{"BW_TIMEOUT_FORMAT=600", "BW_STEP_TIMEOUT=600"}
	relay := mk("relay_bin_x64", 0, "relay-bin", "x64")
	relay.Artifacts = []string{"dist/relay"}
	unknown := usage("usage_unknown_command", "no-such-command")
	unknown.Check = checkNoRunDir
	return []Case{
		lintClean, lintBad, qClean, qBad, qUnknown, qLong, qMut,
		unknown,
		usage("usage_mutate_no_args", "mutate"),
		usage("usage_mutate_one_arg", "mutate", "core"),
		usage("usage_relay_bin_bad_arch", "relay-bin", "badarch"),
		core,
		mk("analyze_core", 0, "analyze", "core"),
		shellExit,
		imageName,
		relay, fwd,
		{Name: "lsp_initialize", WantExit: -1, Custom: lspRoundTrip},
	}
}

func heavyCases(t *testing.T, repo string) []Case {
	h := func(c Case) Case { c.Heavy = true; return c }
	var out []Case
	test := mk("test", 0, "test")
	test.Unordered = true
	out = append(out, h(mk("core", 0, "core")), h(mk("analyze_core_app", 0, "analyze", "core", "app")), h(test))

	if small := smallDesktopTests(t, repo, 2); len(small) == 2 {
		dt := mk("desktop_test_small", 0, "desktop-test", small[0])
		dt.Artifacts = []string{"dist/screens/linux"}
		par := mk("desktop_test_jobs2_a_b_layout", 0, "desktop-test", small[0], small[1], "layout")
		par.Env = []string{"BW_JOBS=2"}
		par.Unordered = true
		par.Artifacts = []string{"dist/screens/linux"}
		out = append(out, h(dt), h(par))
	}
	linux := mk("linux", 0, "linux")
	linux.Artifacts = []string{"dist/BudgetWallet-linux-x64.tar.gz"}
	smoke := mk("desktop_smoke", 0, "desktop-smoke")
	smoke.Artifacts = []string{"dist/BudgetWallet-linux-x64.tar.gz"}
	smoke.Env = []string{"BW_SMOKE_SECONDS=3"}
	apk := mk("apk", 0, "apk")
	apk.Artifacts = []string{"dist/BudgetWallet-android.apk"}
	apk.SkipIf = func(t *testing.T, repo string) string {
		if _, err := os.Stat(filepath.Join(requireSigning(t, repo), "signing.env")); err != nil {
			return "no local signing key (signing.env in ~/.config/budget-wallet or BW_SIGNING_DIR)"
		}
		return ""
	}
	apk.Check = func(t *testing.T, s *side) { checkNoSecrets(t, s, requireSigning(t, repo)) }
	stage := mk("stage", 0, "stage")
	stage.Unordered = true
	stage.WantExit = -1 // a red stage on the lead's laptop is still comparable
	out = append(out, h(linux), h(smoke), h(apk), h(mk("web_test", 0, "web-test")), h(stage))
	return out
}

func TestParity(t *testing.T) {
	repo := repoRoot(t)
	t.Logf("repo %s; comparing bash with %q (BW_PARITY_IMPL), heavy=%v", repo, implName(), os.Getenv(heavyEnv) == "1")
	for _, c := range append(cheapCases(t, repo), heavyCases(t, repo)...) {
		t.Run(c.Name, func(t *testing.T) { runCase(t, c) })
	}
}
