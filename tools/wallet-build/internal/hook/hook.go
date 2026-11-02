// Package hook is the Go port of tools/no-poll-hook.sh: the PreToolUse hook for Bash that blocks poll loops (owner rule: no
// sleep/until/while loops on local work; start long commands with run_in_background and wait for the notification, or use
// the Monitor tool). `wallet-build hook no-poll` reads the hook JSON on stdin; exit 2 plus one line on stderr blocks the call.
package hook

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
)

// The bash hook's pattern is PCRE (grep -P):
//
//	\b(until|while)\b.*\bsleep\b|(?<![-\w])timeout +[0-9]+[smh]? .*\b(until|while)\b
//
// RE2 has no lookbehind; "not preceded by [-\w]" is "at the start or preceded by a character that is not [-\w]", which
// consumes one more character but matches the same strings.
var pollRE = regexp.MustCompile(`\b(until|while)\b.*\bsleep\b|(?:^|[^-\w])timeout +[0-9]+[smh]? .*\b(until|while)\b`)

// BlockedMessage is the one line printed to stderr when a command is blocked.
const BlockedMessage = "Blocked: no sleep/until/while poll loops (owner rule). Use run_in_background and wait for the notification, or the Monitor tool."

// IsPoll reports whether a command line is a poll loop. Newlines count as spaces, as in the shell hook (tr '\n' ' ').
func IsPoll(cmd string) bool {
	return pollRE.MatchString(strings.ReplaceAll(cmd, "\n", " "))
}

// CommandOf extracts tool_input.command from the hook JSON; anything unreadable is "" (the shell hook let such input pass).
func CommandOf(r io.Reader) string {
	var in struct {
		ToolInput struct {
			Command any `json:"command"`
		} `json:"tool_input"`
	}
	if err := json.NewDecoder(r).Decode(&in); err != nil {
		return ""
	}
	s, _ := in.ToolInput.Command.(string)
	return s
}

// Run is `hook no-poll` with the hook JSON on stdin: 2 blocks the call (message on stderr), 0 lets it pass.
func Run(stdin io.Reader, stderr io.Writer) int {
	if IsPoll(CommandOf(stdin)) {
		fmt.Fprintln(stderr, BlockedMessage)
		return 2
	}
	return 0
}

// Case is one self-test case: the expected decision for a command.
type Case struct {
	Expect  string // "block" or "pass"
	Command string
}

// SelfTestCases are the cases of tools/no-poll-hook.sh --self-test, in order, plus more allowed and blocked commands.
var SelfTestCases = []Case{
	// ported 1:1 from the bash self-test
	{"block", "until grep -q done log; do sleep 5; done"},
	{"block", "while true; do sleep 1; done"},
	{"block", "while ! curl -s localhost:8787; do sleep 2; done"},
	{"block", `timeout 300 bash -c "until test -f x; do :; done"`},
	{"block", `timeout 5m sh -c "while :; do :; done"`},
	{"pass", "timeout 120 tools/build.sh test"},
	{"pass", "tools/build.sh app app/test/x_test.dart"},
	{"pass", "sleep 1"},
	{"pass", "grep -rn until docs"},
	{"pass", "timeout 60s tools/build.sh lint"},
	{"block", "until grep -q done log; do\n  sleep 5\ndone"},
	{"pass", `tools/build.sh app --timeout 60s | while read -r l; do echo "$l"; done`},
	// more
	{"block", "while [ ! -f dist/x ]; do sleep 2; done"},
	{"block", "until [ -s log ]; do sleep 1; done && echo ok"},
	{"block", "cd /tmp && while true; do sleep 30; done"},
	{"block", "while read -r l; do sleep 1; done < list"},
	{"block", "timeout 10h bash -c 'until ready; do sleep 1; done'"},
	{"block", "timeout 90 sh -c 'while ! test -e f; do :; done'"},
	{"block", "echo start; timeout 60 bash -c 'while true; do :; done'"},
	{"block", "wallet-build app x_test.dart && until grep -q ok log; do sleep 3; done"},
	{"pass", "wallet-build app test/x_test.dart"},
	{"pass", "make test Q=1"},
	{"pass", "sleep 30"},
	{"pass", "timeout 5m make lint"},
	{"pass", "git log --oneline until-merge"},
	{"pass", "echo meanwhile"},
	{"pass", "grep -rn 'while' docs"},
	{"pass", "tail -f dist/logs/app.log"},
	{"pass", "ls -la; cat dist/logs/last.status"},
	{"pass", "for f in a b c; do echo $f; done"},
	{"pass", "xtimeout 60 bash -c 'while :; do :; done'"},
	{"pass", "my-timeout 60 bash -c 'while :; do :; done'"},
	{"pass", ""},
}

// stdinCase is a case of the stdin path with real hook JSON.
type stdinCase struct {
	json string
	code int
}

var stdinCases = []stdinCase{
	{`{"tool_input":{"command":"while true; do sleep 1; done"}}`, 2},
	{`{"tool_input":{"command":"timeout 120 tools/build.sh test"}}`, 0},
	{`{"tool_input":{"command":"until x; do sleep 1; done"},"tool_name":"Bash"}`, 2},
	{`{"tool_input":{}}`, 0},
	{`{}`, 0},
	{`not json`, 0},
	{``, 0},
	{`{"tool_input":{"command":42}}`, 0},
}

// SelfTest is `hook no-poll --self-test`: the cases above and the stdin path. It prints "self-test FAILED: …" lines to stderr
// and returns 1 on any failure, else prints "no-poll-hook self-test ok".
func SelfTest(stdout, stderr io.Writer) int {
	rc := 0
	for _, c := range SelfTestCases {
		got := "pass"
		if IsPoll(c.Command) {
			got = "block"
		}
		if got != c.Expect {
			fmt.Fprintf(stderr, "self-test FAILED: expected %s: %s\n", c.Expect, c.Command)
			rc = 1
		}
	}
	for _, c := range stdinCases {
		var sink strings.Builder
		if got := Run(strings.NewReader(c.json), &sink); got != c.code {
			fmt.Fprintf(stderr, "self-test FAILED: stdin %q: exit %d, expected %d\n", c.json, got, c.code)
			rc = 1
		} else if c.code == 2 && strings.TrimSpace(sink.String()) != BlockedMessage {
			fmt.Fprintf(stderr, "self-test FAILED: stdin %q: wrong message\n", c.json)
			rc = 1
		}
	}
	if rc == 0 {
		fmt.Fprintln(stdout, "no-poll-hook self-test ok")
	}
	return rc
}

// Main is `hook <name> [--self-test]`; ok=false is a usage error.
func Main(args []string, stdin io.Reader, stdout, stderr io.Writer) (rc int, ok bool) {
	if len(args) == 0 || args[0] != "no-poll" {
		return 2, false
	}
	switch {
	case len(args) == 1:
		return Run(stdin, stderr), true
	case len(args) == 2 && args[1] == "--self-test":
		return SelfTest(stdout, stderr), true
	}
	return 2, false
}
