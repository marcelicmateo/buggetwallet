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
  `logs_io.dart` (`RotatingFileSink`). `platform_error_io/web.dart` give `describeError` its
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
- `schema.dart` — the typed entity schema: `entitySchema` (entity → `EntityDef`: table, `ColumnDef`s with type
  text/integer/flag, nullable, searchable, default, indexes). The DDL (`schemaSql`), the column migration on open,
  `_apply`'s type check, the snapshot writer, `isEmpty` and `searchRows` derive from it; `test/schema_test.dart` pins
  the generated DDL to the hand-written v7 text and checks it against `test/support/sim.dart`'s independent list.
- `repo.dart` — `WalletRepo`: open/migrate, change log, reads, and every write. Writes go through `_write(...)` so each one
  becomes a sync op; never `db.execute` an INSERT/UPDATE on a data table directly. `_apply` reads the row's clocks once
  and checks each field's type (`_fieldValue` by its `ColumnDef`): a wrong-typed one is ignored (`repo.badField`, entity +
  field only) without recording its clock, the op's other fields apply, and a row is only created when some field applies.
  Sections live in `part` files as extensions on `WalletRepo` (same library, so they use `_write`): `repo_planned.dart`
  (`WalletRepoPlanned`), `repo_bills.dart` (`WalletRepoBills`), `repo_blobs.dart` (`WalletRepoBlobs`), `repo_settings.dart`
  (`WalletRepoSettings`: `setCategoryBudget`, `setMerchantPattern`, `removeMerchantPattern`, the schema-8 migration, and
  `_readSettings`/`_settingChanges` behind `settings()`/`updateSettings`).
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
  paydayDay, today)` (dates.dart) = the latest expected payday on or before today, for "start the new period" after
  several missed paydays; `daysLeft` is the real count (0 once passed);
  `allowanceToday` ≥ 0 always (0 when passed or the money is used up); `allowanceTomorrow` (Stage I) = max(0,
  round((flexBudget − spent) ÷ (daysLeft − 1))), null when `daysLeft` ≤ 1 or passed; `safeToday` = allowance − spentToday (negative =
  `overToday`); `overBy` = max(0, −remaining); `overBudget` = `overBy > 0 || planDaily <= 0`. `affordability`:
  `Verdict.overBudget` whenever `p.overBudget` (never `now`), `later` once the payday passed or when the price does not
  fit, `newDaily` never negative. `lowIncome` (moved from the app): received > 0, below 90 % of salary (int maths), at
  least 4 days in and not in the first `samePaydayDays` (7) days; in `incomeMode == 'received'` those first 7 days count
  `max(received, salary)` (salary parts still landing; owner: paid 10th–15th). `periods.dart`'s grouping constant is
  `_salaryGroupDays` (20). `WalletSettings.fromMap` reads a stored `paydayDay` 29..31 as 28 (`maxPaydayDay`).
  Budget vs actual per category (calendar months, owner decision 2026-10-20): `budgetVsActual(txs, month, budgets, today:, currency:)` →
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
- `recurring.dart` — recurring bills (M4). `detectRecurring(txs, today:, currency:)`: candidates = a payee (`merchantKey`) with ≥ 3
  live bank outflows (no transfers, no hand-added rows) in the last 7 calendar months, every gap 30 ± 3 days, every
  amount within 10 % of the median (`withinBand`, inclusive, int arithmetic); `expectedAmount` = median, `nextDue` =
  last payment + 30, label/category from the latest row, id `rec:<payee>` (`RecurringBill.idFor`) so every device
  derives the same row; ordered by label. One extra purchase at the payee breaks the chain (shops are never bills).
  `planRecurringPayments(bills, rows, currency:)`: for each confirmed bill the live bank row with its payee key within ± 3 days of
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
  `movePattern(id, MoveDirection)` (swap orders; ties renumbered). Logs `settings.pattern {op, match, range}`.
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
  9 = the `account` entity, no data migration; 10 = the `category` entity (P1), no data migration). Opening an existing database with an older version
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
- `dates.dart` — `YYYY-MM-DD` string helpers. `hlc.dart` (H7 bounded HLC: `maxClockDrift` 1 h; an owner write (the
  public write API) throws `ClockBehindException` (nothing written, message without clock values) while this device's
  wall clock is more than that behind the highest reading it wrote with (device-local meta `wall_high`, raised by every
  write, owner or internal; never a peer's clock, so a database holding a far-future HLC from before Stage H still accepts owner
  writes); `repo.clockBehind` logs minutes only. Internal write paths skip the guard:
  `WalletRepo._writeInternal(changes)` and `_asInternal(body)` (the open-time migration, `_reconcile` = pairing,
  matching, H9 repairs, bill links, `refreshRecurring`, `runPendingMatch`, `dropOrphanBlobs`); `tick` stays monotonic.
  `SyncEngine.run` catches a `ClockBehindException` from `runPendingMatch` (logged, matching stays pending).
  `restoreBackupBytes` refuses a backup whose newest clock is more than `maxClockDrift` ahead of the wall clock:
  `BackupException(BackupFailure.clockAhead)`, nothing applied), `vault.dart` (key + encryption; `VaultKey.parse` ignores case, spaces and dashes and reads a digit 0 as O (Base32 has
  no 0; 1 stays refused); `UnsealFailure` says why a
  file was refused, `tooLarge` past the inflate cap; `deriveKey` = HKDF-SHA256, empty salt), `sync.dart` (`SyncException`,
  `SyncReport`, `SyncWaiting`, `SyncDevice`, `relayFingerprint(instance)` = first 8 hex as `xxxx-xxxx`; web-safe) +
  `sync_engine.dart` (below).
- `vault.dart` formats (H8): `seal(plain, key, {required aad, nonce})` writes `BWOP2` = magic | nonce(24) | mac(16) |
  XChaCha20-Poly1305 of gzip with `aad` as associated data (`nonce` is a test seam for known-answer vectors). AAD per
  use: `aadSyncFile(device, seq)` = `bw-sync-file\n<relay device name>\n<seq>`, `aadSnapshot(id)` = `bw-snapshot\n<id>`,
  `aadBackup`, `aadBlob`, `aadWebKey` (the app's passphrase-wrapped key). `unseal(data, key, {required aad, maxBytes})`
  reads `BWOP2` (another AAD = `badKey`, like a changed file) and `BWOP1` from older builds (no AAD, any `aad` given);
  `BWOP3`+ = `newerFormat`. Inflate capped at `maxUnsealBytes` (256 MiB, `maxBytes` lower only in tests) through
  `package:archive`'s `maxOutputSize` → `tooLarge` (quarantined as `corrupt`). `syncReaderVersion` = 2. Older builds
  read `BWOP2` as `unknownVersion` (quarantined, read after their upgrade). `local_db.dart` pins
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
  (source, currency), cash = `source` null; dates not after the repo clock's today. `accounts.dart` (pure):
  `accountBalances` = opening + rows after `openingDate` (bank: its source's imported rows, every kind; cash: hand-added
  rows not matched or pending; ATM never adds to cash); a sync duplicate (same key, larger id) gets `duplicateOf`, its
  opening only, and `balanceTotals` (per currency) skips it. `suggest.dart` (pure): `suggestPlan(txs, st, today,
  confirmed:)` reads salary/paydayDay (payday groups), rent/loan (categoriser's Rent/Loan rows, never the amount) and
  subs (confirmed Bills & subscriptions bills) in the home currency; `planProposals` lists the differing ones (never
  writes). `budgetProposals` (budget.dart) is the Suggest diff (empty fields first).
- `planned.dart` + `ics.dart` — future spending (§4.3, API and decisions in `docs/context/FUTURE_SPENDING_API.md`), pure
  and web-safe. `PlannedCost` (`models.dart`): synced entity `planned` (schema 6: `title`, `date`, `amount` nullable
  cents > 0, `category`, `source` manual|calendar|bill, `source_ref` = `CalendarEvent.ref` = `calendarEventRef`
  (SHA-256 prefix over the normalized title + date, the same on every device and source; `calendarRef` per calendar
  only for titles without letters; never a raw id or title), `status` open|paid|skipped, `paid_tx`, `deleted`). Repo: `plannedCosts(includeClosed:)`, `addPlanned` (id
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
- `bills.dart` + `blob_store.dart` — bills database (stage B, API and decisions in `docs/context/BILLS_API.md`), pure and
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
  settings `returnReminderDays` (3, 0..30) / `warrantyReminderDays` (14, 0..90). `BlobStore(repo, key, maxCacheBytes:)`:
  `add` (async: seal, hash = SHA-256 of the sealed bytes, cache + `blob_outbox`), `read(hash, transport:)` (cache, else
  fetch, hash checked, unsealed, cached). Device-local tables `blob_cache` (LRU by a use counter, never evicts a queued
  hash), `blob_outbox`, `blob_delete`, `blob_own` (files this device attached to a bill; not in `_entities`, snapshots
  or backups); repo helpers `putCachedBlob`, `cachedBlob`, `evictBlobs`, `queuedBlobs`, `markBlobUploaded`, `blobDeletes`,
  `markBlobDeleted`, `dropOrphanBlobs` (own files no live bill points to: a queued one forgotten, an uploaded one queued
  for deletion; after a caught-up run and before uploads). H9 field pairs (`_repairFieldPairs`, in `_reconcile` before
  `_autoLinkBills`, through `_write`): a live planned row keeps `paid_tx` only while `status == paid`; a payment row pays
  at most one live bill (earliest `linked_tx` clock stays, then smallest id; the others unlinked via `_billWrites`); every
  bill's planned row `bill:<id>` is set to what `_billWrites` wants for the bill as it is. `_billWrites` writes
  `status` and `paid_tx` together whenever either changes; `skipPlanned` clears `paid_tx`. Delete vs edit per entity:
  `docs/context/DESIGN_DECISIONS.md` §4.10. Logs: `bills.*`, `blob.*`,
  `sync.blob*` with counts, sources and enum words only.
- `ranges.dart` + `insights.dart` — graph ranges, graph data and the Spending drill-down (N3, spec + clarifications in
  `docs/context/N3_SPEC.md`), pure and web-safe. `DateRange` (inclusive `YYYY-MM-DD`, checked), `rangeFor` (pay period from
  `detectPaydays`, whole calendar months, custom ≤ 5 years and not past today's month), `shiftRange` (needs `today:`), `rangeLabel`.
  `insights.dart` never counts on its own: per month it clips the rows to the range and calls `monthSummary` (spending,
  income; extra = `monthSummary` of the extra rows), `budgetVsActual` (`budgetVsActualSeries`) and `averageByCategory`
  (`compareCategory`); the row lists (`merchantsIn`, `rowsFor`, `merchantTrend`, `biggestRows`) use `_isSpending`, the same
  rule row by row, so `rowsFor` sums equal their totals. Group key `''` (`Other`) = manual row without a note or `merchantKey`
  `x`. Tests: `test/n3_ranges_test.dart`, `test/n3_insights_test.dart` (incl. a loose 500 ms perf test on ~10k rows from
  `test/support/n3.dart` `bigWalletRows`).
- `search.dart` — `searchAll(query, txs:, goals:, wishlist:, bills:, planned:)` → `SearchResult` (`txs` newest first capped at
  `searchTxLimit` 200, `goals`, `wishlist`, `bills`, `planned`, `billsDb` (stored bills: payee, description, item
  names, exact total), `isEmpty`; blank query → `SearchResult.empty`). Text: `foldText`
  (lower case, č ć š ž đ → c c s z d, `dj` → `d`, common Latin accents) substring over tx description/note/category
  (resolved), goal name, wish name, bill label/category; live rows only. Amount: `parseAmountQuery` (`12`, `12.5`,
  `12,50`, `-12.50`, `12.50 €`; null for `12.`, more than two decimals — never rounded —, words, thousands separators,
  > 15 digits) → cents; matches `Tx.amount.abs()`, goal target or saved, wish price, bill expectedAmount. A query
  that is both matches either way; a row is listed once.
- `sync_problems.dart` — a peer file that cannot be used is skipped (the run goes on with the other files and devices)
  and quarantined: `BadFiles`, one device-local value (`localValue('syncBadFiles')`, never synced), records device,
  file, `SyncProblemReason` (`badKey`, `corrupt`, `unknownVersion`, `applyFailed`, `clockDrift` (H7, retried at
  `retryAt`); `unreadable` = I/O error, not quarantined; `deviceIdInUse` (H6) = about this device's own uploads, never a
  quarantine), size and content hash. It is read again only when its content changes, or (unknownVersion,
  applyFailed) once after `SyncEngine.build` changes (`<syncReaderVersion>.<WalletRepo.schemaVersion>+<app version
  passed to SyncEngine>`). `SyncReport.problems` lists every file not applied, also the known ones on every run
  (`SyncProblem`: short device id = first 8 characters of its id, reason, bytes, `isNew`), `badFiles` is
  their count. Database errors that are about this device (read-only, disk full, I/O, locked) stop the run instead,
  so the file is not refused for good. The quarantine is separate from the cursors: a schema upgrade reads every
  peer file again, an unchanged badKey/corrupt file stays skipped, unknownVersion/applyFailed are tried once more.
- `sync_engine.dart` — relay sync (§4.9, wire protocol `docs/context/RELAY_PROTOCOL.md`), web-safe. `SyncTransport`
  (`state`, `put`, `get`, `ack`, `putSnapshot`, `getSnapshot`, `putBlob`/`getBlob` (null on 404)/`deleteBlob`, whose
  defaults act like an older relay: 404; `run` uploads `blob_outbox` before the ops (a 404 before this device's first
  file is retried once after it: the relay creates a wallet only then), sends `blob_delete` after the ack, failures stay
  queued and never stop the run, `SyncReport.blobsSent`/`blobsWaiting`/`blobsUnsupported` (404 on an upload for a wallet the relay knows = older relay); failures are `TransportException(TransportFailure)`),
  `RelayState`/`RelayDevice`/`RelaySnapshot` (+ `fromJson`), implemented by `MemoryTransport` (`sync_memory.dart`: the
  relay's rules in memory — no gaps, never overwritten, acks grow, snapshot 422 before 409, two kept snapshots, pruning
  incl. the 90-day rule driven by `now`; no signature check; blobs: hash checked, 404 for an unknown wallet, hooks `blobs`, `blobRoutes`, `tamperBlob`; test hooks `offline`, `corrupt`, `failGet`, `replace`, `files`,
  `calls`, `instance` (random per transport, sent once the wallet exists; null = an api-2 relay), `maxBytes` (reported
  with `storedBytes` in state once the wallet exists, not enforced; null = an older relay), `wipe()` (empty, new
  instance), `copy()`/`restore(copy)` (a relay restored from an older copy of its data folder, same instance)) and
  `RelayTransport` (`sync_relay.dart`, `package:http` + `cryptography`, api 3 (`relayApi`), paths under `/v2/`: `wid` and the Ed25519
  key pair from `deriveKey` (`relayIdInfo`, `relaySignInfo`; `ids` = (wid, public key)); every request carries
  `X-BW-Time` (device clock + `clockOffsetMs`) and `X-BW-Sig` over `signedText` (`bw-relay-v3`: method, `signedHost`
  of the URL (lower case, port only when not the default), path from `/v2/` even behind a base path, `X-BW-Covers`,
  body SHA-256, time); `PUT d/<device>/1` also sends `X-BW-Pub` and, with `createToken:` set, `X-BW-Create-Token`
  (403 `createToken` → `TransportFailure.createToken`, fatal for the run). `clockOffsetMs` lives in the transport
  (never persisted; the app builds a new transport per run, so a device whose clock is off pays one 401 `clock` retry
  per run). 401 `clock` → offset from the
  `Date` header (`parseHttpDate`, no dart:io) and one retry, never more (a second `clock` = `other`); status → failure,
  `api` above 3 → `newerApi`, below → `olderApi`; a 401 that is not `clock` asks `health` once (api 2 → `olderApi`,
  above 3 → `newerApi`, else `refused`); 404 state = empty relay, 30 s timeout; `health(base)` asks
  `/v2/health`, on 404 `/v1/health` to tell an older relay apart; `now:` for tests). About 1.8 ms per signature on the VM.
  Stage H (H5–H9) in the engine: `SyncEngine.run` while a run of the same engine is in progress returns that run's
  future (`sync.run.joined`); relay usage (Stage I: `RelayState.bytes`/`maxBytes`, null from an older relay or for a
  value that is not a non-negative int; `SyncReport.relayBytes`/`relayMaxBytes` from the run's state read, so the run's
  own later upload may not be in it; `test/relay_usage_test.dart`); relay instance (`RelayState.instance`, device-local `syncInstance` stored when an upload
  went through completely; another id = `SyncReport.relayChanged`: every cursor to 0 and a first connect; none stored
  yet = adopted; a run that created the wallet asks `state` once more to learn it); streams and ownership (H5b/HBb,
  RELAY_PROTOCOL.md "Device streams and ownership"; `SyncEngine.streamName/streamBase/streamEpoch`, local
  `syncStream` (current; absent = the device id), `syncStreams` (every stream this install wrote and acks as),
  `syncSending` (`{"from", "parts": {seq: fileHash}}` during an upload, each part recorded before its PUT),
  `syncForeign` (streams of other installs already reported), `syncStreamLast` (relay `last` of each stream it left),
  `syncAcked` (the acks it stored per stream)): `_move` takes a fresh stream `<id>-<n><6 random letters>` (n above
  every same-id stream known) and the next upload is the whole state from seq 1, when the relay's `last` of the current
  stream is below `syncSent` (kept as acked; its `last` recorded), above it with an extra seq that is not its own
  recorded part (fetched and hashed once; another install, or this database restored from an older file copy; no
  longer acked as), or on a 409 (same run, once; `syncSending` cleared). A left stream whose `last` grows past
  `syncStreamLast` is dropped from `syncStreams` (another install writes it; reported once). An ack on the relay below
  `syncAcked` = a rolled-back relay: `relayChanged`, every cursor 0, `syncAcked` cleared. Every stream but the current one is read like a peer's;
  acks go under the current stream and every listed stream in `syncStreams` (cursors + the current `last`); cursors of
  streams the relay no longer lists are dropped; `SyncReport.devices` lists one entry per device id. `deviceIdInUse`
  (`SyncProblem.device` = own short id, `bytes` 0 or the refused file's size) is information, reported once per move or
  newly seen same-id stream; it does not stop uploads or `caughtUp`. `clockDrift`: a file
  or snapshot whose newest op clock is more than `maxClockDrift` ahead of the repo's wall clock (`repo.clock.now()`) is
  quarantined with `BadFile.retryAt` (= newest − 1 h, JSON `u`; snapshots `retryAt`) and read again from then on, or
  after a build change. Every file is unsealed with `aadSyncFile(<stream>, seq)`, snapshots with `aadSnapshot(id)`.
  `SyncEngine(transport, key, appVersion:, now:, partBytes:).run(repo)`: reads `state`; uploads pending ops as `last + 1`
  (seq from the relay, so a failed PUT leaves no gap; a 422 keeps the outbox for the next run, a 409 moves the stream); the **first run on a
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
  full, newer relay API, older relay API, other. Opening a database from the old folder-sync builds drops its `peer_files` table (`repo.peerFiles.dropped`).
- `logs.dart` — logging (`package:logging`): `logEvent`/`logError` (structured events), `formatLogRecord` (one line,
  errors via `describeError`, which drops SQL parameters, paths and FormatException sources), `LogSink` (`add`,
  `flush`, `close`) with `MemoryLogSink` (ring buffer by UTF-8 bytes, `maxBytes` default 2 MiB, oldest lines dropped
  and counted in `dropped`, the newest line always kept; `lines`, `dump()` = lines joined with `\n`; the web app's
  Diagnostics download) and `RotatingFileSink` (`logs_io.dart`, native), `timed`/`timedAsync`/`PerfTimer` (on
  `bw.perf`), `FrameStats`.

## Rules
- Amounts are `int` cents; expenses negative. Dates are `YYYY-MM-DD` strings.
- New table or field: add it to `entitySchema` in `schema.dart` (DDL, sync, type check and migration follow) and to
  `entityTables` in `test/support/sim.dart`;
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
- Planned costs: a planned cost whose bank row already landed still reserves until the owner marks it Paid or its date
  passes (counted as spent and reserved meanwhile; the app suggests "Paid by this?"). `.ics` UNTIL is compared by date
  only; a UTC time without `toLocal` takes its UTC date. Older builds ignore the `planned` entity (replayed once).
- Bills: the same bill imported on two devices before a sync: the later import's read fields (date, total, …) win over
  an edit made on the other device in between (status and deleted never: the creation op carries neither). An auto link
  is never re-planned: rows imported one by one link to the first candidate even if a second one comes later. A bill
  linked to a hand-added expense stays paid when matching later replaces that entry with its bank row. A deleted bill's
  file stays in other devices' caches until their next caught-up run. A blob added before this device ever stored a
  file waits for one (the relay creates the wallet only then). Older builds ignore the `bill` entity (replayed once).
  A slip is matched to a confirmed recurring bill by exact payee key only (slip payee vs bank text may differ; then only
  its category keeps it from being reserved on top of the fixed plan). Files attached before B5a are not in `blob_own`,
  so an orphan among them stays on the relay. Two devices adding an `asNew` copy before syncing make one bill.
- Rules (P7, no schema bump): a build before P7 reads a `contains` pattern as a regex and ignores its amount range, so
  it can categorize differently (text only) until it upgrades. A deleted pattern's tombstone keeps no order: Undo
  (set again) puts it last.
- Legacy settings maps after schema 8: a `categoryBudgets`/`merchantPatterns` map row (an older build's write, or an
  old `.bwb` restored) fills in only entries that have no per-key row at all, live or removed. So an older build's
  change or removal of an entry that already has a row is ignored by upgraded devices (make it again on an upgraded
  build), while an entry it adds shows up. When that older device upgrades, its migration writes only the map entries
  that still have no row (with the map's clock); its edits to entries that have one are lost. Upgraded devices'
  per-key edits never reach an older build (it keeps showing its own map).

- Calendar refs are built from the normalized title and date (`calendarEventRef`): two events with the same normalized

  title on the same day (amounts stripped: `Dentist 80 €` and `Dentist 90 €`) show as one suggestion, and renaming an
  event in the calendar makes it a new suggestion. A title without letters (`80 €`) gets a per-calendar ref, so its
  "No cost" or confirm on one device does not reach the same event read on another device. A huge `.ics` file
  (over 10⁶ recurrence steps) gives later recurring events their first in-range occurrence only.

## Tests
- `test/core_test.dart`, one `group` per area. Shared synthetic data in `test/support/synthetic.dart`
  (`n(...)` builds a transaction, `january` is a sample month). Add new feature tests as `test/<feature>_test.dart`
  (goals: `test/goal_contrib_test.dart`, quarantine: `test/sync_quarantine_test.dart`, hints: `test/kind_hint_test.dart`,
  own transfers incl. two devices: `test/transfers_test.dart`, budgets per category incl. the setting and two devices:
  `test/budget_vs_actual_test.dart`, recurring bills + weekly review incl. two devices: `test/habits_test.dart`, M5 backup
  round trip incl. two devices + resend: `test/backup_test.dart`, bills (repo API, planned row, auto link, two devices, backup, schema 6 → 7):
  `test/bills_test.dart` (+ `bills_spec_test.dart`; B5a review fixes incl. two devices `bills_b5a_test.dart`; B6
  `bills_b6_test.dart`; helper
  `support/bill_helpers.dart` `confirmWithCategory`), bill files (BlobStore, engine queues, Memory/RelayTransport blob calls):
  `test/blob_store_test.dart` (+ `blob_spec_test.dart`; real relay: `sync_relay_test.dart`), future spending (planned costs, .ics, Upcoming, two
  devices): `test/future_spending_test.dart` (+ `future_spending_spec_test.dart`, `ics_spec_test.dart`; F4a: content refs
  incl. two devices `calendar_ref_test.dart`, parseIcs cost bounds + dismiss title `future_spending_fixes_test.dart`), CSV: `test/export_test.dart`, search: `test/search_test.dart`,
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
  pruning, first connect, S1/S2), `harden_sync_test.dart` (Stage H5–H9 + HBb: relay instance incl. A → B → A, streams on 2,
  3 and 4 devices incl. a double restore with an offline peer, ownership (clone both editing, 409 then the next run,
  database restored from an older file, fresh database with a kept id, H6 id change still acks), clockDrift incl. a
  pair over an hour apart converging, internal writes with the clock behind, `clockAhead` backups, 401 → health
  (older/newer/refused), BWOP2 AAD/BWOP1/inflate cap, field-pair repair on two devices, one run at a time), `sync_relay_test.dart` (`deriveKey` vs. a hand-written HKDF, `RelayTransport` over
  `MockClient` incl. signatures checked from the protocol text, clock offset retry, older/newer API, `MemoryTransport`
  rules, end to end with the real `relay/` server on port 0 incl. a wrong signature and skewed device clocks).
- Run: `tools/build.sh test` from the repo root (or `tools/build.sh shell`, then `cd packages/wallet_core && dart test`).
