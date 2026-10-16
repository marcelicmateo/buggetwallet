#!/usr/bin/env bash
# Local builds in a rootless Podman container. Runs the same steps as CI (.github/workflows/ci.yml).
#
#   tools/build.sh test     lint, then importer + core + app: analyze and tests (all in parallel)
#   tools/build.sh lint     quick checks: Dart formatting, shellcheck, actionlint (pre-commit hook)
#   tools/build.sh format   rewrite Dart files with `dart format` (page width in analysis_options.yaml)
#   tools/build.sh apk      Android release APK   -> dist/BudgetWallet-android.apk
#   tools/build.sh linux    Linux release bundle  -> dist/BudgetWallet-linux-x64.tar.gz
#   tools/build.sh all      test, then apk and linux
#   tools/build.sh importer|core|app   analyze and test one package (what CI runs, one step each)
#   tools/build.sh shell    interactive shell in the container
#   tools/build.sh image    (re)build the container image (first build ~15 min)
#   tools/build.sh lsp      Dart language server on stdin/stdout, for editors (repo mounted at its host path)
#   tools/build.sh image-name   build the image if needed and print its tag (used by tools/emulator.sh)
#
# The image is rebuilt automatically when dev/Containerfile, dev/install-lint-tools.sh or the Flutter version changes.
# The Flutter version comes from `environment: flutter:` in app/pubspec.yaml (CI reads the same line).
# Logs: dist/logs/<step>.log (with start/end stamps), image builds in dist/logs/image-dev.log, per-test timings in
# dist/logs/tests-<suite>-summary.txt; every step is appended to dist/logs/history.jsonl (tools/build-times.sh).
# The exit code is non-zero if any step failed. BW_NATIVE=1 runs the steps directly on a machine that already has
# the right Flutter installed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FLUTTER_VERSION=$(grep -oP '^\s+flutter:\s*"?\K[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/app/pubspec.yaml")
# Tag = Flutter version + hash of the image inputs, so editing any of them rebuilds the image on the next run
IMAGE="localhost/budget-wallet-dev:$FLUTTER_VERSION-$(cat "$ROOT/dev/Containerfile" "$ROOT/dev/install-lint-tools.sh" | sha256sum | cut -c1-8)"
CMD=${1:-test}
# shellcheck source=tools/timing.sh
source "$ROOT/tools/timing.sh"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# ---- host side: hand the command to the container ----
if [[ "${BW_NATIVE:-}" != 1 ]]; then
  BW_IMAGE=$IMAGE
  build_image() {
    run_begin "$CMD"
    timed_log image "$BW_RUN_DIR/image-dev.log" \
      podman build --build-arg FLUTTER_VERSION="$FLUTTER_VERSION" -t "$IMAGE" "$ROOT/dev"
    BW_COLD=1
  }
  run=()  # the container writes logs and history into this run (tools/timing.sh)
  case "$CMD" in
    image) build_image; exit ;;
    image-name) podman image exists "$IMAGE" || build_image; echo "$IMAGE"; exit ;;
    test|lint|apk|linux|all|importer|core|app) run_begin "$CMD" ;;
    format|shell|lsp) ;;
    *) usage ;;
  esac
  # Build output goes to stderr (stdout belongs to the LSP client in `lsp` mode)
  podman image exists "$IMAGE" || build_image
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
  # Android release signing key (tools/make-signing-key.sh), mounted read-only
  SIGNING_DIR="${BW_SIGNING_DIR:-$HOME/.config/budget-wallet}"
  signing=()
  if [[ -f "$SIGNING_DIR/signing.env" ]]; then
    signing=(-v "$SIGNING_DIR:/signing:ro,z" --env-file "$SIGNING_DIR/signing.env" -e BW_KEYSTORE=/signing/android-release.jks)
  elif [[ "$CMD" == apk || "$CMD" == all ]]; then
    echo "No Android signing key in $SIGNING_DIR. Run tools/make-signing-key.sh first," >&2
    echo "otherwise the APK can't update the installed app." >&2
    exit 1
  fi
  tty=(); [[ -t 0 && -t 1 ]] && tty=(-it)
  inner=(tools/build.sh "$CMD"); [[ "$CMD" == shell ]] && inner=(bash)
  [[ -n "${BW_RUN_DIR:-}" ]] && mapfile -t run < <(run_mounts)
  # Rootless: container root is the host user, so build outputs stay owned by you.
  # Named volumes keep the pub and Gradle caches between runs.
  exec podman run --rm "${tty[@]}" \
    -v "$ROOT:/work:z" \
    -v bw-pub-cache:/cache/pub \
    -v bw-gradle-cache:/cache/gradle \
    -v bw-android-user:/cache/android \
    "${signing[@]}" "${run[@]}" \
    -e BW_NATIVE=1 \
    -w /work "$IMAGE" "${inner[@]}"
fi

# ---- inside the container (or native) ----
cd "$ROOT"
LOGS=${BW_RUN_DIR:-$ROOT/dist/logs}  # natively (CI) without a run dir: plain dist/logs
[[ -L $LOGS && ! -d $LOGS ]] && rm "$LOGS"  # a run-dir link that doesn't resolve here
mkdir -p "$LOGS"
timing_init "$CMD"
export ROOT LOGS
RUN_START=$(now_us)
results=()
timings=()
failed=0

# Dart sources, skipping generated and build folders
dart_files() {
  find app packages \( -name .dart_tool -o -name build -o -name ephemeral -o -name .symlinks \) -prune \
    -o -name '*.dart' -print0
}
# `pub get` only where the resolution is out of date, so a warm run skips it (CI always starts clean).
# Also needed by `dart format`, which reads page_width through the analysis_options.yaml includes.
pub_ready() {
  local d
  for d in packages/wallet_importer packages/wallet_core app; do
    pub_stale "$d" || continue
    echo "--- pub get: $d"
    if [[ $d == app ]]; then (cd "$d" && flutter pub get); else (cd "$d" && dart pub get); fi || return 1
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
export -f dart_files pub_ready pub_stale format_check suite

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

# Packages are resolved first (pub_ready, sequentially: they share the pub cache), so the checks skip their own
# implicit `pub get` (--no-pub) and all run in parallel.
LINT=(format format_check
      shellcheck 'shellcheck tools/*.sh dev/*.sh .github/scripts/*.sh'
      actionlint actionlint)
declare -A SUITE=(
  [importer]='suite importer packages/wallet_importer "dart analyze --fatal-infos" dart test'
  [core]='suite core packages/wallet_core "dart analyze --fatal-infos" dart test'
  [app]='suite app app "flutter analyze --fatal-infos --no-pub" flutter test --no-pub')
TESTS=(importer "${SUITE[importer]}" core "${SUITE[core]}" app "${SUITE[app]}")
run_pub() {
  local cold=false d
  for d in packages/wallet_importer packages/wallet_core app; do [[ -f $d/.dart_tool/package_config.json ]] || cold=true; done
  run_step pub pub_ready || true
  # Only worth showing (and timing) when something had to be resolved
  if [[ $(wc -l < "$LOGS/pub.log") -gt 2 || $(cut -d' ' -f2 "$LOGS/pub.status") != 0 ]]; then
    echo "=== pub ==="; sed '1d;$d' "$LOGS/pub.log"
    record pub "$cold"
  fi
}
build_apk() {
  if [[ ! -f "${BW_KEYSTORE:-}" ]]; then
    echo "BW_KEYSTORE is not set to the release key; refusing to build an APK that can't update the app." >&2
    results+=("apk=FAILED"); failed=1; return
  fi
  local cold=false; [[ -d app/build/app ]] || cold=true
  step apk 'cd app && flutter build apk --release && cp build/app/outputs/flutter-apk/app-release.apk ../dist/BudgetWallet-android.apk' "$cold"
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
build_linux() {
  local cold=false; [[ -d app/build/linux ]] || cold=true
  step linux 'cd app && flutter build linux --release && tar -C build/linux/x64/release -czf ../dist/BudgetWallet-linux-x64.tar.gz bundle' "$cold"
}

# End of run: seconds per step, test timing headlines, total
summary() {
  local t name secs result f
  echo
  printf '%-14s %8s  %s\n' step seconds result
  for t in "${timings[@]}"; do
    read -r name secs result <<<"$t"
    printf '%-14s %8s  %s\n' "$name" "$secs" "$result"
  done
  printf '%-14s %8s\n' total "$(secs_since "$RUN_START")"
  for t in "${timings[@]}"; do  # suite() deletes old summaries first, so these are from this run
    f="$LOGS/tests-${t%% *}-summary.txt"
    if [[ -f $f ]]; then head -1 "$f"; fi
  done
  echo "${results[*]}"
}

case "$CMD" in
  # The SDK's own dart binary: the Flutter wrapper may print to stdout, which would corrupt the LSP stream
  lsp)    pub_ready >&2; exec "${FLUTTER_HOME:+$FLUTTER_HOME/bin/cache/dart-sdk/bin/}dart" language-server --protocol=lsp ;;
  format) pub_ready; dart_files | xargs -0 dart format; exit ;;
  lint)   run_pub; steps "${LINT[@]}" ;;
  test)   run_pub; [[ $failed == 0 ]] && steps "${LINT[@]}" "${TESTS[@]}" ;;
  importer|core|app) run_pub; [[ $failed == 0 ]] && steps "$CMD" "${SUITE[$CMD]}" ;;
  apk)    build_apk ;;
  linux)  build_linux ;;
  all)    run_pub; [[ $failed == 0 ]] && steps "${LINT[@]}" "${TESTS[@]}"; if [[ $failed == 0 ]]; then build_apk; build_linux; fi ;;
  *)      usage ;;
esac

summary
exit $failed
