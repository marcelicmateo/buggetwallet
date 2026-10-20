#!/usr/bin/env bash
# CI result for a commit, without the Actions UI (the Actions API is blocked for Claude sessions).
#
#   tools/ci-status.sh                 status of HEAD's check runs, seconds per step, failing lines from the CI log
#                                      (timing history: tools/build-times.sh --ci)
#   tools/ci-status.sh <sha>           same for another commit
#   tools/ci-status.sh --wait [<sha>]  wait (up to 30 min) until the ci and release workflow runs of the commit have concluded
#   tools/ci-status.sh --log [name]    print a whole log from the ci-logs branch (default: latest)
#
# Exit code: 0 all green, 1 something failed, 2 still running (without --wait).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=marcelicmateo/buggetwallet

show_log() { git fetch -q origin ci-logs:refs/remotes/origin/ci-logs && git show "origin/ci-logs:$1.txt"; }

wait=0
case "${1:-}" in
  --log) show_log "${2:-latest}"; exit ;;
  --wait) wait=1; shift ;;
esac
sha=$(git rev-parse "${1:-HEAD}")

if ! git branch -r --contains "$sha" 2>/dev/null | grep -q origin/; then
  echo "note: ${sha:0:7} is not on GitHub yet (push it first)" >&2
fi

runs() { gh api "repos/$REPO/commits/$sha/check-runs" --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "-")"'; }

# Workflow runs (ci, release) of this commit that have not concluded yet; with --wait the check runs alone are not
# enough: a run can exist before its jobs do (or jobs of a later stage appear after the first ones finished).
wf_pending() {
  local w
  for w in ci release; do
    gh run list --repo "$REPO" --workflow "$w" --commit "$sha" --json status --jq '.[] | select(.status != "completed") | .status' 2>/dev/null
  done | wc -l
}
# The ci workflow must have a run for the commit (a push can take a few seconds to start one).
ci_runs() { gh run list --repo "$REPO" --workflow ci --commit "$sha" --json databaseId --jq 'length' 2>/dev/null || echo 0; }

deadline=$((SECONDS + 1800))
while :; do
  table=$(runs)
  pending=$(awk -F'\t' '$2 != "completed"' <<<"$table" | wc -l)
  if [[ $wait == 1 ]]; then
    wp=$(wf_pending)
    [[ $wp -gt 0 ]] && pending=$((pending + wp))
    if [[ $wp == 0 && $(ci_runs) == 0 && $SECONDS -lt $((deadline - 1500)) ]]; then pending=$((pending + 1)); fi  # allow ~5 min for the run to appear
  fi
  if [[ $wait == 0 || ( -n "$table" && $pending == 0 ) || $SECONDS -ge $deadline ]]; then break; fi
  sleep 20
done

echo "commit ${sha:0:7}"
if [[ -z "$table" ]]; then echo "no check runs yet"; exit 2; fi
column -t -s $'\t' <<<"$table"

failed=$(awk -F'\t' '$2 == "completed" && $3 != "success" && $3 != "skipped" && $3 != "neutral"' <<<"$table" | wc -l)
if [[ $failed -gt 0 ]]; then
  echo
  log=$(show_log latest 2>/dev/null || true)
  if grep -q "${sha}" <<<"$(head -1 <<<"$log")"; then
    sed -n '3p' <<<"$log"   # step outcomes line
    echo "--- failing lines (full log: tools/ci-status.sh --log) ---"
    grep -n -iE 'error|fail|exception|Some tests failed|\[E\]' <<<"$log" | grep -v -iE 'continue-on-error|0 errors' | head -40
  else
    echo "ci-logs/latest.txt is for another commit; see tools/ci-status.sh --log"
  fi
  exit 1
fi
[[ $pending -gt 0 ]] && { echo "still running"; exit 2; }
echo "all green"
log=$(show_log latest 2>/dev/null || true)
if grep -q "${sha}" <<<"$(head -1 <<<"$log")"; then sed -n '3p' <<<"$log"; fi  # step outcomes with seconds
