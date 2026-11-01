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
#                         screenshots; the newest 30 finished runs plus every run in progress (.running marker, < 24 h) are kept. dist/logs is a symlink to the latest run of this worktree.
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
# prune_runs: under flock, keep every in-progress run (has .running, younger than 24 h) plus the newest 30 finished ones.
prune_runs() {
  (
    flock 8
    local d finished=()
    shopt -s nullglob
    for d in "$BW_DATA"/runs/*/; do  # names start with the timestamp, and globs sort
      if [[ -e $d/.running && -z "$(find "$d/.running" -mmin +1440 2>/dev/null)" ]]; then continue; fi
      finished+=("$d")
    done
    shopt -u nullglob
    ((${#finished[@]} > 30)) && rm -rf "${finished[@]:0:${#finished[@]}-30}"
    return 0
  ) 8>"$BW_DATA/.prune.lock"
}
# run_begin <cmd>: new run dir (unique even when worktrees start at the same second), dist/logs -> it, prune old runs.
# A nested call (tools/emulator.sh -> tools/build.sh image-name) keeps the outer run.
run_begin() {
  [[ -n "${BW_RUN_DIR:-}" ]] && return
  timing_init "$1"
  mkdir -p "$BW_DATA/runs" "$BW_DATA/history" "$ROOT/dist"
  local dir n=1
  dir="$BW_DATA/runs/$(date +%Y%m%d-%H%M%S)-$1-$BW_COMMIT"
  local base=$dir
  until mkdir "$dir" 2>/dev/null; do n=$((n + 1)); dir="$base-$n"; done
  BW_RUN_DIR=$dir; BW_RUN_ID=$(basename "$dir")
  : > "$dir/.running"  # in progress: prune_runs keeps it (until 24 h old); removed when this script exits
  # shellcheck disable=SC2064
  trap "write_last '$dir' \$?; rm -f '$dir/.running'" EXIT
  prune_runs
  export BW_RUN_DIR BW_RUN_ID
  [[ -d "$ROOT/dist/logs" && ! -L "$ROOT/dist/logs" ]] && rm -rf "$ROOT/dist/logs"  # pre-symlink layout
  ln -sfn "$dir" "$ROOT/dist/logs"
}
# Arguments for `podman run` so the container writes into the same run and history
run_env() {
  printf '%s\n' -e BW_DATA_DIR -e BW_RUN_DIR -e BW_RUN_ID -e BW_RUN -e BW_COMMIT -e BW_CMD \
    -e BW_IMAGE -e BW_COLD -e BW_SOURCE -e BW_WORKTREE
}
run_mounts() {
  printf '%s\n' -v "$BW_DATA:$BW_DATA:z"
  run_env
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
# write_last <run dir> [exit code]: last.status (one line per step: "<step> ok|failed <seconds>", in start order) and
# last-failed.txt ("<step> <log path>" per failed step, empty when green) from the run's <step>.status files, so a caller reads
# the outcome without parsing logs. A non-zero exit without a failed step (e.g. podman itself failed) is listed as "run".
write_last() {
  local dir=$1 code=${2:-0} f n rc secs started failed=0 lines=()
  [[ -d $dir ]] || return 0
  shopt -s nullglob
  for f in "$dir"/*.status; do
    read -r secs rc started < "$f" || continue
    n=$(basename "$f" .status)
    lines+=("$started $n $([[ $rc == 0 ]] && echo ok || echo failed) $secs")
  done
  shopt -u nullglob
  { ((${#lines[@]})) && printf '%s\n' "${lines[@]}" | sort | cut -d' ' -f2-; true; } > "$dir/last.status"
  {
    while read -r n rc _; do
      if [[ $rc == failed ]]; then failed=1; echo "$n $ROOT/dist/logs/$n.log"; fi
    done < "$dir/last.status"
    if [[ $failed == 0 && $code != 0 ]]; then echo "run $dir (exit $code, no failed step recorded)"; fi
  } > "$dir/last-failed.txt"
}
# fail_host <step> <message>: a failure before any container step ran (missing key, unpinned wasm, ...): message to stderr
# and, in a run, to <step>.log with a failed status so last-failed.txt names it. Exits 1.
fail_host() {
  echo "$2" >&2
  if [[ -n ${BW_RUN_DIR:-} ]]; then
    printf '# %s: started %s\n%s\n# %s: finished %s, 0.0 s, exit 1\n' "$1" "$(now_iso)" "$2" "$1" "$(now_iso)" > "$BW_RUN_DIR/$1.log"
    echo "0.0 1 $(now_iso)" > "$BW_RUN_DIR/$1.status"
  fi
  exit 1
}
# timed_log <name> <logfile> <cmd...>: run cmd, output to the terminal (stderr) and to logfile with start/end
# stamps, then a .status next to the log (same name) and a history line (cold; BW_TIMED_COLD=false for other work, BW_TIMED_HISTORY=0 for none). For image
# builds and other host-side work. BW_TIMED_SPLIT=1 keeps stdout on stdout and stderr on stderr (both go to the log).
timed_log() {
  local name=$1 log=$2 start started rc=0 secs rcf
  shift 2
  mkdir -p "$(dirname "$log")"
  start=$(now_us); started=$(now_iso)
  echo "# $name: started $started" > "$log"
  if [[ ${BW_TIMED_SPLIT:-} == 1 ]]; then
    rcf=$(mktemp)
    { { "$@" && echo 0 > "$rcf" || echo $? > "$rcf"; } 2>&1 1>&3 | tee -a "$log" >&2; } 3>&1 | tee -a "$log"
    rc=$(cat "$rcf"); rm -f "$rcf"
  else
    "$@" 2>&1 | tee -a "$log" >&2 || rc=$?
  fi
  secs=$(secs_since "$start")
  echo "# $name: finished $(now_iso), $secs s, exit $rc" >> "$log"
  echo "$secs $rc $started" > "${log%.log}.status"  # named like the log, so last-failed.txt finds it
  [[ ${BW_TIMED_HISTORY:-1} == 0 ]] || log_history "$name" "$secs" "$([[ $rc == 0 ]] && echo ok || echo FAILED)" "${BW_TIMED_COLD:-true}" "$started"
  return "$rc"
}
