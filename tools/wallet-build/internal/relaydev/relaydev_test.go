package relaydev

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

type fixture struct {
	r      *Relay
	fake   *sys.Fake
	out    *bytes.Buffer
	err    *bytes.Buffer
	root   string
	data   string
	gets   []string
	sleeps int
}

// newFixture builds a repository with the relay's image inputs, a data dir, and a fake podman. running says whether
// `podman inspect` reports the container as running; getErrs is how many health requests fail before one succeeds.
func newFixture(t *testing.T, env sys.Env, running bool, getErrs int) *fixture {
	t.Helper()
	f := &fixture{out: &bytes.Buffer{}, err: &bytes.Buffer{}, root: t.TempDir(), data: t.TempDir()}
	for p, c := range map[string]string{"dev/Containerfile.relay": "FROM x\n", "relay/pubspec.lock": "lock\n", "relay/bin/relay.dart": "main\n",
		"relay/lib/relay.dart": "lib\n", "relay/lib/src/wallet.dart": "w\n", "relay/lib/src/rate_limit.dart": "r\n"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(f.root, p)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(f.root, p), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	f.fake = &sys.Fake{Handle: func(c sys.Cmd) int {
		if len(c.Argv) > 1 && c.Argv[1] == "inspect" {
			if running {
				c.Stdout.Write([]byte("true\n"))
				return 0
			}
			return 125
		}
		return 0
	}}
	c := run.New(f.root, append(sys.Env{"BW_DATA_DIR=" + f.data}, env...), f.out, f.err, f.fake)
	f.r = &Relay{C: c, In: strings.NewReader(""), Sleep: func(time.Duration) { f.sleeps++ }}
	f.r.Get = func(url string) (string, error) {
		f.gets = append(f.gets, url)
		if getErrs > 0 {
			getErrs--
			return "", errors.New("refused")
		}
		return `{"ok":true}` + "\n", nil
	}
	return f
}

func (f *fixture) podman() []string {
	var v []string
	for _, c := range f.fake.Calls {
		v = append(v, strings.Join(c.Argv, " "))
	}
	return v
}

func TestImageTagMatchesTheScript(t *testing.T) {
	f := newFixture(t, nil, false, 0)
	got := ImageTag(f.root)
	if !strings.HasPrefix(got, "localhost/budget-wallet-relay:") || len(got) != len("localhost/budget-wallet-relay:")+8 {
		t.Fatalf("tag %q", got)
	}
	// the script's expression, on the same files
	script := `cd "$1" && cat dev/Containerfile.relay relay/pubspec.lock relay/bin/*.dart relay/lib/*.dart relay/lib/src/*.dart | sha256sum | cut -c1-8`
	out, err := exec.Command("bash", "-c", script, "_", f.root).Output()
	if err != nil {
		t.Skip("bash/sha256sum not available")
	}
	if want := "localhost/budget-wallet-relay:" + strings.TrimSpace(string(out)); got != want {
		t.Errorf("tag %s, script %s", got, want)
	}
	// every input changes the tag
	for _, p := range []string{"dev/Containerfile.relay", "relay/pubspec.lock", "relay/bin/relay.dart", "relay/lib/relay.dart", "relay/lib/src/wallet.dart"} {
		b, _ := os.ReadFile(filepath.Join(f.root, p))
		os.WriteFile(filepath.Join(f.root, p), append(b, 'x'), 0o644)
		if ImageTag(f.root) == got {
			t.Errorf("%s does not change the tag", p)
		}
		os.WriteFile(filepath.Join(f.root, p), b, 0o644)
	}
}

func TestPortMustBeANumber(t *testing.T) {
	for _, cmd := range []string{"status", "start", "bogus"} {
		f := newFixture(t, sys.Env{"BW_RELAY_PORT=80a"}, false, 0)
		if rc := f.r.Main([]string{cmd}); rc != 2 || f.err.String() != "BW_RELAY_PORT must be a number\n" || len(f.fake.Calls) != 0 {
			t.Errorf("%s: rc %d err %q calls %v", cmd, rc, f.err.String(), f.podman())
		}
	}
}

func TestUsage(t *testing.T) {
	f := newFixture(t, nil, false, 0)
	if rc := f.r.Main([]string{"nope"}); rc != 2 || !strings.Contains(f.out.String(), "wallet-build relay reset") || len(f.fake.Calls) != 0 {
		t.Errorf("rc %d out %q", rc, f.out.String())
	}
	if !IsCommand("start") || !IsCommand("logs") || IsCommand("") || IsCommand("tests") || IsCommand("test/x_test.dart") {
		t.Error("IsCommand")
	}
}

func TestStatus(t *testing.T) {
	f := newFixture(t, nil, false, 0)
	if rc := f.r.Main(nil); rc != 0 || f.out.String() != "not running\n" {
		t.Errorf("rc %d out %q", rc, f.out.String())
	}
	f = newFixture(t, sys.Env{"BW_RELAY_PORT=9000"}, true, 0)
	if rc := f.r.Main([]string{"status"}); rc != 0 || f.out.String() != "running on 127.0.0.1:9000: {\"ok\":true}\n" {
		t.Errorf("rc %d out %q", rc, f.out.String())
	}
	if len(f.gets) != 1 || f.gets[0] != "http://127.0.0.1:9000/v2/health" || f.sleeps != 0 {
		t.Errorf("gets %v sleeps %d", f.gets, f.sleeps)
	}
	f = newFixture(t, nil, true, 1)
	f.r.Main([]string{"status"})
	if f.out.String() != "running on 127.0.0.1:8787: no health answer\n" || f.sleeps != 0 {
		t.Errorf("out %q sleeps %d", f.out.String(), f.sleeps)
	}
}

func TestStartBuildsRunsAndWaitsForHealth(t *testing.T) {
	f := newFixture(t, sys.Env{"BW_RELAY_ORIGINS=http://x.test"}, false, 3)
	f.fake.Handle = func(c sys.Cmd) int {
		switch c.Argv[1] {
		case "inspect":
			return 125
		case "image":
			return 1 // not built yet
		}
		return 0
	}
	if rc := f.r.Main([]string{"start"}); rc != 0 {
		t.Fatalf("rc %d err %q", rc, f.err.String())
	}
	tag := ImageTag(f.root)
	want := []string{
		"podman inspect -f {{.State.Running}} bw-relay",
		"podman image exists " + tag,
		"podman build -f " + f.root + "/dev/Containerfile.relay -t " + tag + " " + f.root,
		"podman rm -f bw-relay",
		"podman run -d --name bw-relay --read-only --userns=keep-id:uid=10001,gid=10001 --health-cmd relay --health-check --health-interval 30s " +
			"-p 127.0.0.1:8787:8787 -v " + f.data + "/relay:/data:z -e BW_RELAY_ORIGINS=http://x.test " + tag,
	}
	if got := f.podman(); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("podman calls\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if f.out.String() != "relay up on http://127.0.0.1:8787 (data: "+f.data+"/relay)\n" {
		t.Errorf("out %q", f.out.String())
	}
	if f.err.String() != "building "+tag+"\n" {
		t.Errorf("err %q", f.err.String())
	}
	if len(f.gets) != 4 || f.sleeps != 3 {
		t.Errorf("health tries %d, sleeps %d", len(f.gets), f.sleeps)
	}
	if st, err := os.Stat(filepath.Join(f.data, "relay")); err != nil || !st.IsDir() {
		t.Error("data dir not created")
	}
	// the port is bound to loopback only, whatever the origins
	run := f.podman()[4]
	if !strings.Contains(run, "-p 127.0.0.1:8787:8787") || strings.Contains(run, "0.0.0.0") {
		t.Errorf("run: %s", run)
	}
}

func TestStartDefaultsAndImageExists(t *testing.T) {
	f := newFixture(t, nil, false, 0)
	if rc := f.r.Main([]string{"start"}); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	for _, c := range f.podman() {
		if strings.HasPrefix(c, "podman build") {
			t.Errorf("rebuilt an existing image: %s", c)
		}
	}
	if run := f.podman(); !strings.Contains(run[len(run)-1], "-e BW_RELAY_ORIGINS=http://127.0.0.1:8080,http://localhost:8080 ") {
		t.Errorf("default origins missing: %s", run[len(run)-1])
	}
	if f.err.Len() != 0 {
		t.Errorf("err %q", f.err.String())
	}
}

func TestStartAlreadyRunning(t *testing.T) {
	f := newFixture(t, sys.Env{"BW_RELAY_PORT=9001"}, true, 0)
	if rc := f.r.Main([]string{"start"}); rc != 0 || f.out.String() != "already running on 127.0.0.1:9001\n" || len(f.fake.Calls) != 1 {
		t.Errorf("rc %d out %q calls %v", rc, f.out.String(), f.podman())
	}
}

func TestStartNoAnswerShowsTheLog(t *testing.T) {
	f := newFixture(t, nil, false, 100)
	if rc := f.r.Main([]string{"start"}); rc != 1 {
		t.Errorf("rc %d", rc)
	}
	if f.err.String() != "relay did not answer; log:\n" || len(f.gets) != 16 {
		t.Errorf("err %q tries %d", f.err.String(), len(f.gets))
	}
	got := f.podman()
	if got[len(got)-1] != "podman logs bw-relay" {
		t.Errorf("last call %q", got[len(got)-1])
	}
}

func TestStartRunFailureIsPassedOn(t *testing.T) {
	f := newFixture(t, nil, false, 0)
	f.fake.Handle = func(c sys.Cmd) int {
		if c.Argv[1] == "run" {
			return 126
		}
		if c.Argv[1] == "inspect" {
			return 125
		}
		return 0
	}
	if rc := f.r.Main([]string{"start"}); rc != 126 || len(f.gets) != 0 {
		t.Errorf("rc %d gets %v", rc, f.gets)
	}
}

func TestStopImageLogs(t *testing.T) {
	f := newFixture(t, nil, true, 0)
	if rc := f.r.Main([]string{"stop"}); rc != 0 || f.out.String() != "stopped\n" || f.podman()[0] != "podman rm -f bw-relay" {
		t.Errorf("stop: rc %d out %q %v", rc, f.out.String(), f.podman())
	}
	f = newFixture(t, nil, true, 0)
	f.fake.Handle = func(c sys.Cmd) int { return 125 }
	if rc := f.r.Main([]string{"stop"}); rc != 0 {
		t.Errorf("stop of a missing container: rc %d", rc) // `|| true` in the script
	}
	f = newFixture(t, nil, false, 0)
	if rc := f.r.Main([]string{"image"}); rc != 0 || !strings.HasPrefix(f.podman()[0], "podman build -f "+f.root+"/dev/Containerfile.relay -t localhost/budget-wallet-relay:") {
		t.Errorf("image: rc %d %v", rc, f.podman())
	}
	f = newFixture(t, nil, false, 0)
	if rc := f.r.Main([]string{"logs", "-f", "--tail", "5"}); rc != 0 || f.podman()[0] != "podman logs -f --tail 5 bw-relay" {
		t.Errorf("logs: rc %d %v", rc, f.podman())
	}
	f = newFixture(t, nil, false, 0)
	f.fake.Handle = func(c sys.Cmd) int { return 125 }
	if rc := f.r.Main([]string{"logs"}); rc != 125 {
		t.Errorf("logs of a missing container: rc %d", rc)
	}
}

// bash's read -p shows the question only when stdin is a terminal; the answer is read either way
func TestResetQuestionOnlyOnATerminal(t *testing.T) {
	f := newFixture(t, nil, true, 0)
	f.r.In = strings.NewReader("n\n")
	f.r.IsTTY = func() bool { return false }
	if rc := f.r.Main([]string{"reset"}); rc != 1 || f.err.Len() != 0 || f.out.String() != "aborted\n" {
		t.Errorf("rc %d err %q out %q", rc, f.err.String(), f.out.String())
	}
}

func TestReset(t *testing.T) {
	tty := true
	setup := func(env sys.Env, in string) *fixture {
		f := newFixture(t, env, true, 0)
		f.r.In = strings.NewReader(in)
		f.r.IsTTY = func() bool { return tty }
		if err := os.MkdirAll(filepath.Join(f.data, "relay", "w"), 0o755); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(f.data, "relay", "w", "x"), []byte("x"), 0o644)
		return f
	}
	exists := func(f *fixture) bool { _, err := os.Stat(filepath.Join(f.data, "relay")); return err == nil }
	// asked, answered y
	f := setup(nil, "y\n")
	if rc := f.r.Main([]string{"reset"}); rc != 0 || exists(f) || f.out.String() != "relay data deleted\n" || !strings.Contains(f.err.String(), "(all relay wallets)? [y/N] ") {
		t.Errorf("y: rc %d out %q err %q", rc, f.out.String(), f.err.String())
	}
	if f.podman()[0] != "podman rm -f bw-relay" {
		t.Errorf("container not removed: %v", f.podman())
	}
	// anything else aborts, and nothing is touched
	for _, in := range []string{"n\n", "\n", "yes\n", "Y\n"} {
		f = setup(nil, in)
		if rc := f.r.Main([]string{"reset"}); rc != 1 || !exists(f) || f.out.String() != "aborted\n" || len(f.fake.Calls) != 0 {
			t.Errorf("%q: rc %d out %q", in, rc, f.out.String())
		}
	}
	// end of input: read fails, the script stops silently with 1
	f = setup(nil, "")
	if rc := f.r.Main([]string{"reset"}); rc != 1 || !exists(f) || f.out.Len() != 0 {
		t.Errorf("EOF: rc %d out %q", rc, f.out.String())
	}
	// BW_YES=1 skips the question
	f = setup(sys.Env{"BW_YES=1"}, "")
	if rc := f.r.Main([]string{"reset"}); rc != 0 || exists(f) || strings.Contains(f.err.String(), "[y/N]") {
		t.Errorf("BW_YES: rc %d err %q", rc, f.err.String())
	}
	// BW_YES=y is not 1
	f = setup(sys.Env{"BW_YES=y"}, "n\n")
	if rc := f.r.Main([]string{"reset"}); rc != 1 || !exists(f) {
		t.Errorf("BW_YES=y: rc %d", rc)
	}
}
