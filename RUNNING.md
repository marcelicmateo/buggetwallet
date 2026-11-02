# Running Budget Wallet (for reviewers)

How to build, test and run every part of the app from this repository. Read `docs/TECHNICAL_SPEC.md` first for what the
app is and how it is built; `docs/setup.md` is the end-user setup guide.

Everything uses synthetic data. You never need a bank account, a real export or the owner's keys.

## What you need

| Path | Needs | Good for |
|---|---|---|
| A. Podman only (recommended) | Linux host, Bash 5, GNU tools, Python 3, rootless Podman, ~15 GB disk | Tests, every build, the live demo window, the relay; no Flutter install |
| B. Your own Flutter SDK | Flutter **3.47.7** (Dart 3.13.5), plus the Android SDK for APKs and `libgtk-3-dev`, `clang`, `cmake`, `ninja-build` for Linux | Running from an IDE, debugging |

The Flutter version is pinned in `app/pubspec.yaml` (`environment: flutter:`); other versions are not tested.

## A. With Podman only

The first command builds the dev image (Flutter, Android SDK, lint tools; about 15 minutes once). Outputs land in
`dist/` (ignored by git); logs and timings in `~/.local/share/budget-wallet/` (`BW_DATA_DIR` changes it).

### Run the tests

```sh
make test            # lint + analyze + all unit and widget tests (importer, core, relay, app), ~2 min after the image
make core            # one package: importer | core | relay | app
make core T=test/bills_test.dart     # one test file
make desktop-test    # Linux integration tests under Xvfb (11 files, parallel), screenshots in dist/screens/linux/
make web-test        # browser tests (headless Chrome in the container)
make perf            # frame-time budgets in profile mode on a 20,000-row synthetic wallet
make emulator-screens      # Android emulator (needs /dev/kvm, ~2 GB download once): every tab -> dist/screens/*.png
```

Each run ends with a seconds-per-step table and per-test p50/p90/max.

### See the app

```sh
make live-start ARGS=--demo     # the Linux app in a window on your Wayland desktop, with a synthetic demo wallet
make live-shot ARGS=out.png     # screenshot of that window
make live-stop
```

`--headless` runs it under Xvfb instead (no window; use `shot`). `--fresh` starts with an empty wallet so you see
onboarding. The wallet lives in a throwaway folder under `dist/live/`.

To try importing, copy a synthetic export into `~/.local/share/budget-wallet/live-files/` (the file dialog shows it as
`/files`): bank files are in `packages/wallet_importer/test/fixtures/`, bills (PDF, XML) in
`packages/wallet_importer/test/fixtures/bills/`. `make fixtures` regenerates them.

### Web build (localhost only)

```sh
make web             # dist/web/ (wasm, JS fallback); fetches sqlite3.wasm, pinned by dev/sqlite3-wasm.sha256
make web-serve             # http://127.0.0.1:8080, loopback only
make web-stop
```

Start a new wallet with a passphrase; reload to see the unlock screen. The web build has no sync by design.

### Release builds

```sh
make linux           # dist/BudgetWallet-linux-x64.tar.gz; unpack and run ./budget_wallet
make desktop-smoke   # starts that bundle headless and checks it stays up and logs cleanly
```

**Android:** `make apk` refuses to run without a release signing key (so the owner never publishes an APK
that cannot update the installed app). Make your own throwaway key first:

```sh
BW_SIGNING_DIR=$HOME/.config/bw-review-key make signing-key
BW_SIGNING_DIR=$HOME/.config/bw-review-key make apk                       # arm64 + x86_64, ~86 MB
BW_SIGNING_DIR=$HOME/.config/bw-review-key BW_APK_ABIS=arm64 make apk     # phone-only, ~44 MB
```

Install with `adb install dist/BudgetWallet-android.apk`, or on the emulator: `make emulator-start`, then
`make emulator-install`. An APK signed with your key installs only where the owner's build is not installed.

### The relay (sync server)

```sh
make relay-start           # builds dev/Containerfile.relay, runs on http://127.0.0.1:8787, data in ~/.local/share/budget-wallet/relay/
curl -s http://127.0.0.1:8787/v2/health      # {"api":2}
make relay-logs ARGS=-f
make relay-stop            # data stays; make relay-reset deletes it
```

Then in the app: Plan › Sync → relay address `http://127.0.0.1:8787` (the Android emulator reaches the host as
`http://10.0.2.2:8787`) → **Test connection** → **Sync now**. A second instance joins with **Join my wallet from another
device**, the wallet key (Plan › Sync › Show wallet key) and the same address. To watch two devices converge, run the
live window and the emulator against the same relay.

For a home-server deployment (native systemd service, Caddy HTTPS, backups) see `docs/setup.md` §5.

## B. With your own Flutter SDK

```sh
cd packages/wallet_importer && dart pub get && dart test
cd packages/wallet_core     && dart pub get && dart test
cd relay                    && dart pub get && dart test
cd app && flutter pub get && flutter analyze && flutter test

cd app && XDG_DATA_HOME=/tmp/bw-try flutter run -d linux                          # debug app, empty wallet in a throwaway folder
cd app && BW_LIVE_DEMO=1 XDG_DATA_HOME=/tmp/bw-demo flutter run -d linux -t tool/live_demo.dart   # synthetic demo wallet in a throwaway folder
cd app && flutter build linux --release                # build/linux/x64/release/bundle/budget_wallet
cd app && flutter build apk --debug                    # debug-signed APK, any ABI
cd app && flutter build web --wasm                     # needs app/web/sqlite3.wasm: see make web

cd relay && dart run bin/relay.dart --data /tmp/bw-relay --port 8787   # same relay without a container
```

Relay flags: `--host --port --data --origin (repeatable) --max-wallets --max-bytes`, or the environment variables
`BW_RELAY_HOST/PORT/DATA/ORIGINS/MAX_WALLETS/MAX_BYTES`.

The local database uses SQLite3 Multiple Ciphers, compiled by the `sqlite3` package's build hook
(`hooks: user_defines:` in the pubspecs); the first build needs a C compiler.

## Where to look

| Question | File |
|---|---|
| What is it, how is it built, what is known to be weak | `docs/TECHNICAL_SPEC.md` |
| Relay wire protocol | `docs/context/RELAY_PROTOCOL.md` |
| Feature APIs | `docs/context/FUTURE_SPENDING_API.md`, `docs/context/BILLS_API.md` |
| Theme | `docs/design/ledger-spec.md`, `app/lib/src/theme.dart` |
| Money maths | `packages/wallet_core/lib/src/budget.dart`, `planned.dart`, `bills.dart`, `matching.dart` |
| The one write path | `WalletRepo._write` in `packages/wallet_core/lib/src/repo.dart` |
| Encryption | `packages/wallet_core/lib/src/vault.dart`, `local_db.dart`, `sync_relay.dart` |
| Relay server | `relay/lib/src/relay_server.dart` |
| CI | `.github/workflows/ci.yml` (manual only) |
