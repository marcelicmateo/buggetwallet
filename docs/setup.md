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

Alternatives: containers on a home server (5.7), or a rented server instead of one at home (§6, same files as 5.7).

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
- **Create token.** As in 5.7.4: wallet creation is refused (403) without it; only the device that creates the wallet needs it. A
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

### 5.7 Alternative: containers on a home server (Podman)

The relay is one container (image built from `dev/Containerfile.relay`) that listens on port 8787 inside a private Podman network and
keeps everything in one data folder. **A second container, Caddy, is the only thing reachable from the internet**: it gets a Let's
Encrypt certificate for your name, speaks HTTPS and passes the traffic on to the relay. The relay port is never exposed; only port
443 (and optionally 80, see 5.7.2) is forwarded on the router. The files are in `relay/deploy/`.

```
phone / laptop --https :443--> router --> Caddy (bw-relay-caddy) --private network--> relay (bw-relay) --> /srv/budget-wallet-relay
```

#### 5.7.1 A name for the server
You need a name that points at your home router and that you control. Either:
- a domain of your own with an `A` (and `AAAA`) record such as `wallet.example.org` pointing at your home IP, or
- a dynamic-DNS name (DuckDNS, your router's own service and similar) if your home IP changes.

Put the name only in your local `bw-relay.env` (5.7.3), never in the repository. The address you give the app is `https://` plus that name.

#### 5.7.2 Router and firewall
Forward **TCP 443** to the server. For the certificate, Let's Encrypt must reach the server once and then about every 60 days:
- the simple way: also forward **TCP 80**. Caddy answers it with a redirect to HTTPS and uses it for the HTTP challenge, or
- 443 only: leave 80 unforwarded. Caddy then gets the certificate with the TLS-ALPN challenge on 443 alone (the redirect just is not
  reachable from outside).

**Firewall on the server itself.** On Fedora and other firewalld systems the host drops incoming 80/443 until you allow them (the
router forward alone is not enough):

```sh
sudo firewall-cmd --permanent --add-service=http --add-service=https && sudo firewall-cmd --reload
```

(With the high-port variant below use `--add-port=8080/tcp --add-port=8443/tcp` instead; with 443 only, `--add-service=https` alone is
enough.) Check with `sudo firewall-cmd --list-services`.

Do **not** forward 8787 or any other port. The relay container publishes no port at all. Rootless Podman cannot bind ports below
1024 by default: either `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80` (and put it in `/etc/sysctl.d/`), or change
the two `PublishPort=` lines in `bw-relay-caddy.container` to `8080:80` / `8443:443` and forward external 80/443 to those on the router.

#### 5.7.3 Build the image and install the files
Any machine with Podman (rootless); replace the placeholders.

```sh
# in a checkout of this repository:
podman build --format docker -f dev/Containerfile.relay -t localhost/budget-wallet-relay:latest .
sudo mkdir -p /srv/budget-wallet-relay && sudo chown "$USER": /srv/budget-wallet-relay

mkdir -p ~/.config/containers/systemd ~/.config/budget-wallet-relay
cp relay/deploy/bw-relay.network relay/deploy/bw-relay.container relay/deploy/bw-relay-caddy.container ~/.config/containers/systemd/
cp relay/deploy/Caddyfile ~/.config/budget-wallet-relay/Caddyfile
cp relay/deploy/bw-relay.env.example ~/.config/budget-wallet-relay/bw-relay.env
chmod 600 ~/.config/budget-wallet-relay/bw-relay.env
```

Create the wallet-creation token as a Podman secret (it is mounted into the relay container only, not into Caddy). The command
prints the token once: save it in your password manager, the app asks for it when it creates the wallet on this relay.

```sh
token=$(openssl rand -base64 24) && printf %s "$token" | podman secret create bw-relay-create-token - && echo "$token"
```

Edit `~/.config/budget-wallet-relay/bw-relay.env` (read by both containers):
- `BW_RELAY_DOMAIN=<your name from 5.7.1>`: the one place the name is set (the file holds the placeholder `wallet.example.org`). Caddy
  gets the certificate for it, and the relay uses it as its public host (the host that signed requests must be addressed to).
- keep `BW_RELAY_TRUST_PROXY=1`. The token is not in this file (the secret above).
  Optional: `BW_RELAY_MAX_WALLETS`, `BW_RELAY_MAX_BYTES`.

`--format docker` keeps the image's HEALTHCHECK (the quadlet sets the same check anyway). Then start both (Caddy needs the relay)
and, so they run without a login, enable lingering:

```sh
systemctl --user daemon-reload
systemctl --user start bw-relay-caddy      # starts bw-relay-network and bw-relay first
loginctl enable-linger "$USER"
```

From now on they start with the user session (`WantedBy=default.target`). Check:

```sh
systemctl --user status bw-relay bw-relay-caddy
podman healthcheck run bw-relay                     # exit 0 = healthy
curl -sI https://<your name>/v2/health             # HTTP/2 200 once the certificate is issued (first start: a few seconds)
```

If the certificate is not issued, read `journalctl --user -u bw-relay-caddy`: usually the name does not point at the router yet,
or 443 (and 80) are not forwarded on the router, or the server's firewall blocks them (`sudo firewall-cmd --list-services` should
list `http` and `https`; see 5.7.2). If `bw-relay` does not start with "no secret with name", create the token secret first (5.7.3). Test
from outside your network (mobile data), not from inside it: many routers do not loop a forwarded port back to the LAN.

#### 5.7.4 What is protected
- **Create token.** The relay refuses to create a wallet unless the request carries the token (403 otherwise). Only the device that
  creates the wallet on the relay needs it (the app asks once); devices that join an existing wallet and every later sync do not.
  The token is a Podman secret (`bw-relay-create-token`), visible only inside the relay container. Without it anyone who finds the
  address could fill the relay with wallets: that is development mode only, and the relay says so in its log at start
  (`wallet creation is OPEN`); the template values `CHANGE_ME` and `replace-with-a-long-random-token` are refused as a token. The token is a shared secret between you and the relay, not part
  of the wallet key.
- **Limits.** The relay rate-limits per client address (Caddy passes the real one in `X-Forwarded-For`; the relay trusts that only
  because of `BW_RELAY_TRUST_PROXY=1`, which must never be set when the relay is reachable directly), caps request bodies (Caddy
  64 MiB, the same as the relay) and keeps no access log; Caddy's error log (which would hold the request, client address and
  headers on a 502) is switched off.
- **Container.** Read-only root file system except `/data`, all capabilities dropped, no new privileges, a non-root user.
- **Backup.** Stop the relay (or snapshot the file system) and copy `/srv/budget-wallet-relay`. It holds only sealed files and the
  wallets' public keys, but losing it means every device must upload its history again; keep it in your normal backup. Restoring is
  copying the folder back. Keep the Caddy volume `bw-caddy-data` too if you want to avoid issuing the certificate again.

#### 5.7.5 Upgrading
Pull the repository, rebuild the image (`podman build --format docker …` as in 5.7.3), then `systemctl --user restart bw-relay`
(Caddy keeps running and retries the relay while it restarts). The data folder is untouched. A newer Caddy:
`podman pull docker.io/library/caddy:2 && systemctl --user restart bw-relay-caddy`.

#### 5.7.6 Plain HTTP on the home network (development and try-outs only)
`tools/relay.sh start` runs the same image on `127.0.0.1:8787` (data in `~/.local/share/budget-wallet/relay/`, read-only root file
system, wallet creation open, the local web build's origins allowed): the way to try the app on one computer or the emulator
(`http://10.0.2.2:8787`). For a phone on the same Wi-Fi, run the image by hand with a published port:

```sh
podman run -d --name bw-relay-lan --read-only --userns=keep-id:uid=10001,gid=10001 -p 8787:8787 \
  -v /srv/budget-wallet-relay-lan:/data:z localhost/budget-wallet-relay:latest
```

and use `http://<server-lan-name>:8787` in the app. The app refuses `http://` to a public host: anything on the internet must be
`https://`. Never forward this port on the router and do not keep real wallets on an open plain-HTTP relay; try things out, then
switch to the setup above and point every device at the new address.

## 6. Relay on a rented server (Hetzner Cloud)

Same containers as §5.7, on a small server in a data centre instead of at home: no router, no port forward, no dynamic DNS, and
sync keeps working when the home internet or power is down. The server only ever holds sealed files and the wallets' public keys
(5.7.4), so the host can see sizes, times and client addresses but nothing of the wallet.

```
phone / laptop --https :443--> Hetzner server: Caddy (bw-relay-caddy) --private network--> relay (bw-relay) --> /srv/budget-wallet-relay
```

### Quick way
After 6.1 (the server exists, your ssh key is on it) and the DNS record from 6.3 step 1, `tools/relay-deploy.sh` does 6.2 to 6.5
from the laptop (add `--dry-run` to see the commands first):

```sh
tools/relay-deploy.sh bootstrap <server IP>               # 6.2, as root, once
tools/relay-deploy.sh install <server IP> <your name>     # 6.3 and 5.7.3; shows the creation token once: save it
tools/relay-deploy.sh upgrade <server IP>                 # 6.4
tools/relay-deploy.sh backup <server IP> [folder]         # 6.5
tools/relay-deploy.sh status <server IP>
```

The steps below are the reference for what it does.

### 6.1 Create the server
In the Hetzner Cloud console (console.hetzner.cloud), new project, **Add server**:
- **Location:** an EU one (Falkenstein, Nuremberg or Helsinki).
- **Image:** Fedora (newest offered; the same Podman and firewalld as the laptop) or Ubuntu 24.04 (Podman 4.9, quadlets work).
- **Type:** the smallest **shared x86** plan (2 vCPU, 4 GB at the time of writing) is plenty. Pick x86, not ARM (CAX): the image is
  built on the laptop (6.3), and an x86 image does not run on ARM.
- **Networking:** public IPv4 and IPv6 (IPv4 costs a little extra but phones on mobile data often have no IPv6).
- **SSH key:** add your laptop's public key (`~/.ssh/id_ed25519.pub`); no root password.
- **Firewall:** create one with inbound **TCP 22**, **TCP 80** and **TCP 443** only (22 limited to your home IP if it is fixed) and
  attach it. Nothing else, never 8787.
- **Backups:** optional (+20 % of the server price, daily, 7 kept); see 6.5.

### 6.2 First login: a user, updates, ports
```sh
ssh root@<server IP>
# on the server, as root:
useradd -m -G wheel bw && mkdir -p /home/bw/.ssh && cp ~/.ssh/authorized_keys /home/bw/.ssh/ \
  && chown -R bw: /home/bw/.ssh && chmod 700 /home/bw/.ssh && echo 'bw ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/bw
# (Ubuntu: -G sudo instead of -G wheel)
printf 'PermitRootLogin no\nPasswordAuthentication no\n' > /etc/ssh/sshd_config.d/10-bw.conf && systemctl restart sshd
dnf -y upgrade && dnf -y install podman rsync dnf-automatic && printf "[commands]\napply_updates = yes\n" > /etc/dnf/automatic.conf && systemctl enable --now dnf-automatic.timer
# (Ubuntu: apt update && apt -y upgrade && apt -y install podman unattended-upgrades)
echo 'net.ipv4.ip_unprivileged_port_start=80' > /etc/sysctl.d/90-bw-relay.conf && sysctl --system
```

(On Fedora with dnf5 the timer is `dnf-automatic.timer` or `dnf5-automatic.timer`; there is no `-install` one, hence the config line.
Before closing root login, open a second terminal and check that `ssh bw@<server IP> sudo true` works.)
The last line lets rootless Caddy bind 80 and 443 (5.7.2). If firewalld is running on the server (`systemctl is-active firewalld`),
also allow the ports there: `firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload`. From now on
log in as `ssh bw@<server IP>`.

### 6.3 Name, image and files
1. **DNS:** at your domain's DNS provider, an `A` record (and `AAAA` with the server's IPv6) for the name, e.g. `wallet.example.org`,
   pointing at the server. Check with `dig +short wallet.example.org` before starting Caddy, or the first certificate attempt fails
   (Caddy retries on its own).
2. **Image:** the repository is private, so build on the laptop and copy the image over (no checkout on the server):
   ```sh
   # on the laptop, in a checkout of this repository:
   podman build --format docker -f dev/Containerfile.relay -t localhost/budget-wallet-relay:latest .
   podman save localhost/budget-wallet-relay:latest | ssh bw@<server IP> podman load
   scp relay/deploy/bw-relay.network relay/deploy/bw-relay.container relay/deploy/bw-relay-caddy.container \
       relay/deploy/Caddyfile relay/deploy/bw-relay.env.example bw@<server IP>:
   ```
3. **On the server** (as `bw`):
   ```sh
   sudo mkdir -p /srv/budget-wallet-relay && sudo chown bw: /srv/budget-wallet-relay
   mkdir -p ~/.config/containers/systemd ~/.config/budget-wallet-relay
   mv bw-relay.network bw-relay.container bw-relay-caddy.container ~/.config/containers/systemd/
   mv Caddyfile ~/.config/budget-wallet-relay/Caddyfile
   mv bw-relay.env.example ~/.config/budget-wallet-relay/bw-relay.env && chmod 600 ~/.config/budget-wallet-relay/bw-relay.env
   ```
   Then exactly as in 5.7.3 from "Create the wallet-creation token" on: the token secret, `BW_RELAY_DOMAIN=<your name>` in
   `bw-relay.env`, `systemctl --user daemon-reload && systemctl --user start bw-relay-caddy`, `loginctl enable-linger bw`, and the
   checks (`curl -sI https://<your name>/v2/health` from the laptop should answer `HTTP/2 200`).

In the app the relay address is `https://<your name>` (Plan › Sync › Test connection).

### 6.4 Upgrading
Relay: rebuild on the laptop and copy it again (6.3 step 2, the `podman build` and `podman save | ssh … podman load` lines), then
`ssh bw@<server IP> systemctl --user restart bw-relay` (then `systemctl --user start bw-relay-caddy`, in case it stopped with it). Caddy and system packages as in 5.7.5; the system updates itself
(`dnf-automatic` / `unattended-upgrades`), reboot now and then with `sudo systemctl reboot` (the containers start again by themselves).

### 6.5 Backup
Either turn on Hetzner's backups (6.1; restore = the whole server as it was) or copy the data folder to the laptop now and then:

```sh
ssh bw@<server IP> systemctl --user stop bw-relay
rsync -a --delete bw@<server IP>:/srv/budget-wallet-relay/ ~/backups/budget-wallet-relay/
ssh bw@<server IP> systemctl --user start bw-relay bw-relay-caddy   # stopping the relay stopped Caddy too
```

`--delete` makes the folder an exact copy of the server, so use a folder that holds only this backup. A copy older than the devices is safe: they notice the relay went back and upload what it is missing (Stage H). The devices' own
`.bwb` backups stay the real backup of the wallet.

### 6.6 Moving from the home server
1. Stop the home relay (`systemctl --user stop bw-relay-caddy bw-relay`) and copy `/srv/budget-wallet-relay` to the new server
   (`rsync -a /srv/budget-wallet-relay/ bw@<server IP>:/srv/budget-wallet-relay/`), then set up 6.3 with **the same name** and
   the same creation token.
2. Point the name's DNS records at the new server. With the same name nothing changes in the app: the signed host stays the same
   and devices carry on once DNS has switched (up to the record's TTL).
3. Remove the router forward for 80/443 at home and disable the home units
   (`rm ~/.config/containers/systemd/bw-relay*.{container,network} && systemctl --user daemon-reload`).

With a new name instead, change the relay address in Plan › Sync on every device.
