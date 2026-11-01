#!/usr/bin/env bash
# The merge script of the `log` job of ci.yml before GO3 (verbatim, with the artifact folder and the output paths taken from
# RUNNER_TEMP). The golden test runs it and compares its output byte for byte with `wallet-build ci merge`.
set +e
L="$RUNNER_TEMP/logs"; out="$RUNNER_TEMP/ci.txt"; jobs="lint importer core relay app desktop apk linux"
{
  for j in $jobs; do
    r=R_${j^^}
    if [ -s "$L/ci-log-$j/outcome.txt" ]; then cat "$L/ci-log-$j/outcome.txt"; else echo "$j=${!r}"; fi
  done | paste -sd' '
  for j in $jobs publish; do r=R_${j^^}; printf '%s=%s ' "job:$j" "${!r}"; done; echo
  echo
  echo "step seconds exit"
  for j in $jobs; do cat "$L/ci-log-$j/times.txt" 2>/dev/null || true; done
  for j in $jobs; do echo; cat "$L/ci-log-$j/ci.log" 2>/dev/null || true; done
} > "$out"
for j in $jobs; do cat "$L/ci-log-$j/history.jsonl" 2>/dev/null || true; done > "$RUNNER_TEMP/history.jsonl"
