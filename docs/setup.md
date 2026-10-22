# Setting up Budget Wallet

## 1. Install the app

**Android:** open the latest successful run of the `ci` workflow on GitHub (Actions tab), download `budget-wallet-android`, unzip, open `app-release.apk` on the phone and allow installing from this source.

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
2. In the app: Plan › Sync → **Relay address**, enter `http://<server>:8787` (or the VPN name), tap **Save address**, then **Test connection** and **Sync now**.
3. Each additional device: **Join my wallet from another device**, enter the key and the same address.

The app syncs when it opens, every 2 minutes while open and a few seconds after each change. Requests to the relay are signed
with a key derived from the wallet key and the relay keeps only the public half, so a captured request cannot be replayed and plain
`http://` on the home network is safe for your data. A VPN (Tailscale or WireGuard) is still recommended: it hides who syncs, when
and how much, and lets phones sync away from home.

Backups: Plan › Backup → **Back up now** saves an encrypted `.bwb` file through the save dialog; restore works only into an empty wallet.

## 4. Bring in your history

Plan → **Choose files** and select the PBZ (.xls) and Revolut (.xlsx/.csv) exports. Re-importing the same period is safe.

## 5. Relay on the home server

The relay is a small server that stores the encrypted sync files for your devices; it cannot read them. It is one container
(image built from `dev/Containerfile.relay`), listens on port 8787 and keeps everything in one data folder.

**Build and run once by hand** (any machine with Podman; replace the placeholders):

```sh
git clone <repo-url> && cd <repo>
podman build -f dev/Containerfile.relay -t localhost/budget-wallet-relay .
mkdir -p /srv/budget-wallet-relay
podman run -d --name bw-relay --userns=keep-id:uid=10001,gid=10001 -p 8787:8787 \
  -v /srv/budget-wallet-relay:/data:z \
  -e BW_RELAY_ORIGINS=http://<web-app-host>:8080 localhost/budget-wallet-relay
curl -s http://<server>:8787/v1/health        # {"api":1}
```

`:z` on the volume is needed with SELinux (Fedora and friends). `BW_RELAY_ORIGINS` is a comma separated list of web-app
origins allowed to call the relay (browser CORS); the Android and Linux apps do not need it. Other settings:
`BW_RELAY_MAX_WALLETS` (default 16), `BW_RELAY_MAX_BYTES` per wallet (default 1 GiB), `BW_RELAY_PORT`.

**Run it as a service (Podman quadlet).** Save as `~/.config/containers/systemd/bw-relay.container` (rootless, user `systemd`):

```ini
[Unit]
Description=Budget Wallet relay

[Container]
Image=localhost/budget-wallet-relay:latest
ContainerName=bw-relay
PublishPort=8787:8787
Volume=/srv/budget-wallet-relay:/data:z
Environment=BW_RELAY_ORIGINS=http://<web-app-host>:8080
UserNS=keep-id:uid=10001,gid=10001

[Service]
Restart=always

[Install]
WantedBy=default.target
```

Then `systemctl --user daemon-reload && systemctl --user start bw-relay` and, so it runs without a login,
`loginctl enable-linger <user>`. Tag the image you built as `latest` (`podman tag <image> localhost/budget-wallet-relay:latest`).

**Reaching it.** Inside the home network use `http://<server-lan-name>:8787`. Away from home, put the server and your phone on
Tailscale or WireGuard and use the VPN name or address; do not forward the port on the router. Plain HTTP is accepted (the
files are encrypted before they leave the device, and the VPN encrypts the link). If you want HTTPS anyway, Tailscale can
front the port: `tailscale serve --bg --https=443 http://127.0.0.1:8787`, then use the `https://<machine>.<tailnet>.ts.net` address.

**Backup.** Stop the container (or snapshot the filesystem) and copy the data folder (`/srv/budget-wallet-relay`). It holds only
sealed files and the wallets' token hashes, but losing it means every device must upload its history again; keep it in your
normal backup. Restoring is copying the folder back.

**Upgrading.** `git pull`, rebuild the image (`podman build …` as above), tag it `latest`, then
`systemctl --user restart bw-relay` (or `podman rm -f bw-relay` and run again). The data folder is untouched.

**Local development.** `tools/relay.sh start|stop|status|logs|reset` runs the same image on `127.0.0.1:8787` with data in
`~/.local/share/budget-wallet/relay/`, allowing the local web build's origins.
