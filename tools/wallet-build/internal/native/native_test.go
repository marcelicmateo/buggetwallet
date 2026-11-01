package native

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"wallet-build/internal/sys"
)

// repoRoot is the repository this test runs in (the real relay/deploy/native files are the fixture of the happy path).
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, unitDir, "bw-relay.service")); err != nil {
		t.Skip("relay/deploy/native not found")
	}
	return root
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dst, rel), b, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
}

// fakeRepo is a copy of the deployment files in a temp repository root.
func fakeRepo(t *testing.T) string {
	root := t.TempDir()
	copyTree(t, filepath.Join(repoRoot(t), unitDir), filepath.Join(root, unitDir))
	return root
}

func edit(t *testing.T, path string, f func(string) string) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(f(string(b))), 0o644); err != nil {
		t.Fatal(err)
	}
}

func check(t *testing.T, root string, r sys.Runner) (rc int, out, errs string) {
	t.Helper()
	var o, e bytes.Buffer
	rc = Check(context.Background(), r, root, nil, &o, &e)
	return rc, o.String(), e.String()
}

func TestCheckRealFilesPass(t *testing.T) {
	// no systemd-analyze on the fake runner's PATH: the syntax-only branch, same files as the lint step
	fake := &sys.Fake{Missing: map[string]bool{"systemd-analyze": true}}
	rc, out, errs := check(t, repoRoot(t), fake)
	if rc != 0 || out != "" || !strings.Contains(errs, "systemd-analyze missing, syntax-only check") {
		t.Errorf("rc %d out %q err %q", rc, out, errs)
	}
	if len(fake.Calls) != 0 {
		t.Errorf("ran %v", fake.Argvs())
	}
}

func TestCheckRunsSystemdAnalyzeOnAStandInUnit(t *testing.T) {
	var unit string
	fake := &sys.Fake{Handle: func(c sys.Cmd) int {
		b, _ := os.ReadFile(c.Argv[len(c.Argv)-1])
		unit = string(b)
		return 0
	}}
	rc, _, errs := check(t, repoRoot(t), fake)
	if rc != 0 || errs != "" {
		t.Fatalf("rc %d err %q", rc, errs)
	}
	argv := fake.Calls[0].Argv
	if len(argv) != 4 || argv[0] != "systemd-analyze" || argv[1] != "verify" || argv[2] != "--man=no" || !strings.HasSuffix(argv[3], "bw-relay.service") {
		t.Errorf("argv %v", argv)
	}
	if !strings.Contains(unit, "\nExecStart=/bin/true") || strings.Contains(unit, "/usr/local/bin/bw-relay") {
		t.Errorf("the stand-in binary is not used:\n%s", unit)
	}
}

func TestCheckVerifyOutputFilter(t *testing.T) {
	cases := []struct {
		out  string
		fail bool
	}{
		{"", false},
		{"bw-relay.service: Command /bin/true not found\n", false},
		{"Failed to create bw-relay.service/start: Unit bw-relay.service not found.\n", false},
		{"Unit foo.service not found.\n", false},
		{"bw-relay.service:12: Unknown key name 'Foo' in section 'Service', ignoring.\n", true},
		{"bw-relay.service:7: Invalid argument\n", true},
		{"something went BAD\n", true},
		{"harmless note\n", false},
	}
	for _, c := range cases {
		fake := &sys.Fake{Handle: func(cmd sys.Cmd) int {
			cmd.Stdout.Write([]byte(c.out))
			return 1 // verify's exit code does not matter, as in the script
		}}
		rc, _, errs := check(t, repoRoot(t), fake)
		if (rc != 0) != c.fail {
			t.Errorf("%q: rc %d err %q", c.out, rc, errs)
		}
		if c.fail && !strings.HasPrefix(errs, "relay-native-check: systemd-analyze verify: ") {
			t.Errorf("%q: err %q", c.out, errs)
		}
	}
}

func TestCheckInvariants(t *testing.T) {
	missingTool := map[string]bool{"systemd-analyze": true}
	cases := []struct {
		name string
		file string
		edit func(string) string
		want string
	}{
		{"loopback", "bw-relay.service", func(s string) string { return strings.ReplaceAll(s, "--host 127.0.0.1", "--host 0.0.0.0") }, "relay must be bound to 127.0.0.1"},
		{"trust-proxy", "bw-relay.service", func(s string) string { return strings.ReplaceAll(s, "--trust-proxy", "") }, "relay needs --trust-proxy behind Caddy"},
		{"credential", "bw-relay.service", func(s string) string { return strings.ReplaceAll(s, "LoadCredential=create-token:", "Environment=X:") },
			"creation token must come from LoadCredential="},
		{"caddy", "Caddyfile", func(s string) string {
			return strings.ReplaceAll(s, "reverse_proxy 127.0.0.1:8787", "reverse_proxy 0.0.0.0:8787")
		},
			"Caddyfile must proxy to 127.0.0.1:8787"},
		{"secret in env template", "bw-relay.env.example", func(s string) string { return s + "\nBW_RELAY_CREATE_TOKEN=abc\n" }, "env template must not hold secrets"},
		{"not a key", "bw-relay.service", func(s string) string { return s + "\nthis is not a key\n" }, "bw-relay.service: line that is not Key=Value"},
		{"dropin not a key", "caddy.service.d/bw-relay.conf", func(s string) string { return s + "\n  weird line\n" }, "bw-relay.conf: line that is not Key=Value"},
	}
	for _, c := range cases {
		root := fakeRepo(t)
		edit(t, filepath.Join(root, unitDir, c.file), c.edit)
		rc, out, errs := check(t, root, &sys.Fake{Missing: missingTool})
		if rc != 1 || !strings.Contains(errs, c.want) {
			t.Errorf("%s: rc %d err %q", c.name, rc, errs)
		}
		if strings.HasSuffix(c.name, "not a key") && !strings.Contains(out, "key") && !strings.Contains(out, "weird") {
			t.Errorf("%s: the offending line is not printed on stdout: %q", c.name, out)
		}
	}
}

func TestCheckMissingAndEmptyFiles(t *testing.T) {
	root := fakeRepo(t)
	if err := os.WriteFile(filepath.Join(root, unitDir, "bw-relay.sysusers"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(root, unitDir, "caddy.service.d", "bw-relay.conf"))
	rc, _, errs := check(t, root, &sys.Fake{Missing: map[string]bool{"systemd-analyze": true}})
	if rc != 1 || !strings.Contains(errs, "bw-relay.sysusers missing") || !strings.Contains(errs, "bw-relay.conf missing") {
		t.Errorf("rc %d err %q", rc, errs)
	}
	// no service file at all: the script stops (sed fails under set -e)
	rc, _, _ = check(t, t.TempDir(), &sys.Fake{})
	if rc != 2 {
		t.Errorf("rc %d without files", rc)
	}
}

// With the real systemd-analyze on the host the real files pass, as with the shell script.
func TestCheckRealSystemdAnalyze(t *testing.T) {
	if _, err := exec.LookPath("systemd-analyze"); err != nil {
		t.Skip("no systemd-analyze")
	}
	rc, _, errs := check(t, repoRoot(t), sys.Real{})
	if rc != 0 {
		t.Errorf("rc %d: %s", rc, errs)
	}
}

// ---- relay-native-test ----

func TestContainerfiles(t *testing.T) {
	f, ok := Containerfile("fedora")
	if !ok || !strings.HasPrefix(f, "FROM "+fedoraImage+"\n") || !strings.Contains(f, "dnf -y install systemd caddy") || !strings.Contains(f, "CMD [\"/sbin/init\"]") {
		t.Errorf("fedora: %q", f)
	}
	d, ok := Containerfile("debian")
	if !ok || !strings.HasPrefix(d, "FROM "+debianImage+"\n") || !strings.Contains(d, "apt-get") || !strings.Contains(d, "STOPSIGNAL SIGRTMIN+3") {
		t.Errorf("debian: %q", d)
	}
	if _, ok := Containerfile("arch"); ok {
		t.Error("arch accepted")
	}
}

func TestInsideScriptIsTheScriptsBody(t *testing.T) {
	root := repoRoot(t)
	b, err := os.ReadFile(filepath.Join(root, "tools", "relay-native-test.sh"))
	if err != nil {
		t.Skip("tools/relay-native-test.sh is gone")
	}
	if !strings.Contains(string(b), insideScript) {
		t.Error("the embedded inside script differs from tools/relay-native-test.sh")
	}
	for _, want := range []string{"listens on 127.0.0.1:8787", "systemd-analyze security", "caddy validate", "upgrade script"} {
		if !strings.Contains(insideScript, want) {
			t.Errorf("inside script lacks %q", want)
		}
	}
}

func relayBinary(t *testing.T, root string, content string, sumOf string) {
	t.Helper()
	bin := filepath.Join(root, "dist", "relay", "relay-linux-x64")
	if err := os.MkdirAll(filepath.Dir(bin), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bin, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(sumOf))
	if err := os.WriteFile(bin+".sha256", []byte(hex.EncodeToString(sum[:])+"  relay-linux-x64\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func tester(t *testing.T, root string, fake *sys.Fake, env sys.Env) (*Tester, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	return &Tester{R: fake, Root: root, Env: env, Out: &out, Err: &errb, TmpDir: t.TempDir()}, &out, &errb
}

func TestTestNeedsTheBinary(t *testing.T) {
	root := t.TempDir()
	tt, _, errb := tester(t, root, &sys.Fake{}, nil)
	if rc := tt.Test(context.Background(), nil); rc != 2 || !strings.Contains(errb.String(), "relay-native-test: build the binary first: tools/build.sh relay-bin x64") {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
	// present but not executable
	relayBinary(t, root, "relay", "relay")
	os.Chmod(filepath.Join(root, "dist", "relay", "relay-linux-x64"), 0o644)
	if rc := tt.Test(context.Background(), nil); rc != 2 {
		t.Errorf("not executable: rc %d", rc)
	}
	// wrong checksum
	relayBinary(t, root, "relay", "something else")
	tt, _, errb = tester(t, root, &sys.Fake{}, nil)
	if rc := tt.Test(context.Background(), nil); rc != 2 || !strings.Contains(errb.String(), "sha256 mismatch") {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
}

func TestTestUsage(t *testing.T) {
	root := t.TempDir()
	relayBinary(t, root, "relay", "relay")
	fake := &sys.Fake{}
	tt, _, errb := tester(t, root, fake, nil)
	if rc := tt.Test(context.Background(), []string{"arch"}); rc != 2 || !strings.Contains(errb.String(), "usage: relay-native-test [fedora|debian]...") {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
	if len(fake.Calls) != 0 {
		t.Errorf("ran %v", fake.Argvs())
	}
}

func podmanVerbs(f *sys.Fake) []string {
	var v []string
	for _, c := range f.Calls {
		if c.Argv[0] == "podman" {
			v = append(v, c.Argv[1])
		}
	}
	return v
}

func TestTestOneDistro(t *testing.T) {
	root := t.TempDir()
	relayBinary(t, root, "relay", "relay")
	fake := &sys.Fake{Handle: func(c sys.Cmd) int {
		if len(c.Argv) > 2 && c.Argv[0] == "podman" && c.Argv[1] == "exec" && c.Argv[2] == "-i" {
			c.Stdout.Write([]byte("ok: a\ninfo: b\n"))
		}
		return 0
	}}
	tt, out, errb := tester(t, root, fake, nil)
	if rc := tt.Test(context.Background(), []string{"debian"}); rc != 0 {
		t.Fatalf("rc %d err %q", rc, errb.String())
	}
	if got := out.String(); got != "== debian ==\n[debian] ok: a\n[debian] info: b\nrelay-native-test: all ok\n" {
		t.Errorf("out %q", got)
	}
	want := []string{"rm", "build", "run", "exec", "exec", "rm", "rmi"}
	if got := podmanVerbs(fake); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("podman %v, want %v", got, want)
	}
	for _, c := range fake.Calls {
		if c.Argv[0] != "podman" {
			continue
		}
		a := strings.Join(c.Argv, " ")
		switch c.Argv[1] {
		case "build":
			if a != "podman build -q -t bw-relay-native-test-debian -f - "+root+"/relay/deploy/native" {
				t.Errorf("build: %s", a)
			}
		case "run":
			for _, w := range []string{"run -d --name bw-relay-native-test-debian --systemd=always", "-v " + root + "/dist/relay/relay-linux-x64:/t/relay:ro,z",
				"-v " + root + "/relay/deploy/native/caddy.service.d/bw-relay.conf:/t/caddy-dropin.conf:ro,z", ":/t/place.sh:ro,z", ":/t/upgrade.sh:ro,z"} {
				if !strings.Contains(a, w) {
					t.Errorf("run lacks %q: %s", w, a)
				}
			}
			if !strings.HasSuffix(a, " bw-relay-native-test-debian") {
				t.Errorf("image is not the last argument: %s", a)
			}
		}
	}
	// the checks reach the container on stdin and nowhere else
	var script []byte
	for _, c := range fake.Calls {
		if len(c.Argv) > 2 && c.Argv[1] == "exec" && c.Argv[2] == "-i" {
			if strings.Join(c.Argv, " ") != "podman exec -i bw-relay-native-test-debian bash -s" {
				t.Errorf("exec: %v", c.Argv)
			}
			script, _ = io.ReadAll(c.Stdin)
		}
	}
	if string(script) != insideScript {
		t.Error("the checks were not sent to bash -s")
	}
	// the temp scripts are gone, the image build log stays (like the script)
	if _, err := os.Stat(filepath.Join(tt.TmpDir, "bw-relay-native-build-debian.log")); err != nil {
		t.Error("no build log")
	}
	ents, _ := os.ReadDir(tt.TmpDir)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "relay-native-") {
			t.Errorf("left %s", e.Name())
		}
	}
}

func TestTestFailuresAndKeep(t *testing.T) {
	root := t.TempDir()
	relayBinary(t, root, "relay", "relay")
	// a failing check line
	fake := &sys.Fake{Handle: func(c sys.Cmd) int {
		if len(c.Argv) > 2 && c.Argv[1] == "exec" && c.Argv[2] == "-i" {
			c.Stdout.Write([]byte("ok: one\nFAIL: two\n"))
			return 1
		}
		return 0
	}}
	tt, out, errb := tester(t, root, fake, nil)
	if rc := tt.Test(context.Background(), []string{"fedora"}); rc != 1 {
		t.Errorf("rc %d", rc)
	}
	if !strings.Contains(errb.String(), "relay-native-test: FAIL: fedora: checks failed") || !strings.HasSuffix(errb.String(), "relay-native-test: FAILED\n") ||
		!strings.Contains(out.String(), "[fedora] FAIL: two") {
		t.Errorf("out %q err %q", out.String(), errb.String())
	}
	// the image build fails: reported, the container is never started, cleanup still runs
	fake = &sys.Fake{Handle: func(c sys.Cmd) int {
		if c.Argv[0] == "podman" && c.Argv[1] == "build" {
			return 1
		}
		return 0
	}}
	tt, _, errb = tester(t, root, fake, nil)
	if rc := tt.Test(context.Background(), []string{"debian"}); rc != 1 || !strings.Contains(errb.String(), "debian: image build (log ") {
		t.Errorf("rc %d err %q", rc, errb.String())
	}
	if v := podmanVerbs(fake); strings.Contains(strings.Join(v, " "), "run") || v[len(v)-1] != "rmi" {
		t.Errorf("podman %v", v)
	}
	// BW_KEEP keeps the container and image
	fake = &sys.Fake{}
	tt, _, _ = tester(t, root, fake, sys.Env{"BW_KEEP=1"})
	if rc := tt.Test(context.Background(), []string{"debian"}); rc != 0 {
		t.Errorf("rc %d", rc)
	}
	if v := podmanVerbs(fake); v[len(v)-1] == "rmi" {
		t.Errorf("BW_KEEP=1 still removed the image: %v", v)
	}
	// a helper script that fails stops everything with its status
	fake = &sys.Fake{Handle: func(c sys.Cmd) int {
		if strings.HasSuffix(c.Argv[0], "relay-deploy.sh") {
			return 3
		}
		return 0
	}}
	tt, _, _ = tester(t, root, fake, nil)
	if rc := tt.Test(context.Background(), nil); rc != 3 {
		t.Errorf("rc %d", rc)
	}
}

func TestTestBothByDefault(t *testing.T) {
	root := t.TempDir()
	relayBinary(t, root, "relay", "relay")
	fake := &sys.Fake{}
	tt, out, _ := tester(t, root, fake, nil)
	if rc := tt.Test(context.Background(), nil); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if !strings.HasPrefix(out.String(), "== fedora ==\n") || !strings.Contains(out.String(), "== debian ==\n") {
		t.Errorf("out %q", out.String())
	}
}
