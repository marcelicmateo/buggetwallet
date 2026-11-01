package steps

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func fakeProc(t *testing.T, load, memKB string, cpus int) {
	t.Helper()
	d := t.TempDir()
	write(t, filepath.Join(d, "loadavg"), load+" 1.00 1.00 1/500 12345\n")
	write(t, filepath.Join(d, "meminfo"), "MemTotal:       65000000 kB\nMemAvailable:   "+memKB+" kB\nBuffers: 1 kB\n")
	oldP, oldC := procDir, numCPU
	procDir, numCPU = d, func() int { return cpus }
	t.Cleanup(func() { procDir, numCPU = oldP, oldC })
}

func TestDesktopJobsFromProc(t *testing.T) {
	cases := []struct {
		load, mem string
		cpus      int
		want      int
	}{
		{"0.50", "40000000", 32, 6},  // (32-0)/4 = 8, capped at 6
		{"12.70", "40000000", 32, 5}, // (32-12)/4 = 5
		{"0,50", "40000000", 16, 4},  // a decimal comma
		{"2.00", "7000000", 32, 2},   // 7000000 kB / 3 GB = 2
		{"30.00", "40000000", 32, 1}, // busy machine: at least one
		{"0.00", "1000000", 32, 1},   // little RAM: at least one
		{"3.99", "40000000", 8, 1},   // (8-3)/4 = 1
	}
	for _, c := range cases {
		fakeProc(t, c.load, c.mem, c.cpus)
		got, err := DesktopJobs(sys.Env{})
		if err != nil || got != c.want {
			t.Errorf("load %s mem %s cpus %d: got %d (%v) want %d", c.load, c.mem, c.cpus, got, err, c.want)
		}
	}
}

func TestDesktopJobsEnvOverride(t *testing.T) {
	fakeProc(t, "0.1", "40000000", 32)
	if got, err := DesktopJobs(sys.Env{"BW_JOBS=3"}); got != 3 || err != nil {
		t.Errorf("%d %v", got, err)
	}
	for _, bad := range []string{"0", "-1", "x", "1.5", "007", ""} {
		got, err := DesktopJobs(sys.Env{"BW_JOBS=" + bad})
		if bad == "" {
			if err != nil || got != 6 {
				t.Errorf("empty BW_JOBS means auto: %d %v", got, err)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), "BW_JOBS must be a positive number, not '"+bad+"'") {
			t.Errorf("BW_JOBS=%q: %d %v", bad, got, err)
		}
	}
}

func newSession(t *testing.T, root string, kv ...string) (*run.Session, *bytes.Buffer) {
	t.Helper()
	logs := t.TempDir()
	out := &bytes.Buffer{}
	env := sys.Env{"BW_DATA_DIR=" + t.TempDir(), "BW_RUN_DIR=" + logs, "BW_RUN_ID=r", "BW_COMMIT=c", "BW_SOURCE=local", "BW_WORKTREE=wt", "BW_CMD=desktop-test"}
	c := run.New(root, append(env, kv...), out, out, &sys.Fake{})
	c.Clock = func() time.Time { return time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC) }
	return run.NewSession(c), out
}

// A sharded file's per-shard logs, reports and statuses become one desktop-<name> step with summed seconds.
func TestDesktopMerge(t *testing.T) {
	s, _ := newSession(t, t.TempDir())
	logs := s.Logs
	for i, sh := range []struct {
		secs, rc, started string
		ok                bool
	}{{"10.4", "0", "2026-11-01T09:00:05+00:00", true}, {"20.9", "1", "2026-11-01T09:00:01+00:00", true}, {"", "", "", false}, {"0.3", "0", "2026-11-01T09:00:09+00:00", true}} {
		if !sh.ok {
			continue
		}
		name := "desktop-layout.s" + string(rune('0'+i))
		write(t, filepath.Join(logs, name+".status"), sh.secs+" "+sh.rc+" "+sh.started+"\n")
		write(t, filepath.Join(logs, name+".log"), "# "+name+": started x\nbody of shard "+string(rune('0'+i))+"\n# "+name+": finished y, "+sh.secs+" s, exit "+sh.rc+"\n")
		write(t, filepath.Join(logs, "app-linux-layout.s"+string(rune('0'+i))+".log"), "applog"+string(rune('0'+i))+"\n")
	}
	desktopMerge(s, "layout", 4)
	status, _ := os.ReadFile(filepath.Join(logs, "desktop-layout.status"))
	if string(status) != "31.6 1 2026-11-01T09:00:01+00:00\n" { // 10.4 + 20.9 + 0.3, earliest start, bad because a shard failed or did not run
		t.Errorf("status %q", status)
	}
	log := file(t, filepath.Join(logs, "desktop-layout.log"))
	for _, want := range []string{"# desktop-layout: started 2026-11-01T09:00:01+00:00\n", "--- shard 1/4: 10.4 s, exit 0\nbody of shard 0\n", "--- shard 2/4: 20.9 s, exit 1\n",
		"--- shard 3/4: did not run\n", "--- shard 4/4: 0.3 s, exit 0\n", "--- desktop-layout: no test report at /nonexistent\n", ", 31.6 s, exit 1\n"} {
		if !strings.Contains(log, want) {
			t.Errorf("merged log lacks %q:\n%s", want, log)
		}
	}
	if app := file(t, filepath.Join(logs, "app-linux-layout.log")); app != "applog0\napplog1\napplog3\n" {
		t.Errorf("app log %q", app)
	}
	if m, _ := filepath.Glob(filepath.Join(logs, "*.s[0-9].*")); len(m) != 0 {
		t.Errorf("shard files not removed: %v", m)
	}
}

func file(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestMergeSumsTenthsExactly(t *testing.T) {
	s, _ := newSession(t, t.TempDir())
	for i, secs := range []string{"0.1", "0.2", "0.9", "100.0", "7.7"} {
		n := "desktop-x.s" + string(rune('0'+i))
		write(t, filepath.Join(s.Logs, n+".status"), secs+" 0 2026-11-01T09:00:00+00:00\n")
		write(t, filepath.Join(s.Logs, n+".log"), "a\nb\nc\n")
	}
	desktopMerge(s, "x", 5)
	if st := file(t, filepath.Join(s.Logs, "desktop-x.status")); st != "108.9 0 2026-11-01T09:00:00+00:00\n" {
		t.Errorf("%q", st)
	}
}

func TestEnvSelftest(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "packages/wallet_core/test/a_test.dart"), "final s = Platform.environment['BW_FUZZ_SEED'];\nPlatform.environment[\"BW_ANDROID_ROOT\"];\n")
	write(t, filepath.Join(root, "app/test/b_test.dart"), "Platform.environment['BW_JOBS']\n")
	s, out := newSession(t, root)
	if rc := s.RunStep("env-selftest", EnvSelftest, true); rc != 0 {
		t.Errorf("passed variables and BW_ANDROID_ROOT are fine: rc %d %s", rc, out)
	}
	write(t, filepath.Join(root, "relay/test/c_test.dart"), "Platform.environment['BW_NEW_THING']\n")
	s, out = newSession(t, root)
	if rc := s.RunStep("env-selftest", EnvSelftest, true); rc != 1 || !strings.Contains(out.String(), "env-selftest: BW_NEW_THING is read by a test but not passed") {
		t.Errorf("rc %d out %q", rc, out)
	}
}

// The real repository: every BW_* variable its tests read is in the Go pass-through list.
func TestEnvSelftestRealRepo(t *testing.T) {
	root, _ := filepath.Abs("../../../..")
	if _, err := os.Stat(filepath.Join(root, "app/pubspec.yaml")); err != nil {
		t.Skip("not inside the repository")
	}
	s, out := newSession(t, root)
	if rc := s.RunStep("env-selftest", EnvSelftest, true); rc != 0 {
		t.Errorf("rc %d: %s", rc, out)
	}
}

func TestPubStale(t *testing.T) {
	root := t.TempDir()
	d := "app"
	if !PubStale(root, d) {
		t.Error("no package_config means stale")
	}
	write(t, filepath.Join(root, d, "pubspec.yaml"), "name: a\n")
	write(t, filepath.Join(root, d, ".dart_tool/package_config.json"), `{"packages":[{"name":"x","rootUri": "file://`+root+`/pkgs/x"}]}`)
	os.MkdirAll(filepath.Join(root, "pkgs/x"), 0o755)
	old := time.Now().Add(-time.Hour)
	os.Chtimes(filepath.Join(root, d, "pubspec.yaml"), old, old)
	if PubStale(root, d) {
		t.Error("fresh config, existing pub cache")
	}
	now := time.Now()
	os.Chtimes(filepath.Join(root, d, "pubspec.yaml"), now.Add(time.Hour), now.Add(time.Hour))
	if !PubStale(root, d) {
		t.Error("a newer pubspec makes it stale")
	}
	os.Chtimes(filepath.Join(root, d, "pubspec.yaml"), old, old)
	write(t, filepath.Join(root, "packages/dep/pubspec.yaml"), "name: dep\n")
	if !PubStale(root, d) {
		t.Error("a path dependency's pubspec newer than the config makes it stale")
	}
	os.Chtimes(filepath.Join(root, "packages/dep/pubspec.yaml"), old, old)
	os.RemoveAll(filepath.Join(root, "pkgs/x"))
	if !PubStale(root, d) {
		t.Error("a pub cache that is gone makes it stale")
	}
}

func TestWebBlockers(t *testing.T) {
	log := strings.Join([]string{
		"/cache/pub/hosted/pub.dev/sqlite3-3.8.0/lib/a.dart:1:1: Error: Not found: 'dart:ffi'",
		"/cache/pub/hosted/pub.dev/file_picker-13.1.0/lib/b.dart:2:2: Error: nope",
		"../packages/wallet_core/lib/c.dart:3:3: Error: dart:io",
		"lib/ui/main.dart:4:4: Error: x",
		"warning: not an error",
		"/cache/pub/hosted/pub.dev/sqlite3-3.8.0/lib/a.dart:9:9: Error: again",
	}, "\n")
	if got := WebBlockers(log); got != "file_picker,sqlite3,ui,wallet_core" && got != "file_picker,sqlite3,wallet_core,ui" {
		t.Errorf("got %q", got)
	}
	if got := WebBlockers("nothing\n"); got != "unknown, see web-wasm.log" {
		t.Errorf("got %q", got)
	}
}

func TestChunksKeepArgumentsShort(t *testing.T) {
	var files []string
	for i := 0; i < 5000; i++ {
		files = append(files, strings.Repeat("d", 60)+"/file.dart")
	}
	total := 0
	for _, ch := range chunks(files) {
		n := 0
		for _, f := range ch {
			n += len(f) + 1
		}
		if n > 100100 {
			t.Errorf("chunk of %d bytes", n)
		}
		total += len(ch)
	}
	if total != 5000 {
		t.Errorf("lost files: %d", total)
	}
}

func TestVersionSort(t *testing.T) {
	if !versionLess("build-tools/9.0.0/apksigner", "build-tools/34.0.0/apksigner") || versionLess("build-tools/34.0.0/apksigner", "build-tools/9.0.0/apksigner") {
		t.Error("34.0.0 must sort after 9.0.0 (sort -V)")
	}
	if !versionLess("build-tools/34.0.0/apksigner", "build-tools/34.0.1/apksigner") {
		t.Error("34.0.1 after 34.0.0")
	}
}

func TestSmokeRunDetectsEarlyExitAndCleanShutdown(t *testing.T) {
	dir := t.TempDir()
	crash := filepath.Join(dir, "crash.sh")
	write(t, crash, "#!/bin/sh\nexit 7\n")
	os.Chmod(crash, 0o755)
	var out bytes.Buffer
	if rc := SmokeRun(&out, crash, 3, filepath.Join(dir, "console.log"), nil); rc != 1 || !strings.Contains(out.String(), "FAIL: the app exited after 0s with code 7") {
		t.Errorf("rc %d out %q", rc, out.String())
	}
	good := filepath.Join(dir, "good.sh")
	write(t, good, "#!/bin/sh\necho started\nexec sleep 30\n")
	os.Chmod(good, 0o755)
	out.Reset()
	if rc := SmokeRun(&out, good, 1, filepath.Join(dir, "console2.log"), nil); rc != 1 && rc != 0 {
		t.Errorf("rc %d out %q", rc, out.String())
	}
	if !strings.Contains(out.String(), "app still running after 1 s; sending SIGTERM") {
		t.Errorf("out %q", out.String())
	}
	if !strings.Contains(file(t, filepath.Join(dir, "console2.log")), "started") {
		t.Error("the app's console output is kept")
	}
}
