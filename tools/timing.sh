# shellcheck shell=bash
# Run logs and step timings for tools/build.sh and tools/emulator.sh (sourced, not run).
#
# Everything lives outside the repo, shared by all worktrees, in BW_DATA = ${BW_DATA_DIR:-$XDG_DATA_HOME/budget-wallet}:
#   history/steps.jsonl   one JSON line per step per run (append-only): ts, run, source, worktree, commit, cmd, step,
#                         seconds, result, image, cold; test suites add count/p50/p90/p99/max/slowest
#   history/tests.jsonl   one line per test per run: ts, run, commit, suite, test, ms, result
#   history/perf.jsonl    one line per perf-test action per run (tools/build.sh perf): frame counts, build/raster p90/max ms,
#                         missed frames, ok (budget); frame numbers only
#   runs/<YYYYMMDD-HHMMSS>-<cmd>-<commit>/   the run's step logs, image build logs, emulator log, test reports,
#                         screenshots; the newest 30 are kept. dist/logs is a symlink to the latest run of this worktree.
# Read the history with tools/build-times.sh. The container gets BW_DATA mounted at the same path and the BW_* variables.

BW_DATA=${BW_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/budget-wallet}
BW_DATA_DIR=$BW_DATA
export BW_DATA_DIR

now_iso() { date +%Y-%m-%dT%H:%M:%S%:z; }
now_us() { echo "${EPOCHREALTIME/[.,]/}"; }
secs_since() {  # <start from now_us> -> seconds with one decimal
  local us=$(($(now_us) - $1))
  printf '%d.%d' $((us / 1000000)) $((us / 100000 % 10))
}
commit_id() {  # short sha, -dirty with uncommitted changes
  local c
  c=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) || { echo unknown; return; }
  [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]] && c+=-dirty
  echo "$c"
}
timing_init() {  # <cmd>
  BW_RUN=${BW_RUN:-$(now_iso)}
  BW_COMMIT=${BW_COMMIT:-$(commit_id)}
  BW_CMD=${BW_CMD:-$1}
  BW_COLD=${BW_COLD:-0}
  BW_SOURCE=${BW_SOURCE:-local}
  BW_WORKTREE=${BW_WORKTREE:-$(basename "$ROOT")}
  export BW_RUN BW_COMMIT BW_CMD BW_COLD BW_SOURCE BW_WORKTREE BW_IMAGE
}
# run_begin <cmd>: new run dir (unique even when worktrees start at the same second), dist/logs -> it, prune old runs.
# A nested call (tools/emulator.sh -> tools/build.sh image-name) keeps the outer run.
run_begin() {
  [[ -n "${BW_RUN_DIR:-}" ]] && return
  timing_init "$1"
  mkdir -p "$BW_DATA/runs" "$BW_DATA/history" "$ROOT/dist"
  local old=() dir n=1
  # Keep the newest 30 (names start with the timestamp, and globs sort)
  shopt -s nullglob; old=("$BW_DATA"/runs/*/); shopt -u nullglob
  ((${#old[@]} > 29)) && rm -rf "${old[@]:0:${#old[@]}-29}"
  dir="$BW_DATA/runs/$(date +%Y%m%d-%H%M%S)-$1-$BW_COMMIT"
  local base=$dir
  until mkdir "$dir" 2>/dev/null; do n=$((n + 1)); dir="$base-$n"; done
  BW_RUN_DIR=$dir; BW_RUN_ID=$(basename "$dir")
  export BW_RUN_DIR BW_RUN_ID
  [[ -d "$ROOT/dist/logs" && ! -L "$ROOT/dist/logs" ]] && rm -rf "$ROOT/dist/logs"  # pre-symlink layout
  ln -sfn "$dir" "$ROOT/dist/logs"
}
# Arguments for `podman run` so the container writes into the same run and history
run_mounts() {
  printf '%s\n' -v "$BW_DATA:$BW_DATA:z" -e BW_DATA_DIR -e BW_RUN_DIR -e BW_RUN_ID -e BW_RUN -e BW_COMMIT -e BW_CMD \
    -e BW_IMAGE -e BW_COLD -e BW_SOURCE -e BW_WORKTREE
}
log_history() {  # <step> <seconds> <ok|FAILED> [cold: true|false] [started: iso]
  local cold=${4:-false}
  [[ ${BW_COLD:-0} == 1 ]] && cold=true
  mkdir -p "$BW_DATA/history"
  # one printf = one write, so concurrent appends from several worktrees don't interleave
  printf '{"ts":"%s","run":"%s","source":"%s","worktree":"%s","commit":"%s","cmd":"%s","step":"%s","seconds":%s,"result":"%s","image":"%s","cold":%s}\n' \
    "${5:-$(now_iso)}" "${BW_RUN_ID:-$BW_RUN}" "$BW_SOURCE" "$BW_WORKTREE" "$BW_COMMIT" "$BW_CMD" "$1" "$2" "$3" \
    "${BW_IMAGE:-}" "$cold" >> "$BW_DATA/history/steps.jsonl"
}
# timed_log <name> <logfile> <cmd...>: run cmd, output to the terminal (stderr) and to logfile with start/end
# stamps, then a history line (cold). For image builds and other host-side work.
timed_log() {
  local name=$1 log=$2 start started rc=0 secs
  shift 2
  mkdir -p "$(dirname "$log")"
  start=$(now_us); started=$(now_iso)
  echo "# $name: started $started" > "$log"
  "$@" 2>&1 | tee -a "$log" >&2 || rc=$?
  secs=$(secs_since "$start")
  echo "# $name: finished $(now_iso), $secs s, exit $rc" >> "$log"
  log_history "$name" "$secs" "$([[ $rc == 0 ]] && echo ok || echo FAILED)" true "$started"
  return "$rc"
}
