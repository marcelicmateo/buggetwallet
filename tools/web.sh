#!/usr/bin/env bash
# Serve the web build (tools/build.sh web -> dist/web/) on this computer only, and screenshot it.
#
#   tools/web.sh serve [port]        serve dist/web/ on http://127.0.0.1:<port> (default 8080) with the host's
#                                    `python3 -m http.server --bind 127.0.0.1`: loopback only, in the background
#   tools/web.sh stop                stop it            tools/web.sh status   running? where? (pid file: dist/web-serve.pid)
#   tools/web.sh shot <path> <out.png> [WxH]
#                                    headless Chrome (tools/web_shot.py) screenshot of <path> (e.g. "/") of dist/web/, default 412x915, written
#                                    to <out.png>. Chrome runs in the build container and cannot reach the host's loopback,
#                                    so the container serves dist/web/ itself on its own 127.0.0.1 for the shot; the host
#                                    server need not be running.
#
# Nothing is published: the server binds 127.0.0.1 and the app's data lives in the browser profile. The pid file and the
# server log are in the run directory of the `serve` call (~/.local/share/budget-wallet/runs/…-web-serve-…).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CMD=${1:-status}
PIDFILE=$ROOT/dist/web-serve.pid
# shellcheck source=tools/timing.sh
source "$ROOT/tools/timing.sh"
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

alive() { [[ -f $PIDFILE ]] && kill -0 "$(cut -d' ' -f1 "$PIDFILE")" 2>/dev/null; }
need_build() { [[ -f $ROOT/dist/web/index.html ]] || { echo "no dist/web: run tools/build.sh web first" >&2; exit 1; }; }

case "$CMD" in
  serve)
    port=${2:-8080}
    [[ $port =~ ^[0-9]+$ ]] || usage
    need_build
    if alive; then echo "already running: $(cut -d' ' -f2- "$PIDFILE") (tools/web.sh stop first)"; exit 0; fi
    run_begin web-serve
    trap - EXIT  # the server outlives this command: keep the run's .running marker (prune ignores it after 24 h)
    (cd "$ROOT/dist/web" && exec setsid python3 -I -m http.server "$port" --bind 127.0.0.1 \
      > "$BW_RUN_DIR/web-serve.log" 2>&1 < /dev/null) &
    pid=$!
    echo "$pid http://127.0.0.1:$port/ (log $BW_RUN_DIR/web-serve.log)" > "$PIDFILE"
    if curl -fsS -o /dev/null --retry 10 --retry-connrefused --retry-delay 1 "http://127.0.0.1:$port/"; then
      echo "serving dist/web on http://127.0.0.1:$port/ (pid $pid, loopback only)"; exit 0
    fi
    echo "server did not come up; see $BW_RUN_DIR/web-serve.log" >&2
    kill "$pid" 2>/dev/null || true; rm -f "$PIDFILE"; exit 1 ;;
  stop)
    if alive; then kill "$(cut -d' ' -f1 "$PIDFILE")"; echo "stopped"; else echo "not running"; fi
    rm -f "$PIDFILE" ;;
  status)
    if alive; then echo "running: $(cut -d' ' -f2- "$PIDFILE")"; else echo "not running"; fi ;;
  shot)
    [[ $# -ge 3 ]] || usage
    need_build
    path=/${2#/}
    out=$(realpath -m "$3")
    size=${4:-412x915}
    [[ $size =~ ^[0-9]+x[0-9]+$ ]] || usage
    mkdir -p "$(dirname "$out")"
    img=$("$ROOT/tools/build.sh" image-name)
    # tools/web_shot.py drives Chrome over the DevTools protocol and captures once Flutter has drawn (Chrome's --screenshot
    # fires at the load event, before that)
    podman run --rm -e BW_SHOT_SETTLE -v "$ROOT/dist/web:/web:ro,z" -v "$ROOT/tools:/tools:ro,z" -v "$(dirname "$out"):/out:z" "$img" bash -c '
      python3 -I -m http.server 18080 --bind 127.0.0.1 -d /web > /tmp/http.log 2>&1 &
      curl -fsS -o /dev/null --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:18080/ 2> /dev/null
      python3 -I /tools/web_shot.py "http://127.0.0.1:18080$3" "/out/$2" "$1"
    ' _ "$size" "$(basename "$out")" "$path"
    echo "screenshot: $out" ;;
  *) usage ;;
esac
