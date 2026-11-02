package cli

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/host"
	"wallet-build/internal/sys"
)

// ---- fixtures ----

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// mkRepo is a tiny repository: every package resolved (no pub get), one Dart file, scripts for shellcheck, two integration tests.
func mkRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	write(t, filepath.Join(root, "app/pubspec.yaml"), "environment:\n  sdk: ^3.0.0\n  flutter: \"3.47.7\"\n")
	for _, f := range []string{"dev/Containerfile", "dev/install-lint-tools.sh", "dev/linux-packages.txt"} {
		write(t, filepath.Join(root, f), f)
	}
	write(t, filepath.Join(root, "app/lib/main.dart"), "void main() {}\n")
	write(t, filepath.Join(root, "tools/a.sh"), "#!/bin/sh\n")
	write(t, filepath.Join(root, "dev/b.sh"), "#!/bin/sh\n")
	write(t, filepath.Join(root, ".github/scripts/c.sh"), "#!/bin/sh\n")
	for _, n := range []string{"a", "layout"} {
		write(t, filepath.Join(root, "app/integration_test/"+n+"_test.dart"), "")
	}
	write(t, filepath.Join(root, "app/test/web/x_test.dart"), "")
	write(t, filepath.Join(root, "app/web/sqlite3.wasm"), "wasm")
	write(t, filepath.Join(root, "packages/wallet_core/test/x_test.dart"), "")
	write(t, filepath.Join(root, "app/test/a_test.dart"), "")
	write(t, filepath.Join(root, "app/build/app/outputs/flutter-apk/app-release.apk"), "apk")
	write(t, filepath.Join(root, "app/build/web/index.html"), "")
	for _, d := range []string{"packages/wallet_importer", "packages/wallet_core", "packages/sync", "relay", "app"} {
		if d != "app" {
			write(t, filepath.Join(root, d, "pubspec.yaml"), "name: x\n")
		}
		old := time.Now().Add(-time.Hour)
		os.Chtimes(filepath.Join(root, d, "pubspec.yaml"), old, old)
		write(t, filepath.Join(root, d, ".dart_tool/package_config.json"), "{}")
	}
	return root
}

type result struct {
	code  int
	calls []string
	execs []string
	out   string
	err   string
	root  string
	logs  string
	data  string
	fake  *sys.Fake
}

func rel(root, dir string) string {
	r, err := filepath.Rel(root, dir)
	if err != nil || r == "." {
		return ""
	}
	return r
}

func calls(f *sys.Fake, root string) []string {
	var out []string
	for _, c := range f.Calls {
		out = append(out, rel(root, c.Dir)+"$ "+strings.Join(c.Argv, " "))
	}
	return out
}

type opts struct {
	env    []string
	handle func(c sys.Cmd) int
	setup  func(h *host.Host)
	stdin  io.Reader
	root   string
}

func runCLI(t *testing.T, o opts, args ...string) result {
	t.Helper()
	root := o.root
	if root == "" {
		root = mkRepo(t)
	}
	data := t.TempDir()
	fake := &sys.Fake{Handle: o.handle}
	var out, errb bytes.Buffer
	env := append([]string{"PATH=/usr/bin", "HOME=" + t.TempDir(), "BW_DATA_DIR=" + data, "BW_COMMIT=abc1234", "BW_SOURCE=local", "BW_WORKTREE=wt", "BW_JOBS=1"}, o.env...)
	code := Run(args, env, &out, &errb, Deps{R: fake, Root: root, Self: "/x/wallet-build", HostSetup: o.setup, Stdin: o.stdin})
	r := result{code: code, out: out.String(), err: errb.String(), root: root, data: data, fake: fake}
	r.calls = calls(fake, root)
	for _, e := range fake.Execs {
		r.execs = append(r.execs, strings.Join(e.Argv, " "))
	}
	r.logs = filepath.Join(root, "dist", "logs")
	return r
}

// BW_QUIET=1 in the session env must not swallow the hook's verdict: a block still says why, on stderr.
func TestHookIsExemptFromQuiet(t *testing.T) {
	block := `{"tool_input":{"command":"until x; do sleep 1; done"}}`
	for _, args := range [][]string{{"hook", "no-poll"}, {"-q", "hook", "no-poll"}} {
		r := runCLI(t, opts{env: []string{"BW_QUIET=1"}, stdin: strings.NewReader(block)}, args...)
		if r.code != 2 || !strings.HasPrefix(r.err, "Blocked: no sleep/until/while poll loops") {
			t.Errorf("%v: code %d, stderr %q", args, r.code, r.err)
		}
	}
	r := runCLI(t, opts{env: []string{"BW_QUIET=1"}, stdin: strings.NewReader(`{"tool_input":{"command":"make test"}}`)}, "hook", "no-poll")
	if r.code != 0 || r.err != "" || r.out != "" {
		t.Errorf("pass: code %d out %q err %q", r.code, r.out, r.err)
	}
}

// native runs a command the way the container (or CI) does: BW_NATIVE=1 with a run directory.
func native(t *testing.T, o opts, args ...string) result {
	t.Helper()
	run := t.TempDir()
	o.env = append([]string{"BW_NATIVE=1", "BW_RUN_DIR=" + run, "BW_RUN_ID=r1"}, o.env...)
	r := runCLI(t, o, args...)
	r.logs = run
	return r
}

func sorted(s []string) []string {
	c := append([]string(nil), s...)
	sort.Strings(c)
	return c
}

func expect(t *testing.T, got, want []string) {
	t.Helper()
	g, w := sorted(got), sorted(want)
	if strings.Join(g, "\n") != strings.Join(w, "\n") {
		t.Errorf("commands differ\n--- got\n%s\n--- want\n%s", strings.Join(g, "\n"), strings.Join(w, "\n"))
	}
}

func file(t *testing.T, p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// ---- golden argument vectors, container side ----

// every .dart file mkRepo creates, in the order of the tool (sorted)
const allDart = "app/integration_test/a_test.dart app/integration_test/layout_test.dart app/lib/main.dart app/test/a_test.dart app/test/web/x_test.dart packages/wallet_core/test/x_test.dart"

func TestGoldenArgvLint(t *testing.T) {
	r := native(t, opts{}, "lint")
	expect(t, r.calls, []string{
		"$ dart format -o none --set-exit-if-changed " + allDart,
		"$ shellcheck tools/a.sh dev/b.sh dev/install-lint-tools.sh .github/scripts/c.sh",
		"$ actionlint",
		"$ tools/no-poll-hook.sh --self-test",
		"$ /x/wallet-build hook no-poll --self-test", // the Go port of the hook runs next to the bash one (GO4-B)
		"$ tools/relay-deploy.sh --self-test",
		"$ /x/wallet-build relay-native-check",
	})
	if r.code != 0 {
		t.Errorf("code %d\n%s", r.code, r.err)
	}
	for _, step := range []string{"format", "shellcheck", "actionlint", "hook-selftest", "env-selftest", "deploy-selftest", "native-units"} {
		if _, err := os.Stat(filepath.Join(r.logs, step+".status")); err != nil {
			t.Errorf("no status for %s", step)
		}
	}
	if !strings.Contains(r.out, "pub=") && !strings.Contains(r.out, "format=ok shellcheck=ok actionlint=ok hook-selftest=ok env-selftest=ok deploy-selftest=ok native-units=ok") {
		t.Errorf("results line missing:\n%s", r.out)
	}
}

func TestGoldenArgvPackages(t *testing.T) {
	logs := func(r result, n string) string { return filepath.Join(r.logs, n) }
	cases := []struct {
		args []string
		want func(r result) []string
	}{
		{[]string{"analyze"}, func(r result) []string {
			return []string{"packages/wallet_importer$ dart analyze --fatal-infos", "packages/wallet_core$ dart analyze --fatal-infos", "packages/sync$ dart analyze --fatal-infos",
				"relay$ dart analyze --fatal-infos", "app$ flutter analyze --fatal-infos --no-pub"}
		}},
		{[]string{"analyze", "core", "app"}, func(r result) []string {
			return []string{"packages/wallet_core$ dart analyze --fatal-infos", "app$ flutter analyze --fatal-infos --no-pub"}
		}},
		{[]string{"importer"}, func(r result) []string {
			return []string{"packages/wallet_importer$ dart analyze --fatal-infos",
				"packages/wallet_importer$ dart test --timeout 60s --file-reporter json:" + logs(r, "tests-importer.json")}
		}},
		{[]string{"app"}, func(r result) []string {
			return []string{"app$ flutter analyze --fatal-infos --no-pub", "app$ flutter test --no-pub --timeout 60s --file-reporter json:" + logs(r, "tests-app.json")}
		}},
		{[]string{"core", "test/x_test.dart"}, func(r result) []string {
			return []string{"packages/wallet_core$ dart test --timeout 60s test/x_test.dart --file-reporter json:" + logs(r, "tests-core:one.json")}
		}},
		{[]string{"app", "app/test/a_test.dart"}, func(r result) []string { // repo-root path is accepted
			return []string{"app$ flutter test --timeout 60s --no-pub test/a_test.dart --file-reporter json:" + logs(r, "tests-app:one.json")}
		}},
		{[]string{"format"}, func(r result) []string { return []string{"$ dart format " + allDart} }},
		{[]string{"outdated"}, func(r result) []string {
			return []string{"packages/wallet_importer$ dart pub outdated", "packages/wallet_core$ dart pub outdated", "packages/sync$ dart pub outdated",
				"relay$ dart pub outdated", "app$ flutter pub outdated"}
		}},
		{[]string{"linux"}, func(r result) []string {
			return []string{"app$ flutter build linux --release", "app$ tar -C build/linux/x64/release -czf ../dist/BudgetWallet-linux-x64.tar.gz bundle"}
		}},
		{[]string{"web-test"}, func(r result) []string { return []string{"app$ flutter test --platform chrome --no-pub test/web"} }},
		{[]string{"web-test", "app/test/web/x_test.dart"}, func(r result) []string {
			return []string{"app$ flutter test --platform chrome --no-pub test/web/x_test.dart"}
		}},
		{[]string{"web"}, func(r result) []string {
			return []string{"app$ flutter build web --wasm --release", "$ cp -r app/build/web dist/web"}
		}},
	}
	for _, c := range cases {
		t.Run(strings.Join(c.args, " "), func(t *testing.T) {
			r := native(t, opts{}, c.args...)
			expect(t, r.calls, c.want(r))
			if r.code != 0 {
				t.Errorf("code %d: %s %s", r.code, r.out, r.err)
			}
		})
	}
}

func headless(r result, display, tail string) string {
	return "timeout -k 10 1200 dbus-run-session --config-file=" + r.root + "/tools/dbus-headless.conf -- xvfb-run " + display + " -s -screen 0 1920x1080x24 " + tail
}

func TestGoldenArgvDesktopAndPerf(t *testing.T) {
	r := native(t, opts{}, "desktop-test", "a")
	expect(t, r.calls, []string{"app$ " + headless(r, "-a", "flutter test integration_test/a_test.dart -d linux --no-pub -r expanded --file-reporter json:"+filepath.Join(r.logs, "tests-desktop-a.json"))})
	if r.code != 0 {
		t.Errorf("code %d", r.code)
	}
	r = native(t, opts{}, "perf")
	expect(t, r.calls, []string{"app$ " + headless(r, "-a", "flutter drive --profile -d linux --no-pub --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart")})
	r = native(t, opts{}, "desktop-test", "nonexistent_test.dart")
	if r.code != 1 || !strings.Contains(r.err, "no such test: app/integration_test/nonexistent_test.dart") {
		t.Errorf("code %d err %q", r.code, r.err)
	}
}

func TestDesktopTestParallelShards(t *testing.T) {
	r := native(t, opts{env: []string{"BW_JOBS=2"}}, "desktop-test", "a", "layout")
	if r.code != 0 {
		t.Fatalf("code %d\n%s\n%s", r.code, r.out, r.err)
	}
	var flutter []string
	displays := map[string]bool{}
	for _, c := range r.calls {
		if strings.Contains(c, "flutter test integration_test/") {
			flutter = append(flutter, c[strings.Index(c, "flutter test"):])
			if i := strings.Index(c, "xvfb-run -n "); i >= 0 {
				displays[strings.Fields(c[i:])[2]] = true
			}
		}
	}
	if len(flutter) != 6 {
		t.Fatalf("want 1 unit for a and 5 shards of layout, got %d: %v", len(flutter), flutter)
	}
	shards := 0
	for _, f := range flutter {
		if strings.Contains(f, "layout_test.dart") && strings.Contains(f, "--total-shards 5 --shard-index") {
			shards++
		}
	}
	if shards != 5 {
		t.Errorf("layout shards: %d", shards)
	}
	// Which workers get units depends on scheduling (one fast worker may claim every unit), so check per call:
	// worker N (app copy dist/desktop-test/wN) must use display 100+N, never another worker's.
	for _, c := range r.fake.Calls {
		argv := strings.Join(c.Argv, " ")
		if !strings.Contains(argv, "flutter test integration_test/") {
			continue
		}
		m := regexp.MustCompile(`dist/desktop-test/w(\d+)(/|$)`).FindStringSubmatch(c.Dir)
		if m == nil || !strings.Contains(argv, "xvfb-run -n 10"+m[1]+" ") {
			t.Errorf("worker needs its own display 10N: dir %s argv %s", c.Dir, argv)
		}
	}
	if len(displays) == 0 || len(displays) > 2 {
		t.Errorf("displays: %v", displays)
	}
	// each worker works in its own copy of app/
	for _, c := range r.fake.Calls {
		if strings.Contains(strings.Join(c.Argv, " "), "flutter test integration_test/") &&
			!strings.Contains(c.Dir, "dist/desktop-test/w") {
			t.Errorf("unit ran in %s", c.Dir)
		}
	}
	// shards are merged into one desktop-layout step; shard files are gone
	for _, name := range []string{"desktop-a.status", "desktop-layout.status", "desktop-layout.log", "app-linux-layout.log"} {
		if _, err := os.Stat(filepath.Join(r.logs, name)); err != nil {
			t.Errorf("missing %s", name)
		}
	}
	if m, _ := filepath.Glob(filepath.Join(r.logs, "*.s[0-9].*")); len(m) != 0 {
		t.Errorf("shard files left: %v", m)
	}
	if !strings.Contains(file(t, filepath.Join(r.logs, "desktop-layout.log")), "--- shard 5/5:") {
		t.Errorf("merged log:\n%s", file(t, filepath.Join(r.logs, "desktop-layout.log")))
	}
	hist := file(t, filepath.Join(r.data, "history", "steps.jsonl"))
	if strings.Count(hist, `"step":"desktop-layout"`) != 1 || strings.Contains(hist, `desktop-layout.s`) {
		t.Errorf("one history line per file, never per shard:\n%s", hist)
	}
	if !strings.Contains(r.out, "=== desktop-test: 6 units from 2 files on 2 workers (BW_JOBS) ===") {
		t.Errorf("out:\n%s", r.out)
	}
}

func TestDesktopTestBadJobs(t *testing.T) {
	r := native(t, opts{env: []string{"BW_JOBS=0"}}, "desktop-test", "a")
	if r.code != 1 || !strings.Contains(r.err, "BW_JOBS must be a positive number, not '0'") {
		t.Errorf("code %d err %q", r.code, r.err)
	}
}

func apkHandle(sameKey bool) func(c sys.Cmd) int {
	return func(c sys.Cmd) int {
		switch c.Argv[0] {
		case "keytool":
			c.Stdout.Write([]byte("Certificate fingerprints:\n\t SHA256: AA:BB:CC:01\n"))
		default:
			if strings.HasSuffix(c.Argv[0], "apksigner") {
				d := "aabbcc01"
				if !sameKey {
					d = "deadbeef"
				}
				c.Stdout.Write([]byte("Signer #1 certificate SHA-256 digest: " + d + "\n"))
			}
		}
		return 0
	}
}

func apkEnv(t *testing.T, root string) []string {
	ks := filepath.Join(t.TempDir(), "release.jks")
	os.WriteFile(ks, []byte("k"), 0o600)
	ah := filepath.Join(root, "sdk")
	write(t, filepath.Join(ah, "build-tools/33.0.1/apksigner"), "")
	write(t, filepath.Join(ah, "build-tools/34.0.0/apksigner"), "")
	write(t, filepath.Join(ah, "build-tools/9.0.0/apksigner"), "")
	return []string{"BW_KEYSTORE=" + ks, "BW_KEYSTORE_PASSWORD=pw-should-never-show", "BW_KEY_ALIAS=al", "ANDROID_HOME=" + ah}
}

func TestGoldenArgvApk(t *testing.T) {
	root := mkRepo(t)
	env := apkEnv(t, root)
	r := native(t, opts{root: root, env: env, handle: apkHandle(true)}, "apk")
	expect(t, r.calls, []string{
		"app$ flutter build apk --release --target-platform android-arm64,android-x64",
		"$ keytool -list -v -keystore " + strings.TrimPrefix(env[0], "BW_KEYSTORE=") + " -storepass:env BW_KEYSTORE_PASSWORD -alias al",
		"$ " + root + "/sdk/build-tools/34.0.0/apksigner verify --print-certs dist/BudgetWallet-android.apk",
	})
	if r.code != 0 {
		t.Errorf("code %d\n%s", r.code, r.err)
	}
	if _, err := os.Stat(filepath.Join(root, "dist/BudgetWallet-android.apk")); err != nil {
		t.Error("the APK was not copied to dist/")
	}
	// the password never appears in a log, status or history file
	files, _ := filepath.Glob(filepath.Join(r.logs, "*"))
	for _, f := range files {
		if strings.Contains(file(t, f), "pw-should-never-show") {
			t.Errorf("password in %s", f)
		}
	}
	// arm64-only
	r = native(t, opts{root: root, env: append([]string{"BW_APK_ABIS=arm64"}, env...), handle: apkHandle(true)}, "apk")
	if r.calls[0] != "app$ flutter build apk --release --target-platform android-arm64" {
		t.Errorf("abis: %s", r.calls[0])
	}
	// a different signer fails the signature step
	r = native(t, opts{root: root, env: env, handle: apkHandle(false)}, "apk")
	if r.code != 1 || !strings.Contains(file(t, filepath.Join(r.logs, "apk-signature.log")), "release key: aabbcc01\napk signer:  deadbeef") {
		t.Errorf("code %d log %s", r.code, file(t, filepath.Join(r.logs, "apk-signature.log")))
	}
}

func TestApkRefusesWithoutKey(t *testing.T) {
	r := native(t, opts{}, "apk")
	if r.code != 1 || !strings.Contains(r.err, "BW_KEYSTORE is not set to the release key") || len(r.calls) != 0 {
		t.Errorf("code %d calls %v err %q", r.code, r.calls, r.err)
	}
	if !strings.Contains(file(t, filepath.Join(r.logs, "apk.log")), "exit 1") {
		t.Error("apk.log should record the refusal")
	}
}

func TestGoldenArgvRelayBin(t *testing.T) {
	root := mkRepo(t)
	h := func(c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[1] == "compile" {
			write(t, filepath.Join(root, "dist/relay/relay-linux-x64"), "binary")
		}
		return 0
	}
	r := native(t, opts{root: root, handle: h}, "relay-bin", "x64")
	expect(t, r.calls, []string{"relay$ dart compile exe --target-os linux --target-arch x64 bin/relay.dart -o ../dist/relay/relay-linux-x64", "$ file dist/relay/relay-linux-x64"})
	sum := file(t, filepath.Join(root, "dist/relay/relay-linux-x64.sha256"))
	if !strings.HasSuffix(sum, "  relay-linux-x64\n") || len(sum) != 64+2+len("relay-linux-x64\n") {
		t.Errorf("sha256 file %q", sum)
	}
}

func TestDesktopSmoke(t *testing.T) {
	r := native(t, opts{}, "desktop-smoke")
	if r.code != 1 {
		t.Errorf("no app log means FAIL, got %d", r.code)
	}
	joined := strings.Join(r.calls, "\n")
	for _, want := range []string{"app$ flutter build linux --release", "tar -xzf dist/BudgetWallet-linux-x64.tar.gz -C ", "xvfb-run -a -s -screen 0 1920x1080x24 /x/wallet-build smoke-run "} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q in\n%s", want, joined)
		}
	}
	if !strings.Contains(file(t, filepath.Join(r.logs, "desktop-smoke.log")), "FAIL: no app.start ready line in the app log") {
		t.Error("expected the ready-line failure in the log")
	}
}

// ---- go-check ----

func TestGoCheckNativeWithoutGoIsSkipped(t *testing.T) {
	root := mkRepo(t)
	fake := &sys.Fake{Missing: map[string]bool{"go": true}}
	var out, errb bytes.Buffer
	data := t.TempDir()
	code := Run([]string{"lint"}, []string{"PATH=/usr/bin", "HOME=" + t.TempDir(), "BW_NATIVE=1", "BW_DATA_DIR=" + data, "BW_COMMIT=c", "BW_WORKTREE=wt"}, &out, &errb, Deps{R: fake, Root: root, Self: "/x/wallet-build"})
	if code != 0 {
		t.Fatalf("code %d %s", code, errb.String())
	}
	if !strings.Contains(out.String(), "go not found (CI before GO3), skipped") || !strings.Contains(out.String(), "go-check") {
		t.Errorf("out:\n%s", out.String())
	}
	b, _ := os.ReadFile(filepath.Join(root, "dist/logs/go-check.status"))
	if f := strings.Fields(string(b)); len(f) != 3 || f[1] != "0" {
		t.Errorf("status %q", b)
	}
}

func goHandle(cgo bool) func(c sys.Cmd) int {
	return func(c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[0] == "go" && c.Argv[1] == "version" {
			info := "dist/bin/wallet-build: go1.26.10\n\tbuild\t-trimpath=true\n"
			if cgo {
				info += "\tbuild\tCGO_ENABLED=0\n"
			}
			c.Stdout.Write([]byte(info))
		}
		return 0
	}
}

func TestGoCheckSteps(t *testing.T) {
	r := runCLI(t, opts{env: []string{"BW_NATIVE=1"}, handle: goHandle(true)}, "lint")
	if r.code != 0 {
		t.Fatalf("code %d\n%s", r.code, r.out)
	}
	for _, want := range []string{"tools/wallet-build$ go vet ./...", "tools/wallet-build$ go test ./...", "$ gofmt -l tools/wallet-build", "$ go version -m dist/bin/wallet-build"} {
		found := false
		for _, c := range r.calls {
			found = found || c == want
		}
		if !found {
			t.Errorf("missing %q in %v", want, r.calls)
		}
	}
	r = runCLI(t, opts{env: []string{"BW_NATIVE=1"}, handle: goHandle(false)}, "lint")
	if r.code != 1 || !strings.Contains(r.out, "was not built with CGO_ENABLED=0") {
		t.Errorf("a cgo binary must fail go-check: code %d\n%s", r.code, r.out)
	}
	// gofmt listing a file fails the step
	h := func(c sys.Cmd) int {
		if c.Argv[0] == "gofmt" {
			c.Stdout.Write([]byte("tools/wallet-build/main.go\n"))
		}
		return goHandle(true)(c)
	}
	r = runCLI(t, opts{env: []string{"BW_NATIVE=1"}, handle: h}, "lint")
	if r.code != 1 || !strings.Contains(r.out, "need formatting") {
		t.Errorf("gofmt: code %d\n%s", r.code, r.out)
	}
}

// ---- usage, quiet ----

func TestUsageExitsTwo(t *testing.T) {
	for _, args := range [][]string{
		{"no-such-command"},
		{"mutate"}, {"mutate", "core"}, {"relay-bin", "riscv"},
		{"times", "--bogus"}, {"times", "-n", "x"}, {"times", "--source", "mars"}, {"trend", "-n"}, {"trend", "stray"},
		{"ci"}, {"ci", "bogus"}, {"log"}, {"log", "tests"}, {"log", "drive", "x"}, {"log", "perf"}, {"log", "bogus"}, {"smoke-run"}, {"smoke-run", "bin", "x"},
	} {
		for _, native := range []bool{true, false} {
			env := []string{}
			if native {
				env = []string{"BW_NATIVE=1"}
			} else if args[0] == "mutate" || args[0] == "relay-bin" {
				continue // checked inside the container (TestUsageErrorsInsideContainerStillCreateRunDir)
			}
			r := runCLI(t, opts{env: env}, args...)
			if r.code != 2 {
				t.Errorf("%v (native=%v): exit %d, want 2\n%s%s", args, native, r.code, r.out, r.err)
			}
		}
	}
}

func TestUsageTextIsBuildShHeader(t *testing.T) {
	r := runCLI(t, opts{}, "no-such-command")
	if !strings.HasPrefix(r.out, "Local builds in a rootless Podman container.") || !strings.Contains(r.out, "tools/build.sh [-q|--quiet] <command> [args…]") {
		t.Errorf("usage text:\n%s", r.out[:min(len(r.out), 200)])
	}
	if len(r.calls) != 0 {
		t.Errorf("an unknown command must not start anything: %v", r.calls)
	}
	if m, _ := filepath.Glob(filepath.Join(r.data, "runs", "*")); len(m) != 0 {
		t.Errorf("an unknown command must not create a run dir: %v", m)
	}
}

func TestUsageErrorsInsideContainerStillCreateRunDir(t *testing.T) {
	// bash: run_begin happens on the host before the container sees the bad arguments
	for _, args := range [][]string{{"relay-bin", "badarch"}} { // mutate checks its arguments on the host (TestMutateUsageErrorsNeverTouchPodman)
		r := runCLI(t, opts{handle: func(c sys.Cmd) int { // the container prints the usage and exits 2
			if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "run" {
				return 2
			}
			return 0
		}}, args...)
		if r.code != 2 {
			t.Fatalf("%v: %d", args, r.code)
		}
		runs, _ := filepath.Glob(filepath.Join(r.data, "runs", "*"))
		if len(runs) != 1 || !strings.Contains(runs[0], "-"+args[0]+"-") {
			t.Fatalf("%v: runs %v", args, runs)
		}
		lf := file(t, filepath.Join(runs[0], "last-failed.txt"))
		if lf != "run "+runs[0]+" (exit 2, no failed step recorded)\n" {
			t.Errorf("last-failed.txt %q", lf)
		}
	}
}

func TestQuietPrintsNothing(t *testing.T) {
	cases := [][]string{
		{"-q", "no-such-command"}, {"--quiet", "no-such-command"}, {"-q", "lint"}, {"-q", "shell", "-c", "echo hi"}, {"-q", "stage"}, {"-q", "mutate"},
		{"-q", "times"}, {"-q", "ci", "bogus"}, {"-q", "version"},
	}
	for _, args := range cases {
		for _, nat := range []bool{false, true} {
			env := []string{}
			if nat {
				env = []string{"BW_NATIVE=1"}
			}
			h := func(c sys.Cmd) int {
				if c.Stdout != nil || c.Stderr != nil {
					// a quiet run must never hand our terminal to a child; step logs are our own writers
					if _, ok := c.Stdout.(*os.File); ok {
						t.Errorf("%v: child got a real stdout", args)
					}
				}
				return 0
			}
			r := runCLI(t, opts{env: env, handle: h}, args...)
			if r.out != "" || r.err != "" {
				t.Errorf("%v native=%v printed stdout %q stderr %q", args, nat, r.out, r.err)
			}
			for _, c := range r.fake.Calls {
				if len(c.Argv) > 1 && c.Argv[0] == "podman" && c.Argv[1] == "run" && (c.Stdout != nil || c.Stderr != nil) && args[1] != "shell" {
					t.Errorf("%v: podman run got output writers in quiet mode", args)
				}
			}
		}
	}
	// BW_QUIET=1 is the same as -q
	r := runCLI(t, opts{env: []string{"BW_QUIET=1"}}, "no-such-command")
	if r.out != "" || r.code != 2 {
		t.Errorf("BW_QUIET: %q %d", r.out, r.code)
	}
}

func TestQuietKeepsExitCodeAndLogs(t *testing.T) {
	h := func(c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[0] == "dart" && c.Argv[1] == "format" {
			c.Stdout.Write([]byte("Changed app/lib/zz.dart\n"))
			return 1
		}
		return 0
	}
	r := native(t, opts{handle: h}, "-q", "lint")
	if r.code != 1 || r.out != "" || r.err != "" {
		t.Errorf("code %d out %q err %q", r.code, r.out, r.err)
	}
	if !strings.Contains(file(t, filepath.Join(r.logs, "format.log")), "Changed app/lib/zz.dart") {
		t.Error("the step log is written even when quiet")
	}
}

func TestImageNameIsExemptFromQuiet(t *testing.T) {
	r := runCLI(t, opts{}, "-q", "image-name")
	if !strings.HasPrefix(r.out, "localhost/budget-wallet-dev:3.47.7-") || r.code != 0 {
		t.Errorf("code %d out %q", r.code, r.out)
	}
	if m, _ := filepath.Glob(filepath.Join(r.data, "runs", "*")); len(m) != 0 {
		t.Errorf("image-name must not create a run dir: %v", m)
	}
	if len(r.calls) != 1 || !strings.HasPrefix(r.calls[0], "$ podman image exists localhost/budget-wallet-dev:3.47.7-") {
		t.Errorf("calls %v", r.calls)
	}
}

func TestVersion(t *testing.T) {
	r := runCLI(t, opts{}, "version")
	if !strings.HasPrefix(r.out, "wallet-build ") || !strings.Contains(r.out, "go1.") {
		t.Errorf("%q", r.out)
	}
}
