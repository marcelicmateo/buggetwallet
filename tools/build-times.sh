#!/usr/bin/env bash
# Build and test timings from the shared history (tools/timing.sh: ~/.local/share/budget-wallet/history/).
#
#   tools/build-times.sh [-n RUNS] [--cmd test] [--step app] [--commit SHA] [--source local|ci] [--ci]
#                        last runs (seconds per step), median per step, test-suite stats
#                        --ci also reads CI's history.jsonl from the ci-logs branch (fetched)
#   tools/build-times.sh trend [-n RUNS] [--top N] [--step SUITE]   slowest tests over the last local runs
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == trend ]]; then shift; exec python3 -I tools/build_log.py trend "$@"; fi
args=()
for a in "$@"; do
  if [[ "$a" == --ci ]]; then
    ci=$(mktemp); trap 'rm -f "$ci"' EXIT
    git fetch -q origin ci-logs:refs/remotes/origin/ci-logs
    git show origin/ci-logs:history.jsonl > "$ci" 2>/dev/null || echo "no history.jsonl on ci-logs yet" >&2
    args+=(--ci-file "$ci")
  else
    args+=("$a")
  fi
done
python3 -I tools/build_log.py times "${args[@]}"
