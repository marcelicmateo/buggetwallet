#!/usr/bin/env bash
# Set up and look after the relay on a Raspberry Pi or any systemd Linux server (docs/setup.md sections 5 and 6) from the laptop:
# the native relay binary + systemd + Caddy (files in relay/deploy/native/, its README lists what goes where).
#
#   tools/relay-deploy.sh [--dry-run] native-install <host> <domain> [--data-dir /path]   first install
#   tools/relay-deploy.sh [--dry-run] native-upgrade|native-status <host>                 (build first: make relay-bin ARCH=arm64)
#   tools/relay-deploy.sh [--dry-run] native-backup <host> [dir]           stop, rsync the data folder (through sudo) to dir, start
#   tools/relay-deploy.sh --self-test                                      offline check of the dry-run output (lint step)
#
# <host> is an ssh alias or user@host exactly as given. --dry-run prints the commands and the remote scripts instead of running them.
# The wallet-creation token is made on the server (/etc/bw-relay/create-token) and shown once on your terminal. This script never
# writes it to a file on the laptop, logs it or puts it in the repository. Re-running any step is safe (the token is only made once).
# BW_BACKUP_DIR sets the default backup folder (~/backups/budget-wallet-relay).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DRY=0
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "relay-deploy: $*" >&2; exit 1; }

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

check_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "not a domain name: $1"
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
    echo "health: no 200 from https://$domain/v2/health (got $code). On the server: journalctl -u caddy" >&2
    echo "Usual causes: the DNS record, or the firewall (router, or the Hetzner firewall) does not allow 80 and 443." >&2
    return 1
  fi
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
  if [ -d "$data" ] && [ -n "$($S ls -A "$data")" ] && [ "$($S stat -c %U "$data")" != bw-relay ]; then
    echo "$data exists, is not empty and is not owned by bw-relay: refusing to take it over" >&2; exit 1
  fi
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
  {
    echo
    echo "=========== WALLET-CREATION TOKEN (shown once, not saved anywhere else) ==========="
    echo "$token"
    echo "Save it in your password manager now. It is also in /etc/bw-relay/create-token on this host (root only)."
    echo "====================================================================================="
  } >&2
  token=
else
  echo "token file exists, left as it is (show it: sudo cat /etc/bw-relay/create-token on the host)" >&2
fi
# Firewall: open 80 and 443 where a manager is active (firewalld, ufw); otherwise say so.
if command -v firewall-cmd >/dev/null && $S systemctl is-active --quiet firewalld; then
  $S firewall-cmd --permanent --add-service=http --add-service=https >&2 && $S firewall-cmd --reload >&2
elif command -v ufw >/dev/null && ufw_state=$($S ufw status) && [[ $ufw_state == "Status: active"* ]]; then
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
$S cp -p /usr/local/bin/bw-relay /usr/local/bin/bw-relay.prev
$S install -m 0755 "$bin" /usr/local/bin/bw-relay.new
$S mv -f /usr/local/bin/bw-relay.new /usr/local/bin/bw-relay
$S install -m 0644 bw-relay.service /etc/systemd/system/bw-relay.service
$S install -m 0644 bw-relay.conf /etc/systemd/system/caddy.service.d/bw-relay.conf
if [ -f /etc/caddy/Caddyfile ] && ! $S cmp -s Caddyfile /etc/caddy/Caddyfile; then $S cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-bw-relay; fi
$S install -m 0644 Caddyfile /etc/caddy/Caddyfile
data=$($S cat /etc/bw-relay/data-dir 2>/dev/null || echo /var/lib/bw-relay)
if [ "$data" != /var/lib/bw-relay ]; then
  exec_line=$(grep '^ExecStart=' bw-relay.service | sed "s#--data [^ ]*#--data $data#")
  printf '[Service]\nStateDirectory=\nReadWritePaths=%s\nExecStart=\n%s\n' "$data" "$exec_line" \
    | $S tee /etc/systemd/system/bw-relay.service.d/data.conf >/dev/null
fi
cd && rm -rf ~/.relay-native
$S systemctl daemon-reload
if $S systemctl restart bw-relay && curl -fsS --retry 5 --retry-delay 1 --retry-connrefused -o /dev/null http://127.0.0.1:8787/v2/health; then
  $S systemctl reload-or-restart caddy
  echo "upgraded (previous binary kept as /usr/local/bin/bw-relay.prev)" >&2
else
  echo "new relay did not start or answer health: restoring the previous binary" >&2
  $S cp -p /usr/local/bin/bw-relay.prev /usr/local/bin/bw-relay
  $S systemctl reset-failed bw-relay || true
  $S systemctl restart bw-relay || true
  echo "previous version restored; read: journalctl -u bw-relay" >&2
  exit 1
fi
REMOTE
}

remote_native_status() {
  cat <<'REMOTE'
systemctl is-active bw-relay caddy || true
if /usr/local/bin/bw-relay --health-check; then echo "healthcheck: healthy"; else echo "healthcheck: failed"; fi
S=; [ "$(id -u)" = 0 ] || S=sudo
$S sed -n 's/^BW_RELAY_DOMAIN=//p' /etc/bw-relay/bw-relay.env 2>/dev/null || true
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

# Sets NBIN (the binary built by make relay-bin ARCH=arm64, checksum verified here before anything is copied).
native_binary() {
  NBIN=$ROOT/dist/relay/relay-linux-${BW_NATIVE_ARCH:-arm64}
  if ((DRY)); then return; fi
  [[ -x $NBIN && -f $NBIN.sha256 ]] || die "no $NBIN: run make relay-bin ARCH=${BW_NATIVE_ARCH:-arm64} first"
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
  local t domain=$2 f
  t=$(native_target "$1")
  check_domain "$domain"
  [[ $DATA_DIR =~ ^/[A-Za-z0-9._/-]+$ && $DATA_DIR != *..* && $DATA_DIR != */ ]] || die "bad --data-dir: $DATA_DIR"
  case $DATA_DIR in
    /etc | /etc/* | /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /boot | /boot/* | /dev | /dev/* | /proc | /proc/* | /sys | /sys/* | /root | /root/* | /home | /var | /run | /run/* | /tmp | /tmp/* | /opt | /srv | /mnt | /media)
      die "--data-dir $DATA_DIR is a system folder: use a folder of its own, such as /mnt/ssd/bw-relay" ;;
  esac
  for f in "${NATIVE_FILES[@]}"; do [[ -f $NDIR/$f ]] || die "missing $NDIR/$f"; done
  native_binary
  native_copy "$t"
  if ((DRY)); then
    remote "$t" remote_native_place "$domain" "$DATA_DIR" 1
  else
    # The remote script prints the token itself on stderr (our terminal) as soon as it is written, so a later failure loses nothing.
    remote "$t" remote_native_place "$domain" "$DATA_DIR" 1 > /dev/null
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
  BACKUP_TARGET=$t
  if ((DRY)); then
    echo "+ trap 'start bw-relay' EXIT INT TERM"
  else
    trap 'trap - EXIT INT TERM; remote "$BACKUP_TARGET" remote_native_start || echo "relay-deploy: could not start the relay: run native-status" >&2; exit 1' EXIT INT TERM
  fi
  remote "$t" remote_native_stop
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
  if "$me" --dry-run native-install pi wallet.example.org --data-dir /etc/x > /dev/null 2>&1; then echo "relay-deploy self-test: system data dir accepted" >&2; rc=1; fi
  if "$me" --dry-run native-install -oProxyCommand=x wallet.example.org > /dev/null 2>&1; then echo "relay-deploy self-test: option-like host accepted" >&2; rc=1; fi
  if "$me" --dry-run native-install pi 'bad domain' > /dev/null 2>&1; then echo "relay-deploy self-test: bad domain accepted" >&2; rc=1; fi
  if "$me" --print-script usage > /dev/null 2>&1; then echo "relay-deploy self-test: --print-script accepted any function" >&2; rc=1; fi
  out=$("$me" --dry-run native-upgrade pi) || rc=1
  chk native-upgrade 'systemctl restart bw-relay' "$out"
  out=$("$me" --dry-run native-backup pi /tmp/bwb) || rc=1
  chk native-backup-order 'systemctl stop bw-relay.*rsync -a --no-o --no-g --delete --rsync-path=sudo\\ rsync pi:/var/lib/bw-relay/ /tmp/bwb/.*systemctl start bw-relay' \
    "$(tr '\n' ' ' <<<"$out")"
  out=$("$me" --dry-run native-status pi) || rc=1
  chk native-status 'is-active bw-relay caddy' "$out"
  # the env file is root:root 0640: reading it without sudo gave an empty domain (false "no BW_RELAY_DOMAIN")
  # shellcheck disable=SC2016  # the pattern is literal text of the remote script
  chk native-status-sudo '\$S sed -n .s/\^BW_RELAY_DOMAIN=' "$out"
  if "$me" --dry-run native-install >/dev/null 2>&1; then echo "relay-deploy self-test: native missing args accepted" >&2; rc=1; fi
  if "$me" --dry-run native-status 2001:db8::1 >/dev/null 2>&1; then echo "relay-deploy self-test: native IPv6 host accepted" >&2; rc=1; fi
  grep -q '^ExecStart=.*--data ' "$NDIR/bw-relay.service" || { echo "relay-deploy self-test: native unit has no ExecStart --data" >&2; rc=1; }
}

self_test() {
  local out me=$ROOT/tools/relay-deploy.sh rc=0
  chk() { # chk <label> <pattern> <output>
    grep -qE -- "$2" <<<"$3" || { echo "relay-deploy self-test: $1: missing /$2/" >&2; rc=1; }
  }
  native_self_test
  return "$rc"
}

# ---- arguments ----
ARGS=()
while (($#)); do
  a=$1
  shift
  case "$a" in
    --print-script)  # the remote script of a function (remote_native_place, ...): used by make relay-native-test
      (($#)) || usage
      case $1 in
        remote_native_place | remote_native_upgrade | remote_native_status | remote_native_datadir | remote_native_stop | remote_native_start) "$1" ;;
        *) usage ;;
      esac
      exit
      ;;
    --data-dir)
      (($#)) || usage
      DATA_DIR=$1
      shift
      ;;
    --dry-run) DRY=1 ;;
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
  native-install) (($# == 2)) || usage; cmd_native_install "$@" ;;
  native-upgrade) (($# == 1)) || usage; cmd_native_upgrade "$@" ;;
  native-backup) (($# == 1 || $# == 2)) || usage; cmd_native_backup "$@" ;;
  native-status) (($# == 1)) || usage; cmd_native_status "$@" ;;
  *) usage ;;
esac
