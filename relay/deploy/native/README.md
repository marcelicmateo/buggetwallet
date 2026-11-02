# Relay on a Raspberry Pi: native binary + systemd (no containers)

The relay listens on 127.0.0.1:8787 only. Native Caddy (OS package) terminates HTTPS (Let's Encrypt) and proxies to it.
This folder is what gets installed. One command from the laptop does it all: `tools/relay-deploy.sh native-install <pi-host> <your-domain> [--data-dir /mnt/ssd/bw-relay]` (also `native-upgrade`, `native-backup`, `native-status`; `--dry-run` prints everything; docs/setup.md §5). The table below is what that command does, for installing by hand.

| File | Goes to | What |
|---|---|---|
| `relay-linux-arm64` (built, not in git) | `/usr/local/bin/bw-relay` (0755, root) | `make relay-bin ARCH=arm64` -> `dist/relay/relay-linux-arm64` + `.sha256` (check it after copying) |
| `bw-relay.service` | `/etc/systemd/system/` | hardened service, user `bw-relay`, data `/var/lib/bw-relay` (StateDirectory), token via `LoadCredential=` |
| `bw-relay.sysusers` | `/etc/sysusers.d/bw-relay.conf` | creates the `bw-relay` system user |
| `bw-relay.env.example` | `/etc/bw-relay/bw-relay.env` (root, 0640) | `BW_RELAY_DOMAIN` (public name) and optional limits; no secrets |
| (you create) | `/etc/bw-relay/create-token` (root, 0600) | the wallet-creation token, one line; systemd passes it to the relay only |
| `Caddyfile` | `/etc/caddy/Caddyfile` | hardened headers and limits (no access log, 64 MiB bodies), upstream `127.0.0.1:8787` |
| `caddy.service.d/bw-relay.conf` | `/etc/systemd/system/caddy.service.d/` | gives Caddy `BW_RELAY_DOMAIN`, orders it after the relay |

Data on another path (an SSD): `/etc/systemd/system/bw-relay.service.d/data.conf` with `[Service]`, `StateDirectory=` (empty), `ReadWritePaths=<dir>`, `ExecStart=` (empty) and the `ExecStart=` line from the unit with `--data <dir>`; the folder is `bw-relay:bw-relay` mode 0700. `native-install --data-dir` writes this and `/etc/bw-relay/data-dir` (so backup and upgrade know it).
Backups: `tools/relay-deploy.sh native-backup <pi-host> [dir]` (stop, rsync through sudo, start); not a scheduled job, so there is no timer here.
Clock: a Pi has no hardware clock, and the relay checks request times against its own clock (±5 min). The unit starts after `time-sync.target`; that target only waits for a synchronised clock when `systemd-time-wait-sync.service` is enabled (`sudo systemctl enable systemd-time-wait-sync`, with `systemd-timesyncd` as the NTP client; chrony users: `chrony-wait.service`).
Data disk: the relay writes each file to a temp file, flushes it and renames it into place, but cannot fsync the folder (dart:io cannot open a folder), so a power cut right after a rename could lose that directory entry. Mount the data disk with `dirsync` (fstab options e.g. `defaults,noatime,dirsync`) so folder changes are written at once; without it a lost file answers 404 `missing` to the other devices.
Health: `Restart=on-failure` plus Caddy's `/v2/health` check; `bw-relay --health-check` works by hand.
Checks: `make lint` runs `make relay-native-check` (offline: `systemd-analyze verify` on the service plus invariants) and the deploy script's self-test. `make relay-native-test ARGS=debian` (or `fedora`) (needs network; not in lint) installs the x64 binary with the real install script into Fedora and Debian containers running systemd as PID 1 (rootless Podman) and checks: service active, health 200, 127.0.0.1 only, no SIGSYS/EPERM in the journal, data-dir drop-in, upgrade, `caddy validate`/`adapt`. Result 2026-10-28: all ok on Fedora 43 and Debian 13, `systemd-analyze security bw-relay` = 1.3 OK on both, no directive loosened. Not covered: the real arm64 CPU (the same filter groups apply) and Let's Encrypt (needs the real name).
