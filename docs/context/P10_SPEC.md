# Stage P10 spec: merge from backup (2026-10-25)

Plan item: PATH_FORWARD P10 ("Merge from backup on `applyRemote(resend: true)`; blobs in the backup when they fit"). Owner decision (`NEXT_DECISIONS.md`): merging uses the sync rule — **the newer change wins, field by field; nothing is doubled**.

## What exists
- A backup is sealed JSON `{"v":1,"ops":[...]}` = `snapshotOps()` (one op per row field with its HLC). `restoreBackupBytes` parses, checks the H7 clock guard, then `applyRemote(ops, resend: true)`; it refuses a wallet that is not empty (`StateError`).
- `_apply` is field-level LWW by HLC: an older or equal op changes nothing. So a merge is the same apply on a non-empty wallet.

## 1. Core (`backup.dart`)
- `Future<MergeResult> mergeBackupBytes(WalletRepo repo, List<int> bytes, VaultKey key, {bool dryRun = false})`:
  - same unseal / parse / version / damaged / clockAhead checks as restore (shared code), nothing applied on any failure;
  - applies through the LWW path; `MergeResult {int ops, int changed, Map<String, int> changedByEntity}` (`changed` = ops that changed a field);
  - **`dryRun: true`** runs the apply in a transaction that is rolled back and returns the same counts (the app's preview); the HLC clock and outbox are left exactly as before;
  - only ops that **changed something** go to the outbox (re-sent to other devices); unchanged ones are not queued. Add `applyRemote(..., resendChanged: true)` (additive; `resend: true` keeps its meaning for restore).
  - matching runs afterwards as after a sync (`match: true` when caught up).
- `restoreBackupBytes` keeps refusing a non-empty wallet (the app offers merge there).
- Merging the same backup twice: the second time `changed == 0`.
- A backup made with another key: same "old key" path as restore (`VaultKey` passed in).

## 2. Blobs in the backup
- `backupBytes(repo, key, {int maxBlobBytes = 32 << 20})` adds an optional `"blobs": {"<hash>": "<base64 sealed>"}` with the blobs in this device's cache that live bills reference, newest first, until the total sealed size would pass `maxBlobBytes` (a blob that doesn't fit is skipped, not cut).
- Version: keep `"v":1` **if** an older build's parser ignores the extra key (check `_parse` and the schema-7 old-build fixtures/tests: `h12_old_builds_test.dart`); otherwise bump to 2 and say so in the report.
- Restore and merge put each blob into the cache (`putCachedBlob`, hash checked against the content: a blob whose hash doesn't match is skipped and logged as `backup.blobBad` with a count) and queue it for upload (the relay PUT is idempotent). `blob_own` is not set (the file was attached elsewhere).
- Logs: counts and byte totals only.

## 3. App (Plan › Backup)
- When the wallet has data: **"Merge a backup…"** (`ValueKey('mergeBackup')`) → pick a `.bwb` → preview dialog from `dryRun` ("This brings in 42 changes: 30 payments, 8 tags, 4 settings. Newer changes win; nothing is doubled.") with Merge / Cancel → result toast ("Merged 42 changes"). "Nothing new in this backup" when `changed == 0`.
- Wrong key → offer "Backup made with another key" (same dialog as restore).
- The empty-wallet "Restore from backup…" stays as it is.
- Backup button text notes when bill files were included ("Backup saved with 3 bill files").

## 4. Tests
- Merge into a wallet that edited the same row: the newer field wins on each side, per field (A newer amount, B newer note → both kept).
- A row only in the backup is added; a row only in the wallet stays; a delete newer in the backup wins, an older one doesn't.
- Merging twice → second `changed == 0`; dry run changes nothing (tables, clocks, outbox, HLC identical) and reports the same counts as the real merge.
- Only changed ops are queued; another device applying them ends equal.
- Damaged / truncated / clockAhead / wrong key → nothing applied.
- Blobs: included up to the cap (one over is skipped); restored into the cache; a tampered blob skipped; an old build's parser (or the version rule) handled.
- App: Merge button only with data; preview counts; cancel changes nothing; toast.
