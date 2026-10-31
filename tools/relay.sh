#!/usr/bin/env bash
# Run the relay (relay/) locally in a rootless Podman container, for development and the local web build.
#
#   tools/relay.sh start     build the image if missing (dev/Containerfile.relay), run it on 127.0.0.1:$BW_RELAY_PORT (8787)
#   tools/relay.sh stop      stop and remove the container (data stays)
#   tools/relay.sh status    running? health answer
#   tools/relay.sh logs [-f] container log (no tokens, bodies or addresses are logged)
#   tools/relay.sh reset     stop and delete the data folder (asks first; BW_YES=1 skips the question)
#   tools/relay.sh image     (re)build the image
#
# Dev mode: plain HTTP on 127.0.0.1, wallet creation open. The real deployment (Caddy + HTTPS + create token) is relay/deploy/native/.
# Data: ${BW_DATA_DIR:-~/.local/share/budget-wallet}/relay/. Allowed origins: BW_RELAY_ORIGINS, default the local web build
# (http://127.0.0.1:8080, http://localhost:8080; tools/web.sh serve).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CMD=${1:-status}
BW_DATA=${BW_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/budget-wallet}
DATA=$BW_DATA/relay
PORT=${BW_RELAY_PORT:-8787}
ORIGINS=${BW_RELAY_ORIGINS:-http://127.0.0.1:8080,http://localhost:8080}
NAME=bw-relay
IMAGE=localhost/budget-wallet-relay:$(cat "$ROOT/dev/Containerfile.relay" "$ROOT/relay/pubspec.lock" "$ROOT"/relay/bin/*.dart "$ROOT"/relay/lib/*.dart "$ROOT"/relay/lib/src/*.dart | sha256sum | cut -c1-8)
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[[ $PORT =~ ^[0-9]+$ ]] || { echo "BW_RELAY_PORT must be a number" >&2; exit 2; }
running() { [[ $(podman inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true) == true ]]; }
build_image() {
  echo "building $IMAGE" >&2
  podman build -f "$ROOT/dev/Containerfile.relay" -t "$IMAGE" "$ROOT" >&2
}
health() { curl -fsS --max-time 3 "$@" "http://127.0.0.1:$PORT/v2/health"; }

case "$CMD" in
  image) build_image ;;
  start)
    running && { echo "already running on 127.0.0.1:$PORT"; exit 0; }
    podman image exists "$IMAGE" || build_image
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    mkdir -p "$DATA"
    # The container user (uid 10001) is mapped to the host user, so the data folder stays yours.
    podman run -d --name "$NAME" --read-only --userns=keep-id:uid=10001,gid=10001 \
      --health-cmd 'relay --health-check' --health-interval 30s \
      -p "127.0.0.1:$PORT:8787" -v "$DATA:/data:z" \
      -e "BW_RELAY_ORIGINS=$ORIGINS" "$IMAGE" >/dev/null
    if health --retry 15 --retry-delay 1 --retry-connrefused --retry-all-errors >/dev/null; then
      echo "relay up on http://127.0.0.1:$PORT (data: $DATA)"
    else
      echo "relay did not answer; log:" >&2; podman logs "$NAME" >&2 || true; exit 1
    fi ;;
  stop) podman rm -f "$NAME" >/dev/null 2>&1 || true; echo stopped ;;
  status)
    if running; then echo "running on 127.0.0.1:$PORT: $(health || echo 'no health answer')"; else echo "not running"; fi ;;
  logs) podman logs "${@:2}" "$NAME" ;;
  reset)
    if [[ ${BW_YES:-} != 1 ]]; then
      read -r -p "Delete $DATA (all relay wallets)? [y/N] " a
      [[ $a == y ]] || { echo aborted; exit 1; }
    fi
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$DATA"
    echo "relay data deleted" ;;
  *) usage ;;
esac
