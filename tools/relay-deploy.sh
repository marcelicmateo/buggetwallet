#!/usr/bin/env bash
# Set up and look after the relay on a rented server (docs/setup.md section 6) from the laptop.
#
#   tools/relay-deploy.sh [--dry-run] [--yes] bootstrap <ip|host>          first login as root: user bw, ssh hardening, updates, podman, port 80
#   tools/relay-deploy.sh [--dry-run] [--yes] install <ip|host> <domain>   DNS check, image, units, token secret, start, health check
#   tools/relay-deploy.sh [--dry-run] upgrade <ip|host>                    rebuild the image, copy it, restart the relay
#   tools/relay-deploy.sh [--dry-run] backup <ip|host> [dir]               stop, rsync the data folder to dir, start again
#   tools/relay-deploy.sh [--dry-run] status <ip|host>                     unit states and the public health answer
#   tools/relay-deploy.sh [--dry-run] [--yes] native-install <host> <domain> [--data-dir /path]   Raspberry Pi / native binary + systemd + Caddy
#   tools/relay-deploy.sh [--dry-run] native-upgrade|native-status <host>                          (docs/setup.md 5; build first: tools/build.sh relay-bin arm64)
#   tools/relay-deploy.sh [--dry-run] native-backup <host> [dir]           stop, rsync the data folder (through sudo) to dir, start
#   tools/relay-deploy.sh --self-test                                      offline check of the dry-run output (lint step)
#
# <ip|host> is an address or an ssh alias. Without "user@" it is bw@ (bootstrap: root@). --dry-run prints the commands and the
# remote scripts instead of running them. --yes answers the DNS question with yes (BW_YES=1 does the same).
# Podman only. The wallet-creation token is created on the server as a Podman secret (kept by Podman's secret driver there, as in
# docs/setup.md 5.7.3) and shown once, on install, on your terminal. This script never writes it to a file on the laptop, logs it or
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
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
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

# ---- native target (Raspberry Pi or any systemd Linux; docs/setup.md section 5): no containers ----
# The binary and unit files are copied to ~/.relay-native on the host, then a script places them (root through sudo -n).
NDIR=$ROOT/relay/deploy/native
NATIVE_FILES=(bw-relay.service bw-relay.sysusers bw-relay.env.example Caddyfile caddy.service.d/bw-relay.conf)
DATA_DIR=/var/lib/bw-relay

# Args: $1 domain, $2 data dir, $3 start Caddy (1|0). stdout: the new token (only when it was made now); the rest goes to stderr.
remote_native_place() {
  cat <<'REMOTE'
set -euo pipefail
domain=$1 data=$2 startcaddy=${3:-1}
S=; [ "$(id -u)" = 0 ] || { S=sudo; sudo -n true 2>/dev/null || { echo "sudo asks for a password here; give this user passwordless sudo for the install" >&2; exit 1; }; }
cd ~/.relay-native
case $(uname -m) in aarch64|arm64) a=arm64 ;; x86_64) a=x64 ;; *) echo "unsupported CPU: $(uname -m)" >&2; exit 1 ;; esac
bin=relay-linux-$a
[ -f "$bin" ] || { echo "no $bin copied: the binary must match this CPU ($a)" >&2; exit 1; }
sha256sum -c "$bin.sha256" >&2 || { echo "binary checksum mismatch; nothing installed" >&2; exit 1; }
# Caddy and curl from the OS packages (apt or dnf).
if ! command -v caddy >/dev/null || ! command -v curl >/dev/null || ! command -v rsync >/dev/null; then
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    $S apt-get update >&2 && $S apt-get -y install caddy curl rsync >&2
  elif command -v dnf >/dev/null; then
    $S dnf -y install caddy curl rsync >&2
  else
    echo "neither apt nor dnf found: install caddy, curl and rsync by hand" >&2; exit 1
  fi
fi
$S install -m 0755 "$bin" /usr/local/bin/bw-relay
$S install -d -m 0755 /etc/sysusers.d /etc/bw-relay /etc/systemd/system/caddy.service.d /etc/systemd/system/bw-relay.service.d /etc/caddy
$S install -m 0644 bw-relay.sysusers /etc/sysusers.d/bw-relay.conf
$S systemd-sysusers
$S install -m 0644 bw-relay.service /etc/systemd/system/bw-relay.service
$S install -m 0644 bw-relay.conf /etc/systemd/system/caddy.service.d/bw-relay.conf
# The package's own Caddyfile is kept once as Caddyfile.pre-bw-relay.
if [ -f /etc/caddy/Caddyfile ] && ! $S cmp -s Caddyfile /etc/caddy/Caddyfile && [ ! -f /etc/caddy/Caddyfile.pre-bw-relay ]; then
  $S cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-bw-relay
fi
$S install -m 0644 Caddyfile /etc/caddy/Caddyfile
# Env file: kept when it exists (your edits), else the template; the domain is set either way.
if [ ! -e /etc/bw-relay/bw-relay.env ]; then $S install -m 0640 -o root -g root bw-relay.env.example /etc/bw-relay/bw-relay.env; fi
if $S grep -q '^BW_RELAY_DOMAIN=' /etc/bw-relay/bw-relay.env; then
  $S sed -i "s|^BW_RELAY_DOMAIN=.*|BW_RELAY_DOMAIN=$domain|" /etc/bw-relay/bw-relay.env
else
  echo "BW_RELAY_DOMAIN=$domain" | $S tee -a /etc/bw-relay/bw-relay.env >/dev/null
fi
# Data folder: the unit's own /var/lib/bw-relay (StateDirectory), or another path (an SSD mount) through a drop-in.
if [ "$data" = /var/lib/bw-relay ]; then
  $S rm -f /etc/systemd/system/bw-relay.service.d/data.conf
else
  $S install -d -m 0700 -o bw-relay -g bw-relay "$data"
  exec_line=$(grep '^ExecStart=' bw-relay.service | sed "s#--data [^ ]*#--data $data#")
  printf '[Service]\nStateDirectory=\nReadWritePaths=%s\nExecStart=\n%s\n' "$data" "$exec_line" \
    | $S tee /etc/systemd/system/bw-relay.service.d/data.conf >/dev/null
fi
printf '%s\n' "$data" | $S tee /etc/bw-relay/data-dir >/dev/null
# Token: made here, once, written root-only (0600); it is never on a command line and only printed to your terminal.
token=
if ! $S test -e /etc/bw-relay/create-token; then
  token=$(head -c 24 /dev/urandom | base64)
  (umask 077; printf %s "$token" | $S tee /etc/bw-relay/create-token >/dev/null)
  $S chmod 600 /etc/bw-relay/create-token
else
  echo "token file exists, left as it is" >&2
fi
# Firewall: open 80 and 443 where a manager is active (firewalld, ufw); otherwise say so.
if command -v firewall-cmd >/dev/null && $S systemctl is-active --quiet firewalld; then
  $S firewall-cmd --permanent --add-service=http --add-service=https >&2 && $S firewall-cmd --reload >&2
elif command -v ufw >/dev/null && $S ufw status | grep -q '^Status: active'; then
  $S ufw allow 80/tcp >&2 && $S ufw allow 443/tcp >&2
else
  echo "no active firewalld or ufw: if you run nftables or iptables yourself, allow tcp 80 and 443" >&2
fi
$S systemctl daemon-reload
$S systemctl enable bw-relay >&2
$S systemctl restart bw-relay
if [ "$startcaddy" = 1 ]; then
  $S systemctl enable caddy >&2
  $S systemctl restart caddy
fi
cd && rm -rf ~/.relay-native
echo "installed; domain $domain, data $data" >&2
[ -z "$token" ] || printf '%s\n' "$token"
REMOTE
}

# Replaces the binary and units; keeps env, token and data; restarts the relay.
remote_native_upgrade() {
  cat <<'REMOTE'
set -euo pipefail
S=; [ "$(id -u)" = 0 ] || { S=sudo; sudo -n true 2>/dev/null || { echo "sudo asks for a password here" >&2; exit 1; }; }
cd ~/.relay-native
case $(uname -m) in aarch64|arm64) a=arm64 ;; x86_64) a=x64 ;; *) echo "unsupported CPU: $(uname -m)" >&2; exit 1 ;; esac
bin=relay-linux-$a
sha256sum -c "$bin.sha256" >&2 || { echo "binary checksum mismatch; nothing installed" >&2; exit 1; }
$S test -e /etc/bw-relay/bw-relay.env || { echo "no install here yet (native-install first)" >&2; exit 1; }
$S install -m 0755 "$bin" /usr/local/bin/bw-relay.new
$S mv -f /usr/local/bin/bw-relay.new /usr/local/bin/bw-relay
$S install -m 0644 bw-relay.service /etc/systemd/system/bw-relay.service
$S install -m 0644 bw-relay.conf /etc/systemd/system/caddy.service.d/bw-relay.conf
$S install -m 0644 Caddyfile /etc/caddy/Caddyfile
data=$($S cat /etc/bw-relay/data-dir 2>/dev/null || echo /var/lib/bw-relay)
if [ "$data" != /var/lib/bw-relay ]; then
  exec_line=$(grep '^ExecStart=' bw-relay.service | sed "s#--data [^ ]*#--data $data#")
  printf '[Service]\nStateDirectory=\nReadWritePaths=%s\nExecStart=\n%s\n' "$data" "$exec_line" \
    | $S tee /etc/systemd/system/bw-relay.service.d/data.conf >/dev/null
fi
cd && rm -rf ~/.relay-native
$S systemctl daemon-reload
$S systemctl restart bw-relay
$S systemctl reload-or-restart caddy
echo "upgraded" >&2
REMOTE
}

remote_native_status() {
  cat <<'REMOTE'
systemctl is-active bw-relay caddy || true
if /usr/local/bin/bw-relay --health-check; then echo "healthcheck: healthy"; else echo "healthcheck: failed"; fi
sed -n 's/^BW_RELAY_DOMAIN=//p' /etc/bw-relay/bw-relay.env 2>/dev/null || true
REMOTE
}

remote_native_datadir() {
  cat <<'REMOTE'
cat /etc/bw-relay/data-dir 2>/dev/null || echo /var/lib/bw-relay
REMOTE
}

remote_native_stop() {
  cat <<'REMOTE'
set -euo pipefail
S=; [ "$(id -u)" = 0 ] || S=sudo
$S systemctl stop bw-relay
REMOTE
}

remote_native_start() {
  cat <<'REMOTE'
set -euo pipefail
S=; [ "$(id -u)" = 0 ] || S=sudo
$S systemctl start bw-relay
REMOTE
}

# native_target <host>: an ssh alias or user@host exactly as given (the Pi's login user is yours to choose).
native_target() {
  [[ $1 != *:* ]] || die "IPv6 addresses are not supported here: give an ssh alias or the IPv4 address"
  [[ $1 =~ ^[A-Za-z0-9._@-]+$ && $1 != -* ]] || die "bad host: $1"
  echo "$1"
}

# Sets NBIN (the binary built by tools/build.sh relay-bin arm64, checksum verified here before anything is copied).
native_binary() {
  NBIN=$ROOT/dist/relay/relay-linux-${BW_NATIVE_ARCH:-arm64}
  if ((DRY)); then return; fi
  [[ -x $NBIN && -f $NBIN.sha256 ]] || die "no $NBIN: run tools/build.sh relay-bin ${BW_NATIVE_ARCH:-arm64} first"
  (cd "$(dirname "$NBIN")" && sha256sum -c "$(basename "$NBIN").sha256" > /dev/null) || die "checksum of $NBIN does not match"
}

native_copy() { # $1 target
  local t=$1 f paths=("$NBIN" "$NBIN.sha256")
  run ssh "${SSH_OPTS[@]}" "$t" "rm -rf .relay-native && mkdir -p .relay-native"
  for f in "${NATIVE_FILES[@]}"; do paths+=("$NDIR/$f"); done
  run scp -q "${SSH_OPTS[@]}" "${paths[@]}" "$t:.relay-native/"
}

# The public health answer through Caddy. Not fatal: from the Pi's own network the router often cannot loop public addresses back.
native_health() {
  check_health "$1" || {
    echo "From the Pi's own network the router may not loop the public name back: test from outside (phone on mobile data)." >&2
    echo "On the Pi: tools/relay-deploy.sh native-status <pi-host> shows the unit states and the local health answer." >&2
  }
}

cmd_native_install() {
  local t domain=$2 token f
  t=$(native_target "$1")
  check_domain "$domain"
  [[ $DATA_DIR =~ ^/[A-Za-z0-9._/-]+$ && $DATA_DIR != *..* ]] || die "bad --data-dir: $DATA_DIR"
  for f in "${NATIVE_FILES[@]}"; do [[ -f $NDIR/$f ]] || die "missing $NDIR/$f"; done
  native_binary
  native_copy "$t"
  if ((DRY)); then
    remote "$t" remote_native_place "$domain" "$DATA_DIR" 1
  else
    token=$(remote "$t" remote_native_place "$domain" "$DATA_DIR" 1)
    if [[ -n $token ]]; then
      {
        echo
        echo "=========== WALLET-CREATION TOKEN (shown once, not saved anywhere) ==========="
        echo "$token"
        echo "Copy it into your password manager now. The app asks for it when it creates"
        echo "the wallet on this relay. (Lost? Remove /etc/bw-relay/create-token on the Pi and install again.)"
        echo "==============================================================================="
        echo
      } >&2
    fi
    token=
  fi
  native_health "$domain"
  echo "Relay address for the app: https://$domain"
}

cmd_native_upgrade() {
  local t domain
  t=$(native_target "$1")
  native_binary
  native_copy "$t"
  remote "$t" remote_native_upgrade
  if ((DRY)); then
    native_health "<domain from the host's bw-relay.env>"
    return
  fi
  domain=$(remote "$t" remote_native_status | tail -n 1)
  [[ -n $domain && $domain != healthcheck:* ]] || die "no BW_RELAY_DOMAIN on the host (run native-install)"
  native_health "$domain"
}

cmd_native_backup() {
  local t dir=${2:-${BW_BACKUP_DIR:-$HOME/backups/budget-wallet-relay}} rc=0 data=/var/lib/bw-relay
  t=$(native_target "$1")
  run mkdir -p "$dir"
  if ((!DRY)); then data=$(remote "$t" remote_native_datadir); fi
  remote "$t" remote_native_stop
  BACKUP_TARGET=$t
  if ((DRY)); then
    echo "+ trap 'start bw-relay' EXIT INT TERM"
  else
    trap 'trap - EXIT INT TERM; remote "$BACKUP_TARGET" remote_native_start || echo "relay-deploy: could not start the relay: run native-status" >&2; exit 1' EXIT INT TERM
  fi
  # The data folder belongs to bw-relay (0700): read through sudo on the host. The backup mirrors it (--delete), without owners.
  run rsync -a --no-o --no-g --delete --rsync-path="sudo rsync" "$t:$data/" "$dir/" || rc=$?
  if ((!DRY)); then trap - EXIT INT TERM; fi
  remote "$t" remote_native_start
  ((rc == 0)) || die "rsync failed ($rc); the relay was started again"
  echo "backup in $dir"
}

cmd_native_status() {
  local t out domain
  t=$(native_target "$1")
  if ((DRY)); then
    remote "$t" remote_native_status
    native_health "<domain>"
    return
  fi
  out=$(remote "$t" remote_native_status)
  echo "$out"
  domain=$(tail -n 1 <<<"$out")
  [[ -n $domain && $domain != healthcheck:* ]] || die "no BW_RELAY_DOMAIN on the host (run native-install)"
  native_health "$domain"
}

# Called from self_test (uses its $me, $rc and chk).
native_self_test() {
  local out
  out=$("$me" --dry-run native-install pi@pi.local wallet.example.org) || rc=1
  chk native-copy 'scp -q .*relay-linux-arm64.* .*relay-linux-arm64\.sha256.*bw-relay\.service.*Caddyfile.*pi@pi\.local:\.relay-native/' "$out"
  chk native-sha 'sha256sum -c' "$out"
  chk native-user 'ssh -n pi@pi\.local bash -c' "$out"
  chk native-apt 'apt-get -y install caddy' "$out"
  chk native-dnf 'dnf -y install caddy' "$out"
  chk native-sysusers 'systemd-sysusers' "$out"
  chk native-firewalld 'firewall-cmd --permanent --add-service=http' "$out"
  chk native-ufw 'ufw allow 443/tcp' "$out"
  # shellcheck disable=SC2016  # the pattern is literal text of the remote script
  chk native-token-file 'umask 077; printf %s "\$token" \| \$S tee /etc/bw-relay/create-token' "$out"
  chk native-enable 'systemctl enable caddy' "$out"
  chk native-health 'https://wallet\.example\.org/v2/health' "$out"
  chk native-default-data 'bash wallet\.example\.org /var/lib/bw-relay 1' "$out"
  if grep -E '^\+ (ssh|scp)' <<<"$out" | grep -qiE 'token'; then echo "relay-deploy self-test: token on a command line" >&2; rc=1; fi
  out=$("$me" --dry-run native-install pi wallet.example.org --data-dir /mnt/ssd/bw-relay) || rc=1
  chk native-data-dir 'bash wallet\.example\.org /mnt/ssd/bw-relay 1' "$out"
  chk native-data-dropin 'StateDirectory=' "$out"
  if "$me" --dry-run native-install pi wallet.example.org --data-dir '/mnt/a b' > /dev/null 2>&1; then echo "relay-deploy self-test: bad data dir accepted" >&2; rc=1; fi
  if "$me" --dry-run native-install pi wallet.example.org --data-dir '/mnt/../etc' > /dev/null 2>&1; then echo "relay-deploy self-test: .. in data dir accepted" >&2; rc=1; fi
  out=$("$me" --dry-run native-upgrade pi) || rc=1
  chk native-upgrade 'systemctl restart bw-relay' "$out"
  out=$("$me" --dry-run native-backup pi /tmp/bwb) || rc=1
  chk native-backup-order 'systemctl stop bw-relay.*rsync -a --no-o --no-g --delete --rsync-path=sudo\\ rsync pi:/var/lib/bw-relay/ /tmp/bwb/.*systemctl start bw-relay' \
    "$(tr '\n' ' ' <<<"$out")"
  out=$("$me" --dry-run native-status pi) || rc=1
  chk native-status 'is-active bw-relay caddy' "$out"
  if "$me" --dry-run native-install >/dev/null 2>&1; then echo "relay-deploy self-test: native missing args accepted" >&2; rc=1; fi
  if "$me" --dry-run native-status 2001:db8::1 >/dev/null 2>&1; then echo "relay-deploy self-test: native IPv6 host accepted" >&2; rc=1; fi
  grep -q '^ExecStart=.*--data ' "$NDIR/bw-relay.service" || { echo "relay-deploy self-test: native unit has no ExecStart --data" >&2; rc=1; }
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
  native_self_test
  return "$rc"
}

# ---- arguments ----
ARGS=()
while (($#)); do
  a=$1
  shift
  case "$a" in
    --print-script)  # the remote script of a function (remote_native_place, ...): used by tools/relay-native-test.sh
      (($#)) || usage
      "$1"
      exit
      ;;
    --data-dir)
      (($#)) || usage
      DATA_DIR=$1
      shift
      ;;
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
  native-install) (($# == 2)) || usage; cmd_native_install "$@" ;;
  native-upgrade) (($# == 1)) || usage; cmd_native_upgrade "$@" ;;
  native-backup) (($# == 1 || $# == 2)) || usage; cmd_native_backup "$@" ;;
  native-status) (($# == 1)) || usage; cmd_native_status "$@" ;;
  *) usage ;;
esac
