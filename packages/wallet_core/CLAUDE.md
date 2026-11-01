# wallet_core — notes for Claude

Pure Dart (no Flutter): SQLite repo, field-level change log with HLC, vault (encryption), backups, categories,
budget engine. **All money logic lives here**, so it can be unit-tested without the UI.
The relay sync engine, its transports and `BlobStore` are in `packages/sync` (`wallet_sync`, its own `CLAUDE.md`).
**Dependency cycle, tests only (J4):** `wallet_sync` depends on core; core has `wallet_sync` as a *dev* dependency so
its feature tests can sync two devices (`test/support/sim.dart`). `lib/` and `tool/` never import `package:wallet_sync`
and it never becomes a regular dependency (`test/layering_test.dart`). Errors from sync are logged as their text
through the `LogSafeError` marker (`logs.dart`), so core needs no sync types.

## Web rule (§4.8: the barrel compiles for the web)
`package:wallet_core/wallet_core.dart` must compile with dart2js and dart2wasm, with identical behaviour on native.
Nothing reachable from the barrel may import `dart:io`, `dart:ffi` or `package:sqlite3/sqlite3.dart` unconditionally.
- Database code uses `package:sqlite3/common.dart` (`WalletRepo.db` is a `CommonDatabase`). `WalletRepo.open(path)` /
  `inMemory()` (and `open(path, dbKey:)`, `openKeyedFileDb`) go through `sqlite_io.dart` (native) or `sqlite_web.dart` (throws); the web app opens a
  `package:sqlite3/wasm.dart` database itself and calls `WalletRepo.fromDatabase(db, file:)` (same pragmas/migrations).
- dart:io code lives in `*_io.dart` files with a `*_web.dart` twin of the same public names that throws
  `UnsupportedError`; the barrel picks one with `export 'src/x_io.dart' if (dart.library.js_interop) 'src/x_web.dart';`:
  `logs_io.dart` (`RotatingFileSink`). `platform_error_io/web.dart` give `describeError` its
  dart:io case. New dart:io code goes in one of these (or a new pair), never in a shared file.
- gzip comes from `package:archive` (`vault.dart`): on the VM it is `dart:io`'s codec (same bytes as before), in the
  browser pure Dart; both write one standard gzip member, which is what `_wholeGzip` and older builds check.
  `test/web_core_test.dart` pins that dart:io members unseal and that pure-Dart members are accepted.
- `hlc.dart`: no int literal above 2^53 (dart2js refuses it); `_maxInt` is 2^53 − 1 there, 2^63 − 1 elsewhere.
- Compile check (after `dart pub get` in the package): `tools/build.sh shell -c 'cd packages/wallet_core && dart compile js
  -o /dev/null tool/web_smoke.dart && dart compile wasm -o ../../dist/web_smoke.wasm tool/web_smoke.dart'`
  (`tool/web_smoke.dart` imports the barrel and uses `WalletRepo.fromDatabase`, `backupBytes`, `MemoryLogSink`,
  `seal`/`unseal`, `deriveKey`; the sync half is `packages/sync/tool/web_smoke.dart`; dart2wasm wants a `.wasm` output
  name). Run it whenever an import changes.

## Files
- `schema.dart` — the typed entity schema: `entitySchema` (entity → `EntityDef`: table, `ColumnDef`s with type
  text/integer/flag, nullable, searchable, default, indexes). The DDL (`schemaSql`), the column migration on open,
  `_apply`'s type check, the snapshot writer, `isEmpty` and `searchRows` derive from it; `test/schema_test.dart` pins
  the generated DDL to the hand-written v7 text and checks it against `test/support/sim.dart`'s independent list.
  `addTestEntity` (tests only) adds a throwaway entity on top (`entitySchema` is a read-only view; `schemaSql` a getter).
- `cols.dart` — typed columns (F1, `docs/context/FIELDS_PLAN.md`): `sealed class Col<T>` extends `ColumnDef` (`entity`,
  `column`, `label`, `defaultValue`, `read` lenient = bad/missing → default, `encode`, `problem(v, today:)` = reason
  without the label, `accepts` = Dart type); kinds `TextCol(maxLength)`, `DateCol(notAfterToday)`, `IntCol(min, max,
  unit)`, `MoneyCol(cap = maxAmount, positive, currencyCol)` (its cap is the sync cap, not `_amountCaps`), `FlagCol`,
  `EnumCol(values, wire)`, `RefCol(target)`, `JsonCol(check)`; `clearValue`; `RowModel` (`row`, `model[col]`).
  Holders `BillCols` (bills.dart) and `AccountCols` (models.dart) are `entitySchema['bill'/'account']`; `Bill`/`Account`
  are `RowModel`s whose getters read through them. `repo_patch.dart` (`WalletRepoPatch.patch(entity, id, {col: v})`):
  type + `problem` for every value first (`ArgumentError('<label>: <reason>')`, nothing written), null/`clearValue` =
  none, one op in the map's order; bill hook = `_liveBill` + `_billWrites` (status, links, file, source, currency,
  unsure, deleted refused: their own actions), account hook = `updateAccount`'s rules and texts (trim, "Give the account
  a name.", shape, unique, opening pair, diff; currency/deleted refused); other entities: the row must exist.
  `updateBill`/`updateAccount` are wrappers over it. Incoming ops keep the old check (type, nullability, cap only).
  Tests: `test/f1_cols_test.dart` (kinds, patch, done check with a test-only entity), spec tests `f1_wire_test.dart`,
  `f1_mixed_test.dart`, `f1_refusals_test.dart`.
- `repo.dart` — `WalletRepo`: open/migrate, change log, reads, and every write. Writes go through `_write(...)` so each one
  becomes a sync op; never `db.execute` an INSERT/UPDATE on a data table directly. `_apply` reads the row's clocks once
  and checks each field's type (`_fieldValue` by its `ColumnDef`): a wrong-typed one is ignored (`repo.badField`, entity +
  field only) without recording its clock, the op's other fields apply, and a row is only created when some field applies.
  Sections live in `part` files as extensions on `WalletRepo` (same library, so they use `_write`): `repo_planned.dart`
  (`WalletRepoPlanned`), `repo_bills.dart` (`WalletRepoBills`), `repo_blobs.dart` (`WalletRepoBlobs`), `repo_settings.dart`
  (`WalletRepoSettings`: `setCategoryBudget`, `setMerchantPattern`, `removeMerchantPattern`, the schema-8 migration, and
  `_readSettings`/`_settingChanges` behind `settings()`/`updateSettings`).
  Stage Q0 split the core of `repo.dart` (moves only): `repo_import.dart` (`WalletRepoImport`: matching/transfer glue,
  `_reconcile`, `_reconcileLocal`, `runPendingMatch`), `repo_sync_apply.dart` (`WalletRepoSyncApply`: `_apply`, `_fieldValue`,
  `applyRemote` (`repair`: VC, an equal clock with another value keeps the stored value and records a device-local
  `SyncConflict` (`sync_conflicts.dart`): `syncConflicts()` (local value `syncConflicts`, ≤ 500, oldest dropped; an
  entry whose field clock changed, row is gone or value now equals theirs is dropped on read; ordered entity, row,
  field), `resolveSyncConflict(id, keepMine:)` = owner write of the choice through `_write`; a clock without its row
  takes the resend value), `snapshotOps`, `queueStateResend`,
  `stateDigest` (V2: SHA-256 of the canonical synced state), `clockStats`, sync cursors/files), `repo_tx.dart` (`WalletRepoTx`: `setCategory`, delete/undelete
  transaction, merchant rules), `repo_meta.dart` (`WalletRepoMeta`: `_migrate`, `_meta`). An extension member is visible only
  where the barrel is imported, so public methods that app/sync files reach without that import (`importBatch`,
  `addTransaction`, `transactions`, `localValue`, `setLocalValue`, `pendingOps`) stay on the class.
  `importBatch`: a known id whose stored row has another `amount` or `description` is an id collision: skipped like a
  duplicate (never overwritten), counted in `ImportSummary.collisions` (also in `duplicates`) and logged as
  `repo.idCollision {source, count}` (WARNING; never ids, amounts or descriptions).
  Undo (Stage I): `undeleteTransaction(id)` / `undeleteGoal(id)` are owner writes of `deleted: 0` (synced; the later
  of it and a delete by HLC wins, §4.10; an unknown id → `ArgumentError`, a live row → nothing written). A row keeps
  its other fields (a hand-added entry its `matched_to`); a goal's contributions come back with it; the tx undo then
  runs `_reconcileLocal`. `deleteTransaction` keeps, in device-local meta `undo.<txId>` (`{"at", "bills", "matched",
  "transfer"}`, only when one is non-empty; removed by the undo, or after a day by `_purgeUndo` at open and on every
  delete), the bills it unlinked, the hand-added entries the row replaced (`matched_to`) and its own-transfer partners
  (`transfer_to`), read before the delete. The undo writes them back in the same write: the bill when it is still
  live, unlinked, and no other live bill holds the row (automatic linking takes only bank rows); `matched_to` /
  `transfer_to` when still null and the entry/partner is live (and the row's own `transfer_to` if it was cleared).
  Without this, an undo while not caught up would count a cash entry and its bank row (or a pair's legs) twice.
  Logs `repo.undelete {entity, bills, matches, transfers}`. Tests: `test/undelete_test.dart`.
  `WalletRepo.dataVersion`: in-memory counter, +1 per committed transaction that wrote data (`_apply` accepted a field:
  local `_write`, `applyRemote`, snapshots, restore/merge); bookkeeping, no-op applies, refused files and dry runs leave
  it. The app's "data changed" mark (`clockStats` = count/max of `clocks` is not one: an older-clock peer edit keeps
  both). Tests: `test/data_version_test.dart`.
  `WalletRepo.isWriteError(e)`: true for an error that left a rolled-back write transaction (`_tx` marks it in an
  `Expando`; reads never), so the app's "Couldn't save" fires only for writes (no stack-frame names: web minifies,
  AOT inlines). Tests: `test/write_error_test.dart`.
- `budget.dart` — period maths: `PeriodBudget` (safe to spend), `MonthSummary`, `Affordability`. **Currency (H1):** only
  rows with `tx.currency == settings.currency` count in `computePeriod`, `monthSummary`, `periodSummaries` (and
  `salaryPaydays`/`detectPaydays`), `averageByCategory`, `suggestBudgets`, `budgetVsActual`, `reviewState`'s pace and
  `monthlySummaryCsv`; functions without settings take `currency:` (required). `PeriodBudget.foreignByCurrency` /
  `MonthSummary.foreignByCurrency` = signed sums of the live income/extra/fixed/flex rows left out, by currency (empty
  when none; transfers count nowhere). `transactionsCsv` and search keep every currency. Recurring bills too: only
  home-currency rows make a candidate (`detectRecurring(..., currency:)`) or pay a cycle (`planRecurringPayments(...,
  currency:)`), so a bill paid in another currency is never reserved (owner rule: exact money). Planned costs carry no
  currency (they are entered in the wallet's).
  **Payday and over budget (H2):** `paydayPassed` = today ≥ `end`; once passed, only rows dated before `end` count (later
  rows are the next period's; salary parts are "arriving" only while the period runs); `currentPeriodStart(periodStart,
  paydayDay, today)` (dates.dart) = `periodStart` until its `nextPayday`, then the latest expected payday on or before
  today, for "start the new period" after several missed paydays; `daysLeft` is the real count (0 once passed);
  **Period end (RX7e, owner-approved rule C 2026-10-30, dates.dart; replaces RX7d's rule B):** `nextPayday(start,
  paydayDay)`: expected paydays = `paydayIn(month, day)`, clamped to the month's last day. A start within
  `paydayWindowDays` (7, = `samePaydayDays`) of an expected payday belongs to it: late = the latest one in
  [start − 7, start], else early = the one in (start, start + 7]; the period ends on the expected payday after it.
  Otherwise (a hand-set or mid-cycle start, a first run, a salary more than 7 days early or late) the first expected
  payday more than `salaryGroupDays` (20, dates.dart, shared with periods.dart's grouping) days after the start (RX7f,
  owner 2026-10-31; RX7e's "payday of the month after the start's month" gave 25 Sep / 3 an 8-day period to 3 Oct and
  "Start new period" then counted `salary` again). So 2 Mar with payday 31 → 31 Mar (was 30 Apr), 29 Jan / 3 → 3 Mar,
  8 Mar / 10 → 10 Apr, 1 Oct and 7 Oct / 15 → 15 Nov, 25 Sep / 3 → 3 Nov, 30 Sep / 10 → 10 Nov, a hand-set 26 Mar / 10
  → 10 May (a start in the last 20 days before a payday runs to the one after: owner-accepted). Every period is 21..51
  days (the app's first start walks from today − 62), so a salary 1..20 days after a saved start is always inside it. `previousPayday(date)` = the latest
  expected payday more than 7 days before `date` (rangeFor's steps back). One rule for `computePeriod`, `periodDays`,
  `currentPeriodStart`, `detectPaydays`' assumed paydays, `runningPeriodEnd` and ranges; `loanLeft` uses `paydayIn`
  directly. Tests `test/rx7d_next_payday_test.dart` (incl. day-by-day reference over two years, every payday day).
  `allowanceToday` ≥ 0 always (0 when passed or the money is used up); `allowanceTomorrow` (Stage I) = max(0,
  round((flexBudget − spent) ÷ (daysLeft − 1))), null when `daysLeft` ≤ 1 or passed; `safeToday` = allowance − spentToday (negative =
  `overToday`); `overBy` = max(0, −remaining); `overBudget` = `overBy > 0 || planDaily <= 0`. `affordability`:
  `Verdict.overBudget` whenever `p.overBudget` (never `now`), `later` once the payday passed or when the price does not
  fit, `newDaily` never negative. `lowIncome` (moved from the app): received > 0, below 90 % of salary (int maths), at
  least 4 days in and not in the first `samePaydayDays` (7) days; in `incomeMode == 'received'` those first 7 days count
  `max(received, salary)` (salary parts still landing; owner: paid 10th–15th). `periods.dart`'s grouping constant is
  `salaryGroupDays` (20, dates.dart). `WalletSettings.fromMap` reads a stored `paydayDay` 29..31 as 28 (`maxPaydayDay`).
  **Plan split (CX):** `PeriodBudget.planSplit` → `PlanSplit {inTotal, fixed, saved, spending, over}` for the Plan donut
  (pure getter): `inTotal` = income + landedIncome, `fixed` = fixedPlan + reservedBills + reservedPlanned (= fixedPlan +
  `beforePayday`), `saved` = goalMonthly, `spending` = max(0, flexBudget), `over` = max(0, −flexBudget); identity
  `fixed + saved + spending − over == inTotal` (asserted; follows from computePeriod's flexBudget formula, so a change
  there must keep it). `goalTotals(goals)` → `GoalTotals {saved, target, count}` = plain sums over `WalletRepo.goals()`
  (live goals only, each saved already `goalTotal`-clamped; negative allowed) for the Save dashboard. Tests:
  `test/cx_dashboard_core_test.dart`.
  **Day dots (DD):** `periodDays(...)` (same arguments as `computePeriod`) → one `PeriodDay {date, mark, spent, allowance}`
  per day of `[start, end)`; each day before today (all once the payday passed) has exactly `computePeriod(today: d)`'s
  `spentToday`/`allowanceToday` (rows known now), `DayMark.over` iff spent > allowance; today/later = `today`/`toCome`
  (0/0). One pass over the rows plus per-day sums (bill cycles once, `duePlanned` per day); a change to
  `computePeriod`'s allowance maths must be mirrored there (`test/dd_day_dots_test.dart` pins equality; about 2 ms on 20k rows).
  **Report (CX2):** `PeriodBudget.salary` (= `st.salary`, set by `computePeriod`, default 0) and `aboveSalary` =
  received − salary when salary > 0 and received > salary, else 0 (received = live home-currency income rows only; with no
  salary nothing is "above plan"). `periodDaySpend(txs, st, start, end, table:)` → one `DaySpend {date, spent}` per day of
  `[start, end)` ascending (≤ 1000 days; `start >= end` → empty; a bad date → `ArgumentError`), no verdict (owner
  2026-10-30: a past period's plan is not stored). Rows exactly as `spentToday` (live, home currency, `CategorizedTx.kind`
  flex of the expanded list, so transfers/IOU-linked/fixed/income out; `table` is not consulted: the kind comes from the
  Categorizer built with it). Identities (`test/cx2_report_core_test.dart`): judged days == `periodDays(...).spent`; Σ over a
  past `periodReports` period == `PeriodReport.flex` (same rows when the same table categorized `txs`); for the running
  period the report counts rows up to today only, so Σ over `[start, today]` == its flex (rows dated later differ).
  Budget vs actual per category (calendar months, owner decision 2026-10-20): `budgetVsActual(txs, month, budgets, today:, currency:)` →
  `BudgetVsActual` (one `CategoryBudgetLine` per category with a budget or any spend, actual desc then name; `actual` =
  `monthSummary(...).byCategory`, i.e. the "Where it goes" sums: live rows, fixed + flex, refunds subtracted, transfers
  and income out; `average6` = `averageByCategory`, the mean of the 6 months before, always ÷ 6; `remaining` = budget −
  actual; `pace` = actual ÷ (budget × elapsedDays ÷ daysInMonth), null without a budget, with budget 0 or for a future
  month; elapsedDays = day of `today` in the current month, the whole month for a past one; `remainingTotal` = Σ
  remaining over budgeted lines, null when none is budgeted; `budgetedActual` (CX) = Σ `actual` over budgeted lines, 0
  when none, = `budgetTotal − remainingTotal`: "364 € of 400 € budgeted"). `suggestBudgets(txs, month)` = that average rounded UP to
  1000 cents, zero or negative averages omitted. Ints in cents everywhere, floats only in `pace`.
  `computePeriod(txs, st, goals, today, bills:)`: the confirmed recurring bills due before the next payday (exclusive)
  and not paid in this period are `dueBills`; those in flex categories sum to `reservedBills`, which comes off the
  flexible money on the same path as the planned fixed costs (owner decision 2026-10-20), so `planDaily`/`safeToday`
  drop until the paying row lands (a bill with `lastPaidTx` dated in the period is released even if its next due date
  still falls before payday). A due bill in a fixed category (`RecurringBill.coveredByPlan`: Rent, Loan, Bills &
  subscriptions) is already in `rent`/`loan`/`subs` and is listed but never reserved twice (owner rule: exact).
  **Next period (NP):** `projectedReserves(start:, end:, bills:, txs:, planned:, currency:, table:, payeeAliases:)` →
  `PeriodReserves {cycles, planned, count, total}` = what `[start, end)` will set aside once it starts, if every cycle due
  before `start` is paid on its date. Confirmed bills only (incomes never); a non-long, unfinished bill moves to its first
  `billOccurrences` date in `[start, end − 1]`, else to `firstDueFrom(b, start)` (planned.dart, the same stepping;
  holds nothing but covers its slips as it will); a long bill due before `start` moves to `firstDueFrom(b, start)` and is
  held in full (parts paid of the old cycle never lower the next one), one due on or after `start` stays as it is (parts
  already paid of that cycle count); finished bills stay as they are. Then `computePeriod`'s own
  path through the shared `_setAside` (dueCycles → not `coveredIn`, reserve > 0; `duePlanned` from `start`;
  `plannedReserves` with the moved bills and their occurrence keys). `start >= end` or a bad date → `ArgumentError`.
  Identity (`test/np_projected_reserves_test.dart`, repo + `refreshRecurring`): `total`/`count` (and the cycles) ==
  `computePeriod(today: start)`'s `beforePayday`/`beforePaydayCount`/`reservedCycles` after those payments. Timing: a
  paying row already imported but not yet recorded by `refreshRecurring` makes `dueCycles` hold that long cycle at 0.
  `reviewState(txs, st, wishes, budgets, today:, reviewDates:)` (M4 weekly review) → `ReviewState`: `due` from the
  first `reviewDay` after the last review (newest of `reviewDates` and the legacy `lastReview`) until done (never
  reviewed: due at once), `nextReviewDate` = that day (or the coming one), `streak` = `reviewStreak(...)`,
  `steps` = `import` 0 (the UI fills it), `categories` = live spending rows of the last 7 days without a user-set
  category, `pace` = `budgetVsActual` lines over or behind pace this calendar month, `wishlist` = waiting items past
  their cooling-off at the end of `today`. V3 (schema 18): `WalletRepo.markReviewDone(today)` writes the synced
  `review` row of that date (id = `done` = today; same day twice: no op), `reviewDates()` lists them ascending; pure
  `reviewStreak(dates, legacyLast:, legacyStreak:)` walks back from the newest while gaps are < 14 days and adds the
  legacy `reviewStreak` when the walk reaches `lastReview` (that day counted once). The legacy settings are never
  written again. Tests: `test/review_streak_test.dart` (pure, repo, two devices, 17 → 18), old build
  `test/v3_review_old_build_test.dart`.
- `recurring.dart` — recurring bills (M4). `detectRecurring(txs, today:, currency:)`: candidates = a payee (`merchantKey`) with ≥ 3
  live bank outflows (no transfers, no hand-added rows) in the last 7 calendar months, every gap 30 ± 3 days, every
  amount within 10 % of the median (`withinBand`, inclusive, int arithmetic); `expectedAmount` = median, `nextDue` =
  last payment + 30, label/category from the latest row, id `rec:<payee>` (`RecurringBill.idFor`) so every device
  derives the same row; ordered by label. One extra purchase at the payee breaks the chain (shops are never bills).
  `planRecurringPayments(bills, rows, currency:)`: for each confirmed bill the live bank row with its payee key within ± 3 days of
  `nextDue` and within 10 % of `expectedAmount` (closest, then earliest, then smallest id; never the row that paid the
  last cycle). Speed (CX): only rows dated inside a bill's match window (± tolerance, parts window) get a `merchantKey`
  (the cost: 83–175 ms → 3–5 ms on 20k rows in the test container; `refreshRecurring`'s up to 120 passes gain the same); the old every-row version
  lives in `test/cx_dashboard_core_test.dart` and is compared on 400 seeded wallets. `dueCycles` keeps only the
  `lastPaidTx` dates. `RecurringBill` (`models.dart`): synced entity `recurring` (`payee`, `label`, `category`,
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
  `StateError`).
  **P4 (schema 12, spec + clarifications `docs/context/P4_SPEC.md`):** `recurring` gains `min_amount`/`max_amount`
  (range, `hasRange`, `reserveAmount` = max), `ends_on` (instalments, `finished`, `instalmentsLeft`), `manual`.
  `RecurringPeriod` (weekly 7, biweekly 14, monthly 30, quarterly 91, yearly 365; `of` within the class's
  `RecurringBill.toleranceFor`: ≤7→1, ≤14→2, ≤31→3, ≤92→7, else 10). Detection tries the classes in that order
  (`_classes`: lookback + min rows); monthly is the old rule exactly. `planRecurringPayments` → `paidBy` (single
  payment ± tolerance in band/range) + `parts` (rows in `[nextDue − partsDays, nextDue + tolerance]` after the
  `lastPaidTx` date, each ≤ reserve; ≥ 2 rows reaching `partsThreshold` pay, `paidInParts`, next due = nextDue +
  interval). `dueCycles` (budget.dart): monthly = one cycle as before; `isShort` (< 27 days) = every occurrence from
  the period start before payday (an overdue `nextDue` once); `isLong` (> 31) = the next cycle whatever its date, no
  paid-this-period drop, never covered by a plan line. `computePeriod` computes parts itself. `repo_recurring.dart`
  (`WalletRepoRecurring`): `addRecurring` (`rec:m` + 12 hex, confirmed, never detected or recategorized; no payee =
  never matches), `updateRecurring`, `instalmentsLeft`. Bill history per cycle for non-monthly bills (`BillMonth.due`).
  Tests: `test/p4_recurring_test.dart` (+ `p4_recurring_spec_test.dart`, `p4_recurring_repo_spec_test.dart`).
  **P9 recurring income** (schema 14, `recurring.direction`: null/`out` bill, `in` income, `isIncome`): detected on
  inflows of kind extra (id `recin:<payee>`), landed by a positive payee row (no parts); `recurringBills()` lists both,
  so bill paths skip `isIncome` (dueCycles, upcoming, plannedIcs, bill coverage, suggestBillCategory). An income's
  stored `status` is `in:candidate|in:confirmed|in:dismissed` (`storedStatus`; `fromRow` maps it back, and an `in:`
  status alone marks an income): builds before P9 never list, reserve, recategorize or pay such a row; the creation op
  of a detected income carries `in:candidate`. `computePeriod`: `expectedIncome` (`IncomeCycle`, shown, never added; a
  cycle with an in-band payee payment in `[due − interval/2, due + tolerance]` is hidden), `landedIncome` = max(0, Σ
  kind-extra rows of a confirmed income's payee whose payment fits its band/range (`incomeFits`) + Σ its negative
  kind-extra rows), added to `flexBudget`; `extrasForGoals` = max(0, extras − landedIncome). `refreshRecurring` moves a
  confirmed income's `nextDue` on once `due + tolerance` passed without a landing. Bill history: an income's landed
  inflows. `addRecurring(direction: 'in')`: payee required, kind extra, no instalments.
  Tests: `test/p9_income_test.dart` (+ `p9_income_spec_test.dart`, `p9_income_repo_spec_test.dart`).
  Settings `reviewDay` (1..7, default 7), legacy `lastReview` (date) and
  `reviewStreak` (0..`maxStreak`; read-only since V3) are validated like the others.
- `bill_history.dart` — N4 bill history (spec + clarifications `docs/context/N4_SPEC.md`), pure and web-safe.
  `billHistory(bill, rows, slips, today:, months: 12, currency:)` → `List<BillMonth>` (`month`, `payments`, `slips`,
  `paid` = Σ −amount, `billed` = Σ slip totals or null, `BillMonthState` paid|slipOnly|missing|paidNearby|upcoming, `paidIn`), newest first;
  window = `months` months ending today's month, plus today + 1..2 only when they hold something; `paidNearby` = an
  empty past month next to a month with an extra payment within 3 days of it (dates only); bad dates skipped.
  Payments: live bank outflows in the home currency, no own transfers, `merchantKey == bill.payee` (or the
  `lastPaidTx` row); slips: live, home currency, `billPayeeKey == bill.payee`, in their linked payment's month, else
  `date ?? dueDate`. Never by amount. Tests: `test/n4_bill_history_test.dart`.
- `categories.dart` — `Categorizer`: item override → (paired transfer → importer `kindHint` → source/pattern rules) →
  per-merchant rules. `kindHint` (importer `TxKind`, stored as `tx.kind_hint` by `importBatch`, edited only by the schema-4 rewrite) decides
  first where it can: `salary` → Salary, `atm` → Rent at or above `rentCashThreshold` else Cash, `fee` → Bank fees,
  `ownTransfer` and `exchange` → Internal transfer; `standingOrder`, `card`, `other` and null fall through to the description rules
  (built-in merchant patterns, `merchantPatterns`). A row with `transferTo` is an Internal transfer before any hint.
  `account` from the importer is never stored (it names the owner's account).
  **Own categories (P1, schema 10, spec `docs/context/P1_SPEC.md` incl. Clarifications):** `CategoryTable.from(rows)`
  resolves built-ins + `CategoryRow`s (entity `category`, table `categories`; id `k` + 12 hex, or a built-in name =
  override of label/hidden/position only). **T1: subcategories were replaced by tags**: a stored `parent` is ignored
  (every row is top-level with its own kind; `parentOf` null, `topLevel` = id, `childrenOf` empty, `rollUp` the
  identity) and `addCategory`/`updateCategory` refuse `parent` ("Use a tag for this."); `duplicateOf` = built-in
  first, then smallest id. **Code that can meet a custom id uses the table, never the globals** (`categories`,
  `kindOf`, `spendingCategories`, `isSpendingCategory`, `coveredByPlan` getters stay built-in only): `Categorizer(table:)`
  (an override/rule/pattern to a deleted or unknown id is ignored, nothing rewritten), settings budget parse,
  `setCategoryBudget` (top-level only), `setMerchantPattern`, CSV, budget-vs-actual, review, bill suggestion/history.
  `computePeriod` and `plannedReserves` take `table` as **required** (a custom fixed category must never be reserved as
  flex). `repo_categories.dart` (`WalletRepoCategories`): add/update/delete/undeleteCategory, `categoryRows`;
  `WalletRepo.categoryTable()`. Logs: counts and kinds only, never labels. Tests: `test/p1_categories_test.dart`.
  Owner decisions after review (P1 review fixes, `test/p1_review_test.dart`): **plan lines** — every live top-level
  custom fixed category (`CategoryTable.hasPlanLine`) has a per-key setting `plan:<id>` (cents 0..`maxAmount`,
  `setPlanLine`, `WalletSettings.planLines`, refused by `updateSettings`), summed into `computePeriod`'s `fixedPlan`;
  `fixedPaid` and `CategoryTable.coveredByPlan` (= `coveredByPlanIn`) go by `topLevel`, so a bill or planned cost in a
  child of any fixed category is covered, never reserved; `suggestPlan(table:)` matches rent/loan/subs/plan lines by
  `topLevel` (`planProposals` keys `plan:<id>`). Custom income counts as salary. A **deleted custom category**
  (`isDeadCustom`: not live, a custom row or a `k`+12-hex id; a row with no known `kind` is not live) falls back when
  read: `recurringBills`/`plannedCosts`/`bills` resolve it with `Categorizer.resolveStored` (merchant rule for the
  payee key, then patterns and built-in rules on label/title/payee; recurring: else Shopping), never written;
  `refreshRecurring` never rewrites such a stored category and ignores rows whose own category is one when it picks
  the payee's latest row. Drill-down (`merchantsIn`, `rowsFor`, `merchantTrend`, `compareCategory`) and `searchAll`
  take an optional `table` (label search). `transactionsCsv(table:)` writes labels; the monthly CSV puts
  a sync duplicate into its original's column.
- `rules.dart` — rules (P7, spec + Clarifications `docs/context/P7_SPEC.md`), pure and web-safe: `merchantPatternId`,
  `MerchantPattern` (row value `{category, pattern, order}` + optional `match: contains` (folded substring, 1–60 chars,
  stored trimmed; missing = regex) and `minCents`/`maxCents` (absolute amount, inclusive, 0..`maxAmount`, min ≤ max; only
  narrow a text match, never alone: owner rule); `MerchantPattern.read` drops an unknown `match` row, a bad range only
  drops the range), `WalletSettings.patternRules` (match order; `merchantPatterns` = the same as text pairs; `toMap`
  writes 5-element entries for rules with match/range so `fromMap(toMap())` keeps them), `MerchantRule` +
  `repo.payeeRules()`, `rulesView` (`RuleView`, `RuleKind`), `ruleHits(rows, cz, currency:)` over
  `Categorizer.ruleFor` (`payee:<key>`, pattern row id, `builtIn:<n>`, null). Writes in `repo_settings.dart`:
  `setMerchantPattern(category, pattern, {match, minCents, maxCents})` (sets the whole rule, keeps order),
  `updateMerchantPattern(id, {…, clearRange})` (text change = new id, same order, old row tombstoned, one write),
  `movePattern(id, MoveDirection)` (swap orders; any tie in the list = renumber all, then swap, one write). Review
  fixes: a range only on `contains` (refused on a regex; dropped from a regex row when read), a regex matching the
  empty text is refused and never applied. Logs `settings.pattern {op, match, range}`.
  Tests: `test/p7_rules_impl_test.dart`.
- `tags.dart` + `repo_tags.dart` — tags (T1, schema 11, spec `docs/context/T1_SPEC.md`). The main tag is the row's
  category; extra tags are entity `tag` (table `tags`, id `t` + 12 hex, `TagRow`, `TagTable`: order by position, label,
  id; same folded label = sync duplicate of the smallest id, `resolve` maps it), links `txtag` (table `tx_tags`, id
  `<txId>|<tagId>`, `state` on/off, never deleted; no `deleted` column) and rule tags `ruletag` (table `rule_tags`,
  id `<payee>|<tagId>`, payee = `merchantKey`). `tagsOf` = live rule tags of `tagPayee(t)` + `on` links − `off`
  links, resolved, table order; nothing is written on import. `repo.categorizer()` holds one `tagContext()` read
  (three tables) and fills `CategorizedTx.tags`; internal callers pass `withTags: false`. `suggestTags` (≥ 2 other
  rows of the payee, `off:` the row's off links), `recommendedMainTags`/`recommendedTags` (payee count, overall
  count, table order). Totals: `tagShare`/`rowsForTag`/`tagTrend` in `insights.dart` (overlapping, no permille;
  `untaggedSpent`). `searchAll(tags:)`, `transactionsCsv(tags:)` (`tags` column after `category`, labels joined
  `; `). Name rules (1–40 chars, unique folded among live tags, not a live category label, ≤ 500 live) are checked on
  local writes only. Logs: counts only. Tests: `test/t1_tags_impl_test.dart`.
- `currencies.dart` — UX-A (`docs/context/UX_SPEC.md`): re-exports the importer's table (`CurrencyInfo`, `allCurrencies` =
  circulating ISO 4217 + BTC, `currencyInfo`, `minorDigitsOf` = ISO digits, `displayDigitsOf` = what is shown/typed: JPY
  0, EUR/KWD 2, BTC 8) and **`storageDigitsOf`: the stored scale, 2 (hundredths) for every fiat currency exactly as every
  earlier build, 8 for BTC** (lead rule 2026-11-01: no stored amount is ever read differently). `prevalentCurrency(txs,
  wallet)` (≥ 10 rows, ≥ 80 % by count in one other code; offer only); repo `setWalletCurrency(code)` (one setting
  write; unknown or crypto codes refused; rows keep their own currency). Typed input `parseMoneyCents(s, digits:)`
  (digits = typed decimals, result in stored units), CSV `centsToDecimal(c, digits:)` at storage digits.
- `fx.dart` — other currencies by an owner-set rate (P15, spec `docs/context/P15_SPEC.md`). Settings rows `fx:<CODE>`
  = `{rate, date, home}` (`FxRate`: home units per 1,000,000 foreign units (UX-A: whole units; before it every currency
  had 2 digits, so stored rates keep their meaning); 1..10^8, crypto codes to `maxCryptoRate` 10^12; `convertMinor(a, r,
  fromDigits:, toDigits:)` scales by 10^(to − from) at storage digits (fiat ↔ fiat: the pre-20 math; BTC ↔ fiat 10^6); `setFxRate` takes codes of `allCurrencies`
  only, `removeFxRate` also an older build's other code; `home` = the wallet currency it was set
  against, required; bad rows dropped, `settings.invalid` key `fx`; the wallet currency's own row left out),
  `WalletSettings.fxRates` (home = the wallet currency) / `fxStale` (set against another home: counts nowhere), repo
  `setFxRate(code, rate)` (dated today, home = wallet currency) / `removeFxRate(code)` (stale too). `convertMinor`
  (half away from zero, exact, also on the web), `homeAmount(t, st)` (own → amount; `Tx.homeAmount` hook (bank
  amount, unused yet); rate; null without one or beyond `maxAmount`), `inHomeCurrency(expanded, st)` = the money list
  (rows with a home amount as wallet-currency copies with `CategorizedTx.originalAmount/originalCurrency`; parts
  converted one by one (rate, or the bank amount's proportional share), remainder to the last only when all earlier
  parts are in the list; no rates → the same list). Whole-payment paths keep raw rows: `computePeriod(matchRows:)`
  matches bills and incomes on the raw list. Tests: `test/p15_fx_test.dart`.
- `ecb.dart` + `repo_fx.dart` — UX-FX (schema 20, `docs/context/UX_SPEC.md` "UX-FX"): ECB reference rates per payment
  date. Synced entity `fx_day` (`FxDayCols`, table `fx_days`, id `<CUR>:<YYYY-MM-DD>`, `per_eur` = units per EUR × 1e6,
  `source` 'ecb'), written only for what the wallet needs (`fxNeeds` pure / repo `walletFxNeeds`: foreign fiat payments,
  bills, IOUs, openings without a hand rate) by `fillFxDays` from the device-local cache `ecb_rates` (never synced or
  backed up; `importEcbHistory(bytes)` fills it from `parseEcbRates`: zip (CRC checked by us: archive 4.5's `verify:` is a no-op) / CSV / XML, exact decimals ≤ 6,
  any damage = `FormatException`, nothing written). `EcbRates` (`WalletSettings.ecb`, filled by `settings()`, cached per
  `dataVersion`): `rateOn` / `pairOn` = latest ECB day ≤ date within `ecbMaxGapDays` 7 having both currencies.
  `homeAmount`/`inHomeCurrency`: hand rate (`fxRates`) wins, else `ecbConvert` (BigInt, half away from zero once);
  `fxUsed` says which. `balanceInHome` (owner 2026-11-01): hand rate on the whole balance, else the opening at its date
  + each counted row (`AccountBalance.rows`) at its own date; any part without a rate → null. `fillFxDays` also
  replaces an older day by a newer cached one (an early fetch), and runs by itself after every commit that can add a
  need: a row/bill/IOU/account currency, date or undelete not in the wallet currency, the wallet currency or a hand
  rate (`_fxRelevant` → `_tx`; local or from a sync; never after a dry run), so the app needs no fill rule. One cache
  read per fill (the open needs' range, days looked up in memory); `fxCacheReads`/`fxAutoFills` pin the cost in tests. `WalletSettings.toMap` carries `ecb` (`EcbRates.toJson`); a
  stored settings row `ecb` is ignored. Core never fetches: `ecbFetchPlan()` → `EcbFile` (`history` zip / `recent`
  90-day XML, once a day via `noteEcbAttempt`, only for a missing need a download could answer or a date newer than the
  cache answered by an older day; dates after today never; `force:` for "Get rates now"); app order `ecbFetchPlan` →
  `noteEcbAttempt` → `fetchEcbFile` (wallet_sync) → `importEcbHistory`. `ecbCacheInfo`, `fxMissing` (dates up to
  today). Tests: `test/ux_fx_test.dart`.
- `splits.dart` + `repo_splits.dart` — split transactions (P6, schema 13, spec `docs/context/P6_SPEC.md`). Entity
  `split` (table `tx_splits`, id = the tx id, `parts` = one JSON field `[{a, c, t, n?}]`, so LWW keeps a whole split).
  `setSplit`/`removeSplit`/`splitOf`/`splits`; rules (2–20 parts, payment's sign, exact sum, live non-transfer main
  tag, live resolved tags ≤ 20, note ≤ 200; no transfers) on local writes only. Read time: `Categorizer.expand(t)` /
  `expandAll` = one `CategorizedTx` per part (`amount`, `part`, `parts`, `partNote`; `tx` stays the payment), or the
  payment whole (`splitBroken` when the stored split no longer fits, `splitFits`). Money by category/tag/kind takes the
  expanded list; pickers and detection take whole payments (`categorize`, `wholePayments`). A bank row without a split
  row reads its matched entry's live split (`splitOf`/`splits`, never copied; a removed own split stops it). A dead part
  category falls back to the payment's main tag. `searchAll` returns whole rows (`CategorizedTx.whole`) +
  `matchedPart`; merchant/tag counts are per payment. Tests: `test/p6_split_impl_test.dart`, `p6_split_review_test.dart`.
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
- **Stage Q core A.** Q3 one amount cap: `isSafeCents` (±`maxAmountCents` = `WalletSettings.maxAmount`, `planned.dart`);
  `addTransaction` refuses beyond it (`ArgumentError`), `importBatch` skips and counts (`ImportSummary.tooLarge`,
  `repo.tooLarge {source, count}`), `_fieldValue` quarantines a synced amount column beyond its cap like a wrong type
  (`_amountCaps`: tx and recurring amounts at `legacyRowCapCents` 10^12, the pre-Q importer cap, so an old import is
  never dropped; planned, bills, wish price, account opening, goal `monthly` and IOU/repayment amounts at the cap; goal target/saved keep
  `goalTotal`'s clamping); budget sums assert < 2^53 (`_ok`; 90,000 rows at 10^11 fit, 9,000 at 10^12).
  Q4 `previewImport(batch, {revive})` (`repo_import.dart`, types in `import_preview.dart`): read-only (no row, clock,
  outbox, meta or HLC change), the same classification as `importBatch` (`_classifyBatch`) and the same planners
  (`_planPairs`, `_planManualMatches`, which `_pairTransfers`/`_matchManual` now call) over stored rows + the batch's
  fresh rows (unseen by every entry) + revived ids; plans only while caught up, stored `matched_to`/`transfer_to` of
  batch rows always. With a forced CSV remap it equals the import only when called after `setCsvMapping(force: true)`
  with its revive set. `importBatch(skip:)` writes nothing for those ids (`ImportSummary.skippedByOwner`). Tests: `test/q4_import_preview_test.dart` (prediction == import).
  Q5 (`accounts.dart`): `checkBankBalance` → `BalanceCheck` (`appCents` as `accountBalances` up to the date, `diff` =
  bank − app, `rowsSince`/`since` = opening date), `BankCheck` stored device-locally (`recordBankCheck`/`lastBankCheck`,
  local `bankCheck:<accountId>`, never synced, never changes the balance; stored `appCents` is for display only),
  `balanceTrusted(a, today:, last:, rows:)` (opening date within `bankCheckTrustDays` 35, or a check within 35 days that
  `checkBankBalance` over the rows still matches now). `importBatch` records a check per `ImportBatch.bankBalances` for
  the counting live bank account (`ImportSummary.bankChecks`; an older-dated check never replaces a newer one; none
  dated before the opening, and none when stored rows of that source/currency inside the file's dates are not in the
  file: another IBAN or pocket in one app account).
  Q11 (`forecast.dart`): `forecastToPayday` (`bills` required: every confirmed recurring bill; steps: unpaid bill cycles on their date, overdue ones today; open planned
  costs today..payday, a slip its cycle holds once; incomes on their date, overdue ones never; payday exclusive; out
  before in on a day), `forecastAfterAllowance` (− allowance × days left), `balanceWarnings` (per home-currency bank
  account: untrusted → `checkBalance` only, `belowNow`, `goesBelow` at the first negative point). **Attribution is
  exact:** a bill/income counts on an account only when its `lastPaidTx` row is that account's imported row; planned
  costs and unplaced bills go only into the total forecast. Tests: `test/q3_overflow_test.dart`,
  `q5_bank_balance_test.dart`, `q11_forecast_test.dart`.
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
- `repo_match.dart` — D2 Unlink (schema 19; `WalletRepoMatch`): `unlinkMatch(entryId)` = one owner write on the entry:
  `matched_to` null + the bank row id appended to `tx.match_off` (JSON list in unlink order, newest `maxMatchOff` 20 kept;
  `matchOffIds`/`encodeMatchOff` in `matching.dart`), then `_reconcileLocal` (the entry may take ANOTHER row at once).
  `planMatches(matchOff:)` / `openEntries(matchOff:)` never pair an entry with a row in its `match_off` (other entries
  may take that row) and reopen such a match made by an older build. The bank row keeps what matching copied (category
  when it had none, the entry's extra tags) and the attachments `_moveMatchedAttachments` gave it; it stops reading the
  entry's split (read through `matched_to`). `relinkMatch(entryId, bankId)` = the Undo: bankId must be in the entry's
  `match_off` (`ArgumentError`), live, not a transfer and held by no other live entry (`StateError`); writes
  `matched_to` + the remaining `match_off` (null when empty) + the tag copy, then `_reconcileLocal`; a row the entry took
  meanwhile is free again. `ArgumentError` for an unknown/deleted id, a bank row or no match. `matchedBankIds()` = live
  bank rows a live entry points at (the app's "Matched" mark). Logs `match.unlink {off, rematched}`, `match.relink
  {off, freed}`. Tests: `test/d2_unlink_match_test.dart` (incl. two devices, backup, schema 18 → 19).
- `models.dart` — `Tx`, `Goal`, `GoalContribution`, `WishItem`, `WalletSettings` (row ↔ object), `goalTotal`.
  `WalletSettings.categoryBudgets` (`{category: cents per month}`, default `{}`) is validated entry by entry: only
  `spendingCategories` (fixed + flex) with whole cents 0..`maxBudget` are kept, other entries are dropped (one
  `settings.invalid` with the key `categoryBudgets`). **Per-key rows (schema 8, H3):** one settings row per budget, id
  `budget:<category>`, value = JSON int cents; one per merchant pattern, id `pattern:<16 hex>` = `merchantPatternId(pattern)`
  (first 16 hex of SHA-256 of the pattern's UTF-8: the same pattern on two devices is one row, and the id does not show the
  pattern; it is still never logged, since an unsalted hash of a short pattern is reversed with a word list: problems
  with `pattern:*` rows are logged under the key `merchantPatterns`, `budget:*` under `categoryBudgets`), value = JSON
  `{"category": c, "pattern": regex, "order": int ≥ 0}`. Patterns match in `order` ascending, ties
  by row id; `setMerchantPattern` gives a new pattern the largest live order + 1 and keeps an existing one's order when its
  category changes. Removal = tombstone (`deleted` 1, value null). Writes: `setCategoryBudget(category, cents?)`,
  `setMerchantPattern(category, pattern)`, `removeMerchantPattern(pattern)` (`ArgumentError` for a non-spending category,
  cents out of range, an unknown category, an empty or non-compiling pattern; nothing written when unchanged);
  `updateSettings` with `categoryBudgets`, `merchantPatterns`, `budget:*` or `pattern:*` throws `ArgumentError` (nothing
  of that call is written). `fromMap` reads the legacy maps first and lets per-key rows replace their entries.
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
  once through `_write` and reconciled, `revolutExchangeType`; 5 = the `recurring` entity; 6 = the `planned` entity; 7 = the `bill` entity;
  8 = per-key budget and pattern rows: the legacy `categoryBudgets`/`merchantPatterns` map rows are migrated once, in one
  transaction, to rows written with the legacy row's own `value` clock and queued in the outbox (so they sync; every
  device migrating the same map writes identical ops); an entry whose id already has a row, live or removed (another
  device's per-key write that arrived first), is skipped, as the read fallback does, so a stale map with a newer clock
  never revives or undoes a per-key change; new patterns get orders after the largest live one; a clock-less legacy row
  goes through `_write`; the map rows are left in place for older builds; `repo.migrate` logs `perKeySettings` (count);
  9 = the `account` entity, no data migration; 10 = the `category` entity (P1), no data migration; 11 = tags (T1); 12 = P4
  recurring columns, no data migration; 13 = splits; 14 = recurring income; 15 = P14 local blob tables, no synced change; 16 = `bills.attached_tx` (P16b), no data migration; 17 = the `iou` and `iou_part` entities (Q8), no data migration; 18 = the `review` entity (V3), no data migration; 19 = `tx.match_off` (D2 Unlink), `planned.auto_off` (KL-A auto-Paid Undo) and the `payee_alias` entity (KL-A slip payee aliases), no data migration). Opening an existing database with an older version
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
- `repo_iou.dart` — IOUs (Q8, schema 17): entities `iou` (table `ious`: person, direction `lent`|`borrowed`, amount
  > 0 cents, currency, date, note, `tx`, closed, deleted; id `o…`) and `iou_part` (table `iou_parts`, index on `iou_id`:
  amount, date, `tx`, deleted; id `r…`); models `Iou`, `IouDirection`, `IouPart`, `IouView(iou, parts, outstanding)`
  (outstanding = amount − Σ live parts, never below 0). `WalletRepoIou`: `addIou`, `updateIou` (`clearNote`/`clearTx`),
  `deleteIou`/`undeleteIou`, `closeIou(closed:)`, `addIouPart`, `deleteIouPart`/`undeleteIouPart`, `ious(includeClosed:)`,
  `iouLinkedTx()`. Local writes only (`ArgumentError`): person 1..60, amount 1..`maxAmount`, valid date, no overpaying;
  a linked payment exists, is live, no own transfer, no split, same currency, sign (lent: the IOU's payment out, parts
  in; borrowed: the reverse) and **exactly** the amount, held by one live link only. **Money:** `repo.categorizer()`
  passes `iouLinkedTx()` as `Categorizer(iouTx:)`; `categorize`/`expand` give such a row `BudgetKind.transfer` and keep
  its main tag (`kindFor`), so every total that leaves transfers out leaves it out (period, month, insights, budgets,
  recurring detection, reports); account balances (raw rows) keep it; `setSplit` refuses it. `iouLinkedTx` follows a
  linked hand-added entry to the bank row that replaced it (`matched_to`). Unlinked IOUs change no number. Older builds
  skip both entities (replayed on upgrade). Logs `iou.*` with direction/linked/count only. Tests: `test/q8_iou_test.dart`,
  schema-16 ↔ 17 old-build replay `test/q8_iou_old_build_test.dart`.
- `loan.dart` — `loanLeft(settings, today)` → `LoanLeft {payments, cents, endMonth}` or null (no loan, no `loanEnd`, none left): counts the months from today's month to `loanEnd` inclusive whose payday (`paydayDay`, clamped to the month's last day) is today or later; `cents = payments × loan` (no interest data). Tests: `test/loan_left_test.dart`.
- `dates.dart` — `YYYY-MM-DD` string helpers; payday rule `paydayIn`/`nextPayday`/`previousPayday` (rule C,
  RX7e, see H2). `hlc.dart` (H7 bounded HLC: `maxClockDrift` 1 h; an owner write (the
  public write API) throws `ClockBehindException` (nothing written, message without clock values) while this device's
  wall clock is more than that behind the highest reading it wrote with (device-local meta `wall_high`, raised by every
  write, owner or internal; never a peer's clock, so a database holding a far-future HLC from before Stage H still accepts owner
  writes); `repo.clockBehind` logs minutes only. Internal write paths skip the guard:
  `WalletRepo._writeInternal(changes)` and `_asInternal(body)` (the open-time migration, `_reconcile` = pairing,
  matching, H9 repairs, bill links, `refreshRecurring`, `runPendingMatch`); `tick` stays monotonic.
  `SyncEngine.run` catches a `ClockBehindException` from `runPendingMatch` (logged, matching stays pending).
  `restoreBackupBytes` refuses a backup whose newest clock is more than `maxClockDrift` ahead of the wall clock:
  `BackupException(BackupFailure.clockAhead)`, nothing applied), `vault.dart` (key + encryption; `VaultKey.parse` ignores case, spaces and dashes and reads a digit 0 as O (Base32 has
  no 0; 1 stays refused); `UnsealFailure` says why a
  file was refused, `tooLarge` past the inflate cap; `deriveKey` = HKDF-SHA256, empty salt).
- `vault.dart` formats (H8, V1): `seal(plain, key, {required aad, nonce, legacyFormat})` writes `BWOP3` = magic |
  keyId(8) | nonce(24) | mac(16) | XChaCha20-Poly1305 of gzip with `aad || keyId` as associated data (`keyId` =
  `VaultKey.keyIdBytes()`, the bytes of `keyId()`; `nonce` is a test seam for known-answer vectors). `legacyFormat:
  true` writes `BWOP2` = magic | nonce(24) | mac(16) | ciphertext with `aad` alone: only the app's web key wrap (a wrong
  passphrase must stay `badKey`). AAD per use: `aadSyncFile(device, seq)` = `bw-sync-file\n<relay device name>\n<seq>`,
  `aadSnapshot(id)` = `bw-snapshot\n<id>`, `aadBackup`, `aadBlob`, `aadWebKey` (the app's passphrase-wrapped key).
  `unseal(data, key, {required aad, maxBytes})` reads `BWOP3` (another key id = `otherKey`, nothing decrypted; this
  key's id with a failing MAC, e.g. another AAD or a cut/changed file = `damaged`), `BWOP2` (any MAC failure =
  `badKey`) and `BWOP1` from older builds (no AAD, any `aad` given); `BWOP4`+ = `newerFormat`. Inflate capped at
  `maxUnsealBytes` (256 MiB, `maxBytes` lower only in tests) through `package:archive`'s `maxOutputSize` → `tooLarge`
  (quarantined as `corrupt`). `syncReaderVersion` = 3. Builds before V read `BWOP3` as `unknownVersion` (quarantined,
  read after their upgrade). Backups: restore/merge rethrow `unseal`'s `VaultException` (`failure` = `otherKey` /
  `damaged` / `badKey`); `BackupFailure.otherKey` names the same case for callers mapping both to one reason. `local_db.dart` pins
  `PRAGMA cipher = 'chacha20'` (sqlite3mc's default so far) before every `PRAGMA key` / `rekey`.
- Device id per install (H6): `WalletRepo.open(path, {dbKey, now, deviceId})`, `inMemory({now, deviceId})`,
  `fromDatabase(db, {file, now, deviceId})`. Null = the meta `device_id` (a new database makes one). Given and
  different from the stored one: meta `device_id` takes it, local `syncSent`/`syncStream`/`syncSending` are cleared,
  so the next sync is a first connect under the new id (whole state, clocks unchanged; the outbox is kept and marked
  sent by it); the old id's stream (when this install stored or was storing a file there) is added to `syncStreams`
  with its highest stored seq in `syncStreamLast` (acked as until it grows) and read like a peer's. Ids are
  `[A-Za-z0-9]{1,48}` (`ArgumentError` else; a relay stream name is `<id>-<n><tag>`). `WalletRepo.newDeviceId()` (16 hex), `WalletRepo.storedDeviceId(db)` (read only),
  `repo.deviceId` of a database opened without one = the id to move into the app's key store once.
- `backup.dart` — backups (M5, owner decision 2026-10-22: no sync folder, "Back up now" saves the sealed `.bwb` through
  the save dialog, encrypted with the wallet key, restore only into an empty wallet; web-safe, no file code here).
  `backupFileName(today)` = `bw-backup-<today>.bwb` (`ArgumentError` unless `YYYY-MM-DD`). `backupBytes(repo, key)`:
  sealed with `seal()` like a sync file; payload UTF-8 JSON `{"v":1,"ops":[...]}` = `WalletRepo.snapshotOps()`: every
  row of every synced entity, deleted rows and settings included, as one op per distinct field clock (the fields written
  with that clock and their current values; a field with no clock, i.e. the column default, is left out), so a restore
  records the very same clocks; device-local values never. Logs `backup.write` with the op count.
  `restoreBackupBytes(repo, bytes, key)`: `StateError` unless `repo.isEmpty` (no row at all, deleted included, in tx,
  goals, goal_contrib, wish, recurring, planned, bills, merchant_rules, settings) before anything is read; unseal errors are the
  `VaultException`; content that is not a backup or has a clock that does not parse is a `BackupException` (`reason`:
  `damaged`, `newerVersion` for `v` > `backupVersion`; `unreadable` is what the app uses when it cannot read the picked
  file; nothing applied unless the whole file parses). The ops go through `applyRemote(ops, resend: true)`: matching,
  pairing and bill detection run once at the end, and the ops are queued in the outbox with their clocks unchanged, so
  the next sync exports them as this device's file and the restored state reaches the other devices like local writes
  (devices already holding those fields at the same clocks change nothing: a clock is only accepted when newer; a
  restore into a wallet whose relay still has every device's files converges either way, the resend covers pruned files
  or a new relay). Returns the op count.
  **P10 (spec `docs/context/P10_SPEC.md`):** `mergeBackupBytes(repo, bytes, key, {dryRun, walletKey})` → `MergeResult {ops, changed,
  changedByEntity, blobs}`: same unseal/parse/clockAhead checks (shared `_open`), then `applyRemoteByEntity(resendChanged: true)`
  = field-level LWW, only the fields that changed are queued (op cut to them, clock kept); `dryRun` applies in a rolled-back
  transaction without `clock.receive` (same counts; tables, clocks, outbox, HLC untouched). Bill files: `backupBytesWithInfo(repo,
  key, {maxBlobBytes = 16 MiB, base64 size})` → `BackupResult {bytes, ops, blobs, blobBytes, blobsSkipped}` adds `"blobs": {hash: base64 sealed}`
  (cached files of live bills, newest bill date first, one that would pass the cap skipped); still `v: 1` (every parser reads only
  `v`/`ops`). Restore/merge cache each file whose SHA-256 of the sealed bytes is its hash and that a live bill uses, queued for upload,
  (bad ones: `backup.blobBad {files}`); `walletKey` ≠ `key` (old-key restore) skips the files.
- `export.dart` — CSV (M5, pure, the app saves the text through the system dialog; unencrypted, the app warns once).
  `transactionsCsv(List<CategorizedTx>)`: `date,amount,category,description,source,note`, live rows only (`Tx.live`:
  no deleted rows, no hand-added entries replaced by a bank row that is here), sorted date then id, `amount` the
  stored signed cents as an exact decimal (`centsToDecimal`: int arithmetic, dot, two digits, never `-0.00`),
  `category` the resolved one, RFC 4180 fields (`csvField`: quoted when holding `"`, `,`, LF or CR; quotes doubled),
  LF ends, UTF-8 without BOM. `monthlySummaryCsv(txs, currency:)` (rows in that currency only): `month,<spendingCategories in order>,total`,
  one record per month with a live row in a spending category, ascending; a cell = Σ −amount of that category (refunds
  reduce it, a net refund prints negative, `0.00` without spending), `total` = Σ cells; income, transfers, deleted and
  replaced rows never count.
- Accounts and plan suggestions (N2, spec `docs/context/N2_SPEC.md`). `repo_accounts.dart` (`WalletRepoAccounts`):
  `addAccount`/`updateAccount`/`correctBalance`/`deleteAccount`/`undeleteAccount`/`accounts()`; one live account per
  (source, currency, `match_key`), cash = `source` null; dates not after the repo clock's today. UX-ACC (schema 20,
  `docs/context/SCHEMA21_SPEC.md`): `tx.account` (`TxCols.account`) + `accounts.match_key` (`ak:` + 16 hex,
  `accountMatchKey(VaultKey, exportAccount)` keyed HMAC, never logged, IBAN never stored; `withAccountKeys(key, batch)`
  sets `NormalizedTransaction.accountKey`); `RowAccounts` = the counting rule (named live account of the row's
  source/currency, else the main account: null key, else smallest id); `importBatch` writes the account in the creation
  op and on re-import fills only a row whose `account` was never written (no clock; the owner's `setTxAccount(id, null)`
  stays); `unknownImportAccounts(batch)` → `ImportAccountQuestion`s (ask once). **Ask "Which account is this?" before
  `importBatch`**: rows imported before the answer stay on the main account until that file is imported again. A wallet
  key change makes stored match keys stale (a new key hashes the same IBAN differently), so the question is asked again.
  `checkBankBalance`/`balanceTrusted` take every account (`accounts:` required). Q5 checks per export account. Tests:
  `test/ux_acc_test.dart`. `accounts.dart` (pure):
  `accountBalances` = opening + rows after `openingDate` (bank: its source's imported rows, every kind; cash: hand-added
  rows not matched or pending; ATM never adds to cash); a sync duplicate (same key, larger id) gets `duplicateOf`, its
  opening only, and `balanceTotals` (per currency) skips it. `suggest.dart` (pure): `suggestPlan(txs, st, today,
  confirmed:)` reads salary/paydayDay (payday groups), rent/loan (categoriser's Rent/Loan rows, never the amount) and
  subs (confirmed Bills & subscriptions bills) in the home currency; `planProposals` lists the differing ones (never
  writes). `budgetProposals` (budget.dart) is the Suggest diff (empty fields first).
- `planned.dart` + `ics.dart` — future spending (§4.3, API and decisions in `docs/context/FUTURE_SPENDING_API.md`), pure
  and web-safe. `PlannedCost` (`models.dart`): synced entity `planned` (schema 6: `title`, `date`, `amount` nullable
  cents > 0, `category`, `source` manual|calendar|bill, `source_ref` = `CalendarEvent.ref` = `calendarEventRef`
  (KL-A: SHA-256 prefix over the stable uid (.ics UID / Android `UID_2445`, never `_ID`) + date + `startMinutes`, else
  normalized title + date + start time or an all-day marker (never equal to a legacy ref); `legacyCalendarEventRef` =
  the pre-KL title + date ref (`CalendarEvent.legacyUid`: parseIcs's pre-KL `bw-nouid-<n>` for letterless no-UID
  titles), used only to look up rows written before KL-A: `CalendarEvent.refs`, `dismissCalendarEvent(legacyRef:)`;
  never a raw id or title), `status` open|paid|skipped, `paid_tx`, `deleted`,
  v19 `auto_off` = JSON list of rows `reopenPlanned` reopened it from). KL-A auto-Paid: `planAutoPaid` (exactly one
  bank row, same category, exact amount, ±3 days) runs in `_reconcile` (`_autoPayPlanned`, caught up only); toast list
  `autoPaidPlanned()`/`ackAutoPaidPlanned` (device-local `local.autoPaidPlanned`, max 50). Repo: `plannedCosts(includeClosed:)`, `addPlanned` (id
  `<source>:<ref>` when a ref is given, so devices converge on one row per event; else random `p…`), `updatePlanned`,
  `markPlannedPaid`, `skipPlanned`, `reopenPlanned`, `deletePlanned`, `dismissCalendarEvent` (writes no title).
  Calendar events (`CalendarEvent`) are never stored by core. `computePeriod(..., planned:)`: `duePlanned` = open
  planned costs with an amount dated today .. day before payday; `reservedPlanned` = their sum outside fixed
  categories (`PlannedCost.coveredByPlan` listed, not reserved: exact money); a cost reserves until Paid/Skip or its
  date has passed. `upcoming` (planned + confirmed bill occurrences `billOccurrences` + calendar suggestions with
  `amountFromText`/earlier same `normalizeTitle` amounts), `paidCandidates` (same category ± 3 days, never by amount
  alone), `headsUps`; settings `headsUpCents` (10000, 0..10000000), `headsUpDays` (3, 0..14). `parseIcs` (RRULE
  subset, EXDATE/RDATE/RECURRENCE-ID, folding (linear), escapes; UTC times via the optional `toLocal`; unsupported
  rules → first occurrence + `unsupported` count; a whole-file budget of 10⁶ recurrence steps, after which recurring
  events give their first in-range occurrence only and count as unsupported; never throws), `plannedIcs` (export, `euroText` amounts, stable UIDs).
  Logs: counts and enum words only (`planned.*`, `ics.parse`, `ics.export`).
- `bills.dart` — bills database (stage B, API and decisions in `docs/context/BILLS_API.md`), pure and
  web-safe. `Bill` (`models`-style row ↔ object): synced entity `bill`, table `bills` (schema 7; `items` = JSON text,
  `unsure` count, `linked_tx` the payment, `blob`/`blob_type`/`blob_bytes` the file), id `Bill.idFor(externalId)` =
  `bill:<32 hex SHA-256>` (else random `b…`). Repo: `bills`, `bill`, `importBill` (creation op without status/deleted;
  re-import fills only empty fields, a confirmed bill only items + file; a deleted one is revived; `asNew:` stores a
  copy `Bill.idFor('<ext>#<n>')`), `updateBill`, `confirmBill` (B5a: a bill that would reserve, i.e. confirmed, unpaid,
  total, due from today on, needs a category, also on an `updateBill` of due date/total/category (B6: other edits always save);
  `suggestBillCategory` offers one), `linkBill` (one bill per tx), `unlinkBill`, `deleteBill`, `addExpenseFromBill` (expense + link +
  confirm + the category when the bill has none, in one `_write`). `_billWrites` keeps the planned row `bill:<billId>` in step (open while confirmed, unpaid,
  with total and due date; paid with the payment; deleted with the bill), so `computePeriod(planned:)` reserves an
  unpaid slip, once: a row a confirmed recurring bill already plans (`plannedCoveredBy`/`billCoveredBy`: same
  `billPayeeKey`, due ± 3 days of a cycle, decided when read) is not reserved when that cycle (`plannedCoverage`) is the
  `nextDue` this period's `dueBills` lists, the cycle just paid/skipped, or the bill is `coveredByPlan` (B6: else the slip
  reserves), and not listed in `upcoming`/`plannedIcs` when that cycle is in their range; a bill row without a category
  (`PlannedCost.needsCategory`) is listed, never reserved. One rule: `plannedReserves(p, recurring, counted)` (B6b), used by
  `computePeriod` (`PeriodBudget.reservedPlannedRows`) and the app's Upcoming "Set aside". Auto link `planBillLinks` in `_reconcile` (caught up only) and at confirm: a token (reference ≥ 6
  digits, JIR, invoice no: digits only ≥ 6, mixed ≥ 4 with a letter and a digit) in the bank row's `normalizeForLink` description with digit boundaries, −amount == total,
  date − 3 .. (due ?? date) + 60, exactly one row and one bill; never by amount alone, never reclassifies. Deleting the
  paying tx unlinks at once; other devices unlink a bill whose payment row arrives deleted in `_autoLinkBills` (caught
  up). `billCandidates` (no own transfers), `upcoming(billsDb:)` (`UpcomingKind.warranty`/`returnBy`),
  settings `returnReminderDays` (3, 0..30) / `warrantyReminderDays` (14, 0..90).
  **Attachments (P16b, schema 16):** a bill row with `source: attachment` (`Bill.isAttachment`), random id, its payment
  in `attached_tx` (`Bill.attachedTx`; `linked_tx` always null, so older builds never take it for a payment's bill),
  `total` = |amount|, its date/currency, confirmed, `paid` true. `addAttachment(txId, BlobRef)` (unknown/deleted tx or a type
  outside `attachmentTypes` = jpg/png/pdf: `ArgumentError`; `maxAttachmentsPerTx` (5) live: `StateError`), `attachments(txId)` (live,
  oldest first by the `source` clock, then id), `removeAttachment` (soft delete) / `restoreAttachment` (Undo; cap →
  `StateError`). A hand-added entry replaced by its bank row hands its live attachments to that row
  (`_moveMatchedAttachments` in `_reconcile` after matching, cap not checked); they stay there if the match reopens. Invisible elsewhere: `bills()` (unless `includeAttachments`), the bill calls (`_liveBill` refuses
  them), `planBillLinks`/`billCandidates` (neither link nor take a row), the one-bill-per-payment repair, the
  deleted-payment unlink (they stay on the payment), `_billWrites` (no planned row), search, upcoming reminders, bill
  history. Every live attachment stays in `liveBlobHashes`/`backupBlobCandidates`, also while its payment is deleted
  (the relay's 30 days count from upload, and an undelete of the payment re-uploads nothing). Tests: `test/p16b_attachments_test.dart`.
  `BlobStore` (`packages/sync`) seals and fetches the files; `isBlobHash` is here.
  **P14 (schema 15, `docs/context/P14_SPEC.md`):** one device-local
  table `blob_cache` (`uploaded` 0/1; LRU by a use counter, never evicts an un-uploaded file nor one a pending outbox op
  references); `blob_outbox`/`blob_delete`/`blob_own` are migrated away at open (`_migrateBlobTables`: queued rows →
  `uploaded` 0). **Clients never delete blobs**: `deleteBill` keeps the file cached (until evicted) and on the relay; the
  relay's GC collects files no kept snapshot declares. Repo helpers `putCachedBlob`, `cachedBlob`, `hasCachedBlob`,
  `evictBlobs`, `queuedBlobs` (= `uploaded` 0), `markBlobUploaded`, `liveBlobHashes` (a snapshot's declared set),
  `blobRefOf(op)` / `pendingBlobRefs` (a bill op references a file when it sets `blob` on a bill live here or makes the
  bill live; `deleted` 1 never; a field this device holds with a newer clock never), `markExportedHolding` (outbox rows up to a seq go, held ops go back in, one
  transaction); a re-import whose bill keeps its own file forgets the new un-uploaded one (`_forgetUnusedBlob`); the
  migration sets `WalletRepo.blobReuploadKey` (local): a JSON list of the cached live files; each run PUTs those still listed and keeps only the unconfirmed ones (cleared on a relay
  without blob storage). H9 field pairs (`_repairFieldPairs`, in `_reconcile` before
  `_autoLinkBills`, through `_write`): a live planned row keeps `paid_tx` only while `status == paid`; a payment row pays
  at most one live bill (earliest `linked_tx` clock stays, then smallest id; the others unlinked via `_billWrites`); every
  bill's planned row `bill:<id>` is set to what `_billWrites` wants for the bill as it is. `_billWrites` writes
  `status` and `paid_tx` together whenever either changes; `skipPlanned` clears `paid_tx`. Delete vs edit per entity:
  `docs/context/DESIGN_DECISIONS.md` §4.10. Logs: `bills.*`, `blob.*`,
  `sync.blob*` with counts, sources and enum words only.
- `ranges.dart` + `insights.dart` — graph ranges, graph data and the Spending drill-down (N3, spec + clarifications in
  `docs/context/N3_SPEC.md`), pure and web-safe. `DateRange` (inclusive `YYYY-MM-DD`, checked), `rangeFor` (pay period =
  `periodSummaries`' period `[start, end − 1]` (RX7c), whole calendar months, custom ≤ 5 years and not past today's month), `shiftRange` (needs `today:`), `rangeLabel`.
  `insights.dart` never counts on its own: per month it clips the rows to the range and calls `monthSummary` (spending,
  income; extra = `monthSummary` of the extra rows), `budgetVsActual` (`budgetVsActualSeries`) and `averageByCategory`
  (`compareCategory`); the row lists (`merchantsIn`, `rowsFor`, `merchantTrend`, `biggestRows`) use `_isSpending`, the same
  rule row by row, so `rowsFor` sums equal their totals. Group key `''` (`Other`) = manual row without a note or `merchantKey`
  `x`. Tests: `test/n3_ranges_test.dart`, `test/n3_insights_test.dart` (incl. a loose 500 ms perf test on ~10k rows from
  `test/support/n3.dart` `bigWalletRows`).
- `series.dart` — zoomable graph data (stage ZC, `docs/context/ZC_SPEC.md` §3–4 + "Settled by the lead"), pure and
  web-safe, no DateTime (epoch-day maths on the strings). `DayIndex(expanded, currency:)`: one pass, per-day prefix sums
  of spending (`countsAsSpending`, refunds subtracted), income, extra; per category/tag/merchant key (`merchantGroupKey`,
  shared with `insights.dart`) built on first use and cached; `first`/`last` = days holding a counted row. `bucketFor`
  (day ≤ 35 days, week ≤ 155, month ≤ 4 years, else quarter; coarser while > `maxBars`), `bucketsOf` (aligned: Monday
  weeks, calendar months/quarters, clipped at the window), `spendingSeries`/`incomeSeries`/`budgetSeries` read the index
  only (≈0.1 ms per 40-bar window on 20k rows); windows of 5 years or more → `ArgumentError`. `partial` = holds today or
  clipped. `budgetSeries`: each category's month budget split over its days by largest remainder (earlier days get the
  extra cent), a bar's `budgeted` = Σ of its days' shares, `over` = Σ per category max(0, actual − share), `prorated` =
  not whole calendar months; a `category:` without a `budgets` entry counts nowhere (0/0/0), a 0 budget is real (spending =
  over). Whole months equal `spendingByMonth`/`tagTrend`/`merchantTrend`/`incomeVsSpending`/
  `budgetVsActualSeries`. Tests: `test/series_test.dart` (incl. perf), spec tests `test/zc_series_spec_test.dart`.
- `reports.dart` — reports (P8, spec `docs/context/P8_SPEC.md`), pure and web-safe, nothing written. `periodReports(txs, st, today,
  table:, count:)` → `PeriodReport {start, end, running, income, fixed, flex}` (+ `out`, `net`) on the periods of
  `periodSummaries` (same income/out/net; `fixed` = Σ `byCategory` of tags whose `table.kindOf` is fixed, `flex` = out −
  fixed); `categoryByPeriod(category, txs, st, today, table:, count:)` → `CategoryPeriod {start, end, running, spent,
  budget}` (+ `overBy`, `over`; spent = `rollUp(byCategory)[category]`, budget = `st.categoryBudgets[category]` per pay
  period); `savedByWaiting(wishes, fromMillis:, toMillis:)` / `savedByWaitingAll` → `SavedByWaiting {count, cents}`
  (skipped wishes, `decided` in [from, to)). txs = the expanded list (P6). Tests: `test/p8_reports_test.dart`.
  **Period rule (RX7b, `periods.dart` `payPeriodStarts`/`runningPeriodEnd`, not exported):** periods are contiguous `[start, end)`; the running
  one's `end` = max(nextPayday(start), today + 1) (rule C above), so a late salary keeps it running and it always holds today (rows up
  to today only). Starts = `detectPaydays`, except a saved `periodStart` ≤ today that lies 1..20 days before a real
  payday inside `computePeriod`'s period (salary < `nextPayday(ps)`, RX7e) replaces that payday: the running period is
  then exactly `computePeriod`'s `[ps, end)`, extended to today + 1 only once that payday passed without a salary (a
  salary on or after `nextPayday(ps)` stays the next period's start); a saved start after its salary is not
  used (it would move the salary row back), one > 20 days after the last payday is `detectPaydays`' own. RX7c: `rangeFor`
  / `shiftRange` pay periods use the same two functions: each range = `[start, end − 1]` of its `periodSummaries` period
  (the running one so never ends before today); beyond the list they extend with expected paydays (before the first; after
  today, so a forward step from a late running period skips to the next expected payday); no starts at all = the latest
  expected payday ≤ today (`periodSummaries` is empty then). Same boundaries only with the same `txs`/`st` (the app's
  Insights must pass `settings`, not `effectiveSettings`). Tests `test/rx7c_ranges_test.dart`. Identities pinned in `test/rx7b_periods_test.dart`
  (every row/review/wish in one period, Σ `periodDaySpend` over `[start, min(end, today + 1))` == flex).
- RXc dashboard numbers (pure, web-safe): `averageOut(txs, month, months: 6, currency:)` (budget.dart) = Σ of the `months` months
  before `month` of `monthSummary.out` ÷ months, rounded like `averageByCategory` (it is the rounded total, so it can differ
  by cents from Σ of the rounded per-category values); `changePermille(now, before)` = (now − before)·1000/|before| half away
  from zero, null when before is 0; `reviewsIn(reviewDates, start, end)` (reports.dart) = valid dates in [start, end),
  ascending, once each. Tests: `test/rxc_dashboard_numbers_test.dart`.
- `search.dart` — `searchAll(query, txs:, goals:, wishlist:, bills:, planned:)` → `SearchResult` (`txs` newest first capped at
  `searchTxLimit` 200, `goals`, `wishlist`, `bills`, `planned`, `billsDb` (stored bills: payee, description, item
  names, exact total), `isEmpty`; blank query → `SearchResult.empty`). Text: `foldText`
  (lower case, č ć š ž đ → c c s z d, `dj` → `d`, common Latin accents) substring over tx description/note/category
  (resolved), goal name, wish name, bill label/category; live rows only. Amount: `parseAmountQuery` (`12`, `12.5`,
  `12,50`, `-12.50`, `12.50 €`; null for `12.`, more than two decimals — never rounded —, words, thousands separators,
  > 15 digits) → cents; matches `Tx.amount.abs()`, goal target or saved, wish price, bill expectedAmount. A query
  that is both matches either way; a row is listed once.
- `logs.dart` — logging (`package:logging`): `logEvent`/`logError` (structured events), `formatLogRecord` (one line,
  errors via `describeError`, which drops SQL parameters, paths and FormatException sources), `LogSink` (`add`,
  `flush`, `close`) with `MemoryLogSink` (ring buffer by UTF-8 bytes, `maxBytes` default 2 MiB, oldest lines dropped
  and counted in `dropped`, the newest line always kept; `lines`, `dump()` = lines joined with `\n`; the web app's
  Diagnostics download) and `RotatingFileSink` (`logs_io.dart`, native), `timed`/`timedAsync`/`PerfTimer` (on
  `bw.perf`), `FrameStats`.
- Stage Q core B (pure unless noted, nothing written; tests `test/q1_suggest_categories_test.dart`, `q6_rule_suggestions_test.dart`,
  `q7_search_filter_test.dart`, `q9_recent_changes_test.dart`, `q10_recurring_cost_test.dart`):
  `tags.dart` `suggestCategoriesForText(text, history, cz, {limit: 3, kinds, exclude})` (rule on the text, then rows
  whose folded description/note holds it, ≥ 3 chars, by count then newest; only `pickable(kinds:)` minus `exclude`, on
  every step before the limit, so the result is what the caller's picker offers; never the amount) and
  `recentPayees(history, prefix, {limit: 5})` (bank merchant names + notes, prefix hits first, newest first).
  `rules.dart` `ruleSuggestions(rows, cz, {min: 3, off})` / `ruleSuggestionFor(t, rows, cz, …)` → `RuleSuggestion`
  (≥ min of a payee's newest 5 bank rows set to one live category by hand, no rule, not dismissed; never when a payee
  rule would not decide one of those rows, i.e. its automatic tag is not flex/fixed). `search.dart` `SearchFilter`
  (`searchAll(filter:, attachedTx:)`: per payment on its whole row, `abs` amount and dates inclusive, a split fits by
  any part's tag, tags compared as `duplicateOf` originals (with `table`), attachments from `attachedTx` =
  `repo.attachedTxIds()` (`bills()` holds none),
  `uncategorised` = no owner category and not split; an active filter returns payments only, also for a blank query)
  and `matchSpans(text, query)` (folded match mapped back to the original text). `changes.dart` `ChangeEntry` +
  `repo_changes.dart` (`WalletRepoChanges.recentChanges({limit: 100})`: newest clock per (entity, id) from `clocks`,
  label per entity, logs counts only). `recurring.dart` `recurringCost(bills, currency:)` → `(monthly, yearly,
  approximate)`: confirmed unfinished bills; 27..31 days exact (× 12), quarterly × 4, yearly × 1, others amount × 365
  ~/ days; monthly of non-monthly = yearly ~/ 12; a range counts its midpoint (`approximate`).

## Rules
- Amounts are `int` cents; expenses negative. Dates are `YYYY-MM-DD` strings.
- New table or field: add it to `entitySchema` in `schema.dart` (for bill/account: one `Col` line in `BillCols` /
  `AccountCols`; DDL, sync, type check, migration, search and `patch` follow), bump `schemaVersion` with a new
  `test/fixtures/schema/vNN.sql` (the guard test asks), and add it to `entityTables` in `test/support/sim.dart`;
  existing devices must still open old databases (add columns, never rename).
- Pure functions for new calculations (inputs → result object), so tests need no database.
- **Money is never reclassified on amount alone** (owner rule). Hiding a row as a transfer, or moving it to another
  category, needs evidence from the bank row itself (the importer's `kindHint`, its type or text); an equal amount in
  another account within a few days is never enough on its own. The same goes for any future "looks like" rule.
- Keep `vault.dart` / `sync.dart` file formats backward compatible (`BWOP1`, `BW1-` keys), and the backup payload
  (`{"v":1,"ops":[...]}`): a new shape bumps `backupVersion`, and older builds refuse it as `newerVersion`.
- Backups: restore only into an empty wallet; a wallet with data merges (`mergeBackupBytes`, newer field wins); `snapshotOps` must keep each
  field's own clock (grouping fields by clock), never one fresh clock per row, or a restored device would overrule
  edits other devices made in between.
- Logging: loggers `bw.<area>`; every catch block logs (`logError`). Log counts, durations, sizes, dates, built-in
  categories, setting keys. **Never** amounts, descriptions, merchants, notes, goal/wish names, the key, device ids,
  paths or file names. Noisy per-render logs at FINER. `test/logs_impl_test.dart` checks core logs stay clean.

## Known limits (for the sync redesign)
- Schema 20 (UX-A) amounts: every fiat currency is stored in hundredths as before; a currency with 3 ISO decimals (KWD,
  BHD, JOD, OMR, TND, LYD, IQD) has no third decimal: typed input allows 2. Every importer (PBZ, Revolut, mapped CSV,
  e-invoice) refuses an amount, fee or balance with non-zero digits past the storage scale, per row with a reason
  (`ImportBatch.problems`), never rounded: a 3-decimal EUR cell that v1 rounded (half cents, `-3.333`) is now refused.
  BTC is stored in satoshis from schema 20 on, no migration (owner 2026-11-01): BTC rows imported before schema 20
  would read 10^6 too small; the owner had none. An older build shows and edits BTC amounts wrongly: update every
  device first. Crypto row ids hash the satoshis (`transactionId(..., digits: 8)`); fiat ids stay v1's.
- FX rate range (UX-A review): fiat 1..10^12 (up to 1,000,000 home units per foreign unit), crypto to 10^15 (10^9 per
  coin), so any wallet currency fits (a JPY wallet's USD ≈ 150, BTC ≈ 15,000,000). Exact BigInt above 10^8; a
  converted value past `WalletSettings.maxAmount` stays out of the sums. A synced or restored wallet currency that is
  unknown or crypto reads as EUR (`settings.invalid` key `currency`).
- Built-in rules (UX-A) are one rule per brand with stable slugs (`builtIn:lidl`); `builtIn:<index>` (the 10 grouped
  rules before) resolves to that group's first brand. Overrides are rows `builtInRule:<slug>`; a slug is never reused.
- D2 Unlink (`tx.match_off`, schema 19): a build older than 19 ignores the field, so it can match the unlinked pair
  again (its `matched_to` op then reaches the new builds, which reopen the match: a rewrite back and forth on every
  sync until that device updates). Every device updates together. The unlink does not undo what matching copied to the
  bank row (category when it had none, extra tags) or the attachments it moved there.
- Undo of a deleted payment row restores its bill link from this device's `undo.<txId>` record. If another device runs
  caught up inside the app's 2.5 s Undo window, sees the delete and unlinks the bill with a clock later than the undo,
  that unlink wins: the bill stays open (reserved) while the row counts again, until the owner links it.
- The same export imported on two devices before they sync: the later import's `amount` clock wins, so a cash entry
  added in between on the first device can be matched to that row although that device held it.
- A sync file changed after sealing fails authentication like one sealed with another key: both are `badKey`
  (`MemoryTransport.corrupt` flips the magic too, so it gives `corrupt`).
- A refused relay file that no snapshot covers stops that device's later files on every device that has not applied it
  (the relay never overwrites a file, the blocked reader never acks past it; matching and pairing wait there, cash
  entries keep counting). Self-heal: any caught-up device that applied the file (the author or another one), once it
  has seen the blocked device (seen within 24 h) stay below it for over 24 h, writes a snapshot covering it, and the
  blocked device goes on from it on its next run. KL: from its second blocked run the blocked device asks the author
  (at most once per file per 24 h); a KL-or-newer author that still syncs writes a covering snapshot on its next
  caught-up run and resends its state. When the author is gone (and no other device heals it), the owner can skip the
  file (`skipBlockedFile`, Settings › Sync): device-local, the later files are read, but that file's changes are lost on
  this device unless the author later resends its state or a state-digest repair with a device that holds them brings
  them back. A blocked device that cannot read snapshots stays blocked until skipped (no storm: the snapshot covers the
  file, so nobody writes another).
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
  know. A schema-bump replay or a new device ignores a snapshot of an older schema while the files are still there. A
  device whose next file is pruned starts from a kept snapshot of its schema first (newer builds write one as soon as
  the newest is older-schema, Q8); with none kept it starts from the older one and, if it started from empty cursors,
  writes no snapshot of its own (heal snapshots excepted) for up to 30 days and takes the next current-schema one when
  a device holding the fields writes it. Past those 30 days (no
  upgraded device that holds them synced) the fields stay missing there until they are written again.
- A wiped, replaced or restored relay (H5/H5b): a device whose stream lost files moves to a new stream epoch (never a
  seq reused with other content), and a relay that names another instance makes every device start over (cursors 0,
  whole state again), so nothing is skipped. Remaining: a run that stopped after a stored PUT but before it recorded
  `syncSent`, on a relay then restored to a copy from before that PUT, is not noticed (its `last` equals `syncSent`)
  and that seq can be reused; abandoned streams stay on the relay until snapshots and acks let them be pruned, and
  each one costs one ack request per run; builds before Stage H show every stream as its own device (they cannot talk
  to an api-3 relay anyway).
- Two installs with the same device id (a copied database or key store): the second one to sync moves to a fresh
  stream (whole state once, `deviceIdInUse` reported once) and both keep syncing. They share the HLC node, so two of
  their writes with the same millisecond and counter compare equal (the first applied wins on each device). A stream
  left to another install is no longer acked by this one: if that install stops, pruning of other devices' files waits
  for the 90-day `lastSeen` rule. A database restored from an older file copy looks the same (it reads its own later
  files back from the old stream).
- Device id per install: the old id's stream after an id change stays on the relay as a peer (read once, idempotent)
  and acked as until pruned, or until it grows (the original of a copied database writes it): then never again. Until
  that first growth the copy's acks under it count for pruning; a pruned file is still covered by a snapshot.
- Double restore (database and relay folder from one moment): peers that read past it notice through their acks
  (rolled-back relay) and start over; streams this install made after the moment are missing from its restored
  `syncStreams` and are reported once as `deviceIdInUse`. A stream left to another install that stops syncing holds
  back pruning for up to 90 days (`lastSeen` rule).
- The snapshot rule's "500 ops behind" counts only the files this device applied or sent itself (`sync_files`); files it
  skipped by starting from a snapshot are not counted.
- Own transfers: two devices that pair offline from different row sets can write different partners for one row;
  after sync the non-mutual link is cleared and the pair that both hold stays. A hinted row with two equal candidates
  takes the closest, which can be the wrong one (the real one then stays open; the user override corrects the
  category but not the link). A pair made by the earlier amount-only rule stays on a device that holds only one of its
  rows until the partner arrives. Older builds drop `kind_hint`/`transfer_to` from ops they apply (replayed once on
  upgrade) and categorize a paired row by its text, so they can show a transfer as spending until they upgrade.
- Bounded HLC (H7): a peer whose clock is more than an hour ahead has its files quarantined (`clockDrift`) on the
  others until their clocks catch up or it is corrected (its later files wait behind the first one); it still reads
  theirs. A device whose clock is set more than an hour back (behind its own highest reading) cannot make owner
  writes until it is set right (sync, matching and repairs go on). A database holding far-future clocks taken before
  Stage H keeps working; its new writes are stamped just after those clocks (the HLC counts on from the newest). A clock that is wrong
  from the very first open is not detected. Older builds take far-future clocks as before.
- BWOP2 (H8): files, snapshots and backups written by Stage H builds are unreadable to older builds (`unknownVersion`
  / `newerFormat`, read after their upgrade); a `.bwb` made now does not restore on an older build. `BWOP1` from older
  builds is read without AAD, so an old file moved to another seq on the relay is not detected (only `BWOP2` binds it).
- BWOP3 (V1): the same for Stage V files and `.bwb` on builds before V. Old `BWOP2` files still say only `badKey`
  (another key or damaged). The key id is public (it is also stored next to the data as `keyId()`).
- State digest (V2): compared only when two devices name the same data files (vector) with empty outboxes, so two
  devices that keep writing at the same moment compare only once one of them is quiet; a device that started from a
  snapshot compares only after every device whose covers ended on a records-only file wrote data again; a snapshot
  written while its writer's outbox held ops (matches made in that run) holds state its covers do not name, so a
  compare in that window can report a false mismatch (one needless repair). A field with the same clock but another
  value on two devices is never picked automatically (VC): both keep their own until the owner chooses
  (`syncConflicts`); until then their digests differ, `devicesDisagree` stays and no automatic repair runs. A row whose
  clocks remain but whose row is gone takes the resend value (restores data, changes no value the owner sees as his).
  A conflict entry is device-local: a reinstall loses it (the digest mismatch shows again on the next data change).
  A conflict keeps only the latest `theirs`: with three devices holding three values the owner sees two of them
  (choosing either still settles all three, the choice gets a new clock). Open conflicts are dropped when every peer
  digest read in a run matches (the other value is held by no device any more); after the 500 cap dropped entries, an
  empty list lets one more repair run. A lost row whose own newer-clock fields cannot be read back is restored hidden
  (`deleted` 1 when it has a `deleted` clock) with those fields as conflicts; a lost row without any `deleted` clock
  and no resend field for it stays hidden silently.
  `stateDigest` is cached per `dataVersion`, so a change behind the change log shows only after the next data change.
  Two devices that see the mismatch in the same round both ask: each device then resends its state once per ask
  (bounded, accepted). An ask written by a device whose clock is behind this device's first relay sync is ignored.
  About 300 ms per digest on a 20k-row wallet (VM, laptop), at most once per data version. M2: the engine calls
  `stateDigestAsync(atVersion:)`: for a file opened by `WalletRepo.open` (native) it runs in a new isolate on its own
  read-only connection (same key, `readInIsolate` in `sqlite_io.dart`, one read transaction) and returns null (never
  cached) when `dataVersion` moved meanwhile, so the engine records no digest for a state its vector does not name and
  sends it on a later quiet run; in-memory/`fromDatabase` repos (tests, web) compute it synchronously; an isolate
  failure falls back to the synchronous path (`repo.stateDigest.isolateFailed`). Tests: `test/state_digest_async_test.dart`,
  `packages/sync/test/state_digest_async_sync_test.dart`.
- H9 repairs run only when caught up; a planned row a confirmed bill wants created is not created for a due date in
  the past.
- Recurring bills: a device that imports a payee's rows before syncing writes the candidate's amount/due/label again
  with a newer clock (same values from the same rows; different ones if it holds other rows), but never its status.
  A confirmed bill whose payment is not matched (amount moved > 10 %, paid > 3 days off the expected date, paid from an
  account not imported, or the bill ended) keeps its `nextDue`, so it stays reserved as overdue until the owner acts:
  `skipRecurring` moves it one interval on (the match then looks around the new date; the unmatched row still counts as
  spending, the bill is not reserved for that cycle), dismiss or delete end it. The amount band is not adjusted by a
  skip: a bill whose amount moved for good needs delete + re-confirm once detection sees three new rows. Older builds
  ignore the `recurring` entity (replayed once on upgrade).
- Recurring incomes (P9): the creation op of a detected income carries `status: in:candidate` (so older builds never
  take it for a bill candidate). Two devices that detect the same income from their own imports before syncing: the
  later creation op resets a confirm or dismiss made on the other device in between to candidate (the owner confirms
  again; the income then does not count until he does). Older builds show an income in search as a bill, and refuse a
  hand-added bill for a payee that has a live income.
- Planned costs: a planned cost whose bank row already landed still reserves until the owner marks it Paid or its date
  passes (counted as spent and reserved meanwhile; the app suggests "Paid by this?"). `.ics` UNTIL is compared by date
  only; a UTC time without `toLocal` takes its UTC date. Older builds ignore the `planned` entity (replayed once).
- Bills: the same bill imported on two devices before a sync: the later import's read fields (date, total, …) win over
  an edit made on the other device in between (status and deleted never: the creation op carries neither). An auto link
  is never re-planned: rows imported one by one link to the first candidate even if a second one comes later. A bill
  linked to a hand-added expense stays paid when matching later replaces that entry with its bank row. A deleted bill's
  file stays in the caches until evicted and on the relay until its GC (P14: 30 days after its last upload, once no kept
  snapshot declares it; a blob an op references is uploaded again before that op). A blob added before this device ever stored a
  file waits for one (the relay creates the wallet only then). Older builds ignore the `bill` entity (replayed once).
  A slip is matched to a confirmed recurring bill by exact payee key only (slip payee vs bank text may differ; then only
  its category keeps it from being reserved on top of the fixed plan). An unattached file (added, bill not saved) is
  uploaded and later collected by the relay GC. A key holder declaring empty sets twice lets GC drop files older than
  30 days (recoverable from caches and backups). Two devices adding an `asNew` copy before syncing make two bills (KL-A: the copy id holds the device id).
  Attachments (P16b): the 5-per-payment cap is checked on local adds and restores only; two devices attaching offline
  can leave more than 5 live after a merge (all kept, never deleted; no add or restore until the payment is below 5).
  Builds before P16b read `source: attachment` as `manual` and ignore `attached_tx`: they list an attachment as a
  confirmed, unpaid bill without a link (Bills › Unpaid; never reserved: no due date; never auto-linked: no link token;
  it never touches a real bill's link) until they upgrade; the owner could link it by hand there. A deleted payment's
  attachments keep their files on the relay and in backups (counted in the 16 MB backup budget) until the attachment
  itself is removed.
- Rules (P7, no schema bump): a build before P7 reads a `contains` pattern as a regex and ignores its amount range, so
  it can categorize differently (text only) until it upgrades. A deleted pattern's tombstone keeps no order: Undo
  (set again) puts it last. A text rename (new row + tombstone of the old one) on one device and an edit of the same
  rule on another, offline: the later edit revives the old row, so both texts are rules after sync.
- Legacy settings maps after schema 8: a `categoryBudgets`/`merchantPatterns` map row (an older build's write, or an
  old `.bwb` restored) fills in only entries that have no per-key row at all, live or removed. So an older build's
  change or removal of an entry that already has a row is ignored by upgraded devices (make it again on an upgraded
  build), while an entry it adds shows up. When that older device upgrades, its migration writes only the map entries
  that still have no row (with the map's clock); its edits to entries that have one are lost. Upgraded devices'
  per-key edits never reach an older build (it keeps showing its own map).

- Calendar refs (KL-A, `calendarEventRef`): stable uid + date + start time, else normalized title + date + start time;
  the same event read from two sources (phone calendar and an `.ics` link with another uid) gives two suggestions. A
  title without letters and no uid gets a per-calendar ref, so its "No cost" or confirm on one device does not reach
  the same event read on another device. A pre-KL decision stored under the legacy title + date ref applies to every
  event with that title on that day (pre-KL builds could not tell them apart). Two builds deciding the same event (one
  under the legacy ref, one under the new) leave two rows: both reserve, and Upcoming and the `.ics` export list both
  (Upcoming = Today, exactly), so the owner deletes one. A huge `.ics` file
  (over 10⁶ recurrence steps) gives later recurring events their first in-range occurrence only.

## Tests
- `test/core_test.dart`, one `group` per area. Shared synthetic data in `test/support/synthetic.dart`
  (`n(...)` builds a transaction, `january` is a sample month). Add new feature tests as `test/<feature>_test.dart`
  (goals: `test/goal_contrib_test.dart`, hints: `test/kind_hint_test.dart`,
  own transfers incl. two devices: `test/transfers_test.dart`, budgets per category incl. the setting and two devices:
  `test/budget_vs_actual_test.dart`, recurring bills + weekly review incl. two devices: `test/habits_test.dart`, M5 backup
  round trip incl. two devices + resend: `test/backup_test.dart`, V2 state digest / resend queue / tie-break and V1
  backup key id: `test/state_digest_test.dart`, bills (repo API, planned row, auto link, two devices, backup, schema 6 → 7):
  `test/bills_test.dart` (+ `bills_spec_test.dart`; B5a review fixes incl. two devices `bills_b5a_test.dart`; B6
  `bills_b6_test.dart`; helper
  `support/bill_helpers.dart` `confirmWithCategory`), future spending (planned costs, .ics, Upcoming, two
  devices): `test/future_spending_test.dart` (+ `future_spending_spec_test.dart`, `ics_spec_test.dart`; F4a: content refs
  incl. two devices `calendar_ref_test.dart`; KL-A known limits fixed: `kl_1_auto_paid_test.dart`,
  `kl_2_search_rules_test.dart`, `kl_3_payee_alias_test.dart` (synced `payee_alias`, schema 19), `kl_4_calendar_ids_test.dart`,
  `kl_5_copy_id_test.dart`, UX-A (storage scale, currencies, account kinds, built-in rule overrides + oracle `ux_a_builtin_oracle_test.dart`, bill reminder days, schema 20): `ux_a_core_test.dart` +
  spec tests `ux_a_currencies_test.dart`, `ux_a_accounts_test.dart`, `ux_a_builtin_rules_test.dart`, `kl_6_upcoming_today_test.dart`, RX8 `kl_compare_tag_test.dart`, parseIcs cost bounds + dismiss title `future_spending_fixes_test.dart`), CSV: `test/export_test.dart`, search: `test/search_test.dart`, clock stats (`WalletRepo.clockStats`, two devices): `test/clock_stats_test.dart`, data version: `test/data_version_test.dart`,
  web-safe core (`fromDatabase`, `backupBytes`/`restoreBackupBytes`, `MemoryLogSink`, gzip compatibility): `test/web_core_test.dart`,
  encrypted local database (new/convert/wrong key/WAL/interrupted conversion/perf numbers): `test/local_db_test.dart`
  (sqlite3mc proof tests: `test/encrypted_db_test.dart`);
  `<feature>_edge_test.dart` and `<feature>_spec_test.dart` are spec-written tests). Multi-device sim in `test/support/sim.dart` (lists entities on its own): `Net` (one
  `MemoryTransport`; a `Device` uses the latest `Net` made unless given `net:`), `Device` (own database; `run()` uploads
  and applies, `deliver(net, r, p:)` makes the next run's GETs fail with probability 1 − p, `upload` is a no-op kept for
  the helpers; `dbPath:` + `reopen()` simulate a restart or upgrade), `opsInNet`, `dump`, `bookkeeping`. `match_gate_test.dart`: matching only when caught up.
  Sync engine, transport and bill-file tests: `packages/sync/test` (they import this folder's `support/`).
  `test/layering_test.dart`: `lib/` never imports `package:wallet_sync`.
- Run: `tools/build.sh test` from the repo root (or `tools/build.sh shell`, then `cd packages/wallet_core && dart test`).
