#!/usr/bin/env bash
# Set up and look after the relay on a rented server (docs/setup.md section 6) from the laptop.
#
#   tools/relay-deploy.sh [--dry-run] [--yes] bootstrap <ip|host>          first login as root: user bw, ssh hardening, updates, podman, port 80
#   tools/relay-deploy.sh [--dry-run] [--yes] install <ip|host> <domain>   DNS check, image, units, token secret, start, health check
#   tools/relay-deploy.sh [--dry-run] upgrade <ip|host>                    rebuild the image, copy it, restart the relay
#   tools/relay-deploy.sh [--dry-run] backup <ip|host> [dir]               stop, rsync the data folder to dir, start again
#   tools/relay-deploy.sh [--dry-run] status <ip|host>                     unit states and the public health answer
#   tools/relay-deploy.sh --self-test                                      offline check of the dry-run output (lint step)
#
# <ip|host> is an address or an ssh alias. Without "user@" it is bw@ (bootstrap: root@). --dry-run prints the commands and the
# remote scripts instead of running them. --yes answers the DNS question with yes (BW_YES=1 does the same).
# Podman only. The wallet-creation token is created on the server as a Podman secret (kept by Podman's secret driver there, as in
# docs/setup.md 5.3) and shown once, on install, on your terminal. This script never writes it to a file on the laptop, logs it or
# puts it in the repository. Re-running any step is safe (the token is only made once).
# BW_BACKUP_DIR sets the default backup folder (~/backups/budget-wallet-relay).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=localhost/budget-wallet-relay:latest
DEPLOY=$ROOT/relay/deploy
UNITS=(bw-relay.network bw-relay.container bw-relay-caddy.container Caddyfile bw-relay.env.example)
DRY=0
YES=${BW_YES:-0}
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "relay-deploy: $*" >&2; exit 1; }

# ---- remote scripts (run on the server with bash -c) ----
# Not run on the laptop, so they are plain text here.

remote_bootstrap() {
  cat <<'REMOTE'
set -euo pipefail
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *fedora*|*rhel*) os=fedora; wheel=wheel ;;
  *ubuntu*|*debian*) os=ubuntu; wheel=sudo ;;
  *) echo "unsupported system: ${PRETTY_NAME:-unknown} (Fedora or Ubuntu)" >&2; exit 1 ;;
esac
echo "system: $os"
# User bw with the same ssh key as root and passwordless sudo.
id bw >/dev/null 2>&1 || useradd -m -G "$wheel" bw
mkdir -p /home/bw/.ssh
if [ ! -s /home/bw/.ssh/authorized_keys ]; then cp /root/.ssh/authorized_keys /home/bw/.ssh/authorized_keys; fi
if command -v restorecon >/dev/null; then restorecon -R /home/bw/.ssh; fi
[ -s /home/bw/.ssh/authorized_keys ] || { echo "no ssh key for bw" >&2; exit 1; }
echo 'bw ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/bw && chmod 440 /etc/sudoers.d/bw
# Updates, podman, rsync (backups), automatic updates. Stdin is closed so nothing eats this script.
if [ "$os" = fedora ]; then
  dnf -y upgrade && dnf -y install podman rsync dnf-automatic
  mkdir -p /etc/dnf
  printf '[commands]\napply_updates = yes\n' > /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer || systemctl enable --now dnf5-automatic.timer \
    || systemctl enable --now dnf-automatic-install.timer
else
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt_opts='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
  # shellcheck disable=SC2086
  apt-get update && apt-get -y $apt_opts upgrade && apt-get -y $apt_opts install podman rsync unattended-upgrades
fi
# Rootless Caddy may bind 80 and 443.
echo 'net.ipv4.ip_unprivileged_port_start=80' > /etc/sysctl.d/90-bw-relay.conf && sysctl --system >/dev/null
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload
fi
echo "bootstrap done (ssh not hardened yet)"
REMOTE
}

# Second script, run only after the laptop has logged in as bw with sudo: no root login, no passwords.
remote_harden() {
  cat <<'REMOTE'
set -euo pipefail
if systemctl cat sshd.service >/dev/null 2>&1; then sshd=sshd; else sshd=ssh; fi
printf 'PermitRootLogin no\nPasswordAuthentication no\n' > /etc/ssh/sshd_config.d/10-bw.conf
sshd -t || { rm -f /etc/ssh/sshd_config.d/10-bw.conf; echo "sshd config check failed; hardening removed" >&2; exit 1; }
systemctl restart "$sshd"
echo "ssh hardened"
REMOTE
}

# Common first lines of every script that talks to the user's systemd.
user_env() {
  cat <<'REMOTE'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
REMOTE
}

remote_place() { # $1 = domain. stdout: the new token (only when the secret was created now), everything else on stderr
  cat <<'REMOTE'
set -euo pipefail
domain=$1
sudo mkdir -p /srv/budget-wallet-relay && sudo chown "$USER": /srv/budget-wallet-relay
mkdir -p ~/.config/containers/systemd ~/.config/budget-wallet-relay
cd ~/.relay-deploy
mv -f bw-relay.network bw-relay.container bw-relay-caddy.container ~/.config/containers/systemd/
mv -f Caddyfile ~/.config/budget-wallet-relay/Caddyfile
env=~/.config/budget-wallet-relay/bw-relay.env
if [ -e "$env" ]; then rm -f bw-relay.env.example; else mv bw-relay.env.example "$env"; fi
chmod 600 "$env"
if grep -q '^BW_RELAY_DOMAIN=' "$env"; then
  sed -i "s|^BW_RELAY_DOMAIN=.*|BW_RELAY_DOMAIN=$domain|" "$env"
else
  echo "BW_RELAY_DOMAIN=$domain" >> "$env"
fi
cd && rmdir ~/.relay-deploy
echo "files placed, BW_RELAY_DOMAIN=$domain" >&2
if podman secret exists bw-relay-create-token; then
  echo "token secret exists, left as it is" >&2
else
  token=$(head -c 24 /dev/urandom | base64)
  printf %s "$token" | podman secret create bw-relay-create-token - >/dev/null
  printf '%s\n' "$token"
fi
REMOTE
}

remote_start() {
  user_env
  cat <<'REMOTE'
set -euo pipefail
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user restart bw-relay
systemctl --user start bw-relay-caddy
echo "started" >&2
REMOTE
}

remote_restart() {
  user_env
  cat <<'REMOTE'
set -euo pipefail
systemctl --user restart bw-relay
systemctl --user start bw-relay-caddy
echo "restarted" >&2
REMOTE
}

remote_status() {
  user_env
  cat <<'REMOTE'
systemctl --user is-active bw-relay bw-relay-caddy || true
if podman healthcheck run bw-relay; then echo "healthcheck: healthy"; else echo "healthcheck: failed"; fi
sed -n 's/^BW_RELAY_DOMAIN=//p' ~/.config/budget-wallet-relay/bw-relay.env || true
REMOTE
}

remote_stop() {
  user_env
  cat <<'REMOTE'
systemctl --user stop bw-relay bw-relay-caddy
REMOTE
}

remote_domain() {
  cat <<'REMOTE'
sed -n 's/^BW_RELAY_DOMAIN=//p' ~/.config/budget-wallet-relay/bw-relay.env
REMOTE
}

# ---- plumbing ----

# run <cmd…>: run it, or print it with --dry-run.
run() {
  if ((DRY)); then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# remote <target> <script function> [args…]: the function's text runs on the server through ssh (stdin).
remote() {
  local target=$1 fn=$2
  shift 2
  if ((DRY)); then
    printf '+ ssh -n %s bash -c <script> bash %s   # script %s:\n' "$target" "$*" "$fn"
    "$fn" | sed 's/^/    | /'
  else
    # The script travels as an argument (base64), not on stdin: nothing in it can eat the rest of the script.
    # Arguments are validated names (domain), so plain words are safe here.
    local b64
    b64=$("$fn" | base64 -w0)
    ssh -n "${SSH_OPTS[@]}" "$target" "bash -c \"\$(printf %s $b64 | base64 -d)\" bash $*"
  fi
}

# target <host> <default user>: "user@host" unless the argument already has a user.
target() {
  [[ $1 != *:* ]] || die "IPv6 addresses are not supported here: give an ssh alias (Host entry in ~/.ssh/config) or the IPv4 address"
  [[ $1 =~ ^[A-Za-z0-9._@-]+$ && $1 != -* ]] || die "bad host: $1"
  if [[ $1 == *@* ]]; then echo "$1"; else echo "$2@$1"; fi
}

check_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "not a domain name: $1"
}

# Address of the server behind an ssh target (the ip itself, or what ssh would connect to for an alias).
server_addr() {
  local h=${1#*@}
  if [[ $h =~ ^[0-9.]+$ ]]; then echo "$h"; else ssh -G "$h" | awk '$1 == "hostname" {print $2}'; fi
}

# Does the domain point at the server? Warn and ask if not (a wrong record never works; a late one Caddy retries).
check_dns() {
  local domain=$1 addr found a
  if ((DRY)); then
    echo "+ (dns) check that $domain resolves to the server address"
    return
  fi
  addr=$(server_addr "$2")
  if command -v dig >/dev/null; then
    found=$({ dig +short A "$domain"; dig +short AAAA "$domain"; } || true)
  else
    found=$(getent ahosts "$domain" | awk '{print $1}' | sort -u || true)
  fi
  if grep -qxF "$addr" <<<"$found"; then
    echo "dns: $domain -> $addr ok"
    return
  fi
  echo "WARNING: $domain does not resolve to $addr (it gives: ${found:+${found//$'\n'/ }}${found:-nothing})." >&2
  echo "Create the A record first; until then Caddy cannot get a certificate." >&2
  ((YES)) && return
  [[ -t 0 ]] || die "DNS does not match; fix it or use --yes"
  read -r -p "Continue anyway? [y/N] " a
  [[ $a == y ]] || die "aborted"
}

# Bounded retry by curl itself: up to 15 tries 4 s apart (the first certificate takes a few seconds).
check_health() {
  local domain=$1 code
  if ((DRY)); then
    echo "+ curl --retry 15 https://$domain/v2/health   # expects 200"
    return
  fi
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --retry 15 --retry-delay 4 --retry-all-errors \
    "https://$domain/v2/health") || code=none
  if [[ $code == 200 ]]; then
    echo "health: https://$domain/v2/health answers 200"
  else
    echo "health: no 200 from https://$domain/v2/health (got $code). On the server: journalctl --user -u bw-relay-caddy" >&2
    echo "Usual causes: the DNS record, or the Hetzner firewall does not allow 80 and 443." >&2
    return 1
  fi
}

build_and_load() {
  local t=$1
  run podman build --format docker -f "$ROOT/dev/Containerfile.relay" -t "$IMAGE" "$ROOT"
  if ((DRY)); then
    echo "+ podman save $IMAGE | ssh $t podman load"
  else
    podman save "$IMAGE" | ssh "${SSH_OPTS[@]}" "$t" podman load
  fi
}

# ---- subcommands ----

cmd_bootstrap() {
  local t
  t=$(target "$1" root)
  remote "$t" remote_bootstrap
  # Close root login only if bw can log in and use sudo (a failed check here leaves root login open).
  if ((DRY)); then
    echo "+ ssh -n bw@${1#*@} sudo -n true   # must succeed before hardening"
  else
    ssh -n "${SSH_OPTS[@]}" "bw@${1#*@}" sudo -n true || die "cannot log in as bw with sudo; root login left open, ssh not hardened"
  fi
  remote "$t" remote_harden
  echo "Next: tools/relay-deploy.sh install ${1#*@} <domain>   (bw@ from now on)"
}

cmd_install() {
  local t domain=$2 f token paths=()
  t=$(target "$1" bw)
  check_domain "$domain"
  for f in "${UNITS[@]}"; do [[ -f $DEPLOY/$f ]] || die "missing $DEPLOY/$f"; done
  check_dns "$domain" "$t"
  build_and_load "$t"
  run ssh "${SSH_OPTS[@]}" "$t" mkdir -p .relay-deploy
  for f in "${UNITS[@]}"; do paths+=("$DEPLOY/$f"); done
  run scp -q "${SSH_OPTS[@]}" "${paths[@]}" "$t:.relay-deploy/"
  if ((DRY)); then
    remote "$t" remote_place "$domain"
  else
    token=$(remote "$t" remote_place "$domain")
    if [[ -n $token ]]; then
      {
        echo
        echo "=========== WALLET-CREATION TOKEN (shown once, not saved anywhere) ==========="
        echo "$token"
        echo "Copy it into your password manager now. The app asks for it when it creates"
        echo "the wallet on this relay. (Lost? Remove the secret on the server and install again.)"
        echo "==============================================================================="
        echo
      } >&2
    fi
    token=
  fi
  remote "$t" remote_start
  check_health "$domain"
  echo "Relay address for the app: https://$domain"
}

cmd_upgrade() {
  local t domain
  t=$(target "$1" bw)
  build_and_load "$t"
  remote "$t" remote_restart
  if ((DRY)); then
    check_health "<domain from the server's bw-relay.env>"
    return
  fi
  domain=$(remote "$t" remote_domain)
  [[ -n $domain ]] || die "no BW_RELAY_DOMAIN in the server's bw-relay.env (run install first)"
  check_health "$domain"
}

cmd_backup() {
  local t dir=${2:-${BW_BACKUP_DIR:-$HOME/backups/budget-wallet-relay}} rc=0
  t=$(target "$1" bw)
  run mkdir -p "$dir"
  # Stopping the relay stops Caddy too (it requires it): both are started again, whatever rsync did.
  remote "$t" remote_stop
  # Also on Ctrl-C or a kill: do not leave the relay down.
  BACKUP_TARGET=$t
  if ((DRY)); then
    echo "+ trap 'restart bw-relay bw-relay-caddy' EXIT INT TERM"
  else
    trap 'trap - EXIT INT TERM; remote "$BACKUP_TARGET" remote_restart || echo "relay-deploy: could not restart the relay: run upgrade or status" >&2; exit 1' EXIT INT TERM
  fi
  # --delete: the folder is only this backup, so it mirrors the server.
  run rsync -a --delete "$t:/srv/budget-wallet-relay/" "$dir/" || rc=$?
  if ((!DRY)); then trap - EXIT INT TERM; fi
  remote "$t" remote_restart
  ((rc == 0)) || die "rsync failed ($rc); the relay was started again"
  echo "backup in $dir"
}

cmd_status() {
  local t out domain
  t=$(target "$1" bw)
  if ((DRY)); then
    remote "$t" remote_status
    check_health "<domain>"
    return
  fi
  out=$(remote "$t" remote_status)
  echo "$out"
  domain=$(tail -n 1 <<<"$out")
  [[ -n $domain && $domain != healthcheck:* ]] || die "no BW_RELAY_DOMAIN on the server (run install)"
  check_health "$domain"
}

self_test() {
  local out me=$ROOT/tools/relay-deploy.sh rc=0 f
  chk() { # chk <label> <pattern> <output>
    grep -qE -- "$2" <<<"$3" || { echo "relay-deploy self-test: $1: missing /$2/" >&2; rc=1; }
  }
  out=$("$me" --dry-run bootstrap 203.0.113.9) || rc=1
  chk bootstrap-target 'ssh -n root@203\.0\.113\.9 bash -c' "$out"
  chk bootstrap-ssh 'PermitRootLogin no' "$out"
  chk bootstrap-os 'dnf-automatic' "$out"
  chk bootstrap-port 'ip_unprivileged_port_start=80' "$out"
  out=$("$me" --dry-run install myalias wallet.example.org) || rc=1
  chk install-target 'ssh -n bw@myalias bash -c' "$out"
  chk install-build 'podman build --format docker -f .*Containerfile\.relay' "$out"
  chk install-load 'podman save localhost/budget-wallet-relay:latest \| ssh bw@myalias podman load' "$out"
  chk install-domain 'BW_RELAY_DOMAIN=.domain' "$out"
  chk install-secret 'podman secret create bw-relay-create-token' "$out"
  chk install-linger 'enable-linger' "$out"
  chk install-health 'https://wallet\.example\.org/v2/health' "$out"
  out=$("$me" --dry-run upgrade bw@h) || rc=1
  chk upgrade 'restart bw-relay$' "$out"
  out=$("$me" --dry-run backup h /tmp/bwb) || rc=1
  chk backup-order 'systemctl --user stop bw-relay bw-relay-caddy.*rsync -a --delete bw@h:/srv/budget-wallet-relay/ /tmp/bwb/.*restart bw-relay' \
    "$(tr '\n' ' ' <<<"$out")"
  out=$("$me" --dry-run status h) || rc=1
  chk status 'is-active bw-relay bw-relay-caddy' "$out"
  if "$me" --dry-run install h 'bad domain' >/dev/null 2>&1; then echo "relay-deploy self-test: bad domain accepted" >&2; rc=1; fi
  if "$me" --dry-run install >/dev/null 2>&1; then echo "relay-deploy self-test: missing args accepted" >&2; rc=1; fi
  if "$me" --dry-run bootstrap 2001:db8::1 >/dev/null 2>&1; then echo "relay-deploy self-test: IPv6 host accepted" >&2; rc=1; fi
  out=$("$me" --dry-run bootstrap h) || rc=1
  chk harden-after-login 'sudo -n true.*sshd -t \|\| \{ rm -f' "$(tr '\n' ' ' <<<"$out")"
  chk fedora-timer 'apply_updates = yes' "$out"
  if "$me" --dry-run bootstrap -oProxyCommand=x >/dev/null 2>&1; then echo "relay-deploy self-test: option-like host accepted" >&2; rc=1; fi
  # The files it copies must exist and the units must still use the names it relies on.
  for f in "${UNITS[@]}"; do [[ -f $DEPLOY/$f ]] || { echo "relay-deploy self-test: no $f" >&2; rc=1; }; done
  grep -q 'Secret=bw-relay-create-token' "$DEPLOY/bw-relay.container" || { echo "relay-deploy self-test: secret name changed" >&2; rc=1; }
  grep -q "$IMAGE" "$DEPLOY/bw-relay.container" || { echo "relay-deploy self-test: image name changed" >&2; rc=1; }
  return "$rc"
}

# ---- arguments ----
ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    -h | --help) usage 0 ;;
    --self-test)
      self_test
      exit $?
      ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD=${1:-}
shift || usage
case "$CMD" in
  bootstrap) (($# == 1)) || usage; cmd_bootstrap "$@" ;;
  install) (($# == 2)) || usage; cmd_install "$@" ;;
  upgrade) (($# == 1)) || usage; cmd_upgrade "$@" ;;
  backup) (($# == 1 || $# == 2)) || usage; cmd_backup "$@" ;;
  status) (($# == 1)) || usage; cmd_status "$@" ;;
  *) usage ;;
esac
