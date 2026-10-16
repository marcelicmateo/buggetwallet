# Budget Wallet — Architecture decisions (v2)

The as-built design is in `docs/architecture.md` (v2 branch). This file records the requirements and the
choices behind it.

## Requirements (owner, 2026-10-16)
- Decoupled from Claude: standalone app.
- Cross-platform native: Android, iPhone, desktop (owner uses both phone types + a computer).
- Offline-first, own database.
- Sync between devices from the start, free to run.
- **End-to-end encrypted**: whatever leaves a device is ciphertext; no server or cloud can read the data.
- **Importer lives on edge devices** (phone/computer). Bank file formats (PBZ .xls, Revolut .xlsx) are not coupled to the app: the importer converts them into our own schema; the app only consumes our database.
- More graphs and features later.

## Decided
- 2026-10-16: **Flutter** for the app (Android, iOS, Windows, macOS, Linux).
- 2026-10-16: **E2E encryption** (XChaCha20-Poly1305); importer runs on the owner's devices.
- 2026-10-16: **Transport D — Syncthing shared folder.** Each device writes encrypted op files only into its own subfolder; others read and merge.
- 2026-10-16: SQLite via the `sqlite3` package.

## Shape
```
 bank files ──► Importer module (on device) ──► normalized transactions
                                                      │
 App (Flutter)                                        ▼
 ├─ UI                                         local SQLite = source of truth on device
 ├─ every write → change op (row, fields, HLC timestamp, device id)
 └─ sync engine: encrypt ops → transport → other devices decrypt + merge (last writer wins per field)
```
- **Data model:** own schema (transactions, categories, merchant rules, goals, wishlist, settings).
- **Encryption:** one wallet key per user, created on the first device; new devices join with the key as `BW1-…` text or QR.
- **Transport is pluggable** — the sync engine only needs "put encrypted blob / list blobs since X / get blob".
- **Importer:** separate package behind a versioned contract (normalized transactions with deterministic ids, re-import safe). Bank-specific code lives only there.

## Transport options considered
| Option | Cost | Works away from home | Accounts needed | Notes |
|---|---|---|---|---|
| A. Phone as hub, local Wi-Fi sync | Free | No | None | iPhone syncs only while app is open. |
| B. Cloudflare free tier relay | Free | Yes | Cloudflare | Always on, stores only ciphertext. |
| C. Cloud drive as encrypted mailbox | Free | Yes | Existing account | Login setup per platform is fiddly. |
| **D. Syncthing (chosen)** | Free (iPhone client paid) | Yes | None | Extra app on every device. |

Possible later add-ons: B as an always-on relay, A for offline home sync.
