package sys

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestEnv(t *testing.T) {
	e := Env{"A=1", "B=2"}
	e2 := e.With("A", "9", "C", "3").Without("B")
	if e2.Get("A") != "9" || e2.Get("C") != "3" || e2.Get("B") != "" || len(e2) != 2 {
		t.Errorf("got %v", e2)
	}
	if e.Get("A") != "1" {
		t.Error("With must not change the original")
	}
}

func TestRedactorClean(t *testing.T) {
	r := NewRedactor(Env{"BW_KEYSTORE_PASSWORD=hunter2hunter", "BW_KEY_PASSWORD=ab", "GH_TOKEN=ghp_secretvalue"})
	got := r.Clean("pw=hunter2hunter token ghp_secretvalue ab")
	if strings.Contains(got, "hunter2hunter") || strings.Contains(got, "ghp_secretvalue") {
		t.Errorf("secret survived: %s", got)
	}
	if !strings.Contains(got, " ab") {
		t.Errorf("a 2-byte value must not be redacted (it would blank ordinary text): %s", got)
	}
}

func TestRedactorWriterSplitAcrossWrites(t *testing.T) {
	r := NewRedactor(Env{"BW_KEYSTORE_PASSWORD=correct-horse-battery"})
	var buf bytes.Buffer
	w := r.Writer(&buf)
	for _, chunk := range []string{"start corr", "ect-horse-", "battery end\nnext line c", "orrect-horse-battery"} {
		if _, err := w.Write([]byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	w.Close()
	if strings.Contains(buf.String(), "correct-horse") || strings.Contains(buf.String(), "battery") {
		t.Errorf("secret leaked: %q", buf.String())
	}
	if !strings.Contains(buf.String(), "start ***") || !strings.Contains(buf.String(), "next line ***") {
		t.Errorf("got %q", buf.String())
	}
}

func TestRedactorLongLineWithoutNewline(t *testing.T) {
	r := NewRedactor(Env{"GH_TOKEN=tok_abcdefgh"})
	var buf bytes.Buffer
	w := r.Writer(&buf)
	w.Write([]byte(strings.Repeat("x", 9000) + "tok_abc"))
	w.Write([]byte("defgh" + strings.Repeat("y", 100)))
	w.Close()
	if strings.Contains(buf.String(), "tok_abc") {
		t.Errorf("token leaked across the flush boundary")
	}
}

func TestReadSecretsFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "signing.env")
	os.WriteFile(p, []byte("BW_KEY_ALIAS=alias\nBW_KEYSTORE_PASSWORD=s3cretpass\nBW_KEY_PASSWORD=\"quoted-pw\"\n"), 0o600)
	got := ReadSecretsFile(p)
	if len(got) != 2 || got[0] != "s3cretpass" || got[1] != "quoted-pw" {
		t.Errorf("got %v", got)
	}
}

func TestRealRunExitCodes(t *testing.T) {
	var out, errb bytes.Buffer
	r := Real{}
	if rc := r.Run(context.Background(), Cmd{Argv: []string{"sh", "-c", "echo hi; echo oops >&2; exit 3"}, Stdout: &out, Stderr: &errb}); rc != 3 {
		t.Errorf("rc %d", rc)
	}
	if out.String() != "hi\n" || errb.String() != "oops\n" {
		t.Errorf("out %q err %q", out.String(), errb.String())
	}
	if rc := r.Run(context.Background(), Cmd{Argv: []string{"sh", "-c", "kill -TERM $$"}}); rc != 128+15 {
		t.Errorf("signalled rc %d", rc)
	}
	if rc := r.Run(context.Background(), Cmd{Argv: []string{"/nonexistent/tool"}, Stderr: &errb}); rc != 127 {
		t.Errorf("missing tool rc %d", rc)
	}
}

func TestRealRunNilOutputsAreDevNull(t *testing.T) {
	// stdout and stderr of a child with nil writers must not reach ours (quiet mode)
	old1, old2 := os.Stdout, os.Stderr
	r, w, _ := os.Pipe()
	os.Stdout, os.Stderr = w, w
	rc := Real{}.Run(context.Background(), Cmd{Argv: []string{"sh", "-c", "echo to-out; echo to-err >&2"}})
	os.Stdout, os.Stderr = old1, old2
	w.Close()
	b := new(bytes.Buffer)
	b.ReadFrom(r)
	if rc != 0 || b.Len() != 0 {
		t.Errorf("rc %d leaked %q", rc, b.String())
	}
}

func alive(pid int) bool {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return false
	}
	// a zombie is dead for our purposes
	f := strings.Fields(string(b[strings.LastIndex(string(b), ")")+1:]))
	return len(f) > 0 && f[0] != "Z"
}

// A timed-out step must take its grandchildren with it, even ones that ignore SIGTERM (flutter, Gradle, Xvfb leftovers).
func TestTimeoutKillsGrandchildren(t *testing.T) {
	old := KillGrace
	KillGrace = 300 * time.Millisecond
	defer func() { KillGrace = old }()
	pidFile := filepath.Join(t.TempDir(), "pid")
	script := `trap '' TERM; sleep 120 & echo $! > ` + pidFile + `; wait`
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	start := time.Now()
	rc := Real{}.Run(ctx, Cmd{Argv: []string{"sh", "-c", script}})
	if time.Since(start) > 5*time.Second {
		t.Errorf("took %v", time.Since(start))
	}
	if rc == 0 {
		t.Errorf("rc %d for a killed command", rc)
	}
	b, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	deadline := time.Now().Add(3 * time.Second)
	for alive(pid) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if alive(pid) {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Errorf("grandchild %d survived the timeout", pid)
	}
}

func TestFakeRecords(t *testing.T) {
	f := &Fake{Handle: func(c Cmd) int {
		if c.Argv[0] == "bad" {
			return 4
		}
		return 0
	}}
	f.Run(context.Background(), Cmd{Argv: []string{"a", "b"}})
	if rc := f.Run(context.Background(), Cmd{Argv: []string{"bad"}}); rc != 4 {
		t.Error(rc)
	}
	if got := f.Argvs(); len(got) != 2 || got[0] != "a b" {
		t.Errorf("got %v", got)
	}
}
