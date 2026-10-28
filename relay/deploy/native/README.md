# Relay on a Raspberry Pi: native binary + systemd (no containers)

The relay listens on 127.0.0.1:8787 only. Native Caddy (OS package) terminates HTTPS (Let's Encrypt) and proxies to it.
Bootstrap of the Pi (packages, user, install, firewall/router) is PI2; this folder is what gets installed.

| File | Goes to | What |
|---|---|---|
| `bw-relay-linux-arm64` (built, not in git) | `/usr/local/bin/bw-relay` (0755, root) | `tools/build.sh relay-bin arm64` -> `dist/relay/relay-linux-arm64` + `.sha256` (check it after copying) |
| `bw-relay.service` | `/etc/systemd/system/` | hardened service, user `bw-relay`, data `/var/lib/bw-relay` (StateDirectory), token via `LoadCredential=` |
| `bw-relay.sysusers` | `/etc/sysusers.d/bw-relay.conf` | creates the `bw-relay` system user |
| `bw-relay.env.example` | `/etc/bw-relay/bw-relay.env` (root, 0640) | `BW_RELAY_DOMAIN` (public name) and optional limits; no secrets |
| (you create) | `/etc/bw-relay/create-token` (root, 0600) | the wallet-creation token, one line; systemd passes it to the relay only |
| `Caddyfile` | `/etc/caddy/Caddyfile` | same headers and limits as `relay/deploy/Caddyfile`, upstream `127.0.0.1:8787` |
| `caddy.service.d/bw-relay.conf` | `/etc/systemd/system/caddy.service.d/` | gives Caddy `BW_RELAY_DOMAIN`, orders it after the relay |

Backups: today's backup is a manual stop-rsync-start (`tools/relay-deploy.sh backup`), not a scheduled job, so there is no timer here.
Health: `Restart=on-failure` plus Caddy's `/v2/health` check; `bw-relay --health-check` works by hand.
Offline check: `tools/build.sh lint` runs `tools/relay-native-check.sh` (`systemd-analyze verify` on the service plus invariants). The Caddyfile is validated with `caddy validate` on the Pi (PI2).
