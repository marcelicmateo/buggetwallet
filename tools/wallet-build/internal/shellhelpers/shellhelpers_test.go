package shellhelpers

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"wallet-build/internal/run"
	"wallet-build/internal/sys"
)

func TestHandles(t *testing.T) {
	yes := []struct {
		cmd  string
		rest []string
	}{
		{"relay", []string{"start"}}, {"relay", []string{"stop"}}, {"relay", []string{"status"}}, {"relay", []string{"logs", "-f"}},
		{"relay", []string{"reset"}}, {"relay", []string{"image"}},
		{"web", []string{"serve"}}, {"web", []string{"serve", "9000"}}, {"web", []string{"stop"}}, {"web", []string{"status"}}, {"web", []string{"shot", "/", "o.png"}},
		{"web", []string{"_serve", "d", "1"}},
		{"web-shot", nil}, {"relay-native-check", nil}, {"signing-key", nil}, {"signing-key", []string{"--upload"}}, {"hook", []string{"no-poll"}},
	}
	for _, c := range yes {
		if !Handles(c.cmd, c.rest) {
			t.Errorf("%s %v should be a helper", c.cmd, c.rest)
		}
	}
	// the build steps of the same names stay build steps
	no := []struct {
		cmd  string
		rest []string
	}{
		{"relay", nil}, {"relay", []string{"test/x_test.dart"}}, {"relay", []string{"test"}}, {"web", nil}, {"web", []string{"-x"}},
		{"test", nil}, {"times", nil}, {"ci", []string{"status"}}, {"relay-native-test", nil}, {"relay-bin", nil},
	}
	for _, c := range no {
		if Handles(c.cmd, c.rest) {
			t.Errorf("%s %v should not be a helper", c.cmd, c.rest)
		}
	}
}

func newCtx(t *testing.T, env sys.Env) (*run.Ctx, *bytes.Buffer, *bytes.Buffer, *sys.Fake) {
	out, errb := &bytes.Buffer{}, &bytes.Buffer{}
	fake := &sys.Fake{}
	root := t.TempDir()
	return run.New(root, append(sys.Env{"BW_DATA_DIR=" + t.TempDir(), "HOME=" + t.TempDir()}, env...), out, errb, fake), out, errb, fake
}

func usageCalled() (func() int, *int) {
	n := 0
	return func() int { n++; return 2 }, &n
}

func TestDispatchHook(t *testing.T) {
	c, out, errb, _ := newCtx(t, nil)
	usage, n := usageCalled()
	rc, ok := Dispatch(c, "hook", []string{"no-poll"}, "/x", usage, Deps{Stdin: strings.NewReader(`{"tool_input":{"command":"while true; do sleep 1; done"}}`)})
	if !ok || rc != 2 || !strings.HasPrefix(errb.String(), "Blocked: no sleep/until/while poll loops") || *n != 0 {
		t.Errorf("block: ok %v rc %d err %q", ok, rc, errb.String())
	}
	rc, ok = Dispatch(c, "hook", []string{"no-poll"}, "/x", usage, Deps{Stdin: strings.NewReader(`{"tool_input":{"command":"make test"}}`)})
	if !ok || rc != 0 {
		t.Errorf("pass: ok %v rc %d", ok, rc)
	}
	rc, ok = Dispatch(c, "hook", []string{"no-poll", "--self-test"}, "/x", usage, Deps{})
	if !ok || rc != 0 || out.String() != "no-poll-hook self-test ok\n" {
		t.Errorf("self-test: ok %v rc %d out %q", ok, rc, out.String())
	}
	if rc, ok = Dispatch(c, "hook", []string{"other"}, "/x", usage, Deps{}); !ok || rc != 2 || *n != 1 {
		t.Errorf("usage: ok %v rc %d n %d", ok, rc, *n)
	}
}

func TestDispatchSigningKeyRefusesOtherArguments(t *testing.T) {
	c, out, _, fake := newCtx(t, sys.Env{"BW_SIGNING_DIR=" + filepath.Join(t.TempDir(), "k")})
	usage, _ := usageCalled()
	for _, args := range [][]string{{"--upload", "x"}, {"--other"}, {"a", "b"}} {
		if rc, ok := Dispatch(c, "signing-key", args, "/x", usage, Deps{}); !ok || rc != 2 || !strings.Contains(out.String(), "wallet-build signing-key --upload") {
			t.Errorf("%v: ok %v rc %d", args, ok, rc)
		}
	}
	if len(fake.Calls) != 0 {
		t.Errorf("ran %v", fake.Argvs())
	}
}

func TestDispatchRelayNativeCheckUsesTheRepository(t *testing.T) {
	c, _, errb, _ := newCtx(t, nil) // an empty repository: no service file
	usage, _ := usageCalled()
	if rc, ok := Dispatch(c, "relay-native-check", nil, "/x", usage, Deps{}); !ok || rc != 2 || !strings.Contains(errb.String(), "bw-relay.service") {
		t.Errorf("ok %v rc %d err %q", ok, rc, errb.String())
	}
}

func TestDispatchRelayAndWeb(t *testing.T) {
	c, out, _, fake := newCtx(t, nil)
	usage, _ := usageCalled()
	// relay status in an empty repository: no container
	fake.Handle = func(cmd sys.Cmd) int { return 125 }
	if rc, ok := Dispatch(c, "relay", []string{"status"}, "/x", usage, Deps{}); !ok || rc != 0 || out.String() != "not running\n" {
		t.Errorf("relay status: ok %v rc %d out %q", ok, rc, out.String())
	}
	out.Reset()
	if rc, ok := Dispatch(c, "web", []string{"status"}, "/x", usage, Deps{}); !ok || rc != 0 || out.String() != "not running\n" {
		t.Errorf("web status: ok %v rc %d out %q", ok, rc, out.String())
	}
	if _, err := os.Stat(filepath.Join(c.Root, "dist", "web-serve.pid")); err == nil {
		t.Error("pid file created")
	}
	// web _serve needs exactly <dir> <port>
	if rc, ok := Dispatch(c, "web", []string{"_serve", "d"}, "/x", usage, Deps{}); !ok || rc != 2 {
		t.Errorf("_serve usage: ok %v rc %d", ok, rc)
	}
	// anything else is not ours
	if _, ok := Dispatch(c, "relay", nil, "/x", usage, Deps{}); ok {
		t.Error("plain relay was taken")
	}
}
