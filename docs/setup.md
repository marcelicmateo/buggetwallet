# Setting up Budget Wallet

## 1. Install the app

**Android:** open the latest successful run of the `ci` workflow on GitHub (Actions tab), download `budget-wallet-android`, unzip, open `app-release.apk` on the phone and allow installing from this source. The published APK is for 64-bit Android phones only (arm64-v8a; all phones since about 2017), about 44 MB. 32-bit-only phones cannot install it. A local `tools/build.sh apk` also includes x86_64 (about 86 MB) so it installs on the emulator; `BW_APK_ABIS=arm64 tools/build.sh apk` builds the phone-only one.

**Linux:** download `budget-wallet-linux`, unzip, run `budget_wallet`.

**Windows / macOS / iPhone** (parked, not maintained): build from source on that machine:

```
cd app
flutter pub get
flutter run --release          # or: flutter build windows / macos / ipa
```

iPhone builds need Xcode and an Apple ID (free accounts can install for 7 days at a time).

## 2. First device

Open the app → **Start a new wallet**. Then Plan → **Show wallet key** and save the key (`BW1-…`) in a password manager.

**The key is the only way back to your data.** The local database and the copies on the relay are encrypted with it; if you lose it
(and every device that holds it), nothing can be read again, by you or by anyone else.

## 3. Sync through the relay

Devices sync through a small server you run yourself (see §5). It stores only encrypted files and cannot read them.

1. Start the relay (§5; for a try-out on one computer `tools/relay.sh start`).
2. In the app: Plan › Sync → **Relay address**, enter `https://<your relay name>` (§5; `http://<server>:8787` only for a try-out on your home network), tap **Save address**, then **Test connection** and **Sync now**.
3. Each additional device: **Join my wallet from another device**, enter the key and the same address. A relay set up as in §5 also asks
   for its **create token** once, when the wallet is first created on it (not for devices that join an existing wallet).

The app syncs when it opens, every 5 minutes while open and a few seconds after each change. Requests to the relay are signed
with a key derived from the wallet key and the relay keeps only the public half; everything it stores is encrypted before it
leaves the device. Over `https://` nobody on the way can read or change the traffic, and the phone needs no VPN: it syncs
at home and away. On plain `http://` (a try-out on the home network only) someone on the network can see who syncs, when and
how much, and can block or delay sync; they still cannot read your data or forge a change.

**Sync the local web build.** The web build (`tools/build.sh web`, `tools/web.sh serve`, opened at `http://127.0.0.1:8080`) syncs through the
same relay as the phone. A browser may call a relay only from an allowed origin: start the relay with `--origin http://127.0.0.1:8080`
(`tools/relay.sh start` already allows it) and enter the relay address in Settings › Sync; a relay on another machine must be an
`https://` address. Join with the wallet key and a passphrase for this browser (it wraps the key in the browser's storage).

Backups: Plan › Backup → **Back up now** saves an encrypted `.bwb` file through the save dialog; restore works only into an empty wallet.

## 4. Bring in your history

Plan → **Choose files** and select the PBZ (.xls) and Revolut (.xlsx/.csv) exports. Re-importing the same period is safe.

## 5. Relay on a Raspberry Pi at home (native)

The relay is a small server that stores the encrypted sync files for your devices; it cannot read them. On a Raspberry Pi it runs as a
**native program under systemd** (no containers, one binary of about 7 MB) as its own system user, listening on `127.0.0.1:8787` only.
**Caddy** (installed from the operating system's package) is the only thing reachable from the internet: it gets a Let's Encrypt
certificate for your name, speaks HTTPS and passes the traffic on. The phone needs no VPN and syncs at home and away. Only ports 443
(and 80, see 5.3) are forwarded on the router. Files: `relay/deploy/native/` (its README lists what goes where); the install is one
command from the laptop.

```
phone / laptop --https :443--> router --> Pi: Caddy --127.0.0.1:8787--> bw-relay.service --> /var/lib/bw-relay (or your SSD)
```

Alternative: a rented server instead of one at home (§6, the same binary, units and Caddy). Plain HTTP for try-outs on one computer: 5.7.

### 5.1 Open choices (yours; nothing below depends on them being decided today)
| Choice | Options | Notes |
|---|---|---|
| Operating system on the Pi | Debian-family (Raspberry Pi OS Lite 64-bit, Debian, Ubuntu Server) or Fedora (aarch64) | The install script detects `apt` or `dnf` and the firewall (firewalld or ufw). 64-bit only: the binary is `linux-arm64`. |
| Public name (`<your-domain>`) | a domain of your own, or a dynamic-DNS name (DuckDNS, your router's service) | Must point at your home IP (5.3). Lives only in `/etc/bw-relay/bw-relay.env` on the Pi, never in git. |
| Router | forward TCP 443, and 80 if you can | 5.3 |
| Storage | the SD card (default) or an SSD on USB | An SSD lasts far longer than an SD card under constant writes: 5.4. |

### 5.2 Prepare the Pi
1. Flash a 64-bit OS (Raspberry Pi Imager), enable SSH with your laptop's public key (no password login), set a host name.
2. Give the Pi a fixed address on your network (a DHCP reservation in the router) so the port forward keeps working.
3. Update it once (`sudo apt update && sudo apt full-upgrade`, or `sudo dnf upgrade`), and reboot if the kernel changed.
4. The install uses `sudo` without a prompt (it cannot type a password): Raspberry Pi OS has that by default; elsewhere add
   `echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/90-install`. **Keep it:** `native-upgrade`, `native-backup` and
   `native-status` use sudo the same way (they install files, stop and start services, read the data folder). It is full root for that
   login, so use an ssh key only (no password login). To lock down between uses, delete the file and add it again before the next one.
5. On the laptop add an ssh alias for it in `~/.ssh/config` (`Host <pi-host>`, `HostName`, `User`), or use `user@address`.

### 5.3 A name and the router
You need a name that points at your home router: an `A` (and `AAAA`) record of a domain of your own, or a dynamic-DNS name if your
home IP changes. Put it only in the install command (5.4); the address you give the app is `https://<your-domain>`.

On the router forward **TCP 443** to the Pi. For the certificate, Let's Encrypt must reach the Pi once and then about every 60 days:
also forward **TCP 80** (the simple way: Caddy redirects to HTTPS and uses it for the challenge), or leave 80 unforwarded and Caddy
uses the TLS-ALPN challenge on 443 alone. Do **not** forward 8787 or anything else. The install opens 80 and 443 in the Pi's own
firewall when it finds firewalld or ufw active (otherwise it says so: allow them yourself in nftables or iptables).

### 5.4 Install (from the laptop)
```sh
tools/build.sh relay-bin arm64          # -> dist/relay/relay-linux-arm64 (+ .sha256), cross-compiled in the build container
tools/relay-deploy.sh --dry-run native-install <pi-host> <your-domain>     # prints every command and remote script, changes nothing
tools/relay-deploy.sh native-install <pi-host> <your-domain>               # data in /var/lib/bw-relay
tools/relay-deploy.sh native-install <pi-host> <your-domain> --data-dir /mnt/ssd/bw-relay    # data on an SSD (below)
```
It checks the binary's checksum on the laptop and again on the Pi, installs Caddy from the OS packages, creates the `bw-relay` system
user, places the hardened unit and the Caddyfile, writes `/etc/bw-relay/bw-relay.env` with your name, enables `bw-relay` and `caddy`
and asks the relay for its health. The wallet-creation token is made **on the Pi** (a root-only file, 0600, handed to the relay as a
systemd credential), shown once on your terminal and never written on the laptop: save it in your password manager, the app asks for
it when it creates the wallet on this relay (the Pi prints it the moment it is written, so a later failure does not lose it; later: `sudo cat /etc/bw-relay/create-token` on the Pi). Running the command again is safe (the token and your edits to the env file are kept).

Check: `tools/relay-deploy.sh native-status <pi-host>` (unit states, local health, public health). From outside your network (mobile
data) `curl -sI https://<your-domain>/v2/health` should answer `200` once the certificate is issued (first start: a few seconds); many
routers do not loop a forwarded port back to the LAN, so a failed check from inside the network is not a verdict. If the certificate
is not issued: `journalctl -u caddy` on the Pi; usual causes are the name not yet pointing at the router, the forward, or the firewall.

### 5.5 An SSD for the data (optional, recommended)
The relay writes a little with every sync. Put the data on an SSD on USB: format it ext4, mount it by UUID in `/etc/fstab`
(`UUID=<uuid> /mnt/ssd ext4 defaults,nofail 0 2`, `sudo mount -a`), then install (or run again) with `--data-dir /mnt/ssd/bw-relay`.
The install creates the folder for the relay user and adds a systemd drop-in that points the relay at it (the unit's other
restrictions stay; only that folder is writable). Moving later: `native-backup`, then a new install with the new `--data-dir`, then
copy the files into it as root and `sudo chown -R bw-relay: <dir>`.

### 5.6 What is protected, upgrading, backup
- **Create token.** Wallet creation is refused (403) without it; only the device that creates the wallet needs it. A
  shared secret between you and the relay, not part of the wallet key.
- **Limits.** Per-address rate limit (Caddy sets `X-Forwarded-For`; the relay trusts it only because it listens on 127.0.0.1),
  64 MiB request bodies, no access log, Caddy's error log off.
- **Service hardening.** Own user without login, `NoNewPrivileges`, read-only system, private `/tmp`, only the data folder writable, no
  capabilities, a system-call filter, 384 MB memory cap. `systemd-analyze security bw-relay` on the Pi shows the exposure score.
- **Upgrade.** `tools/build.sh relay-bin arm64 && tools/relay-deploy.sh native-upgrade <pi-host>` replaces the binary and units,
  keeps env, token and data (the old binary stays as `/usr/local/bin/bw-relay.prev`; if the new one does not start and answer health it is
  put back and the command fails), restarts the relay (Caddy retries while it restarts) and checks health. A changed Caddyfile is saved
  once as `/etc/caddy/Caddyfile.pre-bw-relay`. OS updates: the OS's own
  mechanism (`unattended-upgrades` or `dnf-automatic`), your choice.
- **Backup.** `tools/relay-deploy.sh native-backup <pi-host> [folder]` stops the relay, copies the data folder to the laptop and
  starts it again (a failed copy still restarts it). The folder holds only sealed files and the wallets' public keys, but losing it
  means every device must upload its history again; keep it in your normal backup. Restore = copy back as root and `chown -R bw-relay:`.
- **By hand.** Everything `native-install` does is listed in `relay/deploy/native/README.md`.

### 5.7 Plain HTTP on the home network (development and try-outs only)
`tools/relay.sh start` runs the same image on `127.0.0.1:8787` (data in `~/.local/share/budget-wallet/relay/`, read-only root file
system, wallet creation open, the local web build's origins allowed): the way to try the app on one computer or the emulator
(`http://10.0.2.2:8787`). For a phone on the same Wi-Fi, run the image by hand with a published port:

```sh
podman run -d --name bw-relay-lan --read-only --userns=keep-id:uid=10001,gid=10001 -p 8787:8787 \
  -v /srv/budget-wallet-relay-lan:/data:z localhost/budget-wallet-relay:latest
```

and use `http://<server-lan-name>:8787` in the app. The app refuses `http://` to a public host: anything on the internet must be
`https://`. Never forward this port on the router and do not keep real wallets on an open plain-HTTP relay; try things out, then
switch to the setup in 5.4 and point every device at the new address.

## 6. Relay on a rented server (Hetzner Cloud)

The same native relay as §5 (binary + systemd + Caddy, files in `relay/deploy/native/`) on a small server in a data centre instead of
at home: no router, no port forward, no dynamic DNS, and sync keeps working when the home internet or power is down. The server only
ever holds sealed files and the wallets' public keys, so the host can see sizes, times and client addresses but nothing of the wallet.

```
phone / laptop --https :443--> Hetzner server: Caddy --127.0.0.1:8787--> bw-relay.service --> /var/lib/bw-relay
```

### 6.1 Create the server
In the Hetzner Cloud console (console.hetzner.cloud), new project, **Add server**:
- **Location:** an EU one (Falkenstein, Nuremberg or Helsinki).
- **Image:** Debian 12 or Ubuntu 24.04 (apt) or Fedora (dnf): the install detects both.
- **Type:** the smallest plan is plenty. The binary must match the CPU: `tools/build.sh relay-bin arm64` for ARM (CAX),
  `tools/build.sh relay-bin x64` for the shared x86 plans (set `BW_NATIVE_ARCH=x64` for `relay-deploy.sh`).
- **Networking:** public IPv4 and IPv6 (IPv4 costs a little extra but phones on mobile data often have no IPv6).
- **SSH key:** add your laptop's public key (`~/.ssh/id_ed25519.pub`); no root password.
- **Firewall:** create one with inbound **TCP 22**, **TCP 80** and **TCP 443** only (22 limited to your home IP if it is fixed) and
  attach it. Nothing else, never 8787.
- **Backups:** optional (+20 % of the server price, daily, 7 kept); see 6.5.

### 6.2 First login: a user, updates
```sh
ssh root@<server IP>
# on the server, as root:
useradd -m -G sudo bw && mkdir -p /home/bw/.ssh && cp ~/.ssh/authorized_keys /home/bw/.ssh/ \
  && chown -R bw: /home/bw/.ssh && chmod 700 /home/bw/.ssh && echo 'bw ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/bw
# (Fedora: -G wheel instead of -G sudo)
printf 'PermitRootLogin no\nPasswordAuthentication no\n' > /etc/ssh/sshd_config.d/10-bw.conf && systemctl restart ssh   # Fedora: sshd
apt update && apt -y upgrade && apt -y install rsync unattended-upgrades      # Fedora: dnf -y upgrade && dnf -y install rsync dnf-automatic
```
Before closing root login, open a second terminal and check that `ssh bw@<server IP> sudo true` works. From now on log in as
`ssh bw@<server IP>` (or add an ssh alias).

### 6.3 Name and install
1. **DNS:** at your domain's DNS provider, an `A` record (and `AAAA` with the server's IPv6) for the name, e.g. `wallet.example.org`,
   pointing at the server. Check with `dig +short wallet.example.org` before the install, or the first certificate attempt fails
   (Caddy retries on its own).
2. **Install**, from the laptop, exactly as in 5.4 with the server as the host (add `--dry-run` first to see every command):
   ```sh
   tools/build.sh relay-bin arm64            # or x64, see 6.1
   tools/relay-deploy.sh native-install bw@<server IP> <your name>
   ```
   It shows the creation token once: save it. Then `curl -sI https://<your name>/v2/health` should answer `HTTP/2 200`.

In the app the relay address is `https://<your name>` (Plan › Sync › Test connection).

### 6.4 Upgrading
As in 5.6: `tools/build.sh relay-bin arm64 && tools/relay-deploy.sh native-upgrade bw@<server IP>`. The system updates itself
(`unattended-upgrades` / `dnf-automatic`); reboot now and then with `sudo systemctl reboot` (the services start again by themselves).

### 6.5 Backup
Either turn on Hetzner's backups (6.1; restore = the whole server as it was) or copy the data folder to the laptop now and then
(it stops the relay for the copy and starts it again):

```sh
tools/relay-deploy.sh native-backup bw@<server IP> ~/backups/budget-wallet-relay
```

The backup folder is an exact copy (rsync `--delete`) of the server, so use a folder that holds only this backup. A copy older than the devices is safe: they notice the relay went back and upload what it is missing (Stage H). The devices' own
`.bwb` backups stay the real backup of the wallet.

### 6.6 Moving from the home server
1. Take a `native-backup` of the home relay (5.6) and copy it into the new server's data folder after the install (5.5, as root, then
   `sudo chown -R bw-relay: <dir>`), with **the same name** and the same creation token.
2. Point the name's DNS records at the new server. With the same name nothing changes in the app: the signed host stays the same
   and devices carry on once DNS has switched (up to the record's TTL).
3. Remove the router forward for 80/443 at home and stop the home relay (`sudo systemctl disable --now bw-relay caddy`).

With a new name instead, change the relay address in Plan › Sync on every device.
