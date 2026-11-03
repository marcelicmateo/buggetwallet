# First relay on the Raspberry Pi: what was done and what to know (2026-11-03)

Log of the first real install of the relay on the owner's Pi (`docs/setup.md` §5), written from that session. **No domain, address,
token or key is recorded here** (they live on the Pi and in the owner's password manager). Result: the install worked end to end
(Let's Encrypt certificate, public `/v2/health` = 200), then the owner shut the relay down the same day (see "State at the end").

## What was set up
- Pi with **Raspberry Pi OS Lite 64-bit (Debian 13 trixie, aarch64)**, SSH key only, a normal user with passwordless sudo.
- Relay: `tools/relay-deploy.sh native-install <user>@<pi> <domain>` with the arm64 binary from `make relay-bin ARCH=arm64`.
- Name: a free DuckDNS name kept current by a systemd timer on the Pi (below).
- Router (Telekom Speedport, VDSL): TCP 443 (and 80) forwarded to the Pi.

## Preparing the card without the Imager (from the laptop)
The image was written with `dd`, the card's partitions mounted on the laptop and edited before the first boot:
- **bootfs**: `ssh` (empty file) enables SSH; `userconf.txt` (`user:<hash from openssl passwd -6>`) creates the first user.
- **rootfs**: the same can be done there without bootfs: symlink
  `/etc/systemd/system/multi-user.target.wants/ssh.service` → `/lib/systemd/system/ssh.service`, and the public key in
  `/home/<user>/.ssh/authorized_keys` (owner uid/gid 1000) or `/root/.ssh/authorized_keys` (Debian's default `PermitRootLogin
  prohibit-password` allows key login as root).
- **Network** (trixie uses NetworkManager): wired DHCP needs nothing. Wi-Fi: a root-owned, mode 600 file
  `/etc/NetworkManager/system-connections/<name>.nmconnection` (`[connection] type=wifi`, `[wifi] ssid=`, `[wifi-security]
  key-mgmt=wpa-psk` + `psk=`); a file that is not 0600 root is ignored. Add `cfg80211.ieee80211_regdom=<CC>` to `cmdline.txt` or Wi-Fi
  stays blocked until a country is set.
- Mixed up in this session: the image, not the card, had been mounted. `lsblk` first; `dd` only to the card.

## Gotchas (each cost time)
1. **Alpine Linux does not work with the deploy script.** `tools/relay-deploy.sh` needs systemd and `apt`/`dnf`; Alpine has OpenRC and
   `apk`. Use Raspberry Pi OS Lite (or another Debian/Fedora). Setup.md §5.2 now says so.
2. **Install as a normal user, not root.** First attempts ran against `root@pi` (the key was only on root): the first-boot user setup was
   not finished, `native-status` reported nothing installed. Make a user with `NOPASSWD` sudo (`/etc/sudoers.d/90-install`, mode 440,
   `visudo -cf`), copy the key to it, then deploy as that user.
3. **`native-status` printed a false "no BW_RELAY_DOMAIN on the host".** It read `/etc/bw-relay/bw-relay.env` (root:root 0640) without
   sudo. Fixed in `tools/relay-deploy.sh` (`$S sed …`) with a self-test line.
4. **Port forward on the Speedport**: in the form the *WAN Host Start/End IP* is the range of outside addresses allowed in, not the
   Pi's address: set both to `0.0.0.0` (or empty). Putting the Pi's address there gives "Invalid WAN host IP". LAN host = the Pi.
5. **From inside the LAN the public name showed the router's own certificate** ("Speedport Plus"): no hairpin NAT, and until the forward
   exists the router answers 443 itself. Test from outside (phone on mobile data) or after the forward; `curl` from the laptop worked
   once the certificate was issued.
6. **DNS name**: DuckDNS A record must be current before Caddy can get the certificate (TLS-ALPN-01 worked with 443 alone). Check CG-NAT
   first (router's WAN IPv4 equals `curl -s ifconfig.me`; VDSL here was a normal public address).
7. **Do not paste secrets into a chat or a tool call.** The DuckDNS token was pasted once (so it was rotated afterwards, see
   below). Write secrets with `read -rsp` on the target or from stdin.

## DuckDNS updater (systemd timer; cron is not installed on trixie)
`/usr/local/bin/duckdns-update` (root, 755) calls `https://www.duckdns.org/update?domains=<name>&token=$(cat /etc/duckdns.token)&ip=`
and fails unless the answer is `OK`; `/etc/duckdns.token` is root-only (600). `duckdns.service` (oneshot,
`ConditionPathExists=/etc/duckdns.token`, after `network-online.target`) and `duckdns.timer` (`OnBootSec=1min`,
`OnUnitActiveSec=5min`). Not part of `relay-deploy.sh`; a candidate for it if DuckDNS stays the choice.

## The creation token in the app
- The relay refuses a new wallet without it (403 `createToken`, relay log `put-d 403`); the health check does not test it, so a wrong
  token only shows on the first sync. The log never contains the token.
- The token on the Pi is 32 base64 characters (`+` and `/` included), which is hard to type on a phone. The token field was obscured
  with no way to see it: it now has an eye icon (`relayCreateTokenReveal`), and Settings › Sync has ONE Save button (checks the relay,
  then saves address and token, then says what failed). See the commit "Sync panel: one Save, token under the address, reveal icon".
- Typing a long secret from the laptop with `adb shell input text` works for `[A-Za-z0-9+/]`; check which field has focus first.

## State at the end of the session
- Relay stopped and disabled on the Pi (`bw-relay`, `caddy`, `duckdns.timer`: `systemctl disable --now`); data kept in
  `/var/lib/bw-relay`; router forward left in place (owner removes it if wanted); DuckDNS name still exists.
- To start again: `ssh <user>@<pi> 'sudo systemctl enable --now bw-relay caddy duckdns.timer'`, then
  `tools/relay-deploy.sh native-status <user>@<pi>`.
- Open: rotate the DuckDNS token (it appeared in a chat transcript) and rewrite `/etc/duckdns.token`.
