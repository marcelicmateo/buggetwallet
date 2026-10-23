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

Backups: Plan › Backup → **Back up now** saves an encrypted `.bwb` file through the save dialog; restore works only into an empty wallet.

## 4. Bring in your history

Plan → **Choose files** and select the PBZ (.xls) and Revolut (.xlsx/.csv) exports. Re-importing the same period is safe.

## 5. Relay on the home server

The relay is a small server that stores the encrypted sync files for your devices; it cannot read them. It is one container
(image built from `dev/Containerfile.relay`) that listens on port 8787 inside a private Podman network and keeps everything in one data
folder. **A second container, Caddy, is the only thing reachable from the internet**: it gets a Let's Encrypt certificate for your
name, speaks HTTPS and passes the traffic on to the relay. The phone needs no VPN and syncs at home and away. The relay port is
never exposed; only port 443 (and optionally 80, see 5.2) is forwarded on the router. The files for all of this are in `relay/deploy/`.

```
phone / laptop --https :443--> router --> Caddy (bw-relay-caddy) --private network--> relay (bw-relay) --> /srv/budget-wallet-relay
```

### 5.1 A name for the server
You need a name that points at your home router and that you control. Either:
- a domain of your own with an `A` (and `AAAA`) record such as `wallet.example.org` pointing at your home IP, or
- a dynamic-DNS name (DuckDNS, your router's own service and similar) if your home IP changes.

Put the name only in your local `bw-relay.env` (5.3), never in the repository. The address you give the app is `https://` plus that name.

### 5.2 Router and firewall
Forward **TCP 443** to the server. For the certificate, Let's Encrypt must reach the server once and then about every 60 days:
- the simple way: also forward **TCP 80**. Caddy answers it with a redirect to HTTPS and uses it for the HTTP challenge, or
- 443 only: leave 80 unforwarded. Caddy then gets the certificate with the TLS-ALPN challenge on 443 alone (the redirect just is not
  reachable from outside).

Do **not** forward 8787 or any other port. The relay container publishes no port at all. Rootless Podman cannot bind ports below
1024 by default: either `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80` (and put it in `/etc/sysctl.d/`), or change
the two `PublishPort=` lines in `bw-relay-caddy.container` to `8080:80` / `8443:443` and forward external 80/443 to those on the router.

### 5.3 Build the image and install the files
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

Edit `~/.config/budget-wallet-relay/bw-relay.env` (read by both containers):
- `BW_RELAY_DOMAIN=<your name from 5.1>`: the one place the name is set (the file holds the placeholder `wallet.example.org`). Caddy
  gets the certificate for it, and the relay uses it as its public host (the host that signed requests must be addressed to).
- `BW_RELAY_CREATE_TOKEN=<a long random secret>` (make one with `openssl rand -base64 24`), and keep `BW_RELAY_TRUST_PROXY=1`.
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
or 443 (and 80) are not forwarded.

### 5.4 What is protected
- **Create token.** The relay refuses to create a wallet unless the request carries the token (403 otherwise). Only the device that
  creates the wallet on the relay needs it (the app asks once); devices that join an existing wallet and every later sync do not.
  Without `BW_RELAY_CREATE_TOKEN` anyone who finds the address could fill the relay with wallets: that is development mode only, and
  the relay says so in its log at start (`wallet creation is OPEN`). The token is a shared secret between you and the relay, not part
  of the wallet key.
- **Limits.** The relay rate-limits per client address (Caddy passes the real one in `X-Forwarded-For`; the relay trusts that only
  because of `BW_RELAY_TRUST_PROXY=1`, which must never be set when the relay is reachable directly), caps request bodies (Caddy
  64 MiB, the same as the relay) and keeps no access log.
- **Container.** Read-only root file system except `/data`, all capabilities dropped, no new privileges, a non-root user.
- **Backup.** Stop the relay (or snapshot the file system) and copy `/srv/budget-wallet-relay`. It holds only sealed files and the
  wallets' public keys, but losing it means every device must upload its history again; keep it in your normal backup. Restoring is
  copying the folder back. Keep the Caddy volume `bw-caddy-data` too if you want to avoid issuing the certificate again.

### 5.5 Upgrading
Pull the repository, rebuild the image (`podman build --format docker …` as in 5.3), then `systemctl --user restart bw-relay`
(Caddy keeps running and retries the relay while it restarts). The data folder is untouched. A newer Caddy:
`podman pull docker.io/library/caddy:2 && systemctl --user restart bw-relay-caddy`.

### 5.6 Plain HTTP on the home network (development and try-outs only)
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
