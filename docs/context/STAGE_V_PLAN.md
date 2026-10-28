# Stage V — sync format items before M6 (owner 2026-10-28; schema 18)

## Context
Every approved feature is built (Stage Q, 2026-10-27). The sync-format items that `STAGE_Q_PLAN.md` left for after M6
are built now instead (owner 2026-10-28), so the live test runs on the final format and no format migration lands on
real data afterwards. **Statement ticking is dropped** (owner 2026-10-28): bank rows come from the bank's own file, the
Q balance check already reconciles, and "Matched with your bank" already marks hand-added rows the bank has seen.

**Hard rules** (as in Q): money never changes on amount alone or without the owner's tap; no new packages; logs hold
counts only; integer cents, `YYYY-MM-DD`; every write through `WalletRepo._write`; update every device together.

## V1 — key id on sealed files (core A)
Today a `BWOP2` seal that does not open is `UnsealFailure.badKey` whether the key is wrong or the file was changed or
cut, so the app can only say "made with another key, or damaged".
- **Format `BWOP3`:** `"BWOP3" | keyId(8) | nonce(24) | mac(16) | ciphertext`. `keyId` = first 8 bytes of
  HKDF-SHA256(ikm = key bytes, salt = empty, info = `bw-key-id-v1`). The key id is part of the associated data too
  (`aad || keyId`), so changing it breaks the MAC. `VaultKey.keyId` (8 bytes) exposed.
- `seal` writes `BWOP3` for sync files, snapshots, backups and blobs. `wrapKey` (web passphrase) stays `BWOP2`: a
  wrong passphrase must stay `badKey`/`WrongPassphrase`, nothing gained there.
- `unseal`: `BWOP3` with another key id → new `UnsealFailure.otherKey` (no decrypt attempted); same key id but the
  MAC fails → `UnsealFailure.damaged`; `BWOP1`/`BWOP2` read as today (`badKey` stays ambiguous for old files);
  `BWOP4`+ → `newerFormat` as today.
- Backups: `BackupFailure`/restore paths pass `otherKey` through so the app can say exactly which case it is.
  "Restore a backup made with another key…" still works (it unseals with the typed key).
- Sync: a peer file or snapshot with another key id is quarantined with a new `SyncProblemReason.otherKey`
  (a device of another wallet, or one left on an old key after a key rotation); a damaged one as today.
- Old builds (schema ≤ 17) meeting `BWOP3` report `newerFormat` and wait for an update (existing path, check it says
  "Update the app"). Constants and test vectors in `docs/TECHNICAL_SPEC.md` and `RELAY_PROTOCOL.md` (the relay never
  reads seals: no api bump).

## V2 — device state digest + "devices disagree" repair (core A)
Per-field LWW should give every device the same synced state once they have applied the same files. Nothing checks
that today; Stage Q found three data-loss orders by review. The digest turns such a bug into a visible, self-repairing
event.
- `WalletRepo.stateDigest()` → lowercase hex SHA-256 over a canonical form of the **synced** state: every entity in
  `entitySchema`, rows sorted by id, fields sorted by name, each value with its field clock, deleted rows included.
  Device-local tables and settings excluded. Pure and deterministic (same state → same digest on io and web).
- **When it is sent:** at the end of a run that is caught up with an empty outbox, if data ops were applied or written
  since the last digest this device sent, the device puts one `digest` record into its next upload: the digest and the
  vector it covers (per device: the seq of the last file holding **data** ops that it has applied, its own included).
  Digest/repair records are not data: a file holding only them never causes another digest (no ping-pong between two
  quiet devices; test with 2 and 3 devices).
- **Compare:** a device applying a peer's `digest` record compares when its own data vector equals the record's
  vector and it is caught up with an empty outbox; otherwise the record is ignored (stale or ahead).
- **Repair:** a mismatch is logged (`sync.digest.mismatch`, counts only) and the device uploads its whole state with
  original clocks (the `snapshotOps` resend path, as P10 merge uses) plus a `repair` record asking every device to do
  the same once. LWW then converges; nothing is deleted (deletes are fields). A second mismatch within 7 days of a
  repair stops auto-repair and raises device-local `SyncProblemReason.devicesDisagree` (kept until a later compare
  matches); Settings › Sync shows it with "Save logs" (UI half).
- Records travel as ops of reserved entity kinds (`_digest`, `_repair`) that `applyRemote` never stores as data;
  older builds already skip unknown kinds (Q8), so mixed versions keep syncing.

## V3 — review streak from dated rows (core B, schema 18)
`reviewStreak` is a synced counter: two devices that finish a review on different days before syncing keep one
device's count (PATH_FORWARD J3 second half: counters as rows). Saved by waiting is already read-time (P8).
- New synced entity `review` (schema 18): id = the review date `YYYY-MM-DD` (two devices on one day write the same
  row), fields `done` (the date) and `deleted`. `markReviewDone(today)` writes the row; no counter is written.
- `reviewStreak(rows, {legacyLast, legacyStreak})` pure: walk back from the newest date while the gap is < 14 days;
  if the walk reaches the stored legacy `lastReview` (gap < 14, or the same day), add the legacy `reviewStreak`
  (minus one when it is the same day). `ReviewState.streak` and the Done screen read it. The legacy settings are
  never written again (old builds keep showing their last value).
- `entitySchema`, `sim.dart`, migration 17 → 18 (plain + encrypted) and the upgrade-from-every-version tests extended.

## UI half (ui-builder, after core APIs are fixed below)
- Backup restore/merge, join with key, and "Restore a backup made with another key…": `otherKey` → "This backup was
  made with another wallet key." / "That key doesn't open this backup."; `damaged` → "This backup file is damaged.";
  old `badKey` keeps today's two-way sentence.
- Settings › Sync: `otherKey` problem → "A file from another wallet key is on this relay (ignored)."; `devicesDisagree`
  → "Your devices don't agree on some data. The app tried to repair it. Save logs and send them." with the Diagnostics
  button. No values shown.
- Weekly review Done screen and Today card read the new streak (no visible change expected); screenshots at 320 dp.

## Fixed core API (both halves code against this)
`VaultKey.keyId` · `UnsealFailure.otherKey` · `BackupFailure.otherKey` · `SyncProblemReason.otherKey` ·
`SyncProblemReason.devicesDisagree` · `WalletRepo.stateDigest()` · `reviewStreak(...)` (pure) · `ReviewState.streak`
unchanged.

## Delegation
| # | Item | Agent (model/effort) | Worktree / branch | Depends on | Runs with |
|---|---|---|---|---|---|
| V0a | Context pack: vault seal/unseal callers, backup failures, sync quarantine reasons, `snapshotOps` resend, applyRemote unknown kinds, sim tests | scout (haiku/low) | – | – | V0b, V0c |
| V0b | Context pack: settings `lastReview`/`reviewStreak`, `markReviewDone`, `reviewState`, entitySchema, migration + upgrade tests | scout (haiku/low) | – | – | V0a, V0c |
| V0c | Context pack: app texts for unseal/backup failures, Settings › Sync problems, review Done screen | scout (haiku/low) | – | – | V0a, V0b |
| VA | V1 + V2 | core-builder (session model/high) | `v-sync` from v2 | V0a | VB, VT, VU |
| VB | V3 (schema 18) | core-builder (session model/high) | `v-review` from v2 | V0b | VA, VT, VU |
| VT | Spec tests from this file only: BWOP3 vectors + tamper cases, digest determinism, 2/3-device divergence → repair → converge, no ping-pong, streak from rows incl. legacy base and same-day twins | test-writer (sonnet/medium) | `v-tests` from v2 | V0a, V0b | VA, VB, VU |
| VU | UI half | ui-builder (sonnet/high) | `v-ui` from v2 | V0c, API above | VA, VB, VT |
| VR | Review each half as it lands (findings back to the same builder) | reviewer (session model/high) | – | each half | – |
| V | Merge VB → VA → VT → VU, merge-delta review, `tools/build.sh stage` (haiku/low watcher reads the summary), screenshots, push, STATUS | lead + haiku | v2 | all | – |

Four agents at most at once: VA, VB, VT, VU; reviewers start as builders finish.
