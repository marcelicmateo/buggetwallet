#!/usr/bin/env bash
# Usage: timed.sh <step> <command>
# Runs the command (bash, pipefail), appends its output to $LOG under "=== <step> ===", and records
# "<step> <seconds> <exit code>" in $RUNNER_TEMP/times.txt for the log summary and the ci-logs history.
set -u
name=$1
echo "=== $name ===" | tee -a "$LOG"
start=$(date +%s)
bash -o pipefail -c "$2" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
echo "$name $(($(date +%s) - start)) $rc" >> "$RUNNER_TEMP/times.txt"
exit "$rc"
