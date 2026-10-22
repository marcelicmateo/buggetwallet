# Budget Wallet — Security Review

Companion to `docs/SYSTEM_DESIGN_REVIEW.md` (§9) and the other two reviews. Written 2026-10-22 against spec §5, §9
and the Security checklist in §13, with the code read directly: `vault.dart`, `hlc.dart`, `sync_engine.dart`,
`sync_relay.dart`, `local_db.dart`, `backup.dart`, `blob_store.dart`, `repo.dart` (write and apply paths), the relay
(`relay_server.dart`, `wallet.dart`, `signing.dart`, `bin/relay.dart`, `dev/Containerfile.relay`), the app's key
handling (`key_store_io.dart`, `key_vault.dart`, `key_backup.dart`), parsers (`pdf_text.dart`, `einvoice.dart`,
`xls_reader.dart`, `xlsx_reader.dart`, `ics.dart`, `ics_fetch_io.dart`), bill inputs, the Android manifest and
Gradle config, the web shell, logging, and the build and CI scripts. A secrets scan over tracked files found nothing
(one base64 test fixture matched the pattern and is synthetic).

Security goal as stated by the spec: nobody but the holder of the wallet key can read or change the owner's
financial data, and no third party is in the loop. **That goal is met.** Everything below is about the edges:
availability, integrity under a hostile or misconfigured relay, device cloning, key lifecycle, platform defaults
and hygiene. No finding gives an attacker without the key access to plaintext.

Severity scale: **High** = plaintext exposure or silent data loss reachable by a realistic adversary; **Medium** =
integrity or availability loss, or exposure that needs a second condition; **Low** = hygiene, defence in depth;
**Info** = documented and accepted.

## 1. Findings, ranked

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| 1 | Medium | **No relay identity in the protocol.** The first-upload decision is `relayLast < marker` on a bare sequence number. Switching relay A → B → A, or restoring a relay from an older disk image, makes a device treat the relay as current and skip uploading ops that only reached the other relay. Silent, data-dependent loss. | `sync_engine.dart:578-580`, `RELAY_PROTOCOL.md` | Relay returns a random instance id (or per-wallet creation nonce) in `GET state`; client stores it with the marker; any change = first connect. |
| 2 | Medium | **Device id lives inside the wallet database.** A copied Linux data directory or an Android backup / device-to-device transfer (manifest sets neither `allowBackup="false"` nor `dataExtractionRules`) produces two installs with one device id. Each skips its own id when applying peers and silently retries after a 409 on the other's seq: two installs that never see each other's edits, no error. | `repo.dart:128-136`, `sync_engine.dart:610-615`, `AndroidManifest.xml:15-19` | Device id per install, stored next to the key, not in the DB; a 409 on an own seq is surfaced as "another install uses this device id"; `allowBackup="false"`. |
| 3 | Medium | **Hybrid logical clock accepts unbounded future time.** `receive()` takes the max of wall, last and remote with no bound. One device with a wrong clock (2099) permanently advances every device's clock; local edits from sane devices still win on ties by node but all timestamps become meaningless and the matching window that compares clock prefixes breaks. The 24 h cap the spec mentions applies only to the relay signature offset. | `hlc.dart:57-71` vs `sync_relay.dart:167-199` | Quarantine files whose max HLC is > 1 h ahead of wall time (new reason `clockDrift`); refuse local writes when the wall clock is that far behind the stored clock; show it like `clockSkew`. Actual Budget rejects > 1 min. |
| 4 | Medium | **Unauthenticated wallet creation on the relay.** Anyone who can reach the port creates up to `maxWallets` (16) junk wallets with self-generated keys; the owner's next first connect gets 507. Combined with the documented TOFU squat after a wipe, this is the relay's denial-of-service surface on a LAN or a mis-exposed port. | `relay_server.dart:446-466, 499-518`, `limits_cors_log_test.dart:68-93` | A creation token in relay config, sent once as a header on the first `PUT d/<device>/1`; or an allow-list of wallet ids. Both keep the relay content-blind. |
| 5 | Medium | **Release build silently falls back to the debug signing key** when the keystore environment variables are unset. A CI misconfiguration ships a "release" APK that will not install over the real one and is signed with a public key. | `app/android/app/build.gradle.kts:62` | Fail the build when no keystore is present for the published ABI flavour. |
| 6 | Medium | **No key rotation or device revocation.** Wallet id and signing seed are pure functions of the wallet key. A lost phone that still holds the key cannot be cut off at the relay; there is no rotation flow. Acceptable for one owner only if documented with a procedure. | `sync_relay.dart:53-59`, spec §9 | Document rotation (backup → new wallet key → restore → re-point devices, old relay wallet deleted). Later: per-device signing keys enrolled by the owner, so one can be revoked. |
| 7 | Medium | **Plain HTTP by default, with app-wide cleartext allowed.** Metadata (who syncs, when, how much, blob sizes) and availability are exposed to anyone on the path; `android:usesCleartextTraffic="true"` also permits cleartext to any host, including `.ics` fetches the owner adds. The spec mitigates with "use a VPN". | `AndroidManifest.xml:17`, `docs/setup.md` | Ship TLS as the default path (Caddy sidecar in the quadlet or `tailscale serve` as the documented route); `network_security_config.xml` permitting cleartext only for private ranges or the configured relay host. |
| 8 | Low–Medium | **Rate limiter and in-flight cap key on the socket address with no `X-Forwarded-For` handling.** Behind the recommended TLS reverse proxy every client shares one 20 req/s bucket and one 32 MiB budget: per-attacker isolation disappears and one bad device throttles the rest. | `relay_server.dart:206-211, 376-396` | `--trust-proxy` option, or document binding to localhost only behind the proxy. |
| 9 | Low | **No associated data and no domain separation in `seal`.** Sync files, snapshots, backups, blobs and the web key wrap share one magic and bind nothing about their position. A relay can serve `d/A/5` as `d/B/3` or an old snapshot under a new id undetected at the crypto layer. Because ops are self-describing and LWW is idempotent this did not turn into corruption in any case I could construct, so hygiene rather than exploit. | `vault.dart:207-219` | AAD = `"bw-sync-file\n<device>\n<seq>"`, `"bw-snapshot\n<id>"`, `"bw-backup"`, `"bw-blob"`; bump magic to `BWOP2` (the `newerFormat` path already exists). Include the relay host in the signed request text (SigV4 does). |
| 10 | Low | **SQLite cipher not pinned.** No `PRAGMA cipher` or `cipher_*` anywhere; the on-disk format and strength are whatever the `sqlite3mc` hook's compile-time default is today (ChaCha20-Poly1305 per page). A future default change silently alters the format. | `local_db.dart:269-274` | `PRAGMA cipher = 'chacha20'` (and page/kdf settings) before `PRAGMA key`; record in spec §5. |
| 11 | Low | **Desktop key file written before `chmod 600`**, parent directory created with default permissions. World-readable for the write-to-chmod window under a permissive umask. | `key_store_io.dart:51-57` | Create the directory 0700, write to a temp name, chmod, rename; the roadmap's OS keyring is the real fix. |
| 12 | Low | **No `FLAG_SECURE` on the key screen.** The wallet key text and QR appear in the recents thumbnail and in screenshots on Android. | `screens/key_backup.dart`, no `FLAG_SECURE` anywhere | Set the flag while the key sheet is open (Bitwarden and Aegis do). |
| 13 | Low | **Web key at rest: PBKDF2-HMAC-SHA256 at 310,000 iterations**, unwrapped key text in `sessionStorage`. 310k was the 2021–23 figure; current guidance is 600k, and `package:cryptography` ships Argon2id. `sessionStorage` is readable by any script on the origin and inherited by tabs opened from the page. Localhost-only today. | `key_vault.dart:14, 86, 116-128, 186, 203` | 600k or Argon2id under a `bwk2` prefix; keep the unwrapped key in memory only and ask for the passphrase again on reload. Add one sentence to §9. |
| 14 | Low | **No decompression cap after authentication.** `unseal` gunzips with no output limit; a key holder can craft a ≤ 16 MiB file that inflates to gigabytes. Only reachable with the key (own or compromised device), so low, but it is the one unbounded allocation on the sync path. | `vault.dart:161-163` | Cap plaintext at, say, 256 MiB and quarantine over it. |
| 15 | Low | **Bank file import has no byte cap** and `XlsxReader` inflates `sharedStrings.xml` and the sheet fully before the cell cap applies. The owner picks the file, so the exposure is self-inflicted; bill inputs (share-to-app) do have caps. | `importer.dart:34`, `xlsx_reader.dart:19-45`; contrast `bill_inputs.dart:14`, `controller_bills.dart:142, 274` | 20 MB file cap and an inflated-size cap like the PDF path. |
| 16 | Low | **Backups contain no blobs.** Relay loss plus a restore keeps the bills and loses every photo and PDF; the backup UI does not say so. | `blob_store.dart:22-24`, `backup.dart` | Include blobs when they fit, or state it in the backup panel and §9. |
| 17 | Info | **Relay metadata correlation.** The relay sees a stable 128-bit wallet id, stable device ids, sequence numbers, sizes, times, acks and blob sizes; it can infer device count, activity rhythm and that a receipt photo was just taken, and link the wallet across every relay the owner ever uses. Fine for a self-hosted relay; derive `wid` per relay if a relay is ever shared. | `sync_relay.dart:53-59` | Document; per-relay HKDF salt later. |
| 18 | Info | **TOFU on wallet creation and the 24 h signature offset cap.** Accepted; the squat is denial of service only. With finding 4 fixed the squat needs the token too. | spec §9 | None beyond 4. |
| 19 | Info | **Clipboard copy of the key** is cleared after 60 s; clipboard managers may keep it. Documented. | `controller.dart:851-882` | Offer "show QR only" as the default transfer path. |

## 2. Threat model, revisited (spec §9)

| Adversary | Spec says they cannot | Verified | Additions |
|---|---|---|---|
| Network sniffer on plain HTTP | Read, forge, alter, learn the key | Holds: XChaCha20-Poly1305 content, Ed25519 over method, path, covers, body hash and time, 5-minute window, idempotent writes | Can replay a captured `DELETE blob` against a second relay holding the same wallet within 5 minutes (host not in the signed text, finding 9); can exhaust `maxWallets` (finding 4) |
| Relay operator or stolen relay disk | Read, forge, alter sealed content; sign to another relay; derive the key | Holds | Can swap file positions undetected at the crypto layer (finding 9, no corruption found); can cause silent op loss by restoring an old disk image (finding 1) |
| Relay wiped and squatted | Read anything | Holds (denial of service only) | Finding 4 lets anyone pre-squat without a wipe |
| Person with the unlocked phone | Export key without the key screen; read the DB from another app | Holds (sandbox + encryption) | Can screenshot the key screen or see it in recents (finding 12); Android backup default can carry the encrypted DB and the cloned device id off the device (finding 2) |
| Laptop image or stolen disk | — (known limit) | Key file is plaintext under file permissions | Umask window on first write (finding 11); full-disk encryption remains the mitigation |
| Malicious bill or calendar file | Crash or hang the app | Holds: size caps, step and op budgets, never-throw readers, DOCTYPE/ENTITY refused (`einvoice.dart:43`), PDF off the UI isolate, fuzz tests | Bank files lack the same caps (finding 15) |
| Repository reader | Learn any real figure | Holds: fixtures generated, secrets scan clean, `dist/` and lockfiles of internal packages ignored | Commit the agent definitions so the review process is reproducible (not a security issue) |
| **Missing adversary: a second install with the same device id** (clone) | — | Not modelled | Finding 2 |
| **Missing adversary: a benign device with a wrong clock** | — | Not modelled beyond the signature window | Finding 3 |
| **Missing adversary: the owner's own lost device still holding the key** | — | Not modelled | Finding 6 |

## 3. Cryptography — what is right

- **Content encryption.** XChaCha20-Poly1305 from `package:cryptography`, 24-byte random nonce from the library's
  CSPRNG, 16-byte tag, `BWOP1 | nonce | mac | ciphertext`, gzip-then-encrypt with a whole-member check after
  decryption. With a 192-bit nonce, random generation is the right choice (it would not be with AES-GCM's 96 bits).
  Nonce-reuse checklist item: holds. Tamper and wrong-key tests exist; fixed-key, fixed-nonce known-answer vectors do
  not (add them).
- **Key derivation.** 32 random bytes from `Random.secure()`; HKDF-SHA256 with empty salt and versioned info strings
  (`bw-local-db-v1`, `bw-relay-id-v1`, `bw-relay-sign-v1`), a known-answer test in the engine spec tests. Correct per
  RFC 5869; the empty salt is fine because the input key is uniformly random.
- **Request authentication.** Ed25519 over `bw-relay-v2\nMETHOD\npath\ncovers\nsha256(body)\ntime`; the relay
  rebuilds the path from validated segments, rejects duplicated headers, checks the time window before reading any
  body, verifies with the stored public key or `X-BW-Pub` on creation, and re-checks the key inside the wallet lock
  to close the creation race. The relay tests use an independently written signer and prove a captured request cannot
  be bent to another path, method, body, covers or time. Clock skew is learned from the relay's `Date` only after a
  401 `clock`, retried once, capped at 24 h, never persisted.
- **Local database.** `sqlite3mc` with a raw 32-byte key via `PRAGMA key` (no KDF inside SQLite, correct since the
  key is derived); conversion from plaintext does a keyed open first, probes unkeyed only on NOTADB, checkpoints WAL
  before `PRAGMA rekey`, verifies row counts and uses temp + rename. Pin the cipher (finding 10).
- **Performance note.** Everything is pure Dart (`cryptography_flutter` is not a dependency). Sealing a 15 MiB
  receipt PDF and hashing it twice on a mid-range phone is in the one-to-several-second range. Not a security
  issue; measure on the slowest target before deciding on platform acceleration (which has no XChaCha, so it would
  be HChaCha20 in Dart plus platform ChaCha20-Poly1305).

## 4. Key lifecycle

| Stage | Today | Assessment |
|---|---|---|
| Generation | 32 bytes from the platform CSPRNG on the first device | Right |
| Storage, phone | `flutter_secure_storage` (Android Keystore-backed prefs) | Right; audit `allowBackup` (finding 2) |
| Storage, desktop | Plaintext file in the app support directory, `chmod 600` after write | Known limit; close the umask window (finding 11); keyring on the roadmap |
| Storage, web | PBKDF2-wrapped blob in `localStorage`, unwrapped text in `sessionStorage` | Acceptable for localhost; raise work factor, drop `sessionStorage` (finding 13) |
| Display and transfer | `BW1-…` base32 text with checksum and QR; copy with 60 s clipboard clear; last-four confirmation before the nag stops | Good UX for a one-owner secret; add `FLAG_SECURE` (finding 12) |
| Derived keys | HKDF children for DB, relay id, signing | Right; nothing else to store or sync |
| Rotation | None | Document a procedure (finding 6) |
| Revocation | None; all devices share one identity at the relay | Document; per-device keys later (finding 6) |
| Loss | By design, unrecoverable; prompt and nag | Right for the threat model; the backup UI should say blobs are not in the backup (finding 16) |
| Memory | Dart cannot zero memory; key bytes live in the heap for the process lifetime | Inherent to the platform; note in §9 |

## 5. Relay server

Right: request pipeline rejects before it reads (rate limit → OPTIONS → route and name validation with
`^[A-Za-z0-9_-]{1,64}$` → signature headers → body with per-request and per-address caps and polite draining →
verify → per-wallet mutex → handler); names cannot traverse paths; `meta.json` via temp + rename; files win over meta
on restart; one log line per request with kind, status, bytes and six-character ids only; CORS echoes configured
origins only with `Vary: Origin`; container is two-stage, `--enforce-lockfile`, AOT binary on `debian:bookworm-slim`,
non-root uid 10001, `VOLUME /data`.

Change: creation token (finding 4), proxy-aware limits (finding 8), instance id (finding 1), TLS default
(finding 7). Small: add `HEALTHCHECK` against `/v2/health`; run the container read-only except `/data`; `HEAD`
returns 405 although a branch exists; a known device with a missing file returns 500 rather than a diagnosable
status.

## 6. Sync integrity and availability

Right: outbox cleared only after every part of an upload is stored; each peer file applied in one transaction and
re-applied idempotently after a crash; content-hashed quarantine retried only on content or build change; stuck
peer healed by a snapshot from a caught-up device after 24 h; snapshot dominance enforced by the relay; pruning
gated on both kept snapshots and every device seen in 90 days having acked. I could not construct a case where an
honest relay prunes an op a live device still needs.

Change: findings 1, 2, 3, 9 and 14. Also: `SyncEngine.run` is not re-entrant on the class (the controller's
`syncing` flag is the only guard; two engines on one repo would not corrupt, only duplicate work); document it.
Convergence by recomputation (matching, pairing, bill reserve rows are recomputed on every device and converge only
because the computation is deterministic) deserves a comment and a "zero ops on the second full round" assertion in
the simulation.

## 7. Data at rest beyond the database

- **Bill blobs**: sealed with the wallet key, content-addressed, cached locally with LRU eviction; relay-only when
  evicted. Right; see finding 16 for backups.
- **Logs**: structured events, a per-package test that no amount, merchant, name, key, device id, path or file name
  reaches a log line; rotation on device; export through the save dialog; a redaction hook for platform exceptions.
  This is better than most commercial apps. Keep the test discipline for every new event.
- **Notifications**: never carry amounts or names. Right.
- **Screenshots and recents**: finding 12.
- **Android backup**: finding 2.
- **Bill photos** go through a `FileProvider` path set (`res/xml/bill_photo_paths.xml`); the camera temp file is
  deleted before each capture per the commit history. Verify the temp directory is app-private (it is the cache dir
  by the plugin default).

## 8. Input handling

| Input | Caps and guards | Verdict |
|---|---|---|
| PDF (bill) | 20 MB, 5M ops, 64 MB inflated, 2M chars, capped inflate, never-throw shell, encrypted → null, page-tree cycle guard, XObject recursion ≤ 8, parsed off the UI isolate, 300 mutated fixtures per run | Good |
| UBL XML (e-invoice) | Char cap, `DOCTYPE`/`ENTITY` refused before parsing, exact decimal cents | Good |
| Fiscal QR / HUB-3 | Field parsing with length checks | Good |
| Image + OCR | 40 MiB cap, on-device ML Kit | Good |
| `.ics` | Step budgets, 2 MB, 60 s, redirects capped, https never downgraded to http, http shows a warning | Good; the owner names the host, so LAN reach is by design |
| `.xls` (BIFF8) | OLE2 FAT and mini-FAT loop guards, SST `CONTINUE` handling, 2M-cell sparse cap, truncation tests at every length | Good; no `FILEPASS` detection (reads as "damaged") |
| `.xlsx` | 2M-cell cap after full inflate of the XML parts | Finding 15 |
| `.csv` | Streamed, quoted fields | Good |
| Sealed peer files | 16 MiB relay cap, authenticated before any parse, type-checked fields in `_apply` (wrong-typed fields dropped without recording the clock) | Good except the inflate cap (finding 14) |
| Share-to-app (Android `SEND`, `SEND_MULTIPLE`, PDF and images) | Routed into the same bill readers with caps; `singleTask` activity | Good |

## 9. Platform defaults

- **Android**: `allowBackup` unset (finding 2); `usesCleartextTraffic` app-wide (finding 7); `WRITE_CALENDAR`
  declared because the plugin demands the pair (reviewed, unused; replace the plugin if Play's data-safety form
  matters); CAMERA from `mobile_scanner`'s merged manifest; no storage permissions (all files through the system
  picker and save dialog); R8 not explicitly configured; 64-bit only; signing fallback (finding 5); no
  `network_security_config.xml`.
- **Web**: no CSP meta in `index.html`; Flutter's CanvasKit renderer has little injection surface, and the origin
  is localhost, but a CSP of `default-src 'self'` plus the wasm/CanvasKit allowances costs nothing. Web Locks make
  the wallet single-tab; the persist-before-freeze window is inherent to IndexedDB VFSs.
- **Linux**: key file (finding 11); the live and test tooling isolates the app in a container with its own D-Bus
  session and never passes X11 through, which is more care than most desktop apps take.

## 10. Supply chain and release

Right: Flutter pinned to 3.47.7 and read by CI; `sqlite3.wasm` pinned by SHA-256; the app and relay lockfiles are
committed and the relay image uses `--enforce-lockfile`; a short approved dependency list (107 packages resolved in
the app lockfile, no git dependencies); release APKs signed with one key kept outside the repository; builds in a
rootless Podman image; shellcheck and actionlint pinned.

Change: `flutter pub get` in `tools/build.sh` and the CI APK step do not pass `--enforce-lockfile`, so a drifted
lockfile would resolve silently; the internal packages' lockfiles are gitignored, which is normal for libraries but
means their test runs are not reproducible; finding 5 on the signing fallback. Consider `dependabot`-style
advisories for the 107 packages (Dart has `dart pub outdated` and OSV coverage) once CI runs on push.

## 11. Security testing — present and missing

Present: tamper and wrong-key tests on `seal`/`unseal`; HKDF known-answer vector; an independent hand-written
signer in the relay tests proving every signed field matters; replay, window, duplicate-header, limits, pruning,
restart-recovery and concurrent-creation tests on the relay; 2-to-4-device randomised convergence with fetch
failures and clock skew; fuzzing of PDF, XML, ICS and bank files in isolates with timeouts; log-privacy tests per
package and in the integration harness; a regex test that native plugins stay in their files.

Missing, in order of value: (1) model-equivalence test driving the same random requests through the in-memory
transport and the real relay; (2) scenarios for findings 1, 2 and 3 (relay switch, cloned device id, future clock);
(3) relay fault injection between `writeAtomic` and `saveMeta`, disk full, truncated files; (4) protocol fuzzing
asserting "4xx, never 5xx, state unchanged"; (5) fixed-key, fixed-nonce vectors for `seal` and a nonce-uniqueness
sanity test; (6) a decompression-bomb test for `unseal` and `XlsxReader`; (7) an Android backup/restore test on the
emulator (what survives, what the app shows).

## 12. Spec §13 Security checklist, answered

| Item | Answer |
|---|---|
| Threat model covers the deployment (LAN, VPN, TLS proxy) | Mostly; add the clone, wrong-clock and lost-device adversaries; TLS proxy breaks the per-address limiter (finding 8) |
| Nonce reuse impossible | Yes: 192-bit random nonce per seal |
| TOFU and 24 h clock cap acceptable | TOFU yes once creation needs a token; the 24 h cap covers signatures only, the HLC is unbounded (finding 3) |
| Desktop key, clipboard, Android backup tracked as limits | Tracked; Android backup is a defect to fix, not a limit; add the umask window and `FLAG_SECURE` |
| Parsers safe on hostile input | Yes for PDF, XML, ICS, XLS, images; `.xlsx` and sealed-file inflate are the two unbounded steps |
| Log privacy tests cover every new event | Yes per package and in the integration harness; keep it as a merge gate |

## 13. Recommendations in order

**Before the owner's live test (each under a day):** findings 2 (`allowBackup`, device id out of the DB, 409 on own
seq surfaced), 5 (fail without keystore), 1 (relay instance id), 3 (bounded HLC), 10 (pin the cipher), 9 (AAD and
`BWOP2`), 4 (creation token).

**Next stage:** 7 (TLS default and network security config), 8 (proxy-aware limits), 6 (documented rotation; later
per-device keys), 11, 12, 13, 14, 15, 16, the missing tests in §11.

**Document now in §9:** the clone and wrong-clock adversaries, the rotation procedure, blobs not in backups, the web
`sessionStorage` note, Dart's inability to zero key memory, and the metadata the relay can correlate.
