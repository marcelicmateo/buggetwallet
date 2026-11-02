package hook

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSelfTestPasses(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := SelfTest(&out, &errb); rc != 0 {
		t.Fatalf("rc %d: %s", rc, errb.String())
	}
	if out.String() != "no-poll-hook self-test ok\n" {
		t.Errorf("out %q", out.String())
	}
}

// The commands that must be blocked and those that must pass, in one table (more than the ported self-test).
func TestIsPollTable(t *testing.T) {
	blocked := []string{
		"until grep -q done log; do sleep 5; done",
		"while true; do sleep 1; done",
		"while ! curl -s localhost:8787; do sleep 2; done",
		"for i in 1 2 3; do echo; done; while true; do sleep 1; done",
		"until [ -f /tmp/x ]\ndo\n  sleep 2\ndone",
		"ssh host 'while true; do sleep 1; done'",
		"timeout 300 bash -c 'until test -f x; do :; done'",
		"timeout 5m sh -c 'while :; do :; done'",
		"timeout 1h bash -c \"while true; do :; done\"",
		"cd x && timeout 30 bash -c 'until ready; do :; done'",
		"(timeout 9s sh -c 'while :; do :; done')",
		"timeout 10 sh -c 'until x; do :; done'; echo done",
	}
	passed := []string{
		"",
		"sleep 1",
		"sleep 30 && echo done",
		"timeout 120 tools/build.sh test",
		"timeout 60s tools/build.sh lint",
		"timeout 10m make test",
		"tools/build.sh app app/test/x_test.dart",
		"grep -rn until docs",
		"grep -rn while docs | head",
		"echo while sleeping",
		"sleep 5; until x; do :; done", // sleep before the loop: the pattern wants the loop first
		"git log --oneline",
		"make test Q=1",
		"wallet-build app test/x_test.dart",
		"tail -f dist/logs/app.log",
		"xtimeout 60 bash -c 'while :; do :; done'",
		"my-timeout 60 bash -c 'while :; do :; done'",
		"timeout --signal=KILL 60 bash -c 'while :; do :; done'", // not "timeout <n> ", as in the bash hook
		"cat < <(echo hi)",
		"tools/build.sh app --timeout 60s | while read -r l; do echo \"$l\"; done",
	}
	for _, c := range blocked {
		if !IsPoll(c) {
			t.Errorf("should be blocked: %q", c)
		}
	}
	for _, c := range passed {
		if IsPoll(c) {
			t.Errorf("should pass: %q", c)
		}
	}
}

func TestRun(t *testing.T) {
	cases := []struct {
		in   string
		code int
	}{
		{`{"tool_input":{"command":"while true; do sleep 1; done"}}`, 2},
		{`{"tool_name":"Bash","tool_input":{"command":"timeout 120 tools/build.sh test"}}`, 0},
		{`{"tool_input":{"command":"until x; do sleep 1; done","description":"x"}}`, 2},
		{`{"tool_input":{"command":"a\nuntil x; do\n sleep 1\ndone"}}`, 2},
		{`{"tool_input":{"description":"while true; do sleep 1; done"}}`, 0}, // only the command counts
		{`{"tool_input":{"command":7}}`, 0},
		{`{"tool_input":null}`, 0},
		{`[]`, 0},
		{`garbage`, 0},
		{``, 0},
	}
	for _, c := range cases {
		var errb bytes.Buffer
		rc := Run(strings.NewReader(c.in), &errb)
		if rc != c.code {
			t.Errorf("%q: rc %d, want %d", c.in, rc, c.code)
		}
		if c.code == 2 && errb.String() != BlockedMessage+"\n" {
			t.Errorf("%q: stderr %q", c.in, errb.String())
		}
		if c.code == 0 && errb.Len() != 0 {
			t.Errorf("%q: stderr %q", c.in, errb.String())
		}
	}
}

func TestMain_(t *testing.T) {
	var out, errb bytes.Buffer
	if rc, ok := Main([]string{"no-poll", "--self-test"}, strings.NewReader(""), &out, &errb); !ok || rc != 0 {
		t.Errorf("self-test: rc %d ok %v", rc, ok)
	}
	for _, args := range [][]string{nil, {"other"}, {"no-poll", "--bogus"}, {"no-poll", "--self-test", "x"}} {
		if _, ok := Main(args, strings.NewReader(""), &out, &errb); ok {
			t.Errorf("%v accepted", args)
		}
	}
	if rc, ok := Main([]string{"no-poll"}, strings.NewReader(`{"tool_input":{"command":"while :; do sleep 1; done"}}`), &out, &errb); !ok || rc != 2 {
		t.Errorf("block: rc %d ok %v", rc, ok)
	}
}

// The Go pattern decides like tools/no-poll-hook.sh on every self-test case and table entry (skipped without bash and grep -P).
func TestSameDecisionsAsBashHook(t *testing.T) {
	script := filepath.Join("..", "..", "..", "no-poll-hook.sh")
	if _, err := os.Stat(script); err != nil {
		t.Skip("tools/no-poll-hook.sh not found")
	}
	if err := exec.Command("bash", "-c", "echo x | grep -qP x").Run(); err != nil {
		t.Skip("bash with grep -P not available")
	}
	var cmds []string
	for _, c := range SelfTestCases {
		cmds = append(cmds, c.Command)
	}
	cmds = append(cmds, "timeout 5 x until", "a timeout 5s while", "-timeout 5 while", "_timeout 5 until x", "while x; sleep", "until", "sleep")
	for _, c := range cmds {
		in := `{"tool_input":{"command":` + jsonString(c) + `}}`
		cmd := exec.Command("bash", script)
		cmd.Stdin = strings.NewReader(in)
		err := cmd.Run()
		want := 0
		if ee, ok := err.(*exec.ExitError); ok {
			want = ee.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		if got := Run(strings.NewReader(in), &bytes.Buffer{}); got != want {
			t.Errorf("%q: go %d, bash %d", c, got, want)
		}
	}
}

func jsonString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case '\n':
			b.WriteString(`\n`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
