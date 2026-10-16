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
```
cd packages/wallet_importer && dart test
cd packages/wallet_core && dart test
cd app && flutter test && flutter run
```
CI builds an Android APK and a Linux bundle on every push.

## Milestones
- M0 Setup
- M1 Core (v1 web app)
- M2 Standalone app: offline database, encrypted Syncthing sync, importer — in progress
- M3 More views and graphs
- M4 Polish
