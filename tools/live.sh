#!/usr/bin/env bash
# Live mode: the Linux desktop app in debug mode (`flutter run -d linux`) in the build container, kept running in the
# background so you can click in it while Claude hot-reloads, reads the widget tree and takes screenshots.
#
#   tools/live.sh start [--headless] [--demo] [--profile] [--fresh]
#                          build and start the app; returns once the first frame is up and prints the VM service,
#                          DTD and DevTools addresses. The window opens on your desktop (Wayland only).
#                          --headless  virtual display (Xvfb), like tools/build.sh desktop-test; also used when
#                                      there is no Wayland session
#                          --demo      the synthetic demo wallet of the screenshot tests (app/tool/live_demo.dart)
#                          --profile   profile build: real performance, no hot reload (use `trace`)
#                          --fresh     start with an empty wallet folder
#   tools/live.sh reload   hot reload (keeps state)          tools/live.sh restart   hot restart (state reset)
#   tools/live.sh shot [file]   screenshot of the app -> file (default dist/screens/live.png); --profile: --headless only
#   tools/live.sh trace start   record the performance timeline from now on
#   tools/live.sh trace stop [name]   save it -> <run dir>/trace-<name>.json (Perfetto / DevTools) + -summary.txt
#                          (frames, build/raster p50/p90/max, frames over 16 ms)
#   tools/live.sh status   addresses, mode, wallet folder, logs        tools/live.sh stop   stop it, keep the logs
#   tools/live.sh mcp      Dart MCP server for Claude Code (same as tools/build.sh mcp, see .mcp.json). In Claude Code:
#                          its `dtd` tool, command connect, uri = the dtd line of `status`; then hot_reload,
#                          get_runtime_errors, widget_inspector work on this app.
#
# Privacy: the app's data (wallet, key file, logs, Documents) is a throwaway folder in dist/live/demo/ (--demo) or
# dist/live/wallet/; the container sees only the repo, never your home folder or the real wallet, and gets its own
# D-Bus session (no keyring, no host portal). File pickers (import, Syncthing folder, save logs) open a GTK dialog from
# a portal running on that private bus, drawn in the app's Wayland window; it sees only the container's folders (the
# repo, this run's log folder and history/ — not device-logs/) and /files = ~/.local/share/budget-wallet/live-files on
# the host (copy test bank files there; saved logs land there). The window uses only the Wayland socket: no X11 (an X11 client can read other windows
# and keystrokes). Claude drives the app only from inside (VM service, the dart MCP server), never with host input
# tools (xdotool, ydotool, uinput), and screenshots come from the app or the container's Xvfb, never your screen.
# Network: the app and the MCP server (tools/build.sh mcp) share a pod (bw-<checkout folder>), so the MCP server
# reaches the app's VM service and DTD; only the VM service/DevTools port is published, on the host's 127.0.0.1.
# Logs: the run's folder (dist/logs -> ~/.local/share/budget-wallet/runs/…-live-…): flutter-run.jsonl, app-live.log,
# traces. One live app per checkout (container bw-live-<checkout folder>); the build goes to app/build/live/.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CMD=${1:-status}
NAME=bw-live-$(basename "$ROOT" | tr -c 'a-zA-Z0-9_.\n-' '-')
POD=bw-$(basename "$ROOT" | tr -c 'a-zA-Z0-9_.\n-' '-')
# The VM service (DDS) port, fixed per checkout because a pod's published ports are set when it is created
PORT=$((20000 + $(cksum <<<"$POD" | cut -d' ' -f1) % 20000))
FIFO=/tmp/bw-live-in  # flutter run's stdin, inside the container
# shellcheck source=tools/timing.sh
source "$ROOT/tools/timing.sh"
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
vm() { python3 -I "$ROOT/tools/live_vm.py" "$@"; }

# ---- inside the container: flutter run with a private D-Bus session, on Xvfb or the host's display ----
if [[ "${BW_NATIVE:-}" == 1 ]]; then
  [[ $CMD == serve ]] || usage
  dir=$BW_LIVE_DIR
  mkdir -p "$dir/data" "$dir/docs" /tmp/bw-runtime
  chmod 700 /tmp/bw-runtime
  # path_provider: support folder = $XDG_DATA_HOME/<app id> (wallet, key file, logs), Documents = XDG_DOCUMENTS_DIR
  export XDG_DATA_HOME=$dir/data XDG_DOCUMENTS_DIR=$dir/docs XDG_RUNTIME_DIR=/tmp/bw-runtime NO_AT_BRIDGE=1
  # File pickers (file_picker -> xdg-desktop-portal FileChooser): the portal and its GTK backend are started on demand
  # by the private D-Bus session below, not by anything on the host. Host folders it can browse: /files (live-files),
  # the repo, this run's log folder and history/.
  mkdir -p ~/.config/xdg-desktop-portal ~/.config/gtk-3.0
  printf '[preferred]\ndefault=gtk\n' > ~/.config/xdg-desktop-portal/portals.conf
  echo 'file:///files Test files' > ~/.config/gtk-3.0/bookmarks
  # Own build folder: tools/build.sh mounts the repo at /work, and CMake's cache is tied to the source path
  flutter config --build-dir=build/live >/dev/null
  args=(run -d linux --machine --print-dtd --dds-port "$BW_LIVE_PORT")
  [[ $BW_LIVE_MODE == profile ]] && args+=(--profile)
  [[ -n ${BW_LIVE_TARGET:-} ]] && args+=(-t "$BW_LIVE_TARGET")
  run=(flutter "${args[@]}")
  # Headless: the bus is started outside Xvfb, so tell it the display for the portal's GTK backend
  [[ ${BW_LIVE_HEADLESS:-} == 1 ]] &&
    run=(xvfb-run -a -s '-screen 0 1280x720x24' bash -c 'dbus-update-activation-environment DISPLAY XAUTHORITY; exec "$@"' _ "${run[@]}")
  # DDS listens on 127.0.0.1 only; the published port arrives on the pod's other address
  python3 -I "$ROOT/tools/live_vm.py" forward "$BW_LIVE_PORT" &
  mkfifo "$FIFO"
  exec 3<>"$FIFO"  # read-write, so flutter run never sees end of input
  cd app
  exec dbus-run-session -- "${run[@]}" <&3 >"$BW_RUN_DIR/flutter-run.jsonl" 2>"$BW_RUN_DIR/flutter-run.err"
fi

# ---- host side ----
ensure_pod() {
  podman pod exists "$POD" && return
  podman pod create --name "$POD" --share net -p "127.0.0.1:$PORT:$PORT" >/dev/null || podman pod exists "$POD"
}
running() { [[ "$(podman inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" == true ]]; }
need_running() { running || { echo "Live mode is not running. Start it with: tools/live.sh start" >&2; exit 1; }; }
label() { podman inspect -f "{{index .Config.Labels \"$1\"}}" "$NAME" 2>/dev/null; }
# The run folder and flutter run's state (state, app, mode, vm, dtd, devtools) as shell variables
load() {
  RUN_DIR=$(label bw.run); DATA_DIR=$(label bw.data)
  [[ -d $RUN_DIR ]] || { echo "Live mode's run folder is gone; tools/live.sh stop, then start." >&2; exit 1; }
  state='' app='' mode='' vm_uri='' dtd='' devtools='' error=''
  local line v
  while IFS= read -r line; do
    v=${line#*=}  # (read with IFS='=' would drop a trailing '=' of the URIs)
    case ${line%%=*} in state) state=$v ;; app) app=$v ;; mode) mode=$v ;; vm) vm_uri=$v ;; dtd) dtd=$v ;;
      devtools) devtools=$v ;; error) error=$v ;; esac
  done < <(vm info "$RUN_DIR/flutter-run.jsonl")
  BW_RUN_ID=$(basename "$RUN_DIR"); export BW_RUN_ID
  timing_init live
}
# daemon <method> [full]: send a request to flutter run's stdin and wait for its reply
daemon() {
  local id
  id=$(date +%s%N | cut -c8-16)
  vm request "$id" "$1" "$app" "${2:-}" | podman exec -i "$NAME" sh -c "cat > $FIFO"
  vm reply "$RUN_DIR/flutter-run.jsonl" "$id" "${3:-120}"
}
# The app's log files (path_provider: $XDG_DATA_HOME/<application id>/logs/), oldest first
app_logs() { find "$1/data" -path '*/logs/bw-*.log' -print0 2>/dev/null | sort -z | xargs -0r cat; }
first_frames() { app_logs "$1" | grep -oP 'app\.start \{"phase":"total","ms":\K[0-9]+' || true; }
show() {
  echo "mode:      ${mode:-?} ($state)"
  [[ -n $vm_uri ]] && echo "vm:        $vm_uri"
  [[ -n $dtd ]] && echo "dtd:       $dtd"
  [[ -n $devtools ]] && echo "devtools:  $devtools"
  echo "wallet:    ${DATA_DIR#"$ROOT"/} (throwaway)"
  echo "logs:      $RUN_DIR"
  return 0
}

case "$CMD" in
  start)
    shift
    headless=0 demo=0 mode=debug fresh=0
    for a in "$@"; do
      case $a in --headless) headless=1 ;; --demo) demo=1 ;; --profile) mode=profile ;; --fresh) fresh=1 ;; *) usage ;; esac
    done
    if running; then echo "already running (tools/live.sh stop first):"; load; show; exit 0; fi
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    img=$("$ROOT/tools/build.sh" image-name)
    run_begin live
    t0=$(now_us)
    data=$ROOT/dist/live/wallet target=''
    ((demo)) && data=$ROOT/dist/live/demo target=tool/live_demo.dart
    ((fresh)) && rm -rf "$data"
    mkdir -p "$data"
    frames_before=$(first_frames "$data" | wc -l)
    opts=(-v "$ROOT:$ROOT:z" -v bw-pub-cache:/cache/pub
          -e BW_NATIVE=1 -e BW_LIVE_DIR="$data" -e BW_LIVE_MODE="$mode" -e BW_LIVE_TARGET="$target" -e BW_LIVE_PORT="$PORT"
          -e BW_LIVE_DEMO="$demo")
    # The one host folder for the file pickers (import bank files, Syncthing folder, saved logs), mounted at /files
    files=$BW_DATA/live-files
    mkdir -p "$files" "$BW_DATA/history"
    opts+=(-v "$files:/files:z")
    # Only this run's folder and the timing history, not all of $BW_DATA (device-logs/ holds logs the owner sends):
    # the file dialog can browse every mounted folder.
    run=(-v "$BW_RUN_DIR:$BW_RUN_DIR:z" -v "$BW_DATA/history:$BW_DATA/history:z")
    mapfile -t -O "${#run[@]}" run < <(run_env)
    way=${WAYLAND_DISPLAY:-}; [[ -n $way && $way != /* ]] && way=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$way
    if ((!headless)) && [[ -z $way || ! -S $way ]]; then
      echo "No Wayland session here: running headless (X11 is never passed through)." >&2
      headless=1
    fi
    if ((!headless)); then
      # Only the Wayland socket itself. label=disable: SELinux keeps containers off the session's sockets, and
      # relabeling (:z) them would be wrong.
      opts+=(--security-opt label=disable -v "$way:/tmp/bw-wayland:ro" -e WAYLAND_DISPLAY=/tmp/bw-wayland -e GDK_BACKEND=wayland)
      # The host's mouse cursors (the image has no cursor theme)
      [[ -d /usr/share/icons ]] && opts+=(-v /usr/share/icons:/tmp/bw-icons:ro -e XCURSOR_PATH=/tmp/bw-icons -e XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}")
      # GPU rendering when the host has a render node (Mesa); BW_LIVE_GPU=0 for software rendering
      if [[ ${BW_LIVE_GPU:-1} != 0 && -e /dev/dri/renderD128 ]]; then opts+=(--device /dev/dri); else opts+=(-e LIBGL_ALWAYS_SOFTWARE=1); fi
    fi
    ensure_pod
    podman run -d --name "$NAME" --pod "$POD" --label "bw.run=$BW_RUN_DIR" --label "bw.data=$data" --label "bw.headless=$headless" \
      -e BW_LIVE_HEADLESS="$headless" "${opts[@]}" "${run[@]}" -w "$ROOT" "$img" tools/live.sh serve >/dev/null
    echo "building and starting ($mode$( ((demo)) && echo ', demo wallet')$( ((headless)) && echo ', headless'))…"
    RUN_DIR=$BW_RUN_DIR
    for ((i = 0; i < 1800; i++)); do
      load
      [[ $state == started || $state == stopped ]] && break
      running || break
      sleep 0.5
    done
    secs=$(secs_since "$t0")
    if [[ $state != started ]]; then
      echo "FAILED to start ($state${error:+: $error}). Last lines of $RUN_DIR/flutter-run.err:" >&2
      tail -20 "$RUN_DIR/flutter-run.err" >&2
      log_history live-start "$secs" FAILED
      exit 1
    fi
    log_history live-start "$secs" ok
    # The app logs main() -> first frame shortly after flutter run reports it started
    for ((i = 0; i < 50; i++)); do (($(first_frames "$data" | wc -l) > frames_before)) && break; sleep 0.2; done
    first=$(first_frames "$data" | tail -1)
    echo "started in $secs s${first:+ (main() to first frame: $first ms)}"
    show ;;
  reload|restart)
    need_running; load
    [[ $mode == profile ]] && { echo "No hot $CMD in --profile mode: tools/live.sh stop, then start again." >&2; exit 1; }
    t=$(now_us)
    rc=0; daemon app.restart "$([[ $CMD == restart ]] && echo full)" || rc=$?
    secs=$(secs_since "$t")
    echo "$CMD: $secs s"
    log_history "live-$CMD" "$secs" "$([[ $rc == 0 ]] && echo ok || echo FAILED)"
    exit "$rc" ;;
  shot)
    need_running; load
    file=${2:-$ROOT/dist/screens/live.png}
    mkdir -p "$(dirname "$file")"
    if [[ $mode == debug ]]; then
      vm shot "$vm_uri" "$file"
    elif [[ $(label bw.headless) == 1 ]]; then
      # Profile builds have no inspector: grab the Xvfb screen (sized like the app's window) inside the container.
      # A process started by xvfb-run has its DISPLAY and XAUTHORITY.
      # shellcheck disable=SC2016  # expanded in the container
      podman exec "$NAME" bash -c 'for e in /proc/[0-9]*/environ; do grep -qz "^XAUTHORITY=/tmp/xvfb-run" "$e" 2>/dev/null && break; done
        while IFS= read -r -d "" v; do case $v in DISPLAY=* | XAUTHORITY=*) export "${v?}" ;; esac; done < "$e"
        python3 -I "$1/tools/live_vm.py" xshot -' _ "$ROOT" > "$file"
      echo "$file ($(($(stat -c %s "$file") / 1024)) KB)"
    else
      echo "A --profile app on the desktop has no in-app screenshot; start it with --headless for screenshots." >&2; exit 1
    fi
    cp "$file" "$RUN_DIR/shot-$(date +%H%M%S).png" ;;
  trace)
    need_running; load
    case ${2:-} in
      start) vm trace-start "$vm_uri" ;;
      stop) vm trace-stop "$vm_uri" "$RUN_DIR/trace-${3:-$(date +%H%M%S)}.json" "$mode" ;;
      *) usage ;;
    esac ;;
  status)
    if ! podman container exists "$NAME"; then echo "not running"; exit 0; fi
    load
    running || echo "the container has exited${error:+ ($error)}; see $RUN_DIR/flutter-run.err; tools/live.sh stop cleans up"
    show ;;
  stop)
    if ! podman container exists "$NAME"; then echo "not running"; exit 0; fi
    load
    if running && [[ -n $app ]]; then daemon app.stop '' 15 >/dev/null || true; fi
    podman rm -f -t 5 "$NAME" >/dev/null
    podman pod rm "$POD" >/dev/null 2>&1 || true  # kept while the MCP server still runs in it
    app_logs "$DATA_DIR" > "$RUN_DIR/app-live.log"
    echo "stopped; logs in $RUN_DIR" ;;
  pod) ensure_pod; echo "$POD" ;;  # for tools/build.sh mcp
  mcp) shift; exec "$ROOT/tools/build.sh" mcp "$@" ;;
  *) usage ;;
esac
