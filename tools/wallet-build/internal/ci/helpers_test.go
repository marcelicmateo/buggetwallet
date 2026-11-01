package ci

import (
	"bytes"
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

type hx struct {
	x    *CI
	out  *bytes.Buffer
	errb *bytes.Buffer
	tmp  string // RUNNER_TEMP
}

// newHX is a CI over the real process runner with a synthetic Actions environment.
func newHX(t *testing.T, r sys.Runner, kv ...string) *hx {
	t.Helper()
	h := &hx{out: &bytes.Buffer{}, errb: &bytes.Buffer{}, tmp: t.TempDir()}
	env := sys.Env{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "BW_DATA_DIR=" + t.TempDir(), "RUNNER_TEMP=" + h.tmp,
		"GITHUB_SHA=0123456789abcdef0123456789abcdef01234567", "GITHUB_REF_NAME=v2", "GITHUB_RUN_ID=77", "GITHUB_REPOSITORY=owner/repo"}
	env = append(env, kv...)
	c := run.New(t.TempDir(), env, h.out, h.errb, r)
	h.x = &CI{C: c, Sleep: func(time.Duration) {}}
	return h
}

func need(t *testing.T, tool string) {
	t.Helper()
	if _, err := exec.LookPath(tool); err != nil {
		t.Skipf("%s not installed", tool)
	}
}

func write(t *testing.T, path, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

var reTS = regexp.MustCompile(`"ts":"[^"]*"`)

func maskTS(s string) string { return reTS.ReplaceAllString(s, `"ts":"T"`) }

func lines(s string) []string { return strings.Split(strings.TrimRight(s, "\n"), "\n") }
