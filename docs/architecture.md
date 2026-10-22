# Architecture

Budget Wallet v2 is a standalone, offline-first app. Each device keeps the full
wallet in a local SQLite database. Devices sync through a shared folder
(Syncthing), and everything written to that folder is end-to-end encrypted.

```
 bank files ──► wallet_importer ──► normalized transactions
                                          │
 app (Flutter)                            ▼
 ├─ screens                        wallet_core.WalletRepo (SQLite)
 └─ WalletController ─────────────► every write = field-level change op (HLC timestamp)
                                          │
                                   FolderSync: encrypt ops ──► <sync folder>/budget-wallet/devices/<device>/<n>.bwop
                                               decrypt ops ◄── other devices' files
```

## Packages

| Path | What | Depends on |
|---|---|---|
| `packages/wallet_importer` | Bank formats → normalized transactions (contract v1). Own BIFF8 .xls reader, .xlsx via `archive` + `xml`, CSV. | nothing Flutter |
| `packages/wallet_core` | Database, change log, encryption, folder sync, categorisation, budget maths. | `sqlite3`, `cryptography`, `wallet_importer` |
| `relay` | Home-server relay for sync: stores sealed files it cannot read (protocol `docs/context/RELAY_PROTOCOL.md`). Pure Dart server, own container image. | `cryptography` |
| `app` | Flutter UI for Android, iOS, Windows, macOS, Linux. | both packages |
| `artifact` | v1 web app (claude.ai artifact), kept for reference. | — |

The app never touches bank files directly; it only calls `importBankFile()` and stores the result.

## Data

Tables: `tx`, `goals`, `wish`, `settings` (one row per setting, JSON value), `merchant_rules`.
Sync bookkeeping: `clocks` (entity, id, field → HLC), `outbox` (ops not yet exported), `peer_files` (files already applied), `meta`.

Amounts are integers in minor units (cents). Transaction ids are deterministic
(`yymmdd` + FNV-1a hash of date|amount|description + occurrence index) so
re-importing a file never duplicates rows. The id scheme matches v1.

## Sync

- Every local write produces ops `{entity, id, fields, hlc}` and applies them locally.
- Conflict rule: per field, the op with the higher hybrid logical clock wins. Applying ops is idempotent and order-independent.
- `FolderSync.run()` exports the outbox as one file into this device's own folder, then applies every unseen file from other devices. Devices never write into each other's folders, so Syncthing never sees conflicting edits.
- `vault.json` holds a key fingerprint (no secret) so a device with the wrong key is refused.

## Encryption

- One 32-byte wallet key per user, created on the first device.
- File format: `"BWOP1"` | 24-byte nonce | 16-byte Poly1305 tag | XChaCha20 ciphertext of gzip(JSON ops).
- Key transfer: `BW1-…` base32 text with a 2-byte checksum, also shown as a QR code. It never goes through the sync folder.
- On phones the key is in the system keystore (`flutter_secure_storage`); on computers in a private file in the app support folder.

## Build and test

CI (`.github/workflows/ci.yml`) builds the signed Android APK and the Linux bundle (with its smoke test) on every push as separate jobs; lint (`tools/build.sh lint`), package tests, `flutter analyze`, `flutter test` and the desktop tests run there only on demand (`[ci tests]` in the commit message), since the laptop verifies them before pushing. The log is pushed to the `ci-logs` branch (`latest.txt`); builds are attached to the workflow run.
