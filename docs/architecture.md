# Architecture

Budget Wallet v2 is a standalone, offline-first app. Each device keeps the full
wallet in a local SQLite database, encrypted with a key derived from the wallet
key. Devices sync through a self-hosted relay that stores only end-to-end encrypted files.

```
 bank files ──► wallet_importer ──► normalized transactions
                                          │
 app (Flutter)                            ▼
 ├─ screens                        wallet_core.WalletRepo (SQLite)
 └─ WalletController ─────────────► every write = field-level change op (HLC timestamp)
                                          │
                       wallet_sync.SyncEngine: seal ops ──► relay: devices/<device>/<n> (ciphertext)
                                               open ops ◄── other devices' files
```

## Packages

| Path | What | Depends on |
|---|---|---|
| `packages/wallet_importer` | Bank formats → normalized transactions (contract v1). Own BIFF8 .xls reader, .xlsx via `archive` + `xml`, CSV. | nothing Flutter |
| `packages/wallet_core` | Database, change log, encryption (vault), backups, categorisation, budget maths. | `sqlite3`, `cryptography`, `wallet_importer` |
| `packages/sync` (`wallet_sync`) | Sync engine, relay client (`RelayTransport`), `MemoryTransport`, bill files on the relay (`BlobStore`). Core's tests use it as a dev dependency (two-device tests); core's `lib/` never imports it. | `wallet_core`, `http`, `cryptography` |
| `relay` | Home-server relay for sync: stores sealed files it cannot read (protocol `docs/context/RELAY_PROTOCOL.md`). Pure Dart server, own container image. | `cryptography` |
| `app` | Flutter UI for Android, Linux, web (localhost); iOS, Windows, macOS parked. | the three packages |
| `artifact` | v1 web app (claude.ai artifact), kept for reference. | — |

The app never touches bank files directly; it only calls `importBankFile()` and stores the result.

## Data

Tables: `tx`, `goals`, `wish`, `settings` (one row per setting, JSON value), `merchant_rules`.
Sync bookkeeping: `clocks` (entity, id, field → HLC), `outbox` (ops not yet uploaded), `sync_cursor` (per device: last file applied), `meta`.
The file is encrypted with SQLite3 Multiple Ciphers under a key derived from the wallet key and opened only once the key is known. An old plaintext wallet converts on first start; a file the key cannot open is set aside, never deleted.

Amounts are integers in minor units (cents). Transaction ids are deterministic
(`yymmdd` + FNV-1a hash of date|amount|description + occurrence index) so
re-importing a file never duplicates rows. The id scheme matches v1.

## Sync

- Every local write produces ops `{entity, id, fields, hlc}` and applies them locally.
- Conflict rule: per field, the op with the higher hybrid logical clock wins. Applying ops is idempotent and order-independent.
- `SyncEngine` uploads pending ops as this device's next file (uploads over 8 MiB are split into parts), then applies every other device's files strictly in order. Devices only write their own files, so there are no file conflicts.
- Matching of hand-added expenses and transfer pairing run only when the device is caught up.
- Weekly snapshots let a new device start from state, not history. The relay prunes files covered by both kept snapshots and acked by every device seen in the last 90 days. A device stuck behind pruned files is unstuck by a snapshot from any caught-up device after 24 h.
- Relay requests are signed with an Ed25519 key derived from the wallet key; the relay keeps only the public key. A captured request can only be repeated unchanged for 5 minutes (every write is idempotent or only grows), and nobody without the key can read or forge content; the relay is reached over `https://` through a Caddy reverse proxy (no VPN, only port 443 forwarded; docs/setup.md §5), and on plain `http://` (home-network try-outs only) someone on the network can still block or delay sync and see who syncs, when and how much.

## Encryption

- One 32-byte wallet key per user, created on the first device.
- File format: `"BWOP1"` | 24-byte nonce | 16-byte Poly1305 tag | XChaCha20 ciphertext of gzip(JSON ops).
- Key transfer: `BW1-…` base32 text with a 2-byte checksum, also shown as a QR code. It is never sent to the relay.
- Backups (`.bwb`) are sealed with the wallet key and saved through the save dialog; restore only into an empty wallet.
- Losing the key means the local database and the relay copies cannot be read.
- On phones the key is in the system keystore (`flutter_secure_storage`); on computers in a private file in the app support folder.

## Build and test

CI (`.github/workflows/ci.yml`) builds the signed Android APK and the Linux bundle (with its smoke test) when the owner starts the workflow by hand, as separate jobs; lint (`tools/build.sh lint`), package tests, `flutter analyze`, `flutter test` and the desktop tests run there only with the `tests` input, since the laptop verifies them before pushing. The log is pushed to the `ci-logs` branch (`latest.txt`); builds are attached to the workflow run.
