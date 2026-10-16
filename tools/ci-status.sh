#!/usr/bin/env bash
# CI result for a commit, without the Actions UI (the Actions API is blocked for Claude sessions).
#
#   tools/ci-status.sh                 status of HEAD's check runs, seconds per step, failing lines from the CI log
#                                      (timing history: tools/build-times.sh --ci)
#   tools/ci-status.sh <sha>           same for another commit
#   tools/ci-status.sh --wait [<sha>]  wait (up to 30 min) until every check run has finished
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

deadline=$((SECONDS + 1800))
while :; do
  table=$(runs)
  pending=$(awk -F'\t' '$2 != "completed"' <<<"$table" | wc -l)
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
