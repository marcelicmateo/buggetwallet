#!/usr/bin/env bash
# Local builds in a rootless Podman container. Runs the same steps as CI (.github/workflows/ci.yml).
#
#   tools/build.sh [-q|--quiet] <command> [args…]   (-q or BW_QUIET=1: print nothing at all, stdout and stderr, not even podman or
#                           usage errors; only the exit code comes back. Logs are written exactly as without it; the outcome is in
#                           dist/logs/last.status and dist/logs/last-failed.txt. Not for lsp, mcp, image-name, which talk on stdout)
#   Exit codes: 0 all steps ok; 1 a step failed; 2 usage error (unknown command, mutate without lib files);
#               125-127 podman itself failed (no container started); 130/137/143 interrupted or killed. shell -c returns the
#               command's own code.
#   tools/build.sh test     lint, then importer + core + sync + relay + app: analyze and tests (all in parallel)
#   tools/build.sh lint     quick checks: Dart formatting, shellcheck, actionlint
#   tools/build.sh analyze [pkg…]   analyze only (importer core sync relay app; default all): app compiles against a changed API
#                           without running its tests (app ~7 s)
#   tools/build.sh stage    one stage verification, each step its own run and history lines, in this order: test, desktop-test,
#                           web-test, tools/emulator.sh screens (skipped when the emulator volumes don't exist), perf (last).
#                           Writes dist/logs/stage-summary.txt: seconds and ok/FAILED per step, the failing tests and BUG: skips,
#                           the 10 slowest tests. Takes a long time: start it in the background.
#   tools/build.sh outdated   dart pub outdated per package (needs network; no offline advisory check exists in the SDK).
#                           Not part of test
#   tools/build.sh format   rewrite Dart files with `dart format` (page width in analysis_options.yaml)
#   tools/build.sh apk      Android release APK   -> dist/BudgetWallet-android.apk
#   tools/build.sh linux    Linux release bundle  -> dist/BudgetWallet-linux-x64.tar.gz
#   tools/build.sh relay-bin [arm64|x64]   relay server as a native executable (dart compile exe, cross-compiled; default arm64 for the
#                           Raspberry Pi) -> dist/relay/relay-linux-<arch> + .sha256 (relay/deploy/native/README.md)
#   tools/build.sh relay-native-test [fedora|debian]   x64 relay + relay/deploy/native/ on real systemd in Podman containers (needs network;
#                           not in lint/test; tools/relay-native-test.sh)
#   tools/build.sh web      Flutter web build (--wasm, JS if a dependency blocks it) -> dist/web/; fetches sqlite3.wasm first
#                           (pinned by dev/sqlite3-wasm.sha256). Serve it with tools/web.sh
#   tools/build.sh web-test [file…]   flutter test --platform chrome: app/test/web/ or the given files
#   tools/build.sh all      test, then apk, linux, desktop-test and desktop-smoke
#   tools/build.sh desktop-test [name…]   app integration tests on the Linux desktop app under Xvfb: every
#                           app/integration_test/*_test.dart, or just <name>_test.dart. Screenshots -> dist/screens/linux/<name>/,
#                           app log -> dist/logs/app-linux-<name>.log; each file starts with an empty wallet folder.
#                           Files run in parallel on BW_JOBS workers (default: min(nproc/4, free RAM/3 GB, 6), less when the
#                           machine is busy; 1 = one after another in app/). Each worker builds in its own copy of app/ under
#                           dist/desktop-test/w<N> (own Xvfb display, own wallet folders); layout is split in shards
#   tools/build.sh desktop-smoke   build the Linux release bundle, start it under Xvfb with empty HOME/XDG folders for
#                           BW_SMOKE_SECONDS (10) s: it must stay up, log app.start with no SEVERE line, and exit on SIGTERM
#   tools/build.sh perf     profile-mode frame performance on the Linux desktop app (big synthetic wallet, Spending scroll and
#                           tab switches; flutter drive --profile under Xvfb). Writes <action>.timeline.json (open in DevTools or
#                           Perfetto) and .timeline_summary.json to dist/logs, appends history/perf.jsonl, fails on a budget
#                           overrun (app/test_driver/perf_budget.dart). Not part of test or all.
#   tools/build.sh importer|core|sync|relay|app   analyze and test one package (what CI runs, one step each)
#   tools/build.sh importer|core|sync|relay|app <test file or dir>…   only those tests (paths relative to the package or the repo root),
#                           no analyze; step name <pkg>:one, so the full-suite medians stay clean
#   tools/build.sh mutate <importer|core|sync> <lib file>… [--max N] [--seed S] [--tests <test file>…] [--timeout SECS] [--list]
#                           mutation testing (tools/mutate.py): seeded sample of simple mutants per lib file, each run against the
#                           package tests (one at a time, file restored after each), survivors listed; dist/mutation/<pkg>-<file>.json
#   tools/build.sh shell    interactive shell in the container;  shell -c '<command>' runs one command non-interactively
#   tools/build.sh image    (re)build the container image (first build ~15 min)
#   tools/build.sh lsp      Dart language server on stdin/stdout, for editors (repo mounted at its host path)
#   tools/build.sh mcp      Dart/Flutter MCP server (`dart mcp-server`) on stdin/stdout for Claude Code (.mcp.json);
#                           runs in the live-mode pod, so it reaches the app of tools/live.sh
#   tools/build.sh image-name   build the image if needed and print its tag (used by tools/emulator.sh)
#
# The image is rebuilt automatically when dev/Containerfile, dev/install-lint-tools.sh, dev/linux-packages.txt or the
# Flutter version changes.
# The Flutter version comes from `environment: flutter:` in app/pubspec.yaml (CI reads the same line).
# Logs: dist/logs/<step>.log (with start/end stamps) and <step>.status ("seconds exit started"), image builds in
# dist/logs/image-dev.log, per-test timings in dist/logs/tests-<suite>-summary.txt; every step is appended to
# history/steps.jsonl (tools/build-times.sh). dist/logs/last.status has one line per step ("<step> ok|failed <seconds>") and
# dist/logs/last-failed.txt "<step> <log path>" per failed step (empty when green): read these instead of parsing output.
# The exit code is non-zero if any step failed. BW_NATIVE=1 runs the steps directly on a machine that already has
# the right Flutter installed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The Go port (tools/wallet-build, `make bin`) takes over the commands named in the case below. BW_IMPL=go forces it for every
# command (to try a port), BW_IMPL=bash keeps this script; natively (BW_NATIVE=1: CI, and the bash steps inside the image)
# auto means bash. A command is added to the auto list only after its parity case passes. Exit 3 = the tool did not build.
impl=${BW_IMPL:-auto}
[[ $impl == auto && ${BW_NATIVE:-} == 1 ]] && impl=bash
cmd_=${1:-}
case "$cmd_" in -q|--quiet) cmd_=${2:-} ;; esac
case "$impl:${cmd_:-test}" in
  # auto list (M3, 2026-11-01): the commands whose parity case passed (tools/wallet-build/parity). Still bash: format,
  # outdated, perf, web, all, image, mcp, relay-native-test, stage (no parity case yet, or not soaked).
  go:*|auto:test|auto:lint|auto:analyze|auto:importer|auto:core|auto:sync|auto:relay|auto:app|auto:shell|auto:image-name|\
  auto:lsp|auto:relay-bin|auto:linux|auto:desktop-smoke|auto:apk|auto:web-test|auto:desktop-test|auto:mutate)
    mkdir -p "$ROOT/dist/bin"
    if ! (cd "$ROOT/tools/wallet-build" && GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -o "$ROOT/dist/bin/wallet-build" .) \
      > "$ROOT/dist/wallet-build-build.log" 2>&1; then
      [[ ${BW_QUIET:-} == 1 || ${1:-} == -q || ${1:-} == --quiet ]] || cat "$ROOT/dist/wallet-build-build.log" >&2
      exit 3
    fi
    exec "$ROOT/dist/bin/wallet-build" "$@" ;;
esac
case "${1:-}" in -q|--quiet) BW_QUIET=1; shift ;; esac
# Quiet: everything below (podman, flutter, python helpers, our own echo) inherits /dev/null; the logs are written by the steps.
# lsp, mcp and image-name use stdout as their result, so they stay as they are.
case "${1:-}" in lsp|mcp|image-name) ;; *) [[ ${BW_QUIET:-} == 1 ]] && exec >/dev/null 2>&1 ;; esac
FLUTTER_VERSION=$(grep -oP '^\s+flutter:\s*"?\K[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/app/pubspec.yaml")
# Tag = Flutter version + hash of the image inputs, so editing any of them rebuilds the image on the next run
IMAGE="localhost/budget-wallet-dev:$FLUTTER_VERSION-$(cat "$ROOT/dev/Containerfile" "$ROOT/dev/install-lint-tools.sh" "$ROOT/dev/linux-packages.txt" | sha256sum | cut -c1-8)"
CMD=${1:-test}
# shellcheck source=tools/timing.sh
source "$ROOT/tools/timing.sh"

usage() { sed -n '2,/^set -/{/^set -/!p}' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# stage (host): the stage verification, one sub-run per step so each keeps its own run dir and history lines. Continues after
# a failure; stage-summary.txt goes into the stage's own run dir (dist/logs points there at the end).
host_stage() {
  run_begin stage
  local stage_dir=$BW_RUN_DIR names=() secs=() results=() dirs=() n start rc d i=0
  local sub=(test "$ROOT/tools/build.sh" test
             desktop-test "$ROOT/tools/build.sh" desktop-test
             web-test "$ROOT/tools/build.sh" web-test)
  if podman volume exists bw-emulator 2>/dev/null && podman volume exists bw-emulator-image 2>/dev/null; then
    sub+=(emulator-screens "$ROOT/tools/emulator.sh" screens)
  else
    echo "stage: emulator volumes missing, skipping emulator-screens (tools/emulator.sh screens sets them up, ~2 GB)"
  fi
  sub+=(perf "$ROOT/tools/build.sh" perf)
  while ((i < ${#sub[@]})); do
    n=${sub[i]}
    echo "=== stage: $n ==="
    start=$(now_us); rc=0
    # a fresh run per step: the sub-command must not join the stage's run
    env -u BW_RUN_DIR -u BW_RUN_ID -u BW_RUN -u BW_CMD -u BW_COLD "${sub[i + 1]}" "${sub[i + 2]}" || rc=$?
    names+=("$n"); secs+=("$(secs_since "$start")"); results+=("$([[ $rc == 0 ]] && echo ok || echo FAILED)")
    d=$(readlink "$ROOT/dist/logs" || true); dirs+=("$d")
    # one status per sub-run; its log is a pointer to the sub-run (that run's own last-failed.txt names the failed steps)
    printf '# %s: sub-run %s\nfailed steps: %s/last-failed.txt\n' "$n" "$d" "$d" > "$stage_dir/$n.log"
    echo "${secs[-1]} $rc $(now_iso)" > "$stage_dir/$n.status"
    i=$((i + 3))
  done
  ln -sfn "$stage_dir" "$ROOT/dist/logs"
  {
    for i in "${!names[@]}"; do printf '%-18s %8s s  %s\n' "${names[i]}" "${secs[i]}" "${results[i]}"; done
    printf '%s\n' "${dirs[@]}" | python3 -I "$ROOT/tools/stage_summary.py"
    echo "--- slowest 10 tests (tools/build-times.sh trend)"
    python3 -I "$ROOT/tools/build_log.py" trend --top 10 2>&1 || true
  } | tee "$stage_dir/stage-summary.txt"
  for rc in "${results[@]}"; do [[ $rc == FAILED ]] && return 1; done
  return 0
}

# ---- host side: hand the command to the container ----
if [[ "${BW_NATIVE:-}" != 1 ]]; then
  BW_IMAGE=$IMAGE
  build_image() {
    run_begin "$CMD"
    timed_log image "$BW_RUN_DIR/image-dev.log" \
      podman build --build-arg FLUTTER_VERSION="$FLUTTER_VERSION" -t "$IMAGE" "$ROOT/dev"
    BW_COLD=1
  }
  # sqlite3mc.wasm (SQLite3 Multiple Ciphers: the web build's SQLite, encryption capable) for the sqlite3 version in app/pubspec.lock: a release asset of the sqlite3.dart
  # project, pinned by dev/sqlite3-wasm.sha256 ("<sha256>  sqlite3mc-<version>"), cached outside the repo, copied to the
  # git-ignored app/web/sqlite3.wasm (same URL the app loads). The first fetch of a version writes its hash into that file (commit it).
  fetch_sqlite_wasm() {
    local ver cache want got pinned="$ROOT/dev/sqlite3-wasm.sha256"
    ver=$(awk '/^  sqlite3:$/ {f=1} f && /version:/ {gsub(/"/, "", $2); print $2; exit}' "$ROOT/app/pubspec.lock")
    [[ -n $ver ]] || { echo "no sqlite3 version in app/pubspec.lock" >&2; return 1; }
    cache="${BW_DATA_DIR:-$HOME/.local/share/budget-wallet}/cache/sqlite3mc-$ver.wasm"
    mkdir -p "$(dirname "$cache")"
    if [[ ! -f $cache ]]; then
      echo "fetching sqlite3mc.wasm $ver" >&2
      curl -fsSL -o "$cache.part" "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-$ver/sqlite3mc.wasm" \
        || { rm -f "$cache.part"; echo "download of sqlite3mc.wasm $ver failed" >&2; return 1; }
      mv "$cache.part" "$cache"
    fi
    got=$(sha256sum "$cache" | cut -d' ' -f1)
    want=$(awk -v n="sqlite3mc-$ver" '$2 == n {print $1}' "$pinned" 2>/dev/null || true)
    if [[ -z $want ]]; then
      # No trust on first use: a new version is pinned by hand after checking the hash against the release page.
      echo "sqlite3mc.wasm $ver is not pinned. Check its sha256 on the sqlite3.dart release page, then add this line" >&2
      echo "to dev/sqlite3-wasm.sha256 and commit it:  $got  sqlite3mc-$ver" >&2
      return 1
    elif [[ $want != "$got" ]]; then
      rm -f "$cache"
      echo "sqlite3mc.wasm $ver sha256 mismatch: pinned $want, got $got (cache deleted)" >&2
      return 1
    fi
    cp "$cache" "$ROOT/app/web/sqlite3.wasm"
    cp "$cache" "$ROOT/app/test/sqlite3.wasm"  # flutter test --platform chrome serves app/test/ at the root
  }
  run=()  # the container writes logs and history into this run (tools/timing.sh)
  case "$CMD" in
    image) build_image; exit ;;
    image-name) podman image exists "$IMAGE" || build_image; echo "$IMAGE"; exit ;;
    test|lint|apk|linux|all|importer|core|sync|relay|app|mutate|desktop-test|desktop-smoke|perf|web|web-test|analyze|outdated|relay-bin) run_begin "$CMD" ;;
    stage) host_stage; exit ;;
    relay-native-test)
      run_begin "$CMD"
      "$ROOT/tools/build.sh" relay-bin x64 || exit 1
      BW_TIMED_SPLIT=1 BW_TIMED_COLD=false timed_log relay-native-test "$BW_RUN_DIR/relay-native-test.log" \
        "$ROOT/tools/relay-native-test.sh" "${@:2}"
      exit ;;
    format) run_begin "$CMD" ;;
    shell) [[ ${2:-} == -c ]] && run_begin "$CMD" ;;
    lsp|mcp) ;;
    *) usage ;;
  esac
  [[ "$CMD" == web || "$CMD" == web-test ]] && { fetch_sqlite_wasm || fail_host "$CMD" "sqlite3mc.wasm unavailable (see the message above)"; }
  # mutate works on a copy, but a leftover mutant from an older run would be mutated again: refuse (checked here, the
  # worktree's git directory is not visible inside the container)
  if [[ "$CMD" == mutate ]] && ! git -C "$ROOT" diff --quiet HEAD -- packages/wallet_core/lib packages/sync/lib packages/wallet_importer/lib; then
    fail_host mutate "mutate: lib files differ from HEAD (a leftover mutant?). Restore with: git checkout -- packages/wallet_core/lib packages/sync/lib packages/wallet_importer/lib"
  fi
  # Build output goes to stderr (stdout belongs to the LSP client in `lsp` mode)
  podman image exists "$IMAGE" || build_image
  # go-check (tools/wallet-build): the tool's gofmt, go vet, go test and a CGO_ENABLED=0 check, on the host before the container.
  # The Go port runs the same step, so both implementations list it in lint and test.
  # shellcheck disable=SC2329  # run by name through timed_log
  go_check() {
    local d=$ROOT/tools/wallet-build rc=0 out
    command -v go > /dev/null || { echo "go not found on PATH: the host needs Go for tools/wallet-build"; return 1; }
    echo "--- gofmt -l tools/wallet-build"
    out=$(gofmt -l "$d") || rc=1
    [[ -z $out ]] || { echo "gofmt: these files need formatting (run gofmt -w):"; echo "$out"; rc=1; }
    echo "--- go vet ./..."; (cd "$d" && GOTOOLCHAIN=local go vet ./...) || rc=1
    echo "--- go test ./..."; (cd "$d" && GOTOOLCHAIN=local go test ./...) || rc=1
    if [[ -d $d/parity ]]; then echo "--- go vet -tags parity ./... (parity)"; (cd "$d/parity" && GOTOOLCHAIN=local go vet -tags parity ./...) || rc=1; fi
    echo "--- go version -m dist/bin/wallet-build"
    mkdir -p "$ROOT/dist/bin"
    (cd "$d" && GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -o "$ROOT/dist/bin/wallet-build" .) || { echo "wallet-build did not build"; return 1; }
    out=$(cd "$ROOT" && GOTOOLCHAIN=local go version -m dist/bin/wallet-build 2>&1) || { echo "cannot read the build info of dist/bin/wallet-build"; return 1; }
    grep -q 'CGO_ENABLED=0' <<<"$out" || { echo "dist/bin/wallet-build was not built with CGO_ENABLED=0"; rc=1; }
    return "$rc"
  }
  # A failing go-check is a failed step, not a stop: the Dart checks still run, and the run exits non-zero at the end.
  gc_failed=0
  if [[ "$CMD" == lint || "$CMD" == test ]]; then
    BW_TIMED_COLD=false timed_log go-check "$BW_RUN_DIR/go-check.log" go_check || gc_failed=1
  fi
  if [[ "$CMD" == lsp ]]; then
    # Same path inside and outside, so file URIs match what the editor sends.
    # The analysis cache volume makes restarts fast.
    exec podman run --rm -i \
      -v "$ROOT:$ROOT:z" \
      -v bw-pub-cache:/cache/pub \
      -v bw-dart-server:/root/.dartServer \
      -e BW_NATIVE=1 \
      -w "$ROOT" "$IMAGE" tools/build.sh lsp
  fi
  if [[ "$CMD" == mcp ]]; then
    # Like lsp, in the pod of tools/live.sh: the live app's VM service and DTD listen on the pod's 127.0.0.1 (connect
    # with the dtd URI of `tools/live.sh status`; the dtd tool's listDtdUris finds nothing across containers).
    # dart mcp-server installs its pinned dart_mcp_server bundle on first use; the volume keeps it.
    pod=$("$ROOT/tools/live.sh" pod)
    exec podman run --rm -i --pod "$pod" \
      -v "$ROOT:$ROOT:z" \
      -v bw-pub-cache:/cache/pub \
      -v bw-dart-server:/root/.dartServer \
      -v bw-dart-state:/root/.local/state/Dart \
      -e BW_NATIVE=1 \
      -w "$ROOT" "$IMAGE" tools/build.sh mcp "${@:2}"
  fi
  # Android release signing key (tools/make-signing-key.sh), mounted read-only
  SIGNING_DIR="${BW_SIGNING_DIR:-$HOME/.config/budget-wallet}"
  signing=()
  if [[ -f "$SIGNING_DIR/signing.env" ]]; then
    signing=(-v "$SIGNING_DIR:/signing:ro,z" --env-file "$SIGNING_DIR/signing.env" -e BW_KEYSTORE=/signing/android-release.jks)
  elif [[ "$CMD" == apk || "$CMD" == all ]]; then
    fail_host "$CMD" "No Android signing key in $SIGNING_DIR. Run tools/make-signing-key.sh first, otherwise the APK can't update the installed app."
  fi
  tty=(); [[ -t 0 && -t 1 && ${BW_QUIET:-} != 1 ]] && tty=(-it)
  [[ -n "${BW_RUN_DIR:-}" && "$CMD" == shell ]] && tty=()  # shell -c: logged through a pipe, no terminal
  inner=(tools/build.sh "$CMD" "${@:2}"); [[ "$CMD" == shell ]] && inner=(bash "${@:2}")
  [[ -n "${BW_RUN_DIR:-}" ]] && mapfile -t run < <(run_mounts)
  # step time limits set on the host (BW_TIMEOUT_<STEP>) apply inside the container too
  fwd=(); while read -r v; do fwd+=(-e "$v"); done < <(compgen -e | grep '^BW_TIMEOUT_' | LC_ALL=C sort || true)
  # Rootless: container root is the host user, so build outputs stay owned by you.
  # Named volumes keep the pub and Gradle caches between runs.
  # No exec: the shell must stay to remove the run's .running marker on exit (tools/timing.sh)
  rc=0
  podrun=(podman run --rm "${tty[@]}" \
    -v "$ROOT:/work:z" \
    -v bw-pub-cache:/cache/pub \
    -v bw-gradle-cache:/cache/gradle \
    -v bw-android-user:/cache/android \
    "${signing[@]}" "${run[@]}" \
    -e BW_NATIVE=1 -e BW_JOBS -e BW_GL_THREADS -e BW_APK_ABIS -e BW_FUZZ_ITERATIONS -e BW_FUZZ_SEED \
    -e BW_STEP_TIMEOUT -e BW_HEADLESS_TIMEOUT -e BW_SMOKE_SECONDS "${fwd[@]}" \
    -w /work "$IMAGE" "${inner[@]}")
  if [[ "$CMD" == shell && -n "${BW_RUN_DIR:-}" ]]; then  # shell -c: output to the terminal and to the run's shell.log
    BW_TIMED_SPLIT=1 BW_TIMED_COLD=false timed_log shell "$BW_RUN_DIR/shell.log" "${podrun[@]}" || rc=$?
  else
    "${podrun[@]}" || rc=$?
  fi
  [[ $rc == 0 && $gc_failed == 1 ]] && rc=1
  exit "$rc"
fi

# ---- inside the container (or native) ----
cd "$ROOT"
LOGS=${BW_RUN_DIR:-$ROOT/dist/logs}  # natively (CI) without a run dir: plain dist/logs
# lsp/mcp keep no logs, and must leave this checkout's dist/logs link (unresolvable in their container) alone
if [[ $CMD != lsp && $CMD != mcp ]]; then
  [[ -L $LOGS && ! -d $LOGS ]] && rm "$LOGS"  # a run-dir link that doesn't resolve here
  mkdir -p "$LOGS"
fi
timing_init "$CMD"
export ROOT LOGS
RUN_START=$(now_us)
results=()
timings=()
failed=0

# Dart sources, skipping generated and build folders
# shellcheck disable=SC2329  # also run by name through steps (export -f below)
dart_files() {
  find app packages relay \( -name .dart_tool -o -name build -o -name ephemeral -o -name .symlinks \) -prune \
    -o -name '*.dart' -print0
}
# `pub get` only where the resolution is out of date, so a warm run skips it (CI always starts clean).
# Also needed by `dart format`, which reads page_width through the analysis_options.yaml includes.
pub_ready() {
  local d
  for d in packages/wallet_importer packages/wallet_core packages/sync relay app; do
    pub_stale "$d" || continue
    echo "--- pub get: $d"
    # app and relay have a tracked pubspec.lock: --enforce-lockfile fails instead of silently moving versions (to change a
    # dependency run `pub get` without it in a shell, then commit the lock). The packages' locks are git-ignored.
    case $d in
      app) (cd "$d" && flutter pub get --enforce-lockfile) ;;
      relay) (cd "$d" && dart pub get --enforce-lockfile) ;;
      *) (cd "$d" && dart pub get) ;;
    esac || return 1
    touch "$d/.dart_tool/package_config.json"  # pub leaves it alone when nothing changed
  done
}
# Stale = no package_config, or older than a pubspec/lockfile it depends on (path dependencies included),
# or resolved against a pub cache that isn't here (a deleted volume, a host SDK).
pub_stale() {
  local cfg=$1/.dart_tool/package_config.json f root
  [[ -f $cfg ]] || return 0
  for f in "$1/pubspec.yaml" "$1/pubspec.lock" packages/*/pubspec.yaml; do
    [[ $f -nt $cfg ]] && return 0
  done
  root=$(grep -m1 -oP '"rootUri": "file://\K[^"]+' "$cfg" || true)
  [[ -n $root && ! -d $root ]]
}
# shellcheck disable=SC2329  # called by name through a step
format_check() {
  if ! dart_files | xargs -0 dart format -o none --set-exit-if-changed; then
    echo "format check failed: run tools/build.sh format" >&2
    return 1
  fi
}
# suite <name> <dir> <analyze command> <test command...>: analyze, test with a JSON report next to the logs, then
# per-test timings (tools/build_log.py: histogram, slowest tests, history lines) even when tests failed.
# shellcheck disable=SC2329  # called by name through a step
suite() {
  local name=$1 dir=$2 analyze=$3 rc=0
  shift 3
  rm -f "$LOGS/tests-$name.json" "$LOGS/tests-$name-summary.txt"
  # shellcheck disable=SC2086  # the analyze command is meant to split into words
  (cd "$dir" && $analyze && "$@" --file-reporter "json:$LOGS/tests-$name.json") || rc=$?
  [[ -f "$LOGS/tests-$name.json" ]] && python3 -I "$ROOT/tools/build_log.py" tests "$name" "$LOGS/tests-$name.json"
  return "$rc"
}
# Every BW_* variable a test reads through Platform.environment must be passed into the container (podman run -e above).
# shellcheck disable=SC2329  # run by the env-selftest lint step (export -f below)
env_selftest() {
  local v rc=0
  while read -r v; do
    grep -q -- "-e $v\\b" "$ROOT/tools/build.sh" || { echo "env-selftest: $v is read by a test but not passed by tools/build.sh" >&2; rc=1; }
  done < <(grep -rhoP "Platform\.environment\[['\"]\KBW_[A-Z_]+" packages/*/test relay/test app/test 2>/dev/null | sort -u | grep -v '^BW_ANDROID_ROOT$')
  return "$rc"
}
export -f dart_files pub_ready pub_stale format_check suite env_selftest

# run_step <name> <command> [live]: run the command (bash -c) with its output in dist/logs/<name>.log between
# start/end stamps, and "<seconds> <exit> <started>" in dist/logs/<name>.status. `live` also shows the output.
run_step() {
  local name=$1 start started rc=0 secs
  start=$(now_us); started=$(now_iso)
  echo "# $name: started $started" > "$LOGS/$name.log"
  if [[ ${3:-} == live ]]; then
    bash -o pipefail -c "$2" 2>&1 | tee -a "$LOGS/$name.log" || rc=$?
  else
    bash -c "$2" >> "$LOGS/$name.log" 2>&1 || rc=$?
  fi
  secs=$(secs_since "$start")
  echo "# $name: finished $(now_iso), $secs s, exit $rc" >> "$LOGS/$name.log"
  echo "$secs $rc $started" > "$LOGS/$name.status"
  return "$rc"
}
# record <name> [cold]: add a finished step to the results, the timing table and history.jsonl
record() {
  local secs rc started result=ok
  read -r secs rc started < "$LOGS/$1.status"
  [[ $rc == 0 ]] || { result=FAILED; failed=1; }
  results+=("$1=$result"); timings+=("$1 $secs $result")
  log_history "$1" "$secs" "$result" "${2:-false}" "$started"
}
# fail_step <name> <message>: a step that could not even start (bad argument, missing key): the message to stderr and to the
# step's log, a failed status, and the usual record, so last-failed.txt names it.
fail_step() {
  echo "$2" >&2
  printf '# %s: started %s\n%s\n# %s: finished %s, 0.0 s, exit 1\n' "$1" "$(now_iso)" "$2" "$1" "$(now_iso)" > "$LOGS/$1.log"
  echo "0.0 1 $(now_iso)" > "$LOGS/$1.status"
  record "$1"
}
# step <name> <command> [cold]: one step, output shown as it runs
step() {
  echo "=== $1 ==="
  run_step "$1" "$2" live || true
  record "$1" "${3:-false}"
}
# steps name1 'cmd1' name2 'cmd2' ...: run them at the same time, then print each log in order.
steps() {
  local names=() pids=() i
  while (($# >= 2)); do
    run_step "$1" "$2" &
    names+=("$1"); pids+=($!); shift 2
  done
  for i in "${!names[@]}"; do
    wait "${pids[$i]}" || true
    echo "=== ${names[$i]} ==="; sed '1d;$d' "$LOGS/${names[$i]}.log"
    record "${names[$i]}"
  done
}

# The Go port (wallet-build hook no-poll, relay-native-check; GO4-B) runs when dist/bin/wallet-build exists (the host builds it in
# go-check before the container); without it (CI before GO3) native-units falls back to the old script.
# Packages are resolved first (pub_ready, sequentially: they share the pub cache), so the checks skip their own
# implicit `pub get` (--no-pub) and all run in parallel.
LINT=(format format_check
      shellcheck 'shellcheck tools/*.sh dev/*.sh .github/scripts/*.sh'
      actionlint actionlint
      hook-selftest 'tools/no-poll-hook.sh --self-test && { [[ ! -x dist/bin/wallet-build ]] || dist/bin/wallet-build hook no-poll --self-test; }'
      env-selftest env_selftest
      deploy-selftest 'tools/relay-deploy.sh --self-test'
      native-units 'if [[ -x dist/bin/wallet-build ]]; then dist/bin/wallet-build relay-native-check; else tools/relay-native-check.sh; fi')
declare -A SUITE=(
  [importer]='suite importer packages/wallet_importer "dart analyze --fatal-infos" dart test --timeout 60s'
  [core]='suite core packages/wallet_core "dart analyze --fatal-infos" dart test --timeout 60s'
  [sync]='suite sync packages/sync "dart analyze --fatal-infos" dart test --timeout 60s'
  [relay]='suite relay relay "dart analyze --fatal-infos" dart test --timeout 60s'
  [app]='suite app app "flutter analyze --fatal-infos --no-pub" flutter test --no-pub --timeout 60s')
# one_suite <importer|core|sync|relay|app> <test file or dir>…: just those tests, no analyze, as step "<pkg>:one"
one_suite() {
  local pkg=$1 dir f files=() tcmd=dart
  shift
  case "$pkg" in importer) dir=packages/wallet_importer ;; core) dir=packages/wallet_core ;; sync) dir=packages/sync ;; relay) dir=relay ;; *) dir=app; tcmd='flutter' ;; esac
  for f in "$@"; do
    f=${f#"$ROOT/"}; f=${f#"$dir/"}
    [[ -e $dir/$f ]] || { fail_step "$pkg:one" "no such test file or dir in $dir: $f"; return; }
    files+=("$f")
  done
  echo "($pkg: ${#files[@]} path(s), no analyze)"
  local cmd="suite $pkg:one $dir true $tcmd test --timeout 60s"  # per-test cap: a hung test fails in 1 min, not 10
  [[ $pkg == app ]] && cmd+=" --no-pub"
  steps "$pkg:one" "$cmd $(printf '%q ' "${files[@]}")"
}
# analyze [pkg…]: analysis only (fatal infos), in parallel, step "analyze-<pkg>"
analyze_pkgs() {
  local pkgs=("$@") p args=()
  ((${#pkgs[@]})) || pkgs=(importer core sync relay app)
  for p in "${pkgs[@]}"; do
    case $p in
      importer) args+=(analyze-importer "cd packages/wallet_importer && dart analyze --fatal-infos") ;;
      core) args+=(analyze-core "cd packages/wallet_core && dart analyze --fatal-infos") ;;
      sync) args+=(analyze-sync "cd packages/sync && dart analyze --fatal-infos") ;;
      relay) args+=(analyze-relay "cd relay && dart analyze --fatal-infos") ;;
      app) args+=(analyze-app "cd app && flutter analyze --fatal-infos --no-pub") ;;
      *) fail_step analyze "analyze: unknown package $p (importer core sync relay app)"; return ;;
    esac
  done
  steps "${args[@]}"
}
# outdated: dart pub outdated per package (network). The SDK has no advisory check, so this is the table only.
# shellcheck disable=SC2329  # called by name through a step
outdated() {
  local d
  for d in packages/wallet_importer packages/wallet_core packages/sync relay app; do
    echo "=== $d"
    if [[ $d == app ]]; then (cd "$d" && flutter pub outdated); else (cd "$d" && dart pub outdated); fi || true
  done
}
export -f outdated
TESTS=(importer "${SUITE[importer]}" core "${SUITE[core]}" sync "${SUITE[sync]}" relay "${SUITE[relay]}" app "${SUITE[app]}")
run_pub() {
  local cold=false d
  for d in packages/wallet_importer packages/wallet_core packages/sync relay app; do [[ -f $d/.dart_tool/package_config.json ]] || cold=true; done
  run_step pub pub_ready || true
  # Only worth showing (and timing) when something had to be resolved
  if [[ $(wc -l < "$LOGS/pub.log") -gt 2 || $(cut -d' ' -f2 "$LOGS/pub.status") != 0 ]]; then
    echo "=== pub ==="; sed '1d;$d' "$LOGS/pub.log"
    record pub "$cold"
  fi
}
build_apk() {
  if [[ ! -f "${BW_KEYSTORE:-}" ]]; then
    fail_step apk "BW_KEYSTORE is not set to the release key; refusing to build an APK that can't update the app."
    return
  fi
  local cold=false; [[ -d app/build/app ]] || cold=true
  # BW_APK_ABIS=arm64: phone-only APK (what CI publishes); default also has x86_64 for tools/emulator.sh install
  local apk_abis=android-arm64,android-x64; [[ ${BW_APK_ABIS:-} == arm64 ]] && apk_abis=android-arm64
  step apk "cd app && flutter build apk --release --target-platform $apk_abis && cp build/app/outputs/flutter-apk/app-release.apk ../dist/BudgetWallet-android.apk" "$cold"
  [[ $failed == 0 ]] && step apk-signature check_signature
}
# The APK must carry the release key's certificate, or Android refuses it as an update.
# shellcheck disable=SC2329  # called by name through step
check_signature() {
  local want got apksigner
  want=$(keytool -list -v -keystore "$BW_KEYSTORE" -storepass "$BW_KEYSTORE_PASSWORD" -alias "$BW_KEY_ALIAS" \
    | grep -m1 -oP 'SHA256:\s*\K[0-9A-F:]+' | tr -d ':' | tr 'A-F' 'a-f')
  # shellcheck disable=SC2012  # build-tools folders are plain version numbers
  apksigner=$(ls "$ANDROID_HOME"/build-tools/*/apksigner | sort -V | tail -1)
  got=$("$apksigner" verify --print-certs dist/BudgetWallet-android.apk | grep -m1 -oP 'SHA-256 digest: \K[0-9a-f]+')
  echo "release key: $want"; echo "apk signer:  $got"
  [[ -n "$want" && "$want" == "$got" ]]
}
export -f check_signature
# relay_bin <arm64|x64>: AOT executable for linux/<arch> from relay/bin/relay.dart (the pinned Dart cross-compiles; needs glibc on the target)
# shellcheck disable=SC2329  # called by name through a step
relay_bin() {
  local arch=$1 out="dist/relay/relay-linux-$1"
  mkdir -p dist/relay
  (cd relay && dart compile exe --target-os linux --target-arch "$arch" bin/relay.dart -o "../$out") || return 1
  (cd dist/relay && sha256sum "relay-linux-$arch" > "relay-linux-$arch.sha256") || return 1
  file "$out"
  cat "$out.sha256"
}
export -f relay_bin
build_linux() {
  local cold=false; [[ -d app/build/linux ]] || cold=true
  step linux 'cd app && flutter build linux --release && tar -C build/linux/x64/release -czf ../dist/BudgetWallet-linux-x64.tar.gz bundle' "$cold"
}

# web_blockers <log>: the packages with compile errors in a wasm build log (pub packages by name, path packages, the app)
# shellcheck disable=SC2329
web_blockers() {
  { grep -E ': Error: ' "$1" | grep -oP '^(/cache/pub/hosted/[^/]+/\K[a-z0-9_]+(?=-[0-9])|\S*packages/\K[a-z0-9_]+|lib/\K[a-z]+)' || true; } |
    sort -u | paste -sd, - | grep . || echo "unknown, see web-wasm.log"
}
# web: --wasm (WasmGC) first; a dependency that doesn't compile to it falls back to the JS build, with one line saying which.
# shellcheck disable=SC2329  # called by name through a step
build_web() {
  local mode=wasm
  [[ -f app/web/sqlite3.wasm ]] || { echo "app/web/sqlite3.wasm missing (tools/build.sh web fetches it on the host)"; return 1; }
  if (cd app && flutter build web --wasm --release) > "$LOGS/web-wasm.log" 2>&1; then
    cat "$LOGS/web-wasm.log"
  else
    mode=js
    echo "wasm build failed; blocked by: $(web_blockers "$LOGS/web-wasm.log")"
    (cd app && flutter build web --release) || return 1
  fi
  rm -rf dist/web && mkdir -p dist && cp -r app/build/web dist/web
  echo "web build mode: $mode -> dist/web"
}
# web_test [file…]: flutter test --platform chrome on app/test/web (or the given files, relative to app/ or the repo root)
# shellcheck disable=SC2329
web_test() {
  local f files=()
  for f in "$@"; do f=${f#"$ROOT/"}; files+=("${f#app/}"); done
  ((${#files[@]})) || files=(test/web)
  (cd app && flutter test --platform chrome --no-pub "${files[@]}")
}
export -f web_blockers build_web web_test

# ---- Linux desktop under Xvfb (desktop-test, desktop-smoke) ----
# headless <dir> <cmd...>: run cmd on a virtual X display (Mesa software GL) inside a private D-Bus session, with the
# app's data (XDG_DATA_HOME: wallet, key file, logs), documents and runtime folders inside <dir>. The display is the first
# free one, or :$BW_XDISPLAY (parallel workers: xvfb-run's search for a free one races when several start at once).
# shellcheck disable=SC2329  # called by name through a step
headless() {
  local dir=$1 display=(-a); shift
  [[ -n ${BW_XDISPLAY:-} ]] && display=(-n "$BW_XDISPLAY")
  mkdir -p "$dir/data" "$dir/docs"; mkdir -m 700 "$dir/run"
  XDG_DATA_HOME=$dir/data XDG_DOCUMENTS_DIR=$dir/docs XDG_RUNTIME_DIR=$dir/run NO_AT_BRIDGE=1 \
    timeout -k 10 "${BW_HEADLESS_TIMEOUT:-1200}" dbus-run-session --config-file="$ROOT/tools/dbus-headless.conf" -- \
    xvfb-run "${display[@]}" -s '-screen 0 1920x1080x24' "$@"
}
# The bus has no activatable services (tools/dbus-headless.conf: the image's xdg-desktop-portal is for live mode only), and the
# whole command is killed after $BW_HEADLESS_TIMEOUT seconds (default 20 min) so a hang fails the step instead of blocking.
# The app's log files (path_provider: $XDG_DATA_HOME/<application id>/logs/), oldest first
# shellcheck disable=SC2329
app_logs() { find "$1/data" -path '*/logs/bw-*.log' -print0 2>/dev/null | sort -z | xargs -0r cat; }
# desktop_test <name> [<shard> <shards>]: app/integration_test/<name>_test.dart on the Linux desktop (in $BW_APP_DIR, a
# copy of app/ when workers run in parallel), with a JSON report and per-test timings. Screenshots come from
# integration_test/flutter_test_config.dart (BW_SCREENS_DIR). With a shard (0-based, parallel runs only) it runs that slice
# of the file's tests; the caller cleans the screenshot folder first and merges the reports (desktop_merge).
# shellcheck disable=SC2329
desktop_test() {
  local name=$1 shard=${2:-} shards=${3:-1} dir rc=0 sfx='' opts=() shots=$ROOT/dist/screens/linux/$1
  [[ -n $shard ]] && sfx=.s$shard
  local json=$LOGS/tests-desktop-$name$sfx.json
  ((shards > 1)) && opts=(--total-shards "$shards" --shard-index "$shard")
  dir=$(mktemp -d)
  if [[ -z $shard ]]; then
    rm -rf "$shots" "$LOGS/screens-linux-$name"; rm -f "$LOGS/tests-desktop-$name-summary.txt"
  fi
  rm -f "$json"
  (cd "${BW_APP_DIR:-app}" && BW_SCREENS_DIR=$shots headless "$dir" \
    flutter test "integration_test/${name}_test.dart" -d linux --no-pub -r expanded --file-reporter "json:$json" "${opts[@]}") || rc=$?
  app_logs "$dir" > "$LOGS/app-linux-$name$sfx.log"
  if [[ -z $shard ]]; then
    [[ -d $shots ]] && cp -r "$shots" "$LOGS/screens-linux-$name"
    [[ -f $json ]] && python3 -I tools/build_log.py tests "desktop-$name" "$json"
  fi
  rm -rf "$dir"
  return "$rc"
}
# perf_run: app/integration_test/perf_test.dart in profile mode (`flutter drive`, the host side is
# app/test_driver/perf_driver.dart), then the numbers into perf-summary.txt and history/perf.jsonl. The driver exits
# non-zero on a budget overrun.
# shellcheck disable=SC2329
perf_run() {
  local dir rc=0
  dir=$(mktemp -d)
  rm -f "$LOGS"/perf-records.jsonl "$LOGS"/perf-summary.txt "$LOGS"/*.timeline.json "$LOGS"/*.timeline_summary.json
  # A killed run (SIGKILL of the container) leaves build state that makes the next `flutter drive` stall after
  # "Built ..." without ever launching the app (seen 2026-10-20, three times). Start from a clean profile build:
  # it costs ~1 min of rebuild on a step that is not in `test`/CI.
  rm -rf app/build/linux/x64/profile app/.dart_tool/flutter_build; rm -f app/build/flutter_driver_commands_*.log
  (cd app && BW_PERF_OUT=$LOGS headless "$dir" \
    flutter drive --profile -d linux --no-pub --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart) || rc=$?
  app_logs "$dir" > "$LOGS/app-linux-perf.log"
  python3 -I tools/build_log.py perf "$LOGS/perf-records.jsonl" > /dev/null  # table: perf-summary.txt, shown by summary
  rm -rf "$dir"
  return "$rc"
}
# smoke_run <binary> <seconds>: start it, it must still run after <seconds>, then SIGTERM must end it within 10 s
# (exit 0 or 143 = terminated; a crash shows as 134 abort, 139 segfault, ...).
# shellcheck disable=SC2329
smoke_run() {
  local pid rc=0 i
  "$1" > "$SMOKE_OUT" 2>&1 &
  pid=$!
  for ((i = 0; i < $2; i++)); do
    sleep 1
    kill -0 "$pid" 2>/dev/null || { wait "$pid" || rc=$?; echo "FAIL: the app exited after ${i}s with code $rc"; return 1; }
  done
  echo "app still running after $2 s; sending SIGTERM"
  kill -TERM "$pid"
  for ((i = 0; i < 100; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid"; echo "FAIL: the app ignored SIGTERM for 10 s"; return 1
  fi
  wait "$pid" || rc=$?
  echo "app exited with code $rc"
  [[ $rc == 0 || $rc == 143 ]] || { echo "FAIL: unexpected exit code"; return 1; }
}
# desktop_smoke: the release bundle from dist/BudgetWallet-linux-x64.tar.gz, unpacked to a temp folder and run with
# an empty HOME, like a first start on the owner's computer. smoke_run goes in by source: xvfb-run is a POSIX sh script,
# which drops exported bash functions.
# shellcheck disable=SC2329
desktop_smoke() {
  local dir rc=0 log=$LOGS/app-linux-smoke.log severe
  dir=$(mktemp -d)
  tar -xzf dist/BudgetWallet-linux-x64.tar.gz -C "$dir"
  mkdir -p "$dir/home"
  export SMOKE_OUT=$LOGS/app-linux-smoke-console.log
  HOME=$dir/home XDG_CONFIG_HOME=$dir/home/.config XDG_CACHE_HOME=$dir/home/.cache \
    headless "$dir" bash -c "$(declare -f smoke_run); "'smoke_run "$@"' _ "$dir/bundle/budget_wallet" "${BW_SMOKE_SECONDS:-10}" || rc=1
  app_logs "$dir" > "$log"
  rm -rf "$dir"
  echo "app log: $(wc -l < "$log") lines (dist/logs/app-linux-smoke.log)"
  grep -q 'app.start {"phase":"ready"' "$log" || { echo "FAIL: no app.start ready line in the app log"; rc=1; }
  severe=$(grep -c '^[^ ]* SEVERE ' "$log" || true)
  if [[ $severe != 0 ]]; then echo "FAIL: $severe SEVERE lines:"; grep -A3 '^[^ ]* SEVERE ' "$log" | head -40; rc=1; fi
  grep -c '^[^ ]* WARNING ' "$log" | xargs printf 'WARNING lines: %s\n'
  return "$rc"
}
export -f headless app_logs desktop_test perf_run smoke_run desktop_smoke
# Parallel desktop tests: each worker is a background loop with its own copy of app/ (a shared app/build and .dart_tool
# can't take two `flutter test` runs), its own Xvfb display and wallet/temp folders. Files are units on a shared list, the
# slowest first (history, tools/build_log.py order); a worker claims the next one with mkdir. Files in DESKTOP_SHARDS run as
# several units, each one a slice of the file's tests (flutter test --total-shards), and are merged back into one log,
# one history line per file. Logs, reports, screenshots and history keep their names; the step seconds of a sharded
# file are the sum over its shards.
declare -A DESKTOP_SHARDS=([layout]=5)
# Number of workers: BW_JOBS, else a quarter of the idle cores and one per 3 GB of free RAM, at most 6, at least 1.
desktop_jobs() {
  local jobs load=0 mem
  if [[ -n ${BW_JOBS:-} ]]; then
    [[ $BW_JOBS =~ ^[1-9][0-9]*$ ]] || { echo "BW_JOBS must be a positive number, not '$BW_JOBS'" >&2; return 1; }
    echo "$BW_JOBS"; return
  fi
  read -r load _ < /proc/loadavg || true
  mem=$(awk '/^MemAvailable:/ { print int($2 / 3145728) }' /proc/meminfo)  # kB per 3 GB
  jobs=$((($(nproc) - ${load%%[.,]*}) / 4))
  ((jobs > mem)) && jobs=$mem
  ((jobs > 6)) && jobs=6
  ((jobs < 1)) && jobs=1
  echo "$jobs"
}
# desktop_worker_app <w>: refresh worker <w>'s copy of app/ in dist/desktop-test/w<w>/app (build/ and .dart_tool/flutter_build
# stay there between runs, so only changed files rebuild). packages/ is a symlink next to it for the path dependencies.
desktop_worker_app() {
  local base=$ROOT/dist/desktop-test/w$1 f
  mkdir -p "$base/app/.dart_tool"
  ln -sfn ../../../packages "$base/packages"
  ln -sfn ../../../relay "$base/relay"
  rm -rf "$base"/app/{lib,test,integration_test,test_driver,tool}
  tar -C app --exclude=./build --exclude=./.dart_tool --exclude=./linux/flutter/ephemeral -cf - . | tar -C "$base/app" -xf -
  for f in package_config.json package_graph.json version; do
    if [[ -f app/.dart_tool/$f ]]; then cp -p "app/.dart_tool/$f" "$base/app/.dart_tool/"; fi
  done
}
# desktop_worker <w>: run units (name:shard:shards from $UNITS) until none is left, one console line per unit
desktop_worker() {
  local w=$1 i name shard shards cmd step label status rc secs
  desktop_worker_app "$w" || { echo "  worker $w: copying app/ failed" >&2; return 1; }
  export BW_APP_DIR=$ROOT/dist/desktop-test/w$w/app BW_XDISPLAY=$((100 + w))
  for i in "${!UNITS[@]}"; do
    mkdir "$LOGS/.claim-$i" 2>/dev/null || continue
    IFS=: read -r name shard shards <<<"${UNITS[$i]}"
    cmd="desktop_test $name"; step=desktop-$name; label=$name
    if ((shards > 1)); then cmd+=" $shard $shards"; step+=.s$shard; label+=" $((shard + 1))/$shards"; fi
    run_step "$step" "$cmd" || true
    read -r secs rc _ < "$LOGS/$step.status"
    status=ok; [[ $rc == 0 ]] || status=FAILED
    printf '  desktop-%-14s %-6s %6s s  (worker %s)\n' "$label" "$status" "$secs" "$w"
  done
}
# desktop_merge <name> <shards>: the shards' logs, reports and status as one desktop-<name> step (as run_step writes it)
desktop_merge() {
  local name=$1 shards=$2 i s secs rc started tenths=0 bad=0 start='' jsons=()
  local log=$LOGS/desktop-$name.log
  {
    for ((i = 0; i < shards; i++)); do
      s=desktop-$name.s$i
      if [[ ! -f $LOGS/$s.status ]]; then echo "--- shard $((i + 1))/$shards: did not run"; bad=1; continue; fi
      read -r secs rc started < "$LOGS/$s.status"
      echo "--- shard $((i + 1))/$shards: $secs s, exit $rc"
      sed '1d;$d' "$LOGS/$s.log"
      tenths=$((tenths + 10#${secs/./})); [[ $rc == 0 ]] || bad=1
      if [[ -z $start || $started < $start ]]; then start=$started; fi
      if [[ -f $LOGS/tests-desktop-$name.s$i.json ]]; then jsons+=("$LOGS/tests-desktop-$name.s$i.json"); fi
    done
    python3 -I tools/build_log.py tests "desktop-$name" "${jsons[@]:-/nonexistent}"
  } > "$log.tmp" 2>&1
  if [[ -d dist/screens/linux/$name ]]; then cp -r "dist/screens/linux/$name" "$LOGS/screens-linux-$name"; fi
  cat "$LOGS"/app-linux-"$name".s*.log > "$LOGS/app-linux-$name.log" 2>/dev/null || : > "$LOGS/app-linux-$name.log"
  secs="$((tenths / 10)).$((tenths % 10))"; start=${start:-$(now_iso)}
  { echo "# desktop-$name: started $start"; cat "$log.tmp"
    echo "# desktop-$name: finished $(now_iso), $secs s, exit $bad"; } > "$log"
  echo "$secs $bad $start" > "$LOGS/desktop-$name.status"
  rm -f "$log.tmp" "$LOGS/desktop-$name".s*.{log,status} "$LOGS/app-linux-$name".s*.log
}
# desktop_parallel <jobs> <name…>: run these files on <jobs> workers, then record them in the order given
desktop_parallel() {
  local jobs=$1 name w specs=() n
  shift
  for name; do specs+=("$name${DESKTOP_SHARDS[$name]:+:${DESKTOP_SHARDS[$name]}}"); done
  mapfile -t UNITS < <(python3 -I tools/build_log.py order "${specs[@]}")
  ((jobs > ${#UNITS[@]})) && jobs=${#UNITS[@]}
  echo "=== desktop-test: ${#UNITS[@]} units from $# files on $jobs workers (BW_JOBS) ==="
  for name; do rm -rf "dist/screens/linux/$name" "$LOGS/screens-linux-$name"; rm -f "$LOGS/tests-desktop-$name-summary.txt"; done
  rm -rf "$LOGS"/.claim-*
  for ((w = 1; w <= jobs; w++)); do desktop_worker "$w" & done
  wait
  rm -rf "$LOGS"/.claim-*
  for name; do
    n=${DESKTOP_SHARDS[$name]:-1}
    if ((n > 1)); then
      desktop_merge "$name" "$n"
    elif [[ ! -f $LOGS/desktop-$name.status ]]; then  # never started (every worker failed)
      printf '# desktop-%s: did not run\n' "$name" > "$LOGS/desktop-$name.log"; echo "0.0 1 $(now_iso)" > "$LOGS/desktop-$name.status"
    fi
    if [[ $(cut -d' ' -f2 "$LOGS/desktop-$name.status") != 0 ]]; then
      echo "=== desktop-$name ==="; sed '1d;$d' "$LOGS/desktop-$name.log"
    fi
    record "desktop-$name"
  done
}
# The integration test files to run: the names given, or every app/integration_test/*_test.dart. Parallel on
# desktop_jobs workers (a separate copy of app/ each), or one after another in app/ with a single job or a single unit.
desktop_tests() {
  local names=() valid=() f jobs units=0
  for f in "$@"; do f=${f%.dart}; names+=("${f%_test}"); done
  if ((${#names[@]} == 0)); then
    for f in app/integration_test/*_test.dart; do f=${f##*/}; names+=("${f%_test.dart}"); done
  fi
  for f in "${names[@]}"; do
    if [[ ! -f app/integration_test/${f}_test.dart ]]; then
      fail_step "desktop-$f" "no such test: app/integration_test/${f}_test.dart"; continue
    fi
    valid+=("$f"); units=$((units + ${DESKTOP_SHARDS[$f]:-1}))
  done
  [[ -n ${BW_GL_THREADS:-} ]] && export LP_NUM_THREADS=$BW_GL_THREADS  # llvmpipe rasterizer threads per app
  jobs=$(desktop_jobs) || { fail_step desktop-test "BW_JOBS must be a positive number, not '$BW_JOBS'"; return; }
  if ((jobs > 1 && units > 1)); then
    desktop_parallel "$jobs" "${valid[@]}"
  else
    for f in "${valid[@]}"; do step "desktop-$f" "desktop_test $f"; done
  fi
}

# End of run: seconds per step, test timing headlines, total
summary() {
  local t name secs result f
  echo
  printf '%-16s %8s  %s\n' step seconds result
  for t in "${timings[@]}"; do
    read -r name secs result <<<"$t"
    printf '%-16s %8s  %s\n' "$name" "$secs" "$result"
  done
  printf '%-16s %8s\n' total "$(secs_since "$RUN_START")"
  for t in "${timings[@]}"; do  # suite() deletes old summaries first, so these are from this run
    f="$LOGS/tests-${t%% *}-summary.txt"
    if [[ -f $f ]]; then head -1 "$f"; fi
  done
  [[ -f $LOGS/perf-summary.txt ]] && cat "$LOGS/perf-summary.txt"
  echo "${results[*]}"
}

case "$CMD" in
  # The SDK's own dart binary: the Flutter wrapper may print to stdout, which would corrupt the LSP stream
  lsp)    pub_ready >&2; exec "${FLUTTER_HOME:+$FLUTTER_HOME/bin/cache/dart-sdk/bin/}dart" language-server --protocol=lsp ;;
  # launch_app & co. would start apps in this display-less container: live mode (tools/live.sh) does that instead
  mcp)    pub_ready >&2; exec "${FLUTTER_HOME:+$FLUTTER_HOME/bin/cache/dart-sdk/bin/}dart" mcp-server --disable flutter_app_lifecycle "${@:2}" ;;
  format) run_pub; [[ $failed == 0 ]] && step format 'dart_files | xargs -0 dart format' ;;
  lint)   run_pub; steps "${LINT[@]}" ;;
  analyze) run_pub; [[ $failed == 0 ]] && analyze_pkgs "${@:2}" ;;
  outdated) step outdated outdated ;;
  test)   run_pub; [[ $failed == 0 ]] && steps "${LINT[@]}" "${TESTS[@]}" ;;
  importer|core|sync|relay|app)
    if (($# > 1)); then run_pub; [[ $failed == 0 ]] && one_suite "$CMD" "${@:2}"
    else run_pub; [[ $failed == 0 ]] && steps "$CMD" "${SUITE[$CMD]}"; fi ;;
  mutate) (($# > 2)) || usage
          run_pub; [[ $failed == 0 ]] && step mutate "python3 -I $ROOT/tools/mutate.py $(printf '%q ' "${@:2}")" ;;
  apk)    run_pub; [[ $failed == 0 ]] && build_apk ;;
  relay-bin) case "${2:-arm64}" in arm64|x64) ;; *) usage ;; esac
          run_pub; [[ $failed == 0 ]] && step relay-bin "relay_bin ${2:-arm64}" ;;
  linux)  run_pub; [[ $failed == 0 ]] && build_linux ;;
  desktop-test)  run_pub; [[ $failed == 0 ]] && desktop_tests "${@:2}" ;;
  perf)   run_pub; [[ $failed == 0 ]] && step perf perf_run ;;
  web)    run_pub; [[ $failed == 0 ]] && step web build_web ;;
  web-test) run_pub; [[ $failed == 0 ]] && step web-test "web_test$( (($# > 1)) && printf " %q" "${@:2}")" ;;
  desktop-smoke) run_pub; [[ $failed == 0 ]] && build_linux; [[ $failed == 0 ]] && step desktop-smoke desktop_smoke ;;
  all)    run_pub; [[ $failed == 0 ]] && steps "${LINT[@]}" "${TESTS[@]}"
          if [[ $failed == 0 ]]; then build_apk; build_linux; desktop_tests; step desktop-smoke desktop_smoke; fi ;;
  *)      usage ;;
esac

summary
exit $failed
