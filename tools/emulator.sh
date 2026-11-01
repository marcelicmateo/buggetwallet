#!/usr/bin/env bash
# Android emulator in a rootless Podman container (needs /dev/kvm). Image: dev/Containerfile.emulator (the build
# image plus the emulator's libraries).
#
#   tools/emulator.sh [-q|--quiet] <command> ...   -q or BW_QUIET=1: print nothing (stdout and stderr), only the exit code
#                                      comes back; the output goes to dist/logs/emulator-<command>.log as always, the outcome to
#                                      dist/logs/last.status and last-failed.txt (see tools/build.sh). Exit 0 ok, 1 failed, 2 usage.
#   tools/emulator.sh screens          boot, run the screenshot test with synthetic data, stop
#                                      -> dist/screens/*.png  (app/integration_test/screens_test.dart)
#   tools/emulator.sh test [name...]   boot once, run every app/integration_test/<name>_test.dart (or the named
#                                      ones: flows, flows_test or a path) with `flutter drive`, each on a freshly
#                                      installed app -> dist/screens/<name>/*.png, dist/logs/app-<name>.log (app log),
#                                      dist/logs/report-<name>.json (perf numbers, known bugs), drive-<name>.log and
#                                      tests-<name>-summary.txt (per-test times); exit 1 if any failed
#   tools/emulator.sh start [--window] boot an emulator that keeps running (--window: show it on the desktop)
#   tools/emulator.sh install [apk]    install an APK on it (default dist/BudgetWallet-android.apk)
#   tools/emulator.sh shot <name>      screenshot of the running emulator -> dist/screens/<name>.png
#   tools/emulator.sh adb <args...>    run adb against it
#   tools/emulator.sh stop             stop it
#   tools/emulator.sh reset            delete the emulator volumes; the next run downloads the latest emulator
#
# The emulator, the system image and the AVD live in Podman volumes (bw-emulator, bw-emulator-image,
# bw-emulator-avd), set up on first use (~2 GB download), so rebuilding the build image doesn't download them again.
# Setup ends with a cold boot of a wiped device and saves a snapshot of it; every run then starts from that
# snapshot in read-only mode (nothing is saved back), so each run sees the same clean device and nothing real is
# ever on it.
# Logs and phase timings (prepare, boot, build, install, test, total) go to the run dir and history like
# tools/build.sh (tools/timing.sh); the emulator's own log is saved as dist/logs/emulator.log, screenshots are copied.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The Go port (tools/wallet-build, `wallet-build emulator`) takes over when BW_IMPL=go (to try it) or when this script is in the
# auto list (since 2026-11-01: every command but reset, after the heavy parity cases screens, test and
# start/install/shot/adb/stop passed; reset deletes the volumes and has no parity case). BW_IMPL=bash keeps this script;
# natively (BW_NATIVE=1) auto means bash. Exit 3 = the tool did not build.
impl=${BW_IMPL:-auto}
[[ $impl == auto && ${BW_NATIVE:-} == 1 ]] && impl=bash
if [[ $impl == auto ]]; then
  c=${1:-}; [[ $c == -q || $c == --quiet ]] && c=${2:-}
  if [[ $c == reset ]]; then impl=bash; else impl=go; fi
fi
case "$impl" in
  go)
    mkdir -p "$ROOT/dist/bin"
    if ! (cd "$ROOT/tools/wallet-build" && GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -o "$ROOT/dist/bin/wallet-build" .) \
      > "$ROOT/dist/wallet-build-build.log" 2>&1; then
      [[ ${BW_QUIET:-} == 1 || ${1:-} == -q || ${1:-} == --quiet ]] || cat "$ROOT/dist/wallet-build-build.log" >&2
      exit 3
    fi
    q=()
    case "${1:-}" in -q|--quiet) q=("$1"); shift ;; esac
    exec "$ROOT/dist/bin/wallet-build" "${q[@]}" emulator "$@" ;;
esac
case "${1:-}" in -q|--quiet) BW_QUIET=1; shift ;; esac
[[ ${BW_QUIET:-} == 1 ]] && exec >/dev/null 2>&1  # podman and the helpers inherit it; the logs are written as without -q
CMD=${1:-screens}
NAME=bw-emulator
SERIAL=emulator-5554
SYSIMG="system-images;android-35;google_apis;x86_64"
# Change this (or the AVD settings in setup) to set the volumes up again on the next run.
SETUP_ID="1 $SYSIMG pixel_6 hw.keyboard=yes hw.ramSize=3072 disk.dataPartition.size=6G lavapipe"
usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
# shellcheck source=tools/timing.sh
source "$ROOT/tools/timing.sh"

# lavapipe (Mesa software Vulkan): SwiftShader GLES segfaults and SwANGLE hits illegal instructions in containers (emulator 37.x)
EMU_ARGS=(-avd bw -no-audio -no-boot-anim -gpu lavapipe -accel on -no-metrics)

wait_booted() {  # inside the container
  timeout 60 adb wait-for-device || { cat /tmp/emulator.log; exit 1; }
  for _ in $(seq 150); do
    [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
    sleep 1
  done
  [[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || { echo "emulator did not boot"; tail -30 /tmp/emulator.log; exit 1; }
  adb shell settings put global window_animation_scale 0
  adb shell settings put global transition_animation_scale 0
  adb shell settings put global animator_duration_scale 0
}

# First use: install into the volumes, create the AVD, cold boot it once and save the clean-boot snapshot.
setup() {  # inside the container, volumes mounted read-write
  exec 9>"$ANDROID_AVD_HOME/.lock"
  flock 9  # several worktrees may start at once
  [[ "$(cat "$ANDROID_AVD_HOME/.ready" 2>/dev/null)" == "$SETUP_ID" ]] && return
  echo "Setting up the emulator (first run: ~2 GB download)…"
  rm -rf "${ANDROID_AVD_HOME:?}"/bw.* "$ANDROID_AVD_HOME/.ready"
  sdkmanager "emulator" "$SYSIMG" >/dev/null
  echo no | avdmanager create avd -n bw -k "$SYSIMG" -d pixel_6 >/dev/null
  printf 'hw.keyboard=yes\nhw.ramSize=3072\ndisk.dataPartition.size=6G\n' >> "$ANDROID_AVD_HOME/bw.avd/config.ini"
  emulator "${EMU_ARGS[@]}" -no-window -no-snapshot-load -wipe-data >/tmp/emulator.log 2>&1 &
  adb start-server >/dev/null
  wait_booted
  sleep 10  # let first-boot work settle before the snapshot
  adb emu kill >/dev/null  # saves the default_boot snapshot on exit
  wait
  echo "$SETUP_ID" > "$ANDROID_AVD_HOME/.ready"
  echo "emulator ready"
}

boot() {  # inside the container
  local window=${1:-}
  # The host found no other emulator container running: a lock left in the AVD by a finished container is stale (the next emulator
  # would take it for a live instance and die after boot).
  # The emulator's lock files are bw.avd/*.lock (multiinstance.lock, snapshot.lock.lock, hardware-qemu.ini.lock).
  [[ "${BW_CLEAR_AVD_LOCK:-}" == 1 ]] && rm -rf "$ANDROID_AVD_HOME"/bw.avd/*.lock
  local args=("${EMU_ARGS[@]}" -read-only -no-snapshot-save)
  [[ -z "$window" ]] && args+=(-no-window)
  emulator "${args[@]}" >/tmp/emulator.log 2>&1 &
  adb start-server >/dev/null
  wait_booted
  echo "emulator booted"
}

# drive <suite> <test name|"">: `flutter drive` one integration test (in app/), log in $LOGS/<suite>.log, then the
# build/install/test history lines and the per-test summary (tools/build_log.py). An empty test name keeps the
# screenshot test's old output paths (dist/screens/*.png, dist/logs/app-emulator.log).
drive() {
  local suite=$1 name=$2 t rc=0 total build install result log
  log="$LOGS/${name:+drive-}$suite.log"
  # Skia, not Impeller: Impeller's GLES calls trip an abort in the emulator's software GLES decoder (37.x).
  # Override with BW_DRIVE_ARGS="" once a newer emulator fixes it.
  read -ra drive_args <<<"${BW_DRIVE_ARGS---no-enable-impeller}"
  t=$(now_us)
  BW_TEST_NAME=$name flutter drive --driver=test_driver/integration_test.dart --target="integration_test/${suite}_test.dart" \
    -d "$SERIAL" "${drive_args[@]}" 2>&1 | tee "$log" || rc=$?
  # `flutter drive` builds, installs and runs in one go: split its time using the durations it prints
  total=$(secs_since "$t")
  build=$(grep -oP "Running Gradle task 'assembleDebug'\.\.\. *\K[0-9.]+(?=s$)" "$log" | tail -1 || true)
  install=$(grep -oP '^Installing .*?\K[0-9]+(?=ms$)' "$log" | tail -1 || true)
  result=$([[ $rc == 0 ]] && echo ok || echo FAILED)
  [[ -n $build ]] && log_history build "$build" ok
  [[ -n $install ]] && log_history install "$(awk -v ms="$install" 'BEGIN { printf "%.1f", ms / 1000 }')" ok
  log_history "test${name:+-$name}" "$(awk -v t="$total" -v b="${build:-0}" -v i="${install:-0}" 'BEGIN { printf "%.1f", t - b - i / 1000 }')" "$result"
  python3 -I "$ROOT/tools/build_log.py" drive "$suite" "$log" || true
  return "$rc"
}

# ---- inside the container ----
if [[ "${BW_NATIVE:-}" == 1 ]]; then
  export ANDROID_AVD_HOME=/opt/avd PATH=$ANDROID_HOME/emulator:$PATH
  LOGS=${BW_RUN_DIR:-$ROOT/dist/logs}
  mkdir -p "$LOGS"
  case "$CMD" in
    setup) setup; exit ;;
    boot)
      t=$(now_us); boot "${2:-}"; log_history boot "$(secs_since "$t")" ok
      exec sleep infinity ;;
    screens)
      trap 'cp /tmp/emulator.log "$LOGS/emulator.log" 2>/dev/null || true' EXIT
      t=$(now_us); boot; log_history boot "$(secs_since "$t")" ok
      mkdir -p "$ROOT/dist/screens"
      cd "$ROOT/app"
      flutter pub get --enforce-lockfile >/dev/null
      rc=0
      drive screens "" || rc=$?
      exit "$rc" ;;
    test)
      trap 'cp /tmp/emulator.log "$LOGS/emulator.log" 2>/dev/null || true' EXIT
      shift
      names=()
      for n in "$@"; do n=${n##*/}; n=${n%.dart}; names+=("${n%_test}"); done
      if ((${#names[@]} == 0)); then
        for f in "$ROOT"/app/integration_test/*_test.dart; do n=${f##*/}; names+=("${n%_test.dart}"); done
      fi
      for n in "${names[@]}"; do
        [[ -f "$ROOT/app/integration_test/${n}_test.dart" ]] || { echo "no such test: app/integration_test/${n}_test.dart" >&2; exit 2; }
      done
      t=$(now_us); boot; log_history boot "$(secs_since "$t")" ok
      cd "$ROOT/app"
      flutter pub get --enforce-lockfile >/dev/null
      rc=0 table=()
      for n in "${names[@]}"; do
        rm -rf "$ROOT/dist/screens/$n"
        adb uninstall hr.marcelic.budget_wallet >/dev/null 2>&1 || true  # each test file starts on a clean app
        t=$(now_us); r=0
        drive "$n" "$n" || r=$?
        ((r == 0)) || rc=1
        table+=("$(printf '%-12s %-7s %6s s' "$n" "$([[ $r == 0 ]] && echo ok || echo FAILED)" "$(secs_since "$t")")")
      done
      echo "--- integration tests (emulator): ${#names[@]} files"
      printf '  %s\n' "${table[@]}"
      exit "$rc" ;;
  esac
  usage
fi

# ---- host side ----
emu_image() {
  local base tag
  base=$("$ROOT/tools/build.sh" image-name)
  tag="localhost/budget-wallet-emu:$( (echo "$base"; cat "$ROOT/dev/Containerfile.emulator") | sha256sum | cut -c1-8)"
  if ! podman image exists "$tag"; then
    timed_log emulator-image "$BW_RUN_DIR/image-emulator.log" \
      podman build --build-arg BASE="$base" -f "$ROOT/dev/Containerfile.emulator" -t "$tag" "$ROOT/dev"
  fi
  echo "$tag"
}
VOLUMES=(bw-emulator:/opt/android-sdk/emulator bw-emulator-image:/opt/android-sdk/system-images bw-emulator-avd:/opt/avd)
# Image and volumes (the setup is a no-op after the first run); sets $img
prepare() {
  local v mounts=() t before log=$BW_RUN_DIR/image-emulator-setup.log
  t=$(now_us)
  before=0; [[ -f "$BW_DATA/history/steps.jsonl" ]] && before=$(wc -l < "$BW_DATA/history/steps.jsonl")
  img=$(emu_image); BW_IMAGE=$img
  for v in "${VOLUMES[@]}"; do mounts+=(-v "$v"); done
  podman run --rm --device /dev/kvm --shm-size=2g "${mounts[@]}" "${run[@]}" -v "$ROOT:/work:z" -e BW_NATIVE=1 -w /work "$img" \
    tools/emulator.sh setup 2>&1 | tee "$log" >&2
  # cold: an image was built (emu_image runs in a subshell, so look for its history line) or the volumes were set up
  if grep -q "Setting up" "$log" || { [[ -f "$BW_DATA/history/steps.jsonl" ]] &&
    tail -n +"$((before + 1))" "$BW_DATA/history/steps.jsonl" | grep -q "\"run\":\"$BW_RUN_ID\".*\"step\":\"[a-z-]*image\""; }; then
    BW_COLD=1
  fi
  log_history prepare "$(secs_since "$t")" ok
}
common=(--device /dev/kvm --shm-size=2g -e BW_DRIVE_ARGS -v "$ROOT:/work:z" -v bw-pub-cache:/cache/pub -v bw-gradle-cache:/cache/gradle
        -v bw-android-user:/cache/android -e BW_NATIVE=1 -w /work)
# Runs only read the SDK volumes. The AVD stays writable for the emulator's lock files; `-read-only` keeps the
# device state itself out of it.
common+=(-v "${VOLUMES[0]}:ro" -v "${VOLUMES[1]}:ro" -v "${VOLUMES[2]}")
# `--rm` emulator containers can leave bw.avd/multiinstance.lock in the writable AVD volume; when no emulator container runs, the
# boot container removes it before the emulator starts (a lock of a running emulator must stay).
lock_args() {
  local out
  out=$(podman ps --format '{{.Image}}' 2>/dev/null) || return 0
  [[ "$out" == *budget-wallet-emu:* ]] || lock=(-e BW_CLEAR_AVD_LOCK=1)
}
running() { podman container exists "$NAME" && [[ "$(podman inspect -f '{{.State.Running}}' "$NAME")" == true ]]; }
need_running() { running || { echo "No emulator running. Start one with: tools/emulator.sh start" >&2; exit 1; }; }
with_run() { mapfile -t run < <(run_mounts); common+=("${run[@]}"); }  # before prepare

case "$CMD" in
  screens|test)
    run_begin "$CMD"
    t0=$(now_us)
    with_run
    prepare
    lock=(); lock_args
    rc=0
    # output to the terminal and to dist/logs/emulator-<cmd>.log (+ .status), no history line (the phases and total are there)
    BW_TIMED_SPLIT=1 BW_TIMED_HISTORY=0 timed_log "emulator-$CMD" "$BW_RUN_DIR/emulator-$CMD.log" \
      podman run --rm "${common[@]}" "${lock[@]}" "$img" tools/emulator.sh "$@" || rc=$?
    if [[ $CMD == screens ]]; then
      cp "$ROOT"/dist/screens/*.png "$BW_RUN_DIR/" 2>/dev/null || true
    else
      mkdir -p "$BW_RUN_DIR/screens"
      cp -r "$ROOT"/dist/screens/*/ "$BW_RUN_DIR/screens/" 2>/dev/null || true
    fi
    log_history total "$(secs_since "$t0")" "$([[ $rc == 0 ]] && echo ok || echo FAILED)"
    exit "$rc" ;;
  start)
    running && { echo "already running"; exit 0; }
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    run_begin start
    with_run
    prepare
    win=(); flag=
    if [[ "${2:-}" == --window ]]; then
      flag=window
      win=(-e DISPLAY="${DISPLAY:-:0}" -e QT_QPA_PLATFORM=xcb -v /tmp/.X11-unix:/tmp/.X11-unix:ro)
      [[ -n "${XAUTHORITY:-}" ]] && win+=(-e XAUTHORITY=/tmp/xauth -v "$XAUTHORITY:/tmp/xauth:ro")
      win+=(--security-opt label=disable)
    fi
    lock=(); lock_args
    # The label tells `stop` where to save the emulator's log
    podman run -d --name "$NAME" --label "bw.run=$BW_RUN_DIR" "${common[@]}" "${lock[@]}" "${win[@]}" "$img" tools/emulator.sh boot $flag >/dev/null
    echo "booting…"
    for _ in $(seq 180); do
      podman logs "$NAME" 2>&1 | grep -q "emulator booted" && { echo "ready ($SERIAL)"; exit 0; }
      running || { podman logs "$NAME" | tail -30; exit 1; }
      sleep 1
    done
    echo "timed out"; podman logs "$NAME" | tail -30; exit 1 ;;
  install)
    need_running
    apk=${2:-dist/BudgetWallet-android.apk}
    [[ "$apk" = /* ]] || apk="/work/$apk"
    run_begin install
    BW_TIMED_SPLIT=1 BW_TIMED_COLD=false timed_log emulator-install "$BW_RUN_DIR/emulator-install.log" \
      podman exec "$NAME" adb install -r "$apk" ;;
  shot)
    need_running
    [[ -n "${2:-}" ]] || usage
    mkdir -p "$ROOT/dist/screens"
    podman exec "$NAME" adb exec-out screencap -p > "$ROOT/dist/screens/$2.png"
    echo "dist/screens/$2.png" ;;
  adb)
    need_running; shift
    podman exec "$NAME" adb "$@" ;;
  stop)
    if podman container exists "$NAME"; then
      dir=$(podman inspect -f '{{index .Config.Labels "bw.run"}}' "$NAME" 2>/dev/null || true)
      if [[ -d "$dir" ]]; then podman cp "$NAME:/tmp/emulator.log" "$dir/emulator.log" 2>/dev/null || true; fi
      podman rm -f -t 0 "$NAME" >/dev/null && echo stopped
    else
      echo "not running"
    fi ;;
  reset)
    running && { echo "Stop the running emulator first: tools/emulator.sh stop" >&2; exit 1; }
    podman volume rm -f bw-emulator bw-emulator-image bw-emulator-avd >/dev/null && echo "emulator volumes deleted" ;;
  *) usage ;;
esac
