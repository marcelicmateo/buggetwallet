package ci

import (
	"context"
	"os"
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

func TestStepHasNoDefaultLimit(t *testing.T) {
	var deadline time.Duration
	var has bool
	h := newHX(t, &sys.Fake{HandleCtx: func(ctx context.Context, c sys.Cmd) int {
		var d time.Time
		d, has = ctx.Deadline()
		deadline = time.Until(d)
		return 0
	}})
	for _, name := range []string{"app", "smoke", "desktop", "apk"} { // the wrapped step has its own default
		has = false
		_, _ = h.x.Step([]string{name, "--", "true"})
		if has {
			t.Errorf("%s: unexpected limit %v", name, deadline)
		}
	}
	h.x.C.Setenv("BW_TIMEOUT_APP", "1800")
	_, _ = h.x.Step([]string{"app", "--", "true"})
	if !has || deadline < 29*time.Minute || deadline > 30*time.Minute {
		t.Errorf("explicit limit: has %v %v", has, deadline)
	}
	has = false
	h.x.C.Setenv("BW_STEP_TIMEOUT", "60")
	_, _ = h.x.Step([]string{"smoke", "--", "true"})
	if !has || deadline > time.Minute {
		t.Errorf("BW_STEP_TIMEOUT: has %v %v", has, deadline)
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
	want := "::error::ANDROID_KEYSTORE_BASE64 secret missing (run make signing-key ARGS=--upload)\n"
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
