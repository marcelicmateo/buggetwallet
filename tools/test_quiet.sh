#!/usr/bin/env bash
# Test of -q/--quiet for tools/build.sh and tools/emulator.sh (needs Podman and the build image, ~30 s warm):
#   - `build.sh -q lint` on a clean tree: no output at all, exit 0, last.status all ok, last-failed.txt empty
#   - the same with an unformatted Dart file: no output, exit 1, last-failed.txt names the failed lint step and its log
#   - usage errors: no output, exit 2 (build.sh and emulator.sh)
# Run it on a tree whose lint is green; it creates and removes one temporary file in app/lib.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bad=0
check() { # <what> <condition command...>
  local what=$1
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; bad=1; fi
}
# shellcheck disable=SC2329  # run through check
is_empty() { [[ -z $1 ]]; }
# shellcheck disable=SC2329
is_eq() { [[ $1 == "$2" ]]; }
logs=$ROOT/dist/logs
tmpfile=$ROOT/app/lib/zz_test_quiet_unformatted.dart
trap 'rm -f "$tmpfile"' EXIT

out=$("$ROOT/tools/build.sh" -q lint 2>&1); rc=$?
check "clean tree: no output" is_empty "$out"
check "clean tree: exit 0" is_eq "$rc" 0
check "clean tree: last.status has the format step, none failed" bash -c "grep -q '^format ok ' '$logs/last.status' && ! grep -q ' failed ' '$logs/last.status'"
check "clean tree: last-failed.txt empty" test ! -s "$logs/last-failed.txt"
check "clean tree: step log written" test -s "$logs/format.log"

printf 'void   main( ) {  }\n' > "$tmpfile"
out=$("$ROOT/tools/build.sh" -q lint 2>&1); rc=$?
rm -f "$tmpfile"
check "unformatted file: no output" is_empty "$out"
check "unformatted file: exit 1" is_eq "$rc" 1
check "unformatted file: last-failed.txt names format and its log" grep -q "^format $ROOT/dist/logs/format.log\$" "$logs/last-failed.txt"
check "unformatted file: last.status marks format failed" grep -q '^format failed ' "$logs/last.status"
check "unformatted file: the log has the reason" grep -q 'zz_test_quiet_unformatted' "$logs/format.log"

out=$("$ROOT/tools/build.sh" --quiet no-such-command 2>&1); rc=$?
check "build.sh usage error: no output" is_empty "$out"
check "build.sh usage error: exit 2" is_eq "$rc" 2
out=$(BW_QUIET=1 "$ROOT/tools/emulator.sh" no-such-command 2>&1); rc=$?
check "emulator.sh usage error: no output" is_empty "$out"
check "emulator.sh usage error: exit 2" is_eq "$rc" 2

exit "$bad"
