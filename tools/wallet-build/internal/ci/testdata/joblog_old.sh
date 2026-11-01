#!/usr/bin/env bash
# The body of .github/actions/job-log before GO3 (OUTCOMES, LOG and RUNNER_TEMP from the environment; $1 = tools/build_log.py).
d="$RUNNER_TEMP/joblog"; mkdir -p "$d"
touch "$RUNNER_TEMP/times.txt"
line=""
for kv in $OUTCOMES; do
  s=$(awk -v s="${kv%%=*}" '$1 == s { printf "(%ss)", $2 }' "$RUNNER_TEMP/times.txt")
  line="$line${line:+ }$kv$s"
done
echo "$line" > "$d/outcome.txt"
cp "$RUNNER_TEMP/times.txt" "$d/times.txt"
cp "$LOG" "$d/ci.log" 2>/dev/null || true
python3 -I "$1" ci-history "$RUNNER_TEMP/times.txt" > "$d/history.jsonl" || true
