package ci

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/sys"
)

// ---- ci step ----

func TestStepWritesLogTimesAndExitCode(t *testing.T) {
	need(t, "sh")
	h := newHX(t, sys.Real{})
	log := filepath.Join(h.tmp, "ci.log")
	h.x.C.Setenv("LOG", log)
	if rc, _ := h.x.Step([]string{"core", "--", "sh", "-c", "echo to-out; echo to-err >&2; exit 3"}); rc != 3 {
		t.Fatalf("rc %d", rc)
	}
	if got := read(t, log); got != "=== core ===\nto-out\nto-err\n" {
		t.Errorf("log %q", got)
	}
	if h.out.String() != "=== core ===\nto-out\nto-err\n" {
		t.Errorf("console %q", h.out)
	}
	if f := strings.Fields(read(t, filepath.Join(h.tmp, "times.txt"))); len(f) != 3 || f[0] != "core" || f[2] != "3" {
		t.Errorf("times.txt %v", f)
	}
	// a second step appends to both files
	if rc, _ := h.x.Step([]string{"sync", "--", "sh", "-c", "echo again"}); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if got := read(t, log); got != "=== core ===\nto-out\nto-err\n=== sync ===\nagain\n" {
		t.Errorf("log %q", got)
	}
	if n := len(lines(read(t, filepath.Join(h.tmp, "times.txt")))); n != 2 {
		t.Errorf("times.txt has %d lines", n)
	}
}

func TestStepSeconds(t *testing.T) {
	h := newHX(t, &sys.Fake{})
	now := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	h.x.C.Clock = func() time.Time { return now }
	h.x.C.R = &sys.Fake{Handle: func(sys.Cmd) int { now = now.Add(125 * time.Second); return 0 }}
	_, _ = h.x.Step([]string{"apk", "--", "true"})
	if got := read(t, filepath.Join(h.tmp, "times.txt")); got != "apk 125 0\n" {
		t.Errorf("times.txt %q", got)
	}
}

func TestStepUsage(t *testing.T) {
	h := newHX(t, &sys.Fake{})
	for _, a := range [][]string{nil, {"core"}, {"core", "--"}, {"core", "x", "y"}, {"", "--", "true"}} {
		if _, ok := h.x.Step(a); ok {
			t.Errorf("%v: accepted", a)
		}
	}
	if _, err := os.Stat(filepath.Join(h.tmp, "times.txt")); err == nil {
		t.Error("usage errors must not record a step")
	}
}

func TestStepMissingCommandFails(t *testing.T) {
	h := newHX(t, sys.Real{})
	if rc, _ := h.x.Step([]string{"x", "--", "/nonexistent/cmd"}); rc != 127 {
		t.Errorf("rc %d", rc)
	}
	if got := read(t, filepath.Join(h.tmp, "times.txt")); !strings.HasPrefix(got, "x ") || !strings.HasSuffix(got, " 127\n") {
		t.Errorf("times.txt %q", got)
	}
}

func TestStepTimeout(t *testing.T) {
	h := newHX(t, &sys.Fake{HandleCtx: func(ctx context.Context, c sys.Cmd) int {
		<-ctx.Done()
		return 143
	}}, "BW_TIMEOUT_SLOW=1")
	log := filepath.Join(h.tmp, "ci.log")
	h.x.C.Setenv("LOG", log)
	if rc, _ := h.x.Step([]string{"slow", "--", "sleep", "100"}); rc != 124 {
		t.Fatalf("rc %d", rc)
	}
	if got := read(t, log); !strings.Contains(got, "step slow timed out after 1 s") {
		t.Errorf("log %q", got)
	}
	if got := read(t, filepath.Join(h.tmp, "times.txt")); !strings.HasSuffix(got, " 124\n") {
		t.Errorf("times.txt %q", got)
	}
}

func TestStepTimeoutOfSmokeIsTheDesktopSmokeLimit(t *testing.T) {
	var deadline time.Duration
	h := newHX(t, &sys.Fake{HandleCtx: func(ctx context.Context, c sys.Cmd) int {
		d, ok := ctx.Deadline()
		if ok {
			deadline = time.Until(d)
		}
		return 0
	}})
	_, _ = h.x.Step([]string{"smoke", "--", "true"})
	if deadline < 19*time.Minute || deadline > 20*time.Minute+time.Second {
		t.Errorf("smoke limit %v", deadline)
	}
	deadline = 0
	_, _ = h.x.Step([]string{"lint-tools", "--", "true"}) // a step without a default limit has no deadline
	if deadline != 0 {
		t.Errorf("unexpected limit %v", deadline)
	}
}

func TestStepRedactsSecrets(t *testing.T) {
	need(t, "sh")
	h := newHX(t, sys.Real{}, "GH_TOKEN=tok-SECRET-1234")
	log := filepath.Join(h.tmp, "ci.log")
	h.x.C.Setenv("LOG", log)
	_, _ = h.x.Step([]string{"x", "--", "sh", "-c", "echo token $GH_TOKEN"})
	if got := read(t, log) + h.out.String(); strings.Contains(got, "SECRET") || !strings.Contains(got, "token ***") {
		t.Errorf("not redacted: %q", got)
	}
}

// ---- ci job-log: golden against the old action body ----

func jobLogCase(t *testing.T, times, outcomes string, withLog bool) {
	t.Helper()
	need(t, "bash")
	need(t, "python3")
	script, _ := filepath.Abs("testdata/joblog_old.sh")
	py, _ := filepath.Abs("../../../build_log.py")
	run := func(useGo bool) (map[string]string, string) {
		h := newHX(t, sys.Real{}, "GITHUB_RUN_ID=77", "ImageOS=ubuntu24")
		if times != "" {
			write(t, filepath.Join(h.tmp, "times.txt"), times)
		}
		log := filepath.Join(h.tmp, "..", filepath.Base(h.tmp)+"-ci.log")
		if withLog {
			write(t, log, "=== lint ===\nall fine\n")
		}
		h.x.C.Setenv("LOG", log)
		if useGo {
			if rc := h.x.JobLog([]string{"--job", "j", "--outcomes", outcomes}); rc != 0 {
				t.Fatalf("rc %d: %s", rc, h.errb)
			}
		} else {
			cmd := exec.Command("bash", script, py)
			cmd.Env = append(h.x.C.Env.Environ(), "OUTCOMES="+outcomes)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("old script: %v\n%s", err, out)
			}
		}
		got := map[string]string{}
		for _, f := range []string{"outcome.txt", "times.txt", "ci.log", "history.jsonl"} {
			if b, err := os.ReadFile(filepath.Join(h.tmp, "joblog", f)); err == nil {
				got[f] = maskTS(string(b))
			} else {
				got[f] = "<missing>"
			}
		}
		return got, h.tmp
	}
	want, _ := run(false)
	got, _ := run(true)
	for f := range want {
		if got[f] != want[f] {
			t.Errorf("%s differs\n go: %q\nold: %q", f, got[f], want[f])
		}
	}
}

func TestJobLogMatchesOldAction(t *testing.T) {
	times := "signing 1 0\napk 412 0\nlint 12 1\ncore 30 0\n"
	t.Run("two steps", func(t *testing.T) { jobLogCase(t, times, "signing=success apk=success", true) })
	t.Run("failed step", func(t *testing.T) { jobLogCase(t, times, "lint=failure", true) })
	t.Run("step that never ran", func(t *testing.T) { jobLogCase(t, times, "core=success sync=skipped", true) })
	t.Run("no times, no log", func(t *testing.T) { jobLogCase(t, "", "app=failure", false) })
	t.Run("same step twice", func(t *testing.T) { jobLogCase(t, "app 5 0\napp 7 0\n", "app=success", true) })
	t.Run("empty outcomes", func(t *testing.T) { jobLogCase(t, times, "", true) })
	t.Run("malformed times lines", func(t *testing.T) { jobLogCase(t, "junk\n\nlint 9 0\n", "lint=success", true) })
}

func TestJobLogUsage(t *testing.T) {
	h := newHX(t, &sys.Fake{})
	for _, a := range [][]string{nil, {"--outcomes", "a=b"}, {"--job"}, {"--bogus", "x"}, {"--job", ""}} {
		if rc := h.x.JobLog(a); rc != 2 {
			t.Errorf("%v: rc %d", a, rc)
		}
	}
}

func TestJobLogHistoryLines(t *testing.T) {
	h := newHX(t, &sys.Fake{})
	write(t, filepath.Join(h.tmp, "times.txt"), "lint 12 0\napk 400 1\n")
	if rc := h.x.JobLog([]string{"--job=lint", "--outcomes=lint=success apk=failure"}); rc != 0 {
		t.Fatal(rc)
	}
	d := filepath.Join(h.tmp, "joblog")
	if got := read(t, filepath.Join(d, "outcome.txt")); got != "lint=success(12s) apk=failure(400s)\n" {
		t.Errorf("outcome.txt %q", got)
	}
	hist := lines(read(t, filepath.Join(d, "history.jsonl")))
	if len(hist) != 2 || !strings.Contains(hist[0], `"step": "lint", "seconds": 12.0, "result": "ok"`) || !strings.Contains(hist[1], `"result": "FAILED"`) {
		t.Errorf("history %q", hist)
	}
}

// ---- ci merge: golden against the bash of the old log job ----

type art struct{ outcome, times, log, hist string }

func mergeCase(t *testing.T, arts map[string]*art, results map[string]string) {
	t.Helper()
	need(t, "bash")
	dir := t.TempDir()
	for j, a := range arts {
		d := filepath.Join(dir, "logs", "ci-log-"+j)
		write(t, filepath.Join(d, "outcome.txt"), a.outcome)
		if a.times != "-" {
			write(t, filepath.Join(d, "times.txt"), a.times)
		}
		if a.log != "-" {
			write(t, filepath.Join(d, "ci.log"), a.log)
		}
		if a.hist != "-" {
			write(t, filepath.Join(d, "history.jsonl"), a.hist)
		}
	}
	script, _ := filepath.Abs("testdata/merge_old.sh")
	cmd := exec.Command("bash", script)
	env := []string{"PATH=" + os.Getenv("PATH"), "RUNNER_TEMP=" + dir}
	for j, r := range results {
		env = append(env, "R_"+strings.ToUpper(j)+"="+r)
	}
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("old script: %v\n%s", err, out)
	}
	needs := "{"
	for j, r := range results {
		if needs != "{" {
			needs += ","
		}
		needs += `"` + j + `":{"result":"` + r + `","outputs":{}}`
	}
	needs += "}"
	h := newHX(t, &sys.Fake{})
	out, hist := filepath.Join(dir, "go.txt"), filepath.Join(dir, "go-history.jsonl")
	if rc := h.x.Merge([]string{"--artifacts", filepath.Join(dir, "logs"), "--needs-json", needs, "--out", out, "--history", hist}); rc != 0 {
		t.Fatalf("rc %d: %s", rc, h.errb)
	}
	if got, want := read(t, out), read(t, filepath.Join(dir, "ci.txt")); got != want {
		t.Errorf("ci.txt differs\n go: %q\nold: %q", got, want)
	}
	if got, want := read(t, hist), read(t, filepath.Join(dir, "history.jsonl")); got != want {
		t.Errorf("history differs\n go: %q\nold: %q", got, want)
	}
}

var allOK = map[string]string{"lint": "success", "importer": "success", "core": "success", "relay": "success", "app": "success", "desktop": "success",
	"apk": "success", "linux": "success", "publish": "success"}

func okArt(j string) *art {
	return &art{outcome: j + "=success(5s)\n", times: j + " 5 0\n", log: "=== " + j + " ===\nline of " + j + "\n", hist: `{"step":"` + j + `"}` + "\n"}
}

func with(base map[string]string, kv ...string) map[string]string {
	m := map[string]string{}
	for k, v := range base {
		m[k] = v
	}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	return m
}

func TestMergeMatchesOldScript(t *testing.T) {
	all := map[string]*art{}
	for _, j := range Jobs {
		all[j] = okArt(j)
	}
	t.Run("all green", func(t *testing.T) { mergeCase(t, all, allOK) })
	t.Run("tests skipped (apk and linux only)", func(t *testing.T) {
		arts := map[string]*art{"apk": okArt("apk"), "linux": okArt("linux")}
		skipped := with(allOK, "lint", "skipped", "importer", "skipped", "core", "skipped", "relay", "skipped", "app", "skipped", "desktop", "skipped", "publish", "skipped")
		mergeCase(t, arts, skipped)
	})
	t.Run("failed job, two steps", func(t *testing.T) {
		arts := map[string]*art{}
		for _, j := range Jobs {
			arts[j] = okArt(j)
		}
		arts["core"] = &art{outcome: "core=failure(31s) sync=success(40s)\n", times: "core 31 1\nsync 40 0\n", log: "=== core ===\nFAIL\n=== sync ===\nok\n", hist: "{\"a\":1}\n{\"a\":2}\n"}
		mergeCase(t, arts, with(allOK, "core", "failure", "desktop", "skipped", "publish", "skipped"))
	})
	t.Run("job died before its log (no artifact)", func(t *testing.T) {
		arts := map[string]*art{}
		for _, j := range Jobs {
			if j != "app" && j != "desktop" {
				arts[j] = okArt(j)
			}
		}
		mergeCase(t, arts, with(allOK, "app", "cancelled", "desktop", "skipped", "publish", "skipped"))
	})
	t.Run("empty outcome file counts as missing", func(t *testing.T) {
		arts := map[string]*art{"lint": {outcome: "", times: "-", log: "-", hist: "-"}, "apk": okArt("apk")}
		mergeCase(t, arts, with(allOK, "lint", "failure"))
	})
	t.Run("logs without final newline", func(t *testing.T) {
		arts := map[string]*art{
			"lint":  {outcome: "lint=success(1s)", times: "lint 1 0", log: "no newline at the end", hist: `{"x":1}`},
			"linux": okArt("linux"),
		}
		mergeCase(t, arts, allOK)
	})
	t.Run("no artifacts at all", func(t *testing.T) {
		mergeCase(t, map[string]*art{}, with(allOK, "apk", "failure", "linux", "cancelled", "publish", "skipped"))
	})
}

func TestMergeRejectsBadArguments(t *testing.T) {
	h := newHX(t, &sys.Fake{})
	d := t.TempDir()
	for _, a := range [][]string{nil, {"--artifacts", d}, {"--artifacts", d, "--out", "o", "--history"}, {"--bogus", "1"}} {
		if rc := h.x.Merge(a); rc != 2 {
			t.Errorf("%v: rc %d", a, rc)
		}
	}
	if rc := h.x.Merge([]string{"--artifacts", d, "--needs-json", "{broken", "--out", filepath.Join(d, "o"), "--history", filepath.Join(d, "h")}); rc != 2 {
		t.Errorf("bad json: rc %d", rc)
	}
}

func TestMergeLayout(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "ci-log-lint", "outcome.txt"), "lint=success(3s)\n")
	write(t, filepath.Join(dir, "ci-log-lint", "times.txt"), "lint 3 0\n")
	write(t, filepath.Join(dir, "ci-log-lint", "ci.log"), "=== lint ===\nok\n")
	text, _ := MergeLog(dir, map[string]string{"lint": "success", "apk": "failure"})
	l := lines(text)
	if l[0] != "lint=success(3s) importer= core= relay= app= desktop= apk=failure linux=" {
		t.Errorf("line 1: %q", l[0])
	}
	if !strings.HasPrefix(l[1], "job:lint=success job:importer= ") || !strings.HasSuffix(l[1], "job:apk=failure job:linux= job:publish= ") {
		t.Errorf("line 2: %q", l[1])
	}
	if l[2] != "" || l[3] != "step seconds exit" || l[4] != "lint 3 0" {
		t.Errorf("rest: %q", l[2:5])
	}
}

// ---- ci keystore / android-key ----

func TestKeystoreDecodesAndSetsEnv(t *testing.T) {
	genv := filepath.Join(t.TempDir(), "env")
	h := newHX(t, &sys.Fake{}, "ANDROID_KEYSTORE_BASE64="+b64("binary\x00key bytes")+"\n", "GITHUB_ENV="+genv)
	if rc := h.x.Keystore(nil); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	jks := filepath.Join(h.tmp, "release.jks")
	if read(t, jks) != "binary\x00key bytes" {
		t.Error("decoded bytes differ")
	}
	if st, _ := os.Stat(jks); st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode())
	}
	if got := read(t, genv); got != "BW_KEYSTORE="+jks+"\n" {
		t.Errorf("GITHUB_ENV %q", got)
	}
	if strings.Contains(h.out.String()+h.errb.String(), b64("binary")) {
		t.Error("the secret was printed")
	}
}

func TestKeystoreMissingSecret(t *testing.T) {
	genv := filepath.Join(t.TempDir(), "env")
	log := filepath.Join(t.TempDir(), "ci.log")
	h := newHX(t, &sys.Fake{}, "GITHUB_ENV="+genv, "LOG="+log)
	if rc := h.x.Keystore(nil); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	want := "::error::ANDROID_KEYSTORE_BASE64 secret missing (run tools/make-signing-key.sh --upload)\n"
	if h.out.String() != want || read(t, log) != want {
		t.Errorf("out %q log %q", h.out, read(t, log))
	}
	if _, err := os.Stat(genv); err == nil {
		t.Error("BW_KEYSTORE must not be set without a key")
	}
	if _, err := os.Stat(filepath.Join(h.tmp, "release.jks")); err == nil {
		t.Error("no keystore file expected")
	}
}

func TestKeystoreBadBase64DoesNotLeakValue(t *testing.T) {
	h := newHX(t, &sys.Fake{}, "ANDROID_KEYSTORE_BASE64=%%%not-base64-SECRETVALUE")
	if rc := h.x.Keystore(nil); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	if got := h.out.String() + h.errb.String(); strings.Contains(got, "SECRETVALUE") || !strings.HasPrefix(got, "::error::") {
		t.Errorf("output %q", got)
	}
}

func TestKeystoreWithoutGithubEnvPrintsAssignment(t *testing.T) {
	h := newHX(t, &sys.Fake{}, "ANDROID_KEYSTORE_BASE64="+b64("k"))
	if rc := h.x.Keystore(nil); rc != 0 || h.out.String() != "BW_KEYSTORE="+filepath.Join(h.tmp, "release.jks")+"\n" {
		t.Errorf("rc %d out %q", rc, h.out)
	}
}

func fakeFlutter(t *testing.T, kt string) (sdk string) {
	sdk = t.TempDir()
	write(t, filepath.Join(sdk, "bin", "flutter"), "")
	write(t, filepath.Join(sdk, "packages", "flutter_tools", "gradle", "src", "main", "kotlin", "FlutterExtension.kt"), kt)
	return sdk
}

func TestAndroidKey(t *testing.T) {
	sdk := fakeFlutter(t, "class FlutterExtension {\n    val ndkVersion: String = \"28.2.13676358\"\n    val x = 1\n}\n")
	gout := filepath.Join(t.TempDir(), "out")
	h := newHX(t, &sys.Fake{}, "GITHUB_OUTPUT="+gout, "ANDROID_HOME=/opt/android")
	h.x.C.R = &lookFake{path: filepath.Join(sdk, "bin", "flutter")}
	if rc := h.x.AndroidKey(nil); rc != 0 {
		t.Fatalf("rc %d: %s", rc, h.errb)
	}
	want := "ndk=28.2.13676358\nndk-dir=/opt/android/ndk/28.2.13676358\ncmake-dir=/opt/android/cmake/3.22.1\n"
	if got := read(t, gout); got != want {
		t.Errorf("got %q", got)
	}
}

func TestAndroidKeyFailures(t *testing.T) {
	h := newHX(t, &sys.Fake{Missing: map[string]bool{"flutter": true}})
	if rc := h.x.AndroidKey(nil); rc != 1 || !strings.HasPrefix(h.out.String(), "::error::") {
		t.Errorf("no flutter: rc %d out %q", rc, h.out)
	}
	sdk := fakeFlutter(t, "no version here\n")
	h = newHX(t, &sys.Fake{})
	h.x.C.R = &lookFake{path: filepath.Join(sdk, "bin", "flutter")}
	if rc := h.x.AndroidKey(nil); rc != 1 {
		t.Errorf("no ndk line: rc %d", rc)
	}
}

// lookFake resolves flutter to a fixed path.
type lookFake struct {
	sys.Fake
	path string
}

func (l *lookFake) LookPath(string) (string, error) { return l.path, nil }
