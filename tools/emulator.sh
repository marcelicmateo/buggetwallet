#!/usr/bin/env bash
# Android emulator in a rootless Podman container (needs /dev/kvm). Image: dev/Containerfile.emulator on top
# of the build image.
#
#   tools/emulator.sh screens          boot, run the screenshot test with synthetic data, stop
#                                      -> dist/screens/*.png  (app/integration_test/screens_test.dart)
#   tools/emulator.sh start [--window] boot an emulator that keeps running (--window: show it on the desktop)
#   tools/emulator.sh install [apk]    install an APK on it (default dist/BudgetWallet-android.apk)
#   tools/emulator.sh shot <name>      screenshot of the running emulator -> dist/screens/<name>.png
#   tools/emulator.sh adb <args...>    run adb against it
#   tools/emulator.sh stop             stop it
#
# The emulator starts from a wiped device every time; nothing real is ever on it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CMD=${1:-screens}
NAME=bw-emulator
SERIAL=emulator-5554
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

boot() {  # inside the container
  local window=${1:-}
  local args=(-avd bw -no-audio -no-boot-anim -no-snapshot -wipe-data -gpu lavapipe -accel on -no-metrics)
  # lavapipe (Mesa software Vulkan): SwiftShader GLES segfaults and SwANGLE hits illegal instructions in containers (emulator 37.x)
  [[ -z "$window" ]] && args+=(-no-window)
  emulator "${args[@]}" >/tmp/emulator.log 2>&1 &
  adb start-server >/dev/null
  timeout 60 adb wait-for-device || { cat /tmp/emulator.log; exit 1; }
  for _ in $(seq 150); do
    [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
    sleep 2
  done
  [[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || { echo "emulator did not boot"; tail -30 /tmp/emulator.log; exit 1; }
  adb shell settings put global window_animation_scale 0
  adb shell settings put global transition_animation_scale 0
  adb shell settings put global animator_duration_scale 0
  echo "emulator booted"
}

# ---- inside the container ----
if [[ "${BW_NATIVE:-}" == 1 ]]; then
  case "$CMD" in
    boot) boot "${2:-}"; exec sleep infinity ;;
    screens)
      boot
      mkdir -p "$ROOT/dist/screens" "$ROOT/dist/logs"
      cd "$ROOT/app"
      flutter pub get >/dev/null
      # Skia, not Impeller: Impeller's GLES calls trip an abort in the emulator's software GLES decoder (37.x).
      # Override with BW_DRIVE_ARGS="" once a newer emulator fixes it.
      read -ra drive_args <<<"${BW_DRIVE_ARGS---no-enable-impeller}"
      flutter drive --driver=test_driver/integration_test.dart --target=integration_test/screens_test.dart \
        -d "$SERIAL" "${drive_args[@]}" 2>&1 | tee "$ROOT/dist/logs/screens.log"
      exit "${PIPESTATUS[0]}" ;;
  esac
  usage
fi

# ---- host side ----
emu_image() {
  local base tag
  base=$("$ROOT/tools/build.sh" image-name)
  tag="localhost/budget-wallet-emu:$( (echo "$base"; cat "$ROOT/dev/Containerfile.emulator") | sha256sum | cut -c1-8)"
  podman image exists "$tag" || podman build --build-arg BASE="$base" -f "$ROOT/dev/Containerfile.emulator" -t "$tag" "$ROOT/dev" >&2
  echo "$tag"
}
common=(--device /dev/kvm --shm-size=2g -e BW_DRIVE_ARGS -v "$ROOT:/work:z" -v bw-pub-cache:/cache/pub -v bw-gradle-cache:/cache/gradle
        -v bw-android-user:/cache/android -e BW_NATIVE=1 -w /work)
running() { podman container exists "$NAME" && [[ "$(podman inspect -f '{{.State.Running}}' "$NAME")" == true ]]; }
need_running() { running || { echo "No emulator running. Start one with: tools/emulator.sh start" >&2; exit 1; }; }

case "$CMD" in
  screens)
    img=$(emu_image)
    tty=(); [[ -t 0 && -t 1 ]] && tty=(-it)
    exec podman run --rm "${tty[@]}" "${common[@]}" "$img" tools/emulator.sh screens ;;
  start)
    running && { echo "already running"; exit 0; }
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    img=$(emu_image)
    win=(); flag=
    if [[ "${2:-}" == --window ]]; then
      flag=window
      win=(-e DISPLAY="${DISPLAY:-:0}" -e QT_QPA_PLATFORM=xcb -v /tmp/.X11-unix:/tmp/.X11-unix:ro)
      [[ -n "${XAUTHORITY:-}" ]] && win+=(-e XAUTHORITY=/tmp/xauth -v "$XAUTHORITY:/tmp/xauth:ro")
      win+=(--security-opt label=disable)
    fi
    podman run -d --name "$NAME" "${common[@]}" "${win[@]}" "$img" tools/emulator.sh boot $flag >/dev/null
    echo "booting (1–2 min)…"
    for _ in $(seq 180); do
      podman logs "$NAME" 2>&1 | grep -q "emulator booted" && { echo "ready ($SERIAL)"; exit 0; }
      running || { podman logs "$NAME" | tail -30; exit 1; }
      sleep 2
    done
    echo "timed out"; podman logs "$NAME" | tail -30; exit 1 ;;
  install)
    need_running
    apk=${2:-dist/BudgetWallet-android.apk}
    [[ "$apk" = /* ]] || apk="/work/$apk"
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
    podman rm -f "$NAME" >/dev/null 2>&1 && echo stopped || echo "not running" ;;
  *) usage ;;
esac
