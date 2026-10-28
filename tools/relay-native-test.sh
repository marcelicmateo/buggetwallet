#!/usr/bin/env bash
# Proves relay/deploy/native/ on real systemd, locally: rootless Podman containers with systemd as PID 1 (Fedora and Debian),
# the x64 relay binary, sysusers, units, env file and a test token. Checks: bw-relay.service active, health answer, listening on
# 127.0.0.1 only, syscall filter silent in the journal, systemd-analyze security score, Caddy: validate + adapt + drop-in.
# Needs network (image pulls, distro packages), so it is NOT part of lint.
#   tools/relay-native-test.sh [fedora|debian]...     (default: both; needs `tools/build.sh relay-bin x64` first)
#   tools/build.sh relay-native-test [fedora|debian]  (builds the x64 binary, then runs this)
# Containers and images are removed at the end (BW_KEEP=1 keeps them). Everything is local; nothing connects to another machine.
# The domain and token used are test values.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
N=$ROOT/relay/deploy/native
BIN=$ROOT/dist/relay/relay-linux-x64
# Pinned base images (bump by hand).
FEDORA_IMG=registry.fedoraproject.org/fedora:43
DEBIAN_IMG=docker.io/library/debian:trixie-20261005
# Caddy is the distro package of each image (as on a Pi), so its version follows the image.
# Everything runs as root inside the container: the sudo and firewall branches of the install script are NOT exercised here.
OSES=("$@")
((${#OSES[@]})) || OSES=(fedora debian)
fail=0
bad() { echo "relay-native-test: FAIL: $*" >&2; fail=1; }

[[ -x $BIN ]] || { echo "relay-native-test: build the binary first: tools/build.sh relay-bin x64" >&2; exit 2; }
(cd "$ROOT/dist/relay" && sha256sum -c relay-linux-x64.sha256 > /dev/null) || { echo "relay-native-test: sha256 mismatch" >&2; exit 2; }

containerfile() { # $1 = fedora|debian
  case $1 in
    fedora)
      cat <<CF
FROM $FEDORA_IMG
RUN dnf -y install systemd caddy curl rsync iproute procps-ng && dnf clean all
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
CF
      ;;
    debian)
      cat <<CF
FROM $DEBIAN_IMG
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends systemd systemd-sysv dbus caddy curl rsync iproute2 procps ca-certificates && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
CF
      ;;
  esac
}

# The checks, run inside the container (bash -s). Prints "ok: ..." lines, "FAIL: ..." for problems, notes as "info: ...".
inside() {
  cat <<'IN'
set -uo pipefail
f=0
ok() { echo "ok: $*"; }
no() { echo "FAIL: $*"; f=1; }
info() { echo "info: $*"; }
# The real install script of tools/relay-deploy.sh (native-install) runs here, as root, with Caddy not started (no ACME in a test).
stage() { # what native_copy puts on the host
  mkdir -p /root/.relay-native
  cp /t/relay /root/.relay-native/relay-linux-x64
  (cd /root/.relay-native && sha256sum relay-linux-x64 > relay-linux-x64.sha256)
  cp /t/bw-relay.service /t/bw-relay.sysusers /t/bw-relay.env.example /t/Caddyfile /root/.relay-native/
  cp /t/caddy-dropin.conf /root/.relay-native/bw-relay.conf
}
stage
place() { bash /t/place.sh "$@" 2>/tmp/place.err; } # args: domain datadir startcaddy
place relay-test.example.invalid /var/lib/bw-relay 0 >/dev/null && ok "install script (default data dir)" || { no "install script"; cat /tmp/place.err; }
tok=$(grep -A1 'WALLET-CREATION TOKEN' /tmp/place.err | tail -n 1)
[[ -n $tok ]] && ok "token printed once on stderr" || no "no token printed"
[[ $(stat -c %a /etc/bw-relay/create-token) == 600 ]] && ok "create-token is 0600" || no "create-token mode"
grep -q "$tok" /etc/bw-relay/bw-relay.env /etc/systemd/system/bw-relay.service && no "token found in env/unit" || ok "token not in env/unit"
[[ $(systemctl is-active bw-relay) == active ]] && ok "bw-relay active" || no "bw-relay not active"
code=$(curl -s -o /dev/null -w '%{http_code}' --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:8787/v2/health || true)
[[ $code == 200 ]] && ok "GET /v2/health 200" || no "health answered $code"
if /usr/local/bin/bw-relay --health-check; then ok "bw-relay --health-check exit 0"; else no "--health-check failed"; fi
ls=$(ss -ltnH | awk '{print $4}')
grep -qx '127.0.0.1:8787' <<<"$ls" && ok "listens on 127.0.0.1:8787" || no "not listening on 127.0.0.1:8787 ($ls)"
if grep -E ':8787$' <<<"$ls" | grep -vq '^127\.0\.0\.1:'; then no "8787 also on a non-loopback address"; else ok "8787 not on 0.0.0.0 / [::]"; fi
[[ $(stat -c %U /var/lib/bw-relay) == bw-relay ]] && ok "state dir owned by bw-relay" || no "state dir owner $(stat -c %U /var/lib/bw-relay)"
ps -o user= -p "$(systemctl show -p MainPID --value bw-relay)" | grep -qx bw-relay && ok "runs as bw-relay" || no "wrong user"
# a creating PUT without the token must be refused (token reached the service as a credential and is enforced)
tc=$(curl -s -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:8787/v2/w/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/d/x/1 -d x || true)
info "unsigned PUT answered $tc (any 4xx = refused before storing)"
for i in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1:8787/v2/health; done
[[ $(systemctl is-active bw-relay) == active ]] && ok "still active after requests" || no "relay died after requests"
j=$(journalctl -u bw-relay --no-pager 2>&1)
if grep -qiE 'SIGSYS|Bad system call|Operation not permitted|EPERM|status=31|seccomp' <<<"$j"; then
  no "journal shows syscall-filter trouble"
  grep -iE 'SIGSYS|Bad system|not permitted|EPERM|seccomp' <<<"$j" | head -5
else ok "journal: no SIGSYS/EPERM"; fi
info "security: $(systemd-analyze security bw-relay --no-pager 2>/dev/null | tail -n 1)"
systemctl stop bw-relay && ok "stop" || no "stop"
[[ $(systemctl show -p Result --value bw-relay) == success ]] && ok "stopped with Result=success" || no "stop result $(systemctl show -p Result --value bw-relay)"
# Second pass: another data folder (SSD mount) through the drop-in, then the upgrade script on top of it.
stage; place relay-test.example.invalid /srv/ssd 0 > /tmp/tok2 && ok "install script again (data dir /srv/ssd)" || { no "reinstall"; cat /tmp/place.err; }
grep -q 'WALLET-CREATION' /tmp/place.err && no "token printed again on re-install" || ok "token kept on re-install (not printed)"
curl -s -o /dev/null --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:8787/v2/health && ok "health with data dir /srv/ssd" || no "no health with /srv/ssd"
tr '\0' ' ' </proc/"$(systemctl show -p MainPID --value bw-relay)"/cmdline | grep -q -- '--data /srv/ssd' && ok "relay runs with --data /srv/ssd" || no "drop-in not applied"
[[ $(stat -c %U /srv/ssd) == bw-relay ]] && ok "/srv/ssd owned by bw-relay" || no "/srv/ssd owner"
stage; bash /t/upgrade.sh 2>/tmp/up.err && ok "upgrade script" || { no "upgrade script"; cat /tmp/up.err; }
curl -s -o /dev/null --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:8787/v2/health && ok "health after upgrade" || no "no health after upgrade"
tr '\0' ' ' </proc/"$(systemctl show -p MainPID --value bw-relay)"/cmdline | grep -q -- '--data /srv/ssd' && ok "upgrade kept --data /srv/ssd" || no "upgrade lost the data dir"
# Failed upgrade: a binary that cannot run must be rolled back.
stage; printf '#!/bin/false\n' > /root/.relay-native/relay-linux-x64; (cd /root/.relay-native && sha256sum relay-linux-x64 > relay-linux-x64.sha256)
if bash /t/upgrade.sh 2>/tmp/up2.err; then no "broken upgrade reported success"; else ok "broken upgrade fails"; fi
curl -s -o /dev/null --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:8787/v2/health && ok "previous binary restored, health ok" || no "no health after rollback"
systemctl stop bw-relay
# Caddy
set -a; . /etc/bw-relay/bw-relay.env; set +a
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/val.txt 2>&1; then ok "caddy validate"; else no "caddy validate"; cat /tmp/val.txt; fi
ad=$(caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null)
grep -q '127.0.0.1:8787' <<<"$ad" && ok "caddy adapt: upstream 127.0.0.1:8787" || no "adapt: no upstream 127.0.0.1:8787"
grep -q 'relay-test.example.invalid' <<<"$ad" && ok "caddy adapt: host from BW_RELAY_DOMAIN" || no "adapt: domain missing"
systemctl cat caddy 2>/dev/null | grep -q 'EnvironmentFile=/etc/bw-relay/bw-relay.env' && ok "caddy.service has the drop-in" || no "drop-in not applied to caddy.service"
systemctl show -p After caddy | grep -q bw-relay.service && ok "caddy ordered after bw-relay" || no "caddy not after bw-relay"
exit "$f"
IN
}

cleanup() { # also on Ctrl-C or an error: container, built image, temp files
  # shellcheck disable=SC2086
  rm -f ${CLEAN_F:-}
  if [[ -z ${BW_KEEP:-} && -n ${CLEAN_C:-} ]]; then
    podman rm -f -t 5 "$CLEAN_C" > /dev/null 2>&1 || true
    podman rmi -f "$CLEAN_I" > /dev/null 2>&1 || true
  fi
  CLEAN_C=
}
trap cleanup EXIT INT TERM

one() { # $1 = fedora|debian
  local os=$1 out scripts
  scripts=$(mktemp)
  CLEAN_C=bw-relay-native-test-$os CLEAN_I=bw-relay-native-test-$os CLEAN_F="$scripts $scripts.up"
  "$ROOT/tools/relay-deploy.sh" --print-script remote_native_place > "$scripts"
  "$ROOT/tools/relay-deploy.sh" --print-script remote_native_upgrade > "$scripts.up"
  local img=bw-relay-native-test-$os c=bw-relay-native-test-$os
  echo "== $os =="
  podman rm -f "$c" > /dev/null 2>&1 || true
  containerfile "$os" | podman build -q -t "$img" -f - "$N" > "${TMPDIR:-/tmp}/bw-relay-native-build-$os.log" 2>&1 || { bad "$os: image build (log ${TMPDIR:-/tmp}/bw-relay-native-build-$os.log)"; return; }
  # --systemd=always: systemd as PID 1; rootless Podman delegates the cgroup.
  podman run -d --name "$c" --systemd=always \
    -v "$BIN:/t/relay:ro,z" -v "$N/bw-relay.service:/t/bw-relay.service:ro,z" -v "$N/bw-relay.sysusers:/t/bw-relay.sysusers:ro,z" \
    -v "$N/caddy.service.d/bw-relay.conf:/t/caddy-dropin.conf:ro,z" -v "$N/Caddyfile:/t/Caddyfile:ro,z" \
    -v "$N/bw-relay.env.example:/t/bw-relay.env.example:ro,z" -v "$scripts:/t/place.sh:ro,z" -v "$scripts.up:/t/upgrade.sh:ro,z" "$img" > /dev/null || { bad "$os: run"; return; }
  # waits (inside systemctl) until boot has finished
  podman exec "$c" systemctl is-system-running --wait > /dev/null 2>&1 || true
  out=$(inside | podman exec -i "$c" bash -s 2>&1) || true
  while IFS= read -r line; do echo "[$os] $line"; done <<<"$out"
  if grep -q '^FAIL' <<<"$out"; then bad "$os: checks failed"; fi
  cleanup
}

for os in "${OSES[@]}"; do
  case $os in
    fedora | debian) one "$os" ;;
    *) echo "usage: $0 [fedora|debian]..." >&2; exit 2 ;;
  esac
done
if ((fail == 0)); then echo "relay-native-test: all ok"; else echo "relay-native-test: FAILED" >&2; fi
exit "$fail"
