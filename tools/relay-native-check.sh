#!/usr/bin/env bash
# Offline checks of relay/deploy/native/ (a lint step, runs in the build container): systemd-analyze verify on the relay service
# (against a stand-in binary, since the real one only exists on the Pi), the Caddy drop-in as plain unit syntax, and a few
# invariants: the relay stays on 127.0.0.1, uses --trust-proxy, takes its token from a credential, no secret in the env template.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
d=relay/deploy/native
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
bad() { echo "relay-native-check: $*" >&2; fail=1; }

# Stand-in for /usr/local/bin/bw-relay: verify wants the executable to exist, so the unit is verified with ExecStart pointing at /bin/true.
sed 's#^ExecStart=/usr/local/bin/bw-relay#ExecStart=/bin/true#' "$d/bw-relay.service" > "$tmp/bw-relay.service"
if command -v systemd-analyze > /dev/null; then
  # Missing user/credential files are not errors for verify; anything else (unknown key, bad value) is.
  out=$(systemd-analyze verify --man=no "$tmp/bw-relay.service" 2>&1) || true
  out=$(grep -v -e 'bw-relay.*not found' -e 'Failed to create bw-relay' -e 'Unit .*not found' <<< "$out" | grep -i -e 'unknown\|invalid\|failed\|error\|bad' || true)
  [[ -z $out ]] || bad "systemd-analyze verify: $out"
else
  echo "relay-native-check: systemd-analyze missing, syntax-only check" >&2
fi

for f in "$d/bw-relay.service" "$d/caddy.service.d/bw-relay.conf" "$d/bw-relay.sysusers"; do
  [[ -s $f ]] || bad "$f missing"
done
# every non-comment line of a unit is a section header or Key=Value
for f in "$d/bw-relay.service" "$d/caddy.service.d/bw-relay.conf"; do
  grep -vE '^\s*(#.*)?$|^\[[A-Za-z]+\]$|^[A-Za-z]+=' "$f" && bad "$f: line that is not Key=Value"
done
grep -q -- '--host 127.0.0.1' "$d/bw-relay.service" || bad "relay must be bound to 127.0.0.1"
grep -q -- '--trust-proxy' "$d/bw-relay.service" || bad "relay needs --trust-proxy behind Caddy"
grep -q '^LoadCredential=create-token:' "$d/bw-relay.service" || bad "creation token must come from LoadCredential="
grep -q 'reverse_proxy 127.0.0.1:8787' "$d/Caddyfile" || bad "Caddyfile must proxy to 127.0.0.1:8787"
grep -qiE 'TOKEN|SECRET|PASSWORD' <(grep -v '^#' "$d/bw-relay.env.example") && bad "env template must not hold secrets"
exit "$fail"
