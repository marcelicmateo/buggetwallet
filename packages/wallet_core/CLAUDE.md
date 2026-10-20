# wallet_core — notes for Claude

Pure Dart (no Flutter): SQLite repo, field-level change log with HLC, encrypted folder sync, categories,
budget engine. **All money logic lives here**, so it can be unit-tested without the UI.

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
  `applyRemote` (FolderSync: once per run, `runPendingMatch`), loading only candidate rows.
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
  once through `_write` and reconciled, `revolutExchangeType`). Opening an existing database with an older version
  clears `peer_files` once, so the next sync re-reads every file and applies ops (or fields) the older build skipped.
- `dates.dart` — `YYYY-MM-DD` string helpers. `hlc.dart`, `vault.dart` (key + encryption; `UnsealFailure` says why a
  file was refused), `sync.dart` (FolderSync).
- `sync_problems.dart` — a peer file that cannot be used is skipped (the run goes on with the other files and devices)
  and quarantined: `BadFiles`, one device-local value (`localValue('syncBadFiles')`, never synced), records device,
  file, `SyncProblemReason` (`badKey`, `corrupt`, `unknownVersion`, `applyFailed`; `unreadable` = I/O error, not
  quarantined), size and content hash. It is read again only when its content changes, or (unknownVersion,
  applyFailed) once after `FolderSync.build` changes (`<syncReaderVersion>.<WalletRepo.schemaVersion>+<app version
  passed to FolderSync>`). `SyncReport.problems` lists every file not applied, also the known ones on every run
  (`SyncProblem`: short device id = first 8 characters of its folder name, reason, bytes, `isNew`), `badFiles` is
  their count. Database errors that are about this device (read-only, disk full, I/O, locked) stop the run instead,
  so the file is not refused for good. The quarantine is separate from `peer_files`: a schema upgrade lists every
  peer file again, an unchanged badKey/corrupt file stays skipped, unknownVersion/applyFailed are tried once more.
- `logs.dart` — logging (`package:logging`): `logEvent`/`logError` (structured events), `formatLogRecord` (one line,
  errors via `describeError`, which drops SQL parameters, paths and FormatException sources), `RotatingFileSink`,
  `timed`/`timedAsync`/`PerfTimer` (on `bw.perf`), `FrameStats`.

## Rules
- Amounts are `int` cents; expenses negative. Dates are `YYYY-MM-DD` strings.
- New table or field: add it to the entity map at the top of `repo.dart` (so it syncs) and to the schema;
  existing devices must still open old databases (add columns, never rename).
- Pure functions for new calculations (inputs → result object), so tests need no database.
- **Money is never reclassified on amount alone** (owner rule). Hiding a row as a transfer, or moving it to another
  category, needs evidence from the bank row itself (the importer's `kindHint`, its type or text); an equal amount in
  another account within a few days is never enough on its own. The same goes for any future "looks like" rule.
- Keep `vault.dart` / `sync.dart` file formats backward compatible (`BWOP1`, `BW1-` keys).
- Logging: loggers `bw.<area>`; every catch block logs (`logError`). Log counts, durations, sizes, dates, built-in
  categories, setting keys. **Never** amounts, descriptions, merchants, notes, goal/wish names, the key, device ids,
  paths or file names. Noisy per-render logs at FINER. `test/logs_impl_test.dart` checks core logs stay clean.

## Known limits (for the sync redesign)
- The same export imported on two devices before they sync: the later import's `amount` clock wins, so a cash entry
  added in between on the first device can be matched to that row although that device held it.
- A damaged, quarantined or late sync file (files from a device are applied even past a gap) while later files from that
  device apply: `seen_bank` (per-device maximum) then claims rows the adding device never got, those never replace the
  entry, and the expense counts twice. Quarantine does not change this (before it, a bad file was retried every run
  with the same result); a repaired copy still applies.
- A sync file changed after sealing fails authentication like one sealed with another key: both are `badKey`.
- Older builds ignore `seen_bank` and match by the old rule: devices on mixed versions can plan different matches,
  and keep doing so after upgrading for entries they received before.
- A device that is behind can match a cash entry to an earlier same-amount card payment (±3 days) it never held.
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
- Replay on upgrade needs the old sync files: once files are pruned (gap 4), snapshots must carry `goal_contrib` rows.
- Own transfers: two devices that pair offline from different row sets can write different partners for one row;
  after sync the non-mutual link is cleared and the pair that both hold stays. A hinted row with two equal candidates
  takes the closest, which can be the wrong one (the real one then stays open; the user override corrects the
  category but not the link). A pair made by the earlier amount-only rule stays on a device that holds only one of its
  rows until the partner arrives. Older builds drop `kind_hint`/`transfer_to` from ops they apply (replayed once on
  upgrade) and categorize a paired row by its text, so they can show a transfer as spending until they upgrade.
- A remote clock far in the future (a peer with a wrong date) is taken as is: this device's later writes sort after it,
  and an edit made on a device with a correct clock loses to that peer's older edits until real time catches up.

## Tests
- `test/core_test.dart`, one `group` per area. Shared synthetic data in `test/support/synthetic.dart`
  (`n(...)` builds a transaction, `january` is a sample month). Add new feature tests as `test/<feature>_test.dart`
  (goals: `test/goal_contrib_test.dart`, quarantine: `test/sync_quarantine_test.dart`, hints: `test/kind_hint_test.dart`,
  own transfers incl. two devices: `test/transfers_test.dart`, budgets per category incl. the setting and two devices:
  `test/budget_vs_actual_test.dart`; `<feature>_edge_test.dart` are
  spec-written edge cases). Multi-device sim in `test/support/sim.dart` (lists entities on its own): `Device` (own
  folder and database; `dbPath:` + `reopen()` simulate a restart or upgrade), `Net`, `dump`, `bookkeeping`.
- Run: `tools/build.sh test` from the repo root (or `tools/build.sh shell`, then `cd packages/wallet_core && dart test`).
