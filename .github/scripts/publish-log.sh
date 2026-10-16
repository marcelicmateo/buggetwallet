#!/usr/bin/env bash
# Usage: publish-log.sh <name> <logfile>
# Pushes the log to the ci-logs branch as <name>.txt so it can be read without the Actions UI.
set -u
name="$1"; log="$2"
url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}"
work="${RUNNER_TEMP:-/tmp}/logs-$name"
rm -rf "$work"
for attempt in 1 2 3 4 5; do
  if git clone -q --depth 1 --branch ci-logs "$url" "$work" 2>/dev/null; then :; else
    mkdir -p "$work" && git -C "$work" init -q -b ci-logs && git -C "$work" remote add origin "$url"
  fi
  { echo "commit: ${GITHUB_SHA}  ref: ${GITHUB_REF_NAME}  run: ${GITHUB_RUN_ID}"; echo; cat "$log" 2>/dev/null; } > "$work/$name.txt"
  git -C "$work" config user.name ci-bot
  git -C "$work" config user.email ci-bot@users.noreply.github.com
  git -C "$work" add "$name.txt"
  git -C "$work" commit -q -m "log $name ${GITHUB_SHA}" || exit 0
  if git -C "$work" push -q origin HEAD:ci-logs 2>/dev/null; then exit 0; fi
  rm -rf "$work"; sleep $((attempt * 3))
done
echo "could not publish log" >&2
