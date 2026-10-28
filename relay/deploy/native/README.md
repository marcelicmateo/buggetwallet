# Relay on a Raspberry Pi: native binary + systemd (no containers)

The relay listens on 127.0.0.1:8787 only. Native Caddy (OS package) terminates HTTPS (Let's Encrypt) and proxies to it.
This folder is what gets installed. One command from the laptop does it all: `tools/relay-deploy.sh native-install <pi-host> <your-domain> [--data-dir /mnt/ssd/bw-relay]` (also `native-upgrade`, `native-backup`, `native-status`; `--dry-run` prints everything; docs/setup.md §5). The table below is what that command does, for installing by hand.

| File | Goes to | What |
|---|---|---|
| `bw-relay-linux-arm64` (built, not in git) | `/usr/local/bin/bw-relay` (0755, root) | `tools/build.sh relay-bin arm64` -> `dist/relay/relay-linux-arm64` + `.sha256` (check it after copying) |
| `bw-relay.service` | `/etc/systemd/system/` | hardened service, user `bw-relay`, data `/var/lib/bw-relay` (StateDirectory), token via `LoadCredential=` |
| `bw-relay.sysusers` | `/etc/sysusers.d/bw-relay.conf` | creates the `bw-relay` system user |
| `bw-relay.env.example` | `/etc/bw-relay/bw-relay.env` (root, 0640) | `BW_RELAY_DOMAIN` (public name) and optional limits; no secrets |
| (you create) | `/etc/bw-relay/create-token` (root, 0600) | the wallet-creation token, one line; systemd passes it to the relay only |
| `Caddyfile` | `/etc/caddy/Caddyfile` | same headers and limits as `relay/deploy/Caddyfile`, upstream `127.0.0.1:8787` |
| `caddy.service.d/bw-relay.conf` | `/etc/systemd/system/caddy.service.d/` | gives Caddy `BW_RELAY_DOMAIN`, orders it after the relay |

Data on another path (an SSD): `/etc/systemd/system/bw-relay.service.d/data.conf` with `[Service]`, `StateDirectory=` (empty), `ReadWritePaths=<dir>`, `ExecStart=` (empty) and the `ExecStart=` line from the unit with `--data <dir>`; the folder is `bw-relay:bw-relay` mode 0700. `native-install --data-dir` writes this and `/etc/bw-relay/data-dir` (so backup and upgrade know it).
Backups: `tools/relay-deploy.sh native-backup <pi-host> [dir]` (stop, rsync through sudo, start); not a scheduled job, so there is no timer here.
Health: `Restart=on-failure` plus Caddy's `/v2/health` check; `bw-relay --health-check` works by hand.
Checks: `tools/build.sh lint` runs `tools/relay-native-check.sh` (offline: `systemd-analyze verify` on the service plus invariants) and the deploy script's self-test. `tools/build.sh relay-native-test [fedora|debian]` (needs network; not in lint) installs the x64 binary with the real install script into Fedora and Debian containers running systemd as PID 1 (rootless Podman) and checks: service active, health 200, 127.0.0.1 only, no SIGSYS/EPERM in the journal, data-dir drop-in, upgrade, `caddy validate`/`adapt`. Result 2026-10-28: all ok on Fedora 43 and Debian 13, `systemd-analyze security bw-relay` = 1.3 OK on both, no directive loosened. Not covered: the real arm64 CPU (the same filter groups apply) and Let's Encrypt (needs the real name).
