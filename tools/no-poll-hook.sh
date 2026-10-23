#!/usr/bin/env bash
# PreToolUse hook for Bash (.claude/settings.json): blocks poll loops (owner rule: no sleep/until/while loops on local
# work; start long commands with run_in_background and wait for the notification, or use the Monitor tool).
# Reads the hook JSON on stdin; exit 2 + one line on stderr blocks the call. `--self-test` checks the pattern.
set -euo pipefail

POLL_RE='\b(until|while)\b.*\bsleep\b|(?<![-\w])timeout +[0-9]+[smh]? .*\b(until|while)\b'

is_poll() { tr '\n' ' ' <<<"$1" | grep -qP "$POLL_RE"; }

if [[ ${1:-} == --self-test ]]; then
  rc=0
  check() {  # <expect: block|pass> <command>
    local got=pass
    is_poll "$2" && got=block
    [[ $got == "$1" ]] || { echo "self-test FAILED: expected $1: $2" >&2; rc=1; }
  }
  check block 'until grep -q done log; do sleep 5; done'
  check block 'while true; do sleep 1; done'
  check block 'while ! curl -s localhost:8787; do sleep 2; done'
  check block 'timeout 300 bash -c "until test -f x; do :; done"'
  check block 'timeout 5m sh -c "while :; do :; done"'
  check pass 'timeout 120 tools/build.sh test'
  check pass 'tools/build.sh app app/test/x_test.dart'
  check pass 'sleep 1'
  check pass 'grep -rn until docs'
  check pass 'timeout 60s tools/build.sh lint'
  check block $'until grep -q done log; do\n  sleep 5\ndone'
  # shellcheck disable=SC2016  # the quoted $l is test data
  check pass 'tools/build.sh app --timeout 60s | while read -r l; do echo "$l"; done'
  # the stdin path with real hook JSON
  printf '{"tool_input":{"command":"while true; do sleep 1; done"}}' | "$0" 2>/dev/null && { echo "self-test FAILED: stdin block" >&2; rc=1; }
  printf '{"tool_input":{"command":"timeout 120 tools/build.sh test"}}' | "$0" || { echo "self-test FAILED: stdin pass" >&2; rc=1; }
  [[ $rc == 0 ]] && echo "no-poll-hook self-test ok"
  exit "$rc"
fi

cmd=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null || true)
if is_poll "$cmd"; then
  echo "Blocked: no sleep/until/while poll loops (owner rule). Use run_in_background and wait for the notification, or the Monitor tool." >&2
  exit 2
fi
exit 0
