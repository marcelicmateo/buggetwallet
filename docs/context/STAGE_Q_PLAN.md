# Stage Q — ideas from Actual Budget + Cashew (approved by the owner 2026-10-27, started 2026-10-27)

## Context
The owner asked us to study Actual Budget and another open-source wallet (Cashew) and take the best ideas, including
technical ones. The research reports stayed in the 2026-10-27 session scratchpad (not in git).

**Owner choices (2026-10-27):**
- **Build:** the items below, the IOU list included (schema 17; all devices update together).
- **Balance check:** automatic, from the bank file.
- **Technical:** split `controller.dart` and `repo.dart`; an old-build test for new record kinds.
- **Extra features:** a recent changes list, subscription cost per month and year, recent merchant autocomplete,
  and a balance forecast to payday.
- **Dropped:** the weekend shift (bills due before payday are already held back, `budget.dart:369-375`; matching
  allows ±3 days), hide amounts, lazy-loading of heavy panels (rerun perf first), and a Croatian UI.
- **After M6 (sync format changes):** the device state digest, a key id on sealed files, and statement ticking.

**Hard rules** for every item:
- Money never changes on amount alone or without the owner's tap; suggestions only suggest.
- No new packages.
- Logs hold counts only (no names, amounts, merchants or people).
- Integer cents; `YYYY-MM-DD` dates.
- Every write goes through `WalletRepo._write`.

## Wave 0 — split the two big files (no behaviour change)
Both already use `part` files (`repo.dart:23-31`, `controller.dart:28-34`); this continues the pattern so the Q code
lands in the right place.
- **`packages/wallet_core/lib/src/repo.dart` (1570 lines):**
  - Split into `repo_import.dart` (`importBatch`, `_reconcile`, `_reconcileLocal`, matching glue),
    `repo_sync_apply.dart` (`_apply`, `_fieldValue`, clocks, outbox), `repo_tx.dart` (transaction CRUD,
    `setCategory`, `setMerchantRule`) and `repo_meta.dart` (open, migrate, `localValue`).
  - `repo.dart` keeps the class, the constructors and `_write`/`_tx`.
- **`app/lib/src/controller.dart` (2158 lines):**
  - Split into `controller_sync.dart` (relay, join, key backup), `controller_import.dart` (`importFiles`,
    `_readImportFile`, CSV layouts), `controller_settings.dart` (theme, number style, nudges, log level),
    `controller_review.dart` (review rows, habits) and `controller_tx.dart` (`addExpense`, `setCategory`,
    delete/undo).
  - `controller.dart` keeps construction, `reload`, `_changed` and the memo cache.
- **Rules:** only `git mv`-style moves. No renames of public API and no logic edits. `layering_test` and all
  tests must stay green unchanged.

## Wave 1/2 items

### Q1. Category suggestions + recent merchant autocomplete when adding a payment
- **Core** (`tags.dart`, next to `suggestTags` :196):
  - `List<String> suggestCategoriesForText(String text, List<CategorizedTx> history, Categorizer c, CategoryTable table, {int limit = 3})`,
    in this order:
    1. `c.merchantCategory(text)`, which applies user and built-in rules.
    2. Live rows whose folded description or note contains the typed word (≥ 3 characters; `foldText` from
       `search.dart:41`), ranked by count and then recency.
    3. Live categories only. It never uses the amount.
  - `List<String> recentPayees(List<CategorizedTx> history, String prefix, {int limit = 5})` returns distinct recent
    merchant names (`merchantName`) and notes that start with or contain the prefix, newest first.
- **App** (`widgets/sheets.dart`, `AddExpenseSheet`, note field around :226):
  - The note field becomes an `Autocomplete` (Flutter SDK) over `recentPayees`.
  - Under it, up to 3 `ChoiceChip`s keyed `suggestCat:<id>`, updated as you type (debounced 250 ms, through
    `wc.suggestCategoriesFor(text)`, cached per data version).
  - A tap sets `cat`; it never changes on its own.

### Q2. Database upgrade tests (test-writer)
- One DDL snapshot per version, `packages/wallet_core/test/fixtures/schema/v8.sql … v17.sql`, rebuilt from
  `git log -p .../schema.dart`. Columns are only added. This extends `_schemaV7` (`test/schema_test.dart:14-60`).
- `test/schema_upgrade_test.dart`, for each snapshot, plain and keyed (as `encrypted_db_test.dart`):
  1. Create the database with raw `sqlite3`.
  2. Insert one synthetic row per table and set `meta.schema = N`.
  3. `WalletRepo.open`. Check that the rows are kept, `meta.schema == schemaVersion`, and the ops replay.
- Guard test: the generated DDL must equal the newest snapshot, so a new column forces a snapshot and a version bump.
- Run `test/fixtures/old_builds/generate.dart` for schema 16 and check it in `h12_old_builds_test.dart`.
- `p16b_attachments_test.dart:329`: change `== 16` to `>= 16`.

### Q3. Overflow guard (core A)
- `isSafeCents(int)` next to `maxAmountCents` (`planned.dart:71`).
- Checked at:
  - `addTransaction` and `importBatch` (rows over the cap are skipped and counted in a new
    `ImportSummary.tooLarge`, with the reason shown);
  - the importer's row normalisation (`limits.dart`: `maxRowAmountMinor`);
  - `repo._fieldValue` for integer amount columns (an op over the cap is quarantined like a wrong-type op).
- A debug `assert(sum.abs() < 1 << 53)` in `budget.dart _sum` (:133) and the folds at 366-382.
- A test shows the worst case stays under 2^53.

### Q4. Import preview (core A + UI X)
- **Core**, read-only, beside `importBatch` (`repo.dart:954`, moved into `repo_import.dart` in wave 0):
  - `ImportPreview previewImport(ImportBatch batch)` returns `rows: List<PreviewRow>`, with `status ∈ {fresh, duplicate, collision, revivable, matchesManual, tooLarge}`,
    plus `matchedManualId` and `transferPair` where they apply.
  - It reuses the same `known` read and `planMatches` (`matching.dart:131`), with the batch rows added as unseen.
- `importBatch(batch, {revive, Set<String> skip = const {}})`.
  - There is no per-row "don't match": matching runs again on every reconcile, so that would need a stored marker,
    which means a schema change. Matches are shown as information.
- **App:** `ImportPreviewSheet` shows "N new · M already here · K match expenses you added · T transfers".
  - Groups expand, each row has **Skip**, and collisions are flagged.
  - **Import** calls `importBatch(skip:)`; **Cancel** writes nothing.
  - `repo.setCsvMapping` moves after the confirm (today it runs before parsing in `_readImportFile`).
  - Settings › Import has an "Always show" switch (local value, default on).

### Q5. Bank balance: known after every import, and a "going into the red" warning (core A + UI X)
The owner needs to know each account's real balance so the app can warn **before** the account goes below zero.
- **Where the balance comes from, in this order:**
  1. **From the file:** Revolut has a `Balance` column.
  2. **PBZ or another file without a balance:** after the import, the result sheet asks "What did the bank app
     show when you downloaded this file?" Prefilled with the app's own computed balance, so a match is one tap on
     **Matches**; otherwise type the number (with the Below zero switch). The question shows the file's newest row
     date and can be skipped. The answer is stored as a check, and "off by" offers Correct balance.
  3. **Worked out:** between checks, the balance = the last anchor (opening or a confirmed check) + the rows since
     (`accountBalances`). That is what the warning uses.
- **Red warning** (uses Q11's forecast per account, not just the total):
  - Today shows "PBZ goes below zero around 28 Oct (rent)" when the forecast for any bank account drops
    under 0 before payday.
  - It shows "PBZ is below zero now" when the worked-out balance is already negative.
  - It shows only for accounts whose balance was confirmed within the last 35 days. Otherwise the line says
    "Check your PBZ balance" and opens the same question. The app never warns from a balance it doesn't trust.
- Details of each source:
- **Importer:**
  - `int? balanceAfter` on `NormalizedTransaction` (`wallet_importer/lib/src/model.dart:33`).
  - Revolut fills it from `Balance` (completed rows).
  - PBZ fills it from an optional `STANJE`/`SALDO` column if the export has one. The profile header today has none
    (`profiles/pbz.dart:35`); check against the owner's real file locally, never committed.
  - Generic CSV: an optional "Balance" role in Map columns (today `csv_generic.dart:545-554` drops it).
  - `ImportBatch.bankBalances`: source + currency → (date, cents), from the last completed row of the newest date,
    in file order.
- **Core** (`accounts.dart`): `BalanceCheck checkBankBalance(Account a, List<Tx> rows, {required String date, required int bankCents})`
  returns `appCents` (the same counting as `accountBalances` :35-76, up to and including `date`), `diff` and
  `rowsSince`.
  - It is stored device-locally with `setLocalValue('bankCheck:<accountId>')`. No schema change.
- **App:**
  - The import line says "matches the bank ✓" or "off by X — see rows since <date>", with a note that payments may
    still be pending at the bank.
  - Settings › Accounts shows the last check. "Off by" opens `CorrectBalanceSheet` (`accounts_panel.dart:385`),
    prefilled. The app never corrects on its own.

### Q6. Rule suggestions (core B + UI Y)
- **Core:** `List<RuleSuggestion> ruleSuggestions(List<Tx> rows, Categorizer c, {int min = 3})` returns
  `(merchantKey, merchantName, category, count)`.
  - It counts live bank rows with an owner-set `tx.category` and no merchant rule.
  - At least `min` of the merchant's last 5 must agree. It never uses the amount.
- **App:**
  - After `setCategory(always: false)`, a toast asks "Always put <merchant> in <category>?" with **Make rule**
    (the existing `always: true` path, with Undo).
  - The Rules panel gets a "Suggested" list with Make rule / Dismiss. Dismissed ones are local
    (`ruleSuggestOff`).

### Q7. Search filters + highlight (core B + UI Y)
- **Core:** `SearchFilter{minCents, maxCents, from, to, categories, hasAttachment, split, uncategorised}`, and
  `searchAll(..., {SearchFilter? filter})`.
  - The filter is a predicate in the existing loop. An empty query with a filter is allowed.
  - Attachment ids come from bills with `isAttachment && !deleted` (`attachedTx`).
- **App** (`screens/search.dart`):
  - A filter chip row; amount and date open small sheets.
  - The matched text is shown in bold.
  - Search also opens from Today's Recent list, which removes that Known limit.

### Q8. IOU list (core C + UI X; schema 17)
- **Entities** in `entitySchema` and `test/support/sim.dart` `entityTables`:
  - `iou{id, person, direction 'lent'|'borrowed', amount, currency, date, note, tx?, closed, deleted}`
  - `iou_part{id, iou_id, amount, date, tx?, deleted}`
- **Old-build test (technical item):** a schema-16 build receives `iou` and `iou_part` ops.
  - Unknown record kinds are skipped without error, and the sync cursor still moves on correctly.
  - After the update, the skipped ops replay and the IOUs appear.
  - Both directions, through `sim.dart` with two devices. If skipping unknown entities turns out not to work, that
    is a bug, fixed in this stage.
- **Repo** (`repo_iou.dart`): add/update/delete/undelete IOU, add/delete part, close, and `ious()` with
  `outstanding = amount − Σ live parts`.
- **Money:** a payment linked by the owner (`iou.tx` / `iou_part.tx`) is neither spending nor income.
  - `computePeriod`, `monthSummary`, insights and reports leave those ids out, like transfers.
  - Unlinked IOUs never change a number.
- **App:**
  - An **Owed** panel on the Save tab under the wishlist ("People owe you X · You owe Y", one line per person,
    **Add**).
  - An IOU sheet with partial repayments, Close, and Delete + Undo.
  - Payment sheet actions: **Lent to someone** on an expense and **Repayment** on income.
  - Linked rows get a "lent" or "repaid" tag.
- Logs: counts only.

### Q9. Recent changes list (core B + UI Y)
- **Core:** `List<ChangeEntry> recentChanges({int limit = 100})` on the repo.
  - It reads the `clocks` table (`schema.dart:230`), grouped by `(entity, id)`, taking the newest HLC per row.
  - Each entry has `(entity, id, fields changed, hlc time, node)`, plus whether the node is this device (`deviceId`)
    or another one, shown with a short id.
  - It joins in a display label per entity: tx description/date, goal name, bill payee, IOU person, setting key
    name.
  - Deletes show as "deleted".
- **App:** Settings › Sync › "Recent changes" lists, newest first: "Today 14:02 · other device · Payment Konzum ·
  category". Tapping a payment opens it. Read-only.
  - It shows only what is on this device and never logs labels.

### Q10. Subscription cost per month and year (core B + UI X)
- **Core** (`recurring.dart`): `({int monthly, int yearly}) recurringCost(List<RecurringBill> bills, {required String currency})`
  over confirmed, live, outgoing bills in that currency.
  - Monthly bills (calendar cycle) count their `expectedAmount` exactly.
  - Day-interval bills use yearly = `expectedAmount × 365 ~/ intervalDays` and monthly = `yearly ~/ 12`, with the
    integer rounding shown in a test.
  - Ranged bills use the midpoint, and the UI says "about".
- **App:** one header line on the Bills tab's Expected bills list: "Bills and subscriptions: X a month · Y a year".
  Display only.

### Q11. Balance forecast to payday (core A + UI X)
- **Core** (`budget.dart` or a new `forecast.dart`):
  `List<({String date, int cents})> forecastToPayday({required int startCents, required String today, required String payday, cycles, planned, incomes})`.
  - It starts from today's total bank balance in the home currency (`accountBalances` / `balanceTotals`).
  - It subtracts each unpaid due bill occurrence (`dueCycles`) and planned cost (`duePlanned`) on its date, and adds
    expected income on its date.
  - It does not guess daily spending; a second line subtracts the daily allowance × days left.
  - Foreign currencies are left out, with the same "not counted" line as today.
- **App:** on the Budget tab under the payday plan, "On payday: about X (after bills, before day-to-day spending)"
  plus a small step chart in `charts.dart`'s style.
  - Only when at least one bank account has a balance; otherwise the line is hidden.

## Delegation (layout before plan; max 4 agents at once)
The Explore results above are the context packs. A haiku/low scout is used only for gaps.

| Wave | Agent | Model/effort | Worktree | Work |
|---|---|---|---|---|
| 0 | core-builder | session/high | `q-split-core` | split `repo.dart` (moves only) |
| 0 | ui-builder | sonnet/high | `q-split-app` | split `controller.dart` (moves only) |
| 0 | reviewer | session/high | – | diff is moves only; then merge, `tools/build.sh test` |
| 1 | core-builder A | session/high | `q-import` | Q3, Q4 core, Q5 importer + core, Q11 core |
| 1 | core-builder B | session/high | `q-suggest` | Q1, Q6, Q7, Q9, Q10 core |
| 1 | core-builder C | session/high | `q-iou` | Q8 schema 17 + repo + money exclusion + old-build entity test |
| 1 | test-writer | sonnet/medium | `q-tests` | Q2 + spec tests for the A/B/C signatures above, from the spec |
| 1→ | reviewer | session/high | – | after each builder |
| 2 | ui-builder X | sonnet/high | `q-ui-money` | Q4 sheet, Q5 lines, Q8 Owed panel + actions, Q10 header, Q11 line + chart |
| 2 | ui-builder Y | sonnet/high | `q-ui-find` | Q1 chips + autocomplete, Q6 toast + Rules list, Q7 filters + highlight, Q9 list |
| 2 | test-writer | sonnet/medium | `q-ui-tests` | widget tests from the spec (keys above) |
| 3 | test-watcher | haiku/low | – | stage run; list failures and `BUG:` skips |

- Wave 1 merges B → A → C, then the tests. At merge the lead adds the v17 snapshot for the Q2 guard test.
- Wave 2 puts its controller code into the wave-0 part files plus new `controller_iou.dart` and
  `controller_suggest.dart`, so X and Y don't collide.

## Time plan (wall clock, agents in parallel; from J1–J4 actuals: a builder about 1.5–2 h, a review + fix round about 1 h)
| When | Wave | What | Done when |
|---|---|---|---|
| Day 1, about 1.5 h | 0 | split `repo.dart` + `controller.dart`, review, merge, full test | same test counts; push |
| Day 1, about 4 h | 1 | core A / B / C + test-writer in parallel, reviews, fixes, merge B → A → C | `tools/build.sh test` green; push |
| Day 2, about 4 h | 2 | UI X + UI Y + widget test-writer, reviews, fixes, merge | test green; screenshots read |
| Day 2, about 1.5 h | 3 | stage run, mutation on the money code, bug fixes, STATUS | stage green; push v2 |
| Then | – | the owner says "start CI" for a new APK/Linux build with Q | `dev` release updated |

- **Total:** about 11 h of work, in 2 days. Bugs the owner reports from the current build come first and push this
  back by however long they take.
- **IOU:** after Q is installed, every device needs that build (schema 17).

## Verification
- **During work:** targeted checks only (`tools/build.sh core|importer|sync|app <test file>`).
- **Per wave:** the lead runs `tools/build.sh test`. Wave 0 must show the same test counts as before (importer 377,
  core 2296, sync 326, app 1822).
- **Per stage:** `tools/build.sh stage` (importer, core, sync, relay, app, desktop, web-test, emulator screens, perf),
  through the haiku watcher.
- **Mutation testing** on the new money code (`accounts.dart`, the forecast, `recurringCost`, the IOU exclusion),
  with tests added for the mutants that survive.
- **Screens:** read `tools/emulator.sh screens` (Save › Owed, import preview, search chips, Budget forecast, Bills
  header, Recent changes) at 320 dp, text scale 2 and dark.
- **Sync:** a two-device IOU test (create, part, delete) plus the schema-16 ↔ 17 old-build replay test.
- **Afterwards:** update STATUS (owner checks; Known limits: search from Today fixed, IOU needs every device updated)
  and push v2. CI runs only when the owner asks.

## Later (after M6, changes the sync format)
- Device state digest with a "devices disagree" repair.
- Key id on sealed files.
- Statement ticking (a per-row cleared mark).
