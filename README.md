# Budget Wallet

Personal finance tracker and budgeting app for one person. Offline first, runs on Android, iPhone, Windows, macOS and Linux, and syncs between your devices through Syncthing with end-to-end encryption.

## What it does
- Imports bank exports: PBZ (.xls) and Revolut (.xlsx / .csv), plus quick manual entry for card payments.
- Home screen shows one number: **safe to spend today**, which rolls over day to day until payday.
- Payday plan: salary minus bills minus savings goals = spending money.
- Wishlist with a cooling-off period for impulse buys, and a "Can I afford it?" check.
- Goals for big purchases and an emergency fund.
- Views: saving or losing per month, where the money goes by category, top places.

## Structure
- `app/` — Flutter app
- `packages/wallet_importer/` — bank file importer (pure Dart, synthetic test fixtures)
- `packages/wallet_core/` — local database, change log, encrypted sync, budget engine
- `artifact/` — v1 web app (claude.ai artifact), kept for reference
- `docs/architecture.md` — how it fits together
- `docs/setup.md` — install, first run, Syncthing setup

## Privacy
This repo holds **code only**. Bank exports, statements, keys and any real transaction data must never be committed. `.gitignore` blocks the common export formats; only synthetic fixtures under `test/fixtures` are allowed.

## Development
Builds run in a rootless [Podman](https://podman.io) container, so Podman is the only thing to install.
The script runs the same steps as CI.

```sh
tools/make-signing-key.sh       # once: the Android signing key, kept in ~/.config/budget-wallet/
tools/build.sh test             # importer + core + app: analyze and tests
tools/build.sh apk              # Android APK   -> dist/BudgetWallet-android.apk
tools/build.sh linux            # Linux bundle  -> dist/BudgetWallet-linux-x64.tar.gz
tools/build.sh all              # tests, then both builds
tools/build.sh shell            # shell inside the container
```

- The first run builds the image (~15 min). Logs are in `dist/logs/`.
- **Back up `~/.config/budget-wallet/`** (a password manager is fine). Every APK must be signed with that key, or
  Android refuses the update and the app has to be uninstalled, which deletes the wallet on the phone.
- CI signs with the same key from GitHub secrets: run `tools/make-signing-key.sh --upload` once.
- iPhone / macOS builds need a Mac with Xcode. CI builds every platform on `master`, tags, or `[release]` commits.

## Milestones
- M0 Setup
- M1 Core (v1 web app)
- M2 Standalone app: offline database, encrypted Syncthing sync, importer — in progress
- M3 More views and graphs
- M4 Polish
