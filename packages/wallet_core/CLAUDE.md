# wallet_core — notes for Claude

Pure Dart (no Flutter): SQLite repo, field-level change log with HLC, encrypted relay sync (`SyncEngine`), categories,
budget engine. **All money logic lives here**, so it can be unit-tested without the UI.

## Web rule (§4.8: the barrel compiles for the web)
`package:wallet_core/wallet_core.dart` must compile with dart2js and dart2wasm, with identical behaviour on native.
Nothing reachable from the barrel may import `dart:io`, `dart:ffi` or `package:sqlite3/sqlite3.dart` unconditionally.
- Database code uses `package:sqlite3/common.dart` (`WalletRepo.db` is a `CommonDatabase`). `WalletRepo.open(path)` /
  `inMemory()` (and `open(path, dbKey:)`, `openKeyedFileDb`) go through `sqlite_io.dart` (native) or `sqlite_web.dart` (throws); the web app opens a
  `package:sqlite3/wasm.dart` database itself and calls `WalletRepo.fromDatabase(db, file:)` (same pragmas/migrations).
- dart:io code lives in `*_io.dart` files with a `*_web.dart` twin of the same public names that throws
  `UnsupportedError`; the barrel picks one with `export 'src/x_io.dart' if (dart.library.js_interop) 'src/x_web.dart';`:
  `backup_io.dart` (`writeBackup`, `restoreBackup`, `listBackups`, `backupsFolder`, `backupPath`), `logs_io.dart`
  (`RotatingFileSink`). `platform_error_io/web.dart` give `describeError` its
  dart:io case. New dart:io code goes in one of these (or a new pair), never in a shared file.
- gzip comes from `package:archive` (`vault.dart`): on the VM it is `dart:io`'s codec (same bytes as before), in the
  browser pure Dart; both write one standard gzip member, which is what `_wholeGzip` and older builds check.
  `test/web_core_test.dart` pins that dart:io members unseal and that pure-Dart members are accepted.
- The sync engine and both transports are shared code (no dart:io): `RelayTransport` uses `package:http` (IOClient on
  the VM, fetch in the browser). The real relay server (`relay/`) is only a dev dependency for the end-to-end test.
- `hlc.dart`: no int literal above 2^53 (dart2js refuses it); `_maxInt` is 2^53 − 1 there, 2^63 − 1 elsewhere.
- Compile check (after `dart pub get` in the package): `tools/build.sh shell -c 'cd packages/wallet_core && dart compile js
  -o /dev/null tool/web_smoke.dart && dart compile wasm -o ../../dist/web_smoke.wasm tool/web_smoke.dart'`
  (`tool/web_smoke.dart` imports the barrel and uses `WalletRepo.fromDatabase`, `backupBytes`, `MemoryLogSink`,
  `seal`/`unseal`, `SyncEngine` over `MemoryTransport` or `RelayTransport`, `deriveKey`; dart2wasm wants a `.wasm` output
  name). Run it whenever an import changes.

## Files
- `repo.dart` — `WalletRepo`: schema, reads, and every write. Writes go through `_write(...)` so each one
  becomes a sync op; never `db.execute` an INSERT/UPDATE on a data table directly. `_apply` checks each field's
  type (`_fieldValue`): a wrong-typed one is ignored (`repo.badField`, entity + field only) without recording its
  clock, the op's other fields apply, and a row is only created when some field applies. New column: add its type there.
- `budget.dart` — period maths: `PeriodBudget` (safe to spend), `MonthSummary`, `Affordability`. Budget vs actual per
  category (calendar months, owner decision 2026-10-20): `budgetVsActual(txs, month, budgets, today:)` →
  `BudgetVsActual` (one `CategoryBudgetLine` per category with a budget or any spend, actual desc then name; `actual` =
  `monthSummary(...).byCategory`, i.e. the "Where it goes" sums: live rows, fixed + flex, refunds subtracted, transfers
  and income out; `average6` = `averageByCategory`, the mean of the 6 months before, always ÷ 6; `remaining` = budget −
  actual; `pace` = actual ÷ (budget × elapsedDays ÷ daysInMonth), null without a budget, with budget 0 or for a future
  month; elapsedDays = day of `today` in the current month, the whole month for a past one; `remainingTotal` = Σ
  remaining over budgeted lines, null when none is budgeted). `suggestBudgets(txs, month)` = that average rounded UP to
  1000 cents, zero or negative averages omitted. Ints in cents everywhere, floats only in `pace`.
  `computePeriod(txs, st, goals, today, bills:)`: the confirmed recurring bills due before the next payday (exclusive)
  and not paid in this period are `dueBills`; those in flex categories sum to `reservedBills`, which comes off the
  flexible money on the same path as the planned fixed costs (owner decision 2026-10-20), so `planDaily`/`safeToday`
  drop until the paying row lands (a bill with `lastPaidTx` dated in the period is released even if its next due date
  still falls before payday). A due bill in a fixed category (`RecurringBill.coveredByPlan`: Rent, Loan, Bills &
  subscriptions) is already in `rent`/`loan`/`subs` and is listed but never reserved twice (owner rule: exact).
  `reviewState(txs, st, wishes, budgets, today:)` (M4 weekly review) → `ReviewState`: `due` from the first `reviewDay`
  after `lastReview` until done (never reviewed: due at once), `nextReviewDate` = that day (or the coming one),
  `steps` = `import` 0 (the UI fills it), `categories` = live spending rows of the last 7 days without a user-set
  category, `pace` = `budgetVsActual` lines over or behind pace this calendar month, `wishlist` = waiting items past
  their cooling-off at the end of `today`. `WalletRepo.markReviewDone(today)`: `lastReview` = today, `reviewStreak` +1
  when the previous review was < 14 days before (no review day skipped), else 1; the same day twice is a no-op.
- `recurring.dart` — recurring bills (M4). `detectRecurring(txs, today:)`: candidates = a payee (`merchantKey`) with ≥ 3
  live bank outflows (no transfers, no hand-added rows) in the last 7 calendar months, every gap 30 ± 3 days, every
  amount within 10 % of the median (`withinBand`, inclusive, int arithmetic); `expectedAmount` = median, `nextDue` =
  last payment + 30, label/category from the latest row, id `rec:<payee>` (`RecurringBill.idFor`) so every device
  derives the same row; ordered by label. One extra purchase at the payee breaks the chain (shops are never bills).
  `planRecurringPayments(bills, rows)`: for each confirmed bill the live bank row with its payee key within ± 3 days of
  `nextDue` and within 10 % of `expectedAmount` (closest, then earliest, then smallest id; never the row that paid the
  last cycle). `RecurringBill` (`models.dart`): synced entity `recurring` (`payee`, `label`, `category`,
  `expected_amount`, `interval_days`, `next_due`, `status` candidate|confirmed|dismissed, `last_paid_tx`, `deleted`).
  `WalletRepo.refreshRecurring(today)` runs after `importBatch` and once per sync run (`runPendingMatch`): adds new
  candidates (the creation op carries no `status`/`deleted`, so a late detection cannot undo a dismiss or delete made
  elsewhere; a payee with any row, deleted included, is never added again), keeps a candidate's amount/due/label/category
  at the latest detection (a row with an empty `payee`, made by a status op that arrived before its creation op, is
  filled the same way whatever its status), keeps a confirmed bill's `category` at the payee's current categorization
  (latest live bank outflow through the categorizer, so a merchant rule made later moves `coveredByPlan` with it:
  never reserved and in the fixed plan at once), and marks a confirmed bill's cycle paid (`last_paid_tx`, `next_due` =
  the paying row's date + `interval_days` — from the real payment like detection, so a bill paid on the 15th never
  drifts out of the ± 3-day window; `expected_amount` unchanged, cycle after cycle for a history import). The paying
  row keeps its category: a bill is information, never a reclassification. `recurringBills(includeDismissed:)`,
  `confirmRecurring`, `dismissRecurring`, `deleteRecurring` (unknown id → `ArgumentError`), `skipRecurring` (async;
  `next_due` += `interval_days` from its current value, no row needed, `last_paid_tx` untouched; no due date yet →
  `StateError`). Settings `reviewDay` (1..7, default 7), `lastReview` (date),
  `reviewStreak` (0..`maxStreak`) are validated like the others.
- `categories.dart` — `Categorizer`: item override → (paired transfer → importer `kindHint` → source/pattern rules) →
  per-merchant rules. `kindHint` (importer `TxKind`, stored as `tx.kind_hint` by `importBatch`, edited only by the schema-4 rewrite) decides
  first where it can: `salary` → Salary, `atm` → Rent at or above `rentCashThreshold` else Cash, `fee` → Bank fees,
  `ownTransfer` and `exchange` → Internal transfer; `standingOrder`, `card`, `other` and null fall through to the description rules
  (built-in merchant patterns, `merchantPatterns`). A row with `transferTo` is an Internal transfer before any hint.
  `account` from the importer is never stored (it names the owner's account).
- `transfers.dart` — `planTransfers`: own transfers between accounts. Only a row the bank itself marks as one
  (`kindHint == ownTransfer`: Revolut `Topup`, PBZ card payments to Revolut; not `exchange`, a conversion inside one bank) may pair: with the equal,
  opposite-sign row of the same currency in another source within `transferDays` (3, inclusive, either way in time),
  hinted or not. The two then hold each other's id in `tx.transfer_to`. Two unhinted rows never pair, whatever the
  amounts. Pure and deterministic: open outflows oldest first (date, id), each takes the closest open inflow it may pair
  with (both sides hinted first, then days, then earliest date, then smallest id); a row pairs once; a holding pair is never re-planned; a partner
  that is deleted, manual or points elsewhere reopens the row (`transfer_to` cleared, or re-paired at once); a pair
  with no hint on either side (an earlier build's amount-only rule) is dissolved on every device holding both rows
  (both `transfer_to` cleared through `_write`, so it syncs; the rows return to their normal categories); a partner not
  here yet keeps the link. A hinted row needs no partner (Internal transfer by its hint). `WalletRepo._pairTransfers`
  runs it before `_matchManual` (`_reconcile`: after imports, deletes and `runPendingMatch`), loading only rows with a
  possible partner (self-join on `amount`, index `tx_amount`, one side hinted) plus stale links and their targets
  (`_openTransfer` mirrors `openTransfers`). A paired row counts as gone for the manual match it replaced (the cash
  entry counts again). `ImportSummary.transfers` = new pairs.
- `matching.dart` — `planMatches`: hand-added expense ↔ bank row (same amount, ±3 days, one-to-one), deterministic;
  only a bank row the adding device did not hold yet replaces the entry (`SeenBank`: the entry's synced `seen_bank`,
  per device the highest bank `amount` clock held at add time; older entries: rows written after the entry). A match
  is reopened only when its bank row is deleted, never because the row has not arrived yet; until it arrives, reads
  mark the entry `Tx.matchPending` and it counts (`Tx.live`). `WalletRepo` runs it after imports, deletes and
  `applyRemote` (SyncEngine: once per run, only when caught up, `runPendingMatch`), loading only candidate rows.
  **Caught-up gate** (stage R, M1): local imports, deletes, the schema-4 rewrite and `applyRemote(match: true)` pair and
  match at once only while `WalletRepo.syncCaughtUp` (device-local `syncCaughtUp`, written by `SyncEngine` after every
  run; absent = never synced = caught up); otherwise they only set `match_pending` and the next caught-up run does it
  (`ImportSummary.transfers`/`matched` are then 0). A pair or match made against rows still on their way would never be
  re-planned. A delete still undoes the links to the deleted row at once (cash entry `matched_to`, partner
  `transfer_to` cleared through `_write`), so the entry it replaced counts again immediately; only new ones wait.
- `models.dart` — `Tx`, `Goal`, `GoalContribution`, `WishItem`, `WalletSettings` (row ↔ object), `goalTotal`.
  `WalletSettings.categoryBudgets` (synced setting, `{category: cents per month}`, default `{}`) is validated entry
  by entry: only `spendingCategories` (fixed + flex) with whole cents 0..`maxBudget` are kept, other entries are
  dropped (one `settings.invalid` with the key), a non-map value falls back to `{}`. Written whole by
  `updateSettings({'categoryBudgets': ...})`, last writer wins across devices like any setting.
- Goals: `Goal.saved` = stored `saved` column (the base) + live `goal_contrib` rows (synced entity: `goal_id`, `amount`
  cents, may be negative, `date`, `deleted`; created clock = its `amount` clock), summed at read (`goalTotal`, clamped to
  ±`Goal.maxSaved`; each row counts at most `Goal.maxContribution`; negative totals allowed, not clamped to 0). New
  builds write `saved` only when creating a goal; `saveGoal` with a changed total writes ONE contribution of the
  difference (from the unclamped total), `addGoalContribution` adds one, `payGoals(period:)` writes `pay:<goal>:<period>`
  rows (one per goal and period). Rows of a deleted or missing goal are hidden. Mixed versions: an older build writes
  `saved` as a full value of what it sees (the base only), so a later remote `saved` is simply the new base and
  contributions add on top. `addGoalContribution` writes nothing (returns null) for 0 or a goal deleted here (a sync
  may have removed it meanwhile); a goal that never existed here is an `ArgumentError`.
- `WalletRepo.schemaVersion` (meta `schema`): bump it when adding a synced entity or field (3 = `tx.kind_hint`,
  `tx.transfer_to`; 4 = the `exchange` hint: Revolut Exchange rows a version-3 build hinted `ownTransfer` are rewritten
  once through `_write` and reconciled, `revolutExchangeType`; 5 = the `recurring` entity). Opening an existing database with an older version
  clears the sync cursors (`sync_cursor`) once, so the next sync starts over like a new device (the latest snapshot if
  written by this schema or newer, else every file still on the relay) and applies ops (or fields) the older build skipped.
- `local_db.dart` — encrypted local database (§4.9, SQLite3MultipleCiphers, web-safe): `localDbKey(VaultKey)` = HKDF
  (`bw-local-db-v1`, 32 bytes), `openKeyed(open, dbKey)` → the database keyed with `PRAGMA key = "x'<hex>'"` (raw key,
  no KDF). Keyed first; only if that cannot read it ("file is not a database", 26) unkeyed: readable = plaintext →
  row counts per table, `journal_mode=DELETE` (sqlite3mc refuses to rekey a WAL database; the switch checkpoints it),
  `PRAGMA rekey`, reopen keyed, same counts or `StateError`; unreadable both ways → `WalletDbKeyException` (file left as
  it was). A new/empty database is keyed from the start. Web path relies on rekey being one journaled transaction
  (checked by killing a converting process, see the doc comment). Native `WalletRepo.open(path, dbKey:)` →
  `openKeyedFileDb` (`sqlite_io.dart`): before the rekey the complete plaintext file is copied to
  `<path>.plain-copy` (temp + rename), deleted only after the check; a copy found at open = interrupted conversion →
  main/-wal/-shm/-journal replaced by it and converted again; a failed rekey or check restores it at once. Test hook
  `step:` (`copied`, `rekeyed`, `verified`). The app (R6b) passes the key on native and wraps the web VFS
  (`multipleciphers-<fs>`) itself.
- `dates.dart` — `YYYY-MM-DD` string helpers. `hlc.dart`, `vault.dart` (key + encryption; `UnsealFailure` says why a
  file was refused; `deriveKey` = HKDF-SHA256, empty salt), `sync.dart` (`SyncException`, `SyncReport`, `SyncWaiting`,
  `SyncDevice`; web-safe) + `sync_engine.dart` (below).
- `backup.dart` — backups (M5, owner decision 2026-10-22: no sync folder any more, "Back up now" saves the sealed `.bwb` through the save dialog,
  encrypted with the wallet key, restore only into an empty wallet; the `*_io.dart` folder helpers below are the older folder variant). Pure half (web-safe): `backupFileName(today)` = `bw-backup-<today>.bwb`
  (`ArgumentError` unless `YYYY-MM-DD`), `backupBytes(repo, key)` = the sealed payload, `restoreBackupBytes(repo,
  bytes, key)` = everything a restore does once the bytes are in hand. File half (`backup_io.dart`):
  `writeBackup(repo, syncFolder, key, today:)` writes `backupBytes` to
  `<syncFolder>/budget-wallet/backups/bw-backup-<today>.bwb` (`backupPath`, `backupsFolder`; temp file + rename, the
  same day's file is replaced) sealed with `seal()` like a sync file; payload UTF-8 JSON `{"v":1,"ops":[...]}` =
  `WalletRepo.snapshotOps()`: every row of every synced entity, deleted rows and settings included, as one op per
  distinct field clock (the fields written with that clock and their current values; a field with no clock, i.e. the
  column default, is left out), so a restore records the very same clocks; device-local values never. Returns the file
  name; logs `backup.write` with the op count. `restoreBackup(repo, file, key)` (full path): `StateError` unless
  `repo.isEmpty` (no row at all, deleted included, in tx, goals, goal_contrib, wish, recurring, merchant_rules,
  settings) before the file is touched; unseal errors are the `VaultException`; a file that cannot be read, is not a
  backup or has a clock that does not parse is a `BackupException` (`reason`: `BackupFailure.unreadable`, `damaged`,
  `newerVersion` for `v` > `backupVersion`; nothing applied unless the whole file parses). The ops go through
  `applyRemote(ops, resend: true)`: matching, pairing and bill detection run once at the end, and the ops are queued in
  the outbox with their clocks unchanged, so the next sync exports them as this device's file and the restored state
  reaches the other devices like local writes (devices already holding those fields at the same clocks change nothing:
  a clock is only accepted when newer; a restore into a wallet whose relay still has every device's files converges either
  way, the resend covers pruned files or a new relay). Returns the op count. `listBackups(syncFolder)` →
  `BackupInfo(name, date, path)` (full path for `restoreBackup`) newest first, only `bw-backup-YYYY-MM-DD.bwb` names, missing folder → `[]`.
- `export.dart` — CSV (M5, pure, the app saves the text through the system dialog; unencrypted, the app warns once).
  `transactionsCsv(List<CategorizedTx>)`: `date,amount,category,description,source,note`, live rows only (`Tx.live`:
  no deleted rows, no hand-added entries replaced by a bank row that is here), sorted date then id, `amount` the
  stored signed cents as an exact decimal (`centsToDecimal`: int arithmetic, dot, two digits, never `-0.00`),
  `category` the resolved one, RFC 4180 fields (`csvField`: quoted when holding `"`, `,`, LF or CR; quotes doubled),
  LF ends, UTF-8 without BOM. `monthlySummaryCsv(List<CategorizedTx>)`: `month,<spendingCategories in order>,total`,
  one record per month with a live row in a spending category, ascending; a cell = Σ −amount of that category (refunds
  reduce it, a net refund prints negative, `0.00` without spending), `total` = Σ cells; income, transfers, deleted and
  replaced rows never count.
- `search.dart` — `searchAll(query, txs:, goals:, wishlist:, bills:)` → `SearchResult` (`txs` newest first capped at
  `searchTxLimit` 200, `goals`, `wishlist`, `bills`, `isEmpty`; blank query → `SearchResult.empty`). Text: `foldText`
  (lower case, č ć š ž đ → c c s z d, `dj` → `d`, common Latin accents) substring over tx description/note/category
  (resolved), goal name, wish name, bill label/category; live rows only. Amount: `parseAmountQuery` (`12`, `12.5`,
  `12,50`, `-12.50`, `12.50 €`; null for `12.`, more than two decimals — never rounded —, words, thousands separators,
  > 15 digits) → cents; matches `Tx.amount.abs()`, goal target or saved, wish price, bill expectedAmount. A query
  that is both matches either way; a row is listed once.
- `sync_problems.dart` — a peer file that cannot be used is skipped (the run goes on with the other files and devices)
  and quarantined: `BadFiles`, one device-local value (`localValue('syncBadFiles')`, never synced), records device,
  file, `SyncProblemReason` (`badKey`, `corrupt`, `unknownVersion`, `applyFailed`; `unreadable` = I/O error, not
  quarantined), size and content hash. It is read again only when its content changes, or (unknownVersion,
  applyFailed) once after `SyncEngine.build` changes (`<syncReaderVersion>.<WalletRepo.schemaVersion>+<app version
  passed to SyncEngine>`). `SyncReport.problems` lists every file not applied, also the known ones on every run
  (`SyncProblem`: short device id = first 8 characters of its id, reason, bytes, `isNew`), `badFiles` is
  their count. Database errors that are about this device (read-only, disk full, I/O, locked) stop the run instead,
  so the file is not refused for good. The quarantine is separate from the cursors: a schema upgrade reads every
  peer file again, an unchanged badKey/corrupt file stays skipped, unknownVersion/applyFailed are tried once more.
- `sync_engine.dart` — relay sync (§4.9, wire protocol `docs/context/RELAY_PROTOCOL.md`), web-safe. `SyncTransport`
  (`state`, `put`, `get`, `ack`, `putSnapshot`, `getSnapshot`; failures are `TransportException(TransportFailure)`),
  `RelayState`/`RelayDevice`/`RelaySnapshot` (+ `fromJson`), implemented by `MemoryTransport` (`sync_memory.dart`: the
  relay's rules in memory — no gaps, never overwritten, acks grow, snapshot 422 before 409, two kept snapshots, pruning
  incl. the 90-day rule driven by `now`; no token check; test hooks `offline`, `corrupt`, `failGet`, `replace`, `files`,
  `calls`) and `RelayTransport` (`sync_relay.dart`, `package:http`: wid/token from `deriveKey`, Bearer header,
  `X-BW-Covers`, status → failure, `api` > 1 → `newerApi`, 404 state = empty relay, 30 s timeout; `health(base)`).
  `SyncEngine(transport, key, appVersion:, now:, partBytes:).run(repo)`: reads `state`; uploads pending ops as `last + 1`
  (seq from the relay, so a failed PUT leaves no gap; 409/422 keep the outbox for the next run); the **first run on a
  relay** (local `syncSent` absent, or the relay's `last` for this device below it = a new or wiped relay) uploads
  `snapshotOps()` instead (the migration from the folder sync). Any upload is split into several seqs, each sealed file
  ≤ `partBytes` (default `maxPartBytes` 8 MiB; the relay refuses > 16 MiB): by op count, sealed size measured, halved
  while over; the outbox and `syncSent` change only after every part is stored, so a run that stops half-way sends it all
  again (idempotent). `MemoryTransport.maxFileBytes` (default 16 MiB) lowers the limit in tests. Cursors (`sync_cursor` table, device-local, `WalletRepo.syncCursors`):
  per other device the last seq applied; files apply strictly in order; the first file that cannot be fetched (`waiting`
  with reason null + an `unreadable` problem), is pruned without a usable snapshot, or is refused (quarantined in
  `BadFiles` under `<device>/<seq>`, fetched and hashed again each run) stops that device. A cursor above a device's
  `last` is reset to 0 (relay lost its files). Snapshot use: when a needed file is pruned; when this device applied
  nothing yet (new device, schema-bump replay) and the snapshot id says this schema or newer (`s<schema>-<ms>-<hex>`);
  and when a blocked file is covered by the snapshot (then the device goes on after it). Latest first, then `previous`;
  covers raise the cursors. The unblock case only for a quarantined wait (`SyncWaiting.reason` set, not a file that
  could not be fetched) and, like the new-device case, only with a snapshot of this schema or newer (latest or
  `previous`, whichever covers it). A snapshot that could not be fetched or refused to apply is remembered device-locally
  (`syncBadSnapshots` = `{"<id>": {reason (null = not fetched), bytes, hash, build, at}}`) and not downloaded again until
  the relay names another id (unknownVersion/applyFailed: once more after `build` changes; not fetched: retried after
  `snapshotRetry`, 1 h); records of ids no longer listed are dropped. It is reported in `SyncReport.problems` as a
  `SyncProblem` with `snapshot: true` and `device` '' (counts in `badFiles`, not in `caughtUp`). Acks every run (a failed ack is only logged). `caughtUp` = no waiting, no problem, every
  device applied through `last` (stored as `syncCaughtUp`, see matching): only then `runPendingMatch()` and the snapshot check: written when files not covered by
  the newest snapshot hold ≥ 500 ops (`sync_files`: ops per recorded file, own uploads included) or the newest is older
  than 7 days (none yet: 7 days since this device's first relay sync, local `syncSince`); payload = backup format,
  covers = every listed device's cursor + own last; refused (another device was faster) is only logged. Self-heal
  (`_trackStuck`, every run): a peer seen within `stuckAfter` (24 h) whose ack for any device D (this one included)
  stays below what this device holds of D (its cursor, or its own last; same value, tracked device-locally in
  `syncPeerStuck` = `{"<peer>/<D>": [ack, sinceMs]}`) for over 24 h, while the newest snapshot does not cover the file it
  needs, makes this device (when caught up) write a snapshot at once; at most one heal snapshot per device per 24 h
  (`syncHealAt`), and a second healer skips once the first one's snapshot covers the file. `SyncReport`:
  `sent` ops, `received` fields changed, `filesRead` (snapshots count), `problems`, `caughtUp`, `waiting`, `devices`
  (short ids, `lastSeen`, `isThis`). Fatal `SyncException`s (short, no address): unreachable, refused (401), relay
  full, newer relay API, other. Opening a folder-sync database drops `peer_files` (`repo.peerFiles.dropped`).
- `logs.dart` — logging (`package:logging`): `logEvent`/`logError` (structured events), `formatLogRecord` (one line,
  errors via `describeError`, which drops SQL parameters, paths and FormatException sources), `LogSink` (`add`,
  `flush`, `close`) with `MemoryLogSink` (ring buffer by UTF-8 bytes, `maxBytes` default 2 MiB, oldest lines dropped
  and counted in `dropped`, the newest line always kept; `lines`, `dump()` = lines joined with `\n`; the web app's
  Diagnostics download) and `RotatingFileSink` (`logs_io.dart`, native), `timed`/`timedAsync`/`PerfTimer` (on
  `bw.perf`), `FrameStats`.

## Rules
- Amounts are `int` cents; expenses negative. Dates are `YYYY-MM-DD` strings.
- New table or field: add it to the entity map at the top of `repo.dart` (so it syncs) and to the schema;
  existing devices must still open old databases (add columns, never rename).
- Pure functions for new calculations (inputs → result object), so tests need no database.
- **Money is never reclassified on amount alone** (owner rule). Hiding a row as a transfer, or moving it to another
  category, needs evidence from the bank row itself (the importer's `kindHint`, its type or text); an equal amount in
  another account within a few days is never enough on its own. The same goes for any future "looks like" rule.
- Keep `vault.dart` / `sync.dart` file formats backward compatible (`BWOP1`, `BW1-` keys), and the backup payload
  (`{"v":1,"ops":[...]}`): a new shape bumps `backupVersion`, and older builds refuse it as `newerVersion`.
- Backups: never restore into a wallet with data (the relay is the merge path); `snapshotOps` must keep each
  field's own clock (grouping fields by clock), never one fresh clock per row, or a restored device would overrule
  edits other devices made in between.
- Logging: loggers `bw.<area>`; every catch block logs (`logError`). Log counts, durations, sizes, dates, built-in
  categories, setting keys. **Never** amounts, descriptions, merchants, notes, goal/wish names, the key, device ids,
  paths or file names. Noisy per-render logs at FINER. `test/logs_impl_test.dart` checks core logs stay clean.

## Known limits (for the sync redesign)
- The same export imported on two devices before they sync: the later import's `amount` clock wins, so a cash entry
  added in between on the first device can be matched to that row although that device held it.
- A sync file changed after sealing fails authentication like one sealed with another key: both are `badKey`
  (`MemoryTransport.corrupt` flips the magic too, so it gives `corrupt`).
- A refused relay file that no snapshot covers stops that device's later files on every device that has not applied it
  (the relay never overwrites a file, the blocked reader never acks past it; matching and pairing wait there, cash
  entries keep counting). Self-heal: any caught-up device that applied the file (the author or another one), once it
  has seen the blocked device (seen within 24 h) stay below it for over 24 h, writes a snapshot covering it, and the
  blocked device goes on from it on its next run. Remaining case: no device that applied the file before it was
  damaged is still syncing and caught up; then it clears only when a newer build reads it (unknownVersion/applyFailed)
  or the file is repaired on the server. A blocked device that cannot read snapshots stays blocked (no storm: the
  snapshot covers the file, so nobody writes another).
- Encrypted local database: a database encrypted with one wallet key cannot be opened after joining another wallet
  (`WalletDbKeyException`; the app decides what to do). The side copy of a native conversion is plaintext for as long
  as the conversion runs (deleted after the check, or used to recover at the next open).
- Older builds ignore `seen_bank` and match by the old rule: devices on mixed versions can plan different matches,
  and keep doing so after upgrading for entries they received before.
- A wrong-typed field (e.g. `amount: "abc"`) is refused with no clock only by builds that check types: older builds
  stored it with its clock, so a later valid write with an older clock wins on new devices and loses on old ones
  until the next write. Only a buggy writer causes this.
- `VaultKey.parse` accepts junk after a valid key (extra characters past the 34 key + checksum bytes are ignored).
- Goal totals on mixed versions: older builds ignore `goal_contrib`, so they show only the base (adds made on new
  devices are missing there until they upgrade; the upgrade replays all sync files once). A total typed on an old device
  from a value seen on a new one counts those adds twice.
- Goal contributions are deltas: two offline "set to X" edits both apply (two corrections to 0 from 50 give −50;
  shown as is, and the next edit sets the exact value). Paying goals offline on two devices counts once only when both
  pass the same `period` (or share the `periodStart` setting); otherwise twice.
- Snapshots are made from the writer's database, so one written by an older build lacks the fields that build does not
  know. A schema-bump replay or a new device ignores a snapshot of an older schema while the files are still there, but a
  device whose next file is pruned starts from it anyway and misses those fields until they are written again.
- A wiped (or new) relay: each device notices its own files are gone (`last` below its `syncSent`) and uploads its whole
  state again, and a peer cursor above that peer's `last` is reset. If a peer re-uploaded more files than the old cursor
  before this device syncs, the cursor is trusted and the files between are skipped (seq numbers carry no relay identity).
- Two installs with the same device id (a copied database) write into one seq stream; a 409/422 on upload keeps the
  outbox for the next run, so both get through, interleaved.
- The snapshot rule's "500 ops behind" counts only the files this device applied or sent itself (`sync_files`); files it
  skipped by starting from a snapshot are not counted.
- Own transfers: two devices that pair offline from different row sets can write different partners for one row;
  after sync the non-mutual link is cleared and the pair that both hold stays. A hinted row with two equal candidates
  takes the closest, which can be the wrong one (the real one then stays open; the user override corrects the
  category but not the link). A pair made by the earlier amount-only rule stays on a device that holds only one of its
  rows until the partner arrives. Older builds drop `kind_hint`/`transfer_to` from ops they apply (replayed once on
  upgrade) and categorize a paired row by its text, so they can show a transfer as spending until they upgrade.
- A remote clock far in the future (a peer with a wrong date) is taken as is: this device's later writes sort after it,
  and an edit made on a device with a correct clock loses to that peer's older edits until real time catches up.
- Recurring bills: a device that imports a payee's rows before syncing writes the candidate's amount/due/label again
  with a newer clock (same values from the same rows; different ones if it holds other rows), but never its status.
  A confirmed bill whose payment is not matched (amount moved > 10 %, paid > 3 days off the expected date, paid from an
  account not imported, or the bill ended) keeps its `nextDue`, so it stays reserved as overdue until the owner acts:
  `skipRecurring` moves it one interval on (the match then looks around the new date; the unmatched row still counts as
  spending, the bill is not reserved for that cycle), dismiss or delete end it. The amount band is not adjusted by a
  skip: a bill whose amount moved for good needs delete + re-confirm once detection sees three new rows. Older builds
  ignore the `recurring` entity (replayed once on upgrade).

## Tests
- `test/core_test.dart`, one `group` per area. Shared synthetic data in `test/support/synthetic.dart`
  (`n(...)` builds a transaction, `january` is a sample month). Add new feature tests as `test/<feature>_test.dart`
  (goals: `test/goal_contrib_test.dart`, quarantine: `test/sync_quarantine_test.dart`, hints: `test/kind_hint_test.dart`,
  own transfers incl. two devices: `test/transfers_test.dart`, budgets per category incl. the setting and two devices:
  `test/budget_vs_actual_test.dart`, recurring bills + weekly review incl. two devices: `test/habits_test.dart`, M5 backup
  round trip incl. two devices + resend: `test/backup_test.dart`, CSV: `test/export_test.dart`, search: `test/search_test.dart`,
  web-safe core (`fromDatabase`, `backupBytes`/`restoreBackupBytes`, `MemoryLogSink`, gzip compatibility): `test/web_core_test.dart`,
  encrypted local database (new/convert/wrong key/WAL/interrupted conversion/perf numbers): `test/local_db_test.dart`
  (sqlite3mc proof tests: `test/encrypted_db_test.dart`), sync self-heal: `test/sync_self_heal_test.dart`;
  `<feature>_edge_test.dart` and `<feature>_spec_test.dart` are spec-written tests). Multi-device sim in `test/support/sim.dart` (lists entities on its own): `Net` (one
  `MemoryTransport`; a `Device` uses the latest `Net` made unless given `net:`), `Device` (own database; `run()` uploads
  and applies, `deliver(net, r, p:)` makes the next run's GETs fail with probability 1 − p, `upload` is a no-op kept for
  the helpers; `dbPath:` + `reopen()` simulate a restart or upgrade), `opsInNet`, `dump`, `bookkeeping`. Sync engine:
  `test/sync_scenarios_test.dart`, `sync_convergence_test.dart` (random, 2-4 devices), `sync_quarantine*_test.dart`,
  `sync_read_edge_test.dart`, `match_gate_test.dart` (matching only when caught up), `sync_snapshot_use_test.dart`
  (unblock conditions, remembered snapshots), `sync_split_upload_test.dart` (uploads over one file), `sync_engine_spec_test.dart` (+ `support/engine_spec_sim.dart`, shared fake clock: snapshots,
  pruning, first connect, S1/S2), `sync_relay_test.dart` (`deriveKey` vs. a hand-written HKDF, `RelayTransport` over
  `MockClient`, `MemoryTransport` rules, end to end with the real `relay/` server on port 0).
- Run: `tools/build.sh test` from the repo root (or `tools/build.sh shell`, then `cd packages/wallet_core && dart test`).
