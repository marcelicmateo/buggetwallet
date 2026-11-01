//go:build parity

package parity

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

var regexpImage = regexp.MustCompile(`^localhost/budget-wallet-dev:\d+\.\d+\.\d+-[0-9a-f]{8}$`)

// ---- lsp: initialize round trip over stdin/stdout (the one command that must not be silenced or wrapped) ----

func lspFrame(v any) []byte {
	b, _ := json.Marshal(v)
	return []byte(fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(b), b))
}

func lspRead(r *bufio.Reader) (map[string]any, error) {
	n := -1
	for {
		ln, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		ln = strings.TrimRight(ln, "\r\n")
		if ln == "" {
			break
		}
		if v, ok := strings.CutPrefix(strings.ToLower(ln), "content-length:"); ok {
			n, _ = strconv.Atoi(strings.TrimSpace(v))
		}
	}
	if n < 0 {
		return nil, fmt.Errorf("frame without Content-Length")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	var m map[string]any
	return m, json.Unmarshal(buf, &m)
}

// lspRoundTrip returns comparable lines: initialize result shape (capability names, server name), shutdown, exit code.
func lspRoundTrip(t *testing.T, repo, impl string) []string {
	t.Helper()
	cmd := exec.Command(filepath.Join(repo, "tools", "build.sh"), "lsp")
	cmd.Dir = repo
	cmd.Env = buildEnv(t.TempDir(), impl, nil)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	in, _ := cmd.StdinPipe()
	outp, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatalf("lsp (%s): %v", impl, err)
	}
	killer := time.AfterFunc(6*time.Minute, func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) })
	defer killer.Stop()
	r := bufio.NewReader(outp)
	send := func(v any) { _, _ = in.Write(lspFrame(v)) }
	await := func(id float64) map[string]any {
		for {
			m, err := lspRead(r)
			if err != nil {
				t.Fatalf("lsp (%s): reading reply %v: %v\nstderr: %s", impl, id, err, tail(stderr.String()))
			}
			if got, ok := m["id"].(float64); ok && got == id && m["method"] == nil {
				return m
			}
		}
	}
	send(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{
		"processId": nil, "rootUri": "file://" + repo, "capabilities": map[string]any{},
	}})
	init := await(1)
	var out []string
	if res, ok := init["result"].(map[string]any); ok {
		caps, _ := res["capabilities"].(map[string]any)
		var names []string
		for k := range caps {
			names = append(names, k)
		}
		sort.Strings(names)
		out = append(out, "capabilities: "+strings.Join(names, ","))
		si, _ := res["serverInfo"].(map[string]any)
		out = append(out, fmt.Sprintf("serverInfo.name: %v", si["name"]))
	} else {
		out = append(out, fmt.Sprintf("no result: %v", init["error"]))
	}
	send(map[string]any{"jsonrpc": "2.0", "method": "initialized", "params": map[string]any{}})
	send(map[string]any{"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
	sd := await(2)
	_, hasErr := sd["error"]
	out = append(out, fmt.Sprintf("shutdown error: %v", hasErr))
	send(map[string]any{"jsonrpc": "2.0", "method": "exit"})
	_ = in.Close()
	err := cmd.Wait()
	out = append(out, fmt.Sprintf("exit code: %d", exitCode(t, err)))
	return out
}

// ---- apk: the keystore password must not appear in the run dir, the history or the output ----

func checkNoSecrets(t *testing.T, s *side, signingDir string) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(signingDir, "signing.env"))
	if err != nil {
		return
	}
	var secrets []string
	for _, ln := range lines(string(raw)) {
		k, v, ok := strings.Cut(ln, "=")
		if !ok || !strings.Contains(strings.ToUpper(k), "PASSWORD") {
			continue
		}
		v = strings.Trim(strings.TrimSpace(v), `"'`)
		if len(v) >= 4 { // shorter values would match anything
			secrets = append(secrets, v)
		}
	}
	if len(secrets) == 0 {
		t.Log("signing.env holds no password of 4+ characters; secret grep not meaningful")
		return
	}
	hit := func(where string, data []byte) {
		for _, sec := range secrets {
			if bytes.Contains(data, []byte(sec)) {
				t.Errorf("%s: a keystore password value appears in %s (value not printed)", s.impl, where)
			}
		}
	}
	hit("stdout", []byte(s.stdout))
	hit("stderr", []byte(s.stderr))
	_ = filepath.WalkDir(s.data, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if b, e := os.ReadFile(p); e == nil {
				rel, _ := filepath.Rel(s.data, p)
				hit("<DATA>/"+rel, b)
			}
		}
		return nil
	})
}

// ---- new behaviour (Go side only; skipped for bash-vs-bash) ----

func goOnly(t *testing.T) string {
	t.Helper()
	if !goSide() {
		t.Skip("new wallet-build behaviour: nothing to compare in bash-vs-bash mode")
	}
	return repoRoot(t)
}

func imageTag(t *testing.T, repo string) string {
	t.Helper()
	cmd := exec.Command(filepath.Join(repo, "tools", "build.sh"), "image-name")
	cmd.Dir = repo
	cmd.Env = buildEnv(t.TempDir(), "bash", nil)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("image-name: %v", err)
	}
	return strings.TrimSpace(string(out))
}

// containers lists id->name of all containers (any state) created from the dev image.
func containers(t *testing.T, image string) map[string]string {
	t.Helper()
	out, err := exec.Command("podman", "ps", "-a", "--filter", "ancestor="+image, "--format", "{{.ID}} {{.Names}}").Output()
	if err != nil {
		t.Fatalf("podman ps: %v", err)
	}
	m := map[string]string{}
	for _, ln := range lines(string(out)) {
		id, name, _ := strings.Cut(ln, " ")
		m[id] = name
	}
	return m
}

func leftovers(before, after map[string]string) []string {
	var out []string
	for id, name := range after {
		if _, old := before[id]; !old {
			out = append(out, id[:min(12, len(id))]+" "+name)
		}
	}
	sort.Strings(out)
	return out
}

func TestNewBehaviour(t *testing.T) {
	t.Run("step_timeout", func(t *testing.T) {
		repo := goOnly(t)
		image := imageTag(t, repo)
		before := containers(t, image)
		s := execSide(t, repo, implName(), Case{Name: "step_timeout", Args: []string{"lint"}, Env: []string{"BW_TIMEOUT_FORMAT=1"}})
		if s.exit != 1 {
			t.Errorf("exit %d, want 1 (a timed-out step fails the run)\nstderr: %s", s.exit, tail(s.stderr))
		}
		if len(s.runs) != 1 {
			t.Fatalf("want one run dir, got %d", len(s.runs))
		}
		st := strings.Fields(s.file(0, "format.status"))
		if len(st) != 3 || st[1] != "124" {
			t.Errorf("format.status = %q, want '<secs> 124 <start>'", s.file(0, "format.status"))
		}
		if !strings.Contains(s.file(0, "format.log"), "timed out after 1 s") {
			t.Errorf("format.log has no 'timed out after 1 s' line; last line: %q", ends(s.m, s.file(0, "format.log")))
		}
		if !strings.Contains(s.file(0, "last.status"), "format failed") {
			t.Errorf("last.status lacks 'format failed':\n%s", s.file(0, "last.status"))
		}
		if left := leftovers(before, containers(t, image)); len(left) > 0 {
			t.Errorf("podman ps -a still shows containers after the timed-out run: %v", left)
		}
		for id, name := range containers(t, image) {
			if strings.Contains(name, filepath.Base(s.runs[0])) {
				t.Errorf("container %s (%s) named after the run still exists", id, name)
			}
		}
	})

	t.Run("exit3_tool_does_not_build", func(t *testing.T) {
		repo := goOnly(t)
		tmp := t.TempDir()
		for _, dir := range []string{"tools", "dev"} {
			if out, err := exec.Command("cp", "-a", filepath.Join(repo, dir), tmp).CombinedOutput(); err != nil {
				t.Fatalf("copy %s: %v: %s", dir, err, out)
			}
		}
		_ = os.MkdirAll(filepath.Join(tmp, "app"), 0o755)
		if b, err := os.ReadFile(filepath.Join(repo, "app", "pubspec.yaml")); err == nil {
			_ = os.WriteFile(filepath.Join(tmp, "app", "pubspec.yaml"), b, 0o644)
		}
		src := filepath.Join(tmp, "tools", "wallet-build")
		if _, err := os.Stat(src); err != nil {
			t.Fatalf("tools/wallet-build is missing in the repo: %v", err)
		}
		// a syntax error in a new file of the copy; the real source is never touched
		if err := os.WriteFile(filepath.Join(src, "zz_broken.go"), []byte("package main\n\nfunc broken( {\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		_ = os.RemoveAll(filepath.Join(tmp, "dist"))
		data := t.TempDir()
		cmd := exec.Command(filepath.Join(tmp, "tools", "build.sh"), "lint")
		cmd.Dir = tmp
		cmd.Env = buildEnv(data, implName(), nil)
		var out, errb bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errb
		err := cmd.Run()
		if code := exitCode(t, err); code != 3 {
			t.Errorf("exit %d, want 3 (the tool did not build)\nstderr: %s", code, tail(errb.String()))
		}
		if runs := listRuns(data); len(runs) != 0 {
			t.Errorf("a run dir was created although the tool did not build: %v", runs)
		}
		logs, _ := filepath.Glob(filepath.Join(tmp, "dist", "*build*.log"))
		if len(logs) == 0 {
			t.Errorf("no compiler log dist/*build*.log in the copy (contract: dist/wallet-build-build.log)")
		}
		for _, l := range logs {
			if fi, err := os.Stat(l); err != nil || fi.Size() == 0 {
				t.Errorf("%s is empty", l)
			}
		}
		if _, err := os.Stat(filepath.Join(repo, "tools", "wallet-build", "zz_broken.go")); err == nil {
			t.Errorf("the real source was modified")
		}
	})

	t.Run("interrupted_desktop_test_leaves_no_container", func(t *testing.T) {
		repo := goOnly(t)
		if os.Getenv(heavyEnv) != "1" {
			t.Skipf("heavy (starts a desktop test container): set %s=1 to run it", heavyEnv)
		}
		small := smallDesktopTests(t, repo, 1)
		if len(small) != 1 {
			t.Skip("no small desktop test")
		}
		image := imageTag(t, repo)
		before := containers(t, image)
		data := t.TempDir()
		cmd := exec.Command(filepath.Join(repo, "tools", "build.sh"), "desktop-test", small[0])
		cmd.Dir = repo
		cmd.Env = buildEnv(data, implName(), nil)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		deadline := time.Now().Add(5 * time.Minute)
		for len(leftovers(before, containers(t, image))) == 0 { // test code waiting for the child's container
			select {
			case err := <-done:
				t.Fatalf("desktop-test ended (%v) before a container showed up", err)
			default:
			}
			if time.Now().After(deadline) {
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				t.Fatal("no container within 5 minutes")
			}
			time.Sleep(time.Second)
		}
		time.Sleep(5 * time.Second) // let the tests start
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGINT)
		select {
		case err := <-done:
			if code := exitCode(t, err); code != 130 && code != 143 {
				t.Errorf("exit %d after SIGINT, want 130 or 143", code)
			}
		case <-time.After(2 * time.Minute):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			t.Fatal("wallet-build did not exit within 2 minutes of SIGINT")
		}
		var left []string
		for end := time.Now().Add(40 * time.Second); time.Now().Before(end); time.Sleep(2 * time.Second) {
			if left = leftovers(before, containers(t, image)); len(left) == 0 {
				break
			}
		}
		if len(left) > 0 {
			t.Errorf("containers left after the interrupted run: %v", left)
		}
		for _, r := range listRuns(data) {
			if _, err := os.Stat(filepath.Join(r, ".running")); err == nil {
				t.Errorf("%s still has .running", filepath.Base(r))
			}
		}
	})
}
