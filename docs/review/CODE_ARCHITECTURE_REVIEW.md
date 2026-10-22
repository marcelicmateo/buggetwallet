# Budget Wallet — Code Architecture and Extensibility Review

Companion to `docs/SYSTEM_DESIGN_REVIEW.md` (§5, §6) and the UI, parity and security reviews. Written 2026-10-22
against spec §6 and the "Code architecture and extensibility" checklist in §13. Method: the four checklist claims
were tested by doing them (a synced setting and a bank profile were added for real, the package suites were run in
the build container, the edits were reverted), the two large files and the sync engine were read for structure, and
a static sweep (duplication, long functions, naming, error handling, dead code, seams, layering, async) was run over
every Dart file with grep and brace counting. Line numbers are from this snapshot.

## 1. Verdict

**The architecture is right and the surface is untidy.** The things that are hard to retrofit are in place and
enforced by the compiler or by tests, not by convention: two pure-Dart packages with no Flutter dependency, a
web-compile proof that the core barrel is free of `dart:io`, no app import of package internals anywhere, one
private write path that makes sync, snapshots and backups automatic for new entities, synced values type-checked on
the way in, timers and futures tidy, zero TODOs, every catch logging or rethrowing. Measured: a new synced setting
is four lines in one file and the 1,218-test core suite stays green; a new bank profile is one 45-line file and one
registry line and works first time.

What a second contributor will trip over is surface: the `wallet_core` barrel exports around 70 types and 90
functions with `show` on only 3 of 23 exports, so API and internals look the same; the repository and the controller
speak three verb dialects for the same operations; the app repeats itself in small flat ways (seven cents-to-text
formatters, ten ISO-date regexes, eight hand-rolled busy/error panels, three copies of the page-or-dialog chooser);
17 public mutable function fields on the controller serve as test seams; and tests pin behaviour by copy, which is
why adding a bank broke ten unrelated tests. The spec's extensibility claims hold for sync, snapshot, backup and Plan
panels, and overstate two things: search does not pick up a new entity automatically, and the platform-boundary test
already misses one capability.

Checklist answers (spec §13): dependency rule enforced — **yes**, by pubspec and a web compile; bank profile and
synced setting as small as claimed — **yes for the code, no for the tests** (ten copy-coupled assertions); seams
enough without DI — **yes**, but ad hoc (three mechanisms); large files navigable — **repo yes, controller
tolerable, both the wrong shape to keep growing**.

## 2. The extensibility claims, measured

Spec §6 claims a new bank is "small; golden tests prove existing ids unchanged" and a new synced setting is "tiny".
Both were tried for real on 2026-10-22 and reverted; the files are kept in the review scratchpad.

### 2.1 A new synced setting — claim holds

`weeklyLimit` (int, minor units) was added to `WalletSettings`: the field, the constructor default, one line in
`fromMap` with the shared range validator, one line in `toMap`. Four lines in one file (`models.dart`). A test
wrote it through `repo.updateSettings`, read it back, found the op queued in the outbox for sync, and saw a
negative value fall back to the default with the key logged. The core suite ran green: 1,218 tests (1,217 + the new
one). Nothing in sync, snapshot, backup or export needed a touch. **Verdict: as claimed.** The validator helpers
(`i`, `str`, `one`) and the "bad value falls back per key, logged by key only" rule are a good pattern; keep it.

### 2.2 A new bank profile — code as claimed, tests not

`DemoBankProfile` (CSV, header `Date;Text;Amount`) was one new file of 45 lines implementing `detect`, `prepare`,
`mapRow` with `ctx.sourceId` for ids, plus one import and one list entry in `registry.dart`. A new golden test
proved detection, mapping, occurrence suffixes on duplicate rows and that the PBZ and Revolut fixtures still route to
their own profiles. The profile worked first time. **The suite went red: 10 pre-existing tests failed**, none of them
about the new bank:

- 8 tests assert the unknown-layout message by copy: `contains('not a PBZ or Revolut')` in `xls_edge_test.dart`,
  `xlsx_edge_test.dart` and `csv_edge_test.dart`. The message is built from the registry's labels
  (`importer.dart:26`, `bankLabels()`), so adding any bank changes it everywhere.
- 2 tests in `profiles_test.dart` pin the registry to exactly `{'pbz', 'revolut'}` and the exact message string.

Six assertion sites hardcode the copy; only two use the exported `unknownLayoutMessage`. **Verdict: the code
extension point is as small as claimed; the test suite is not ready for it.** Fix: assert on `unknownLayoutMessage`
or on a stable fragment (`'I recognise'`), and make the registry test say "contains pbz and revolut" rather than
"equals". One hour; do it before the next bank.

### 2.3 What the experiments say about the design

The pattern that made 2.1 cheap is the one worth protecting: a single map-shaped carrier (`settings` rows, JSON
values, one op per key) plus a typed reader with per-key validation. The pattern that made 2.2 cheap is the
stateless `BankProfile` with per-file state in `ImportContext` and ids derived in one place. The failure in 2.2 is
not a design failure but a test-hygiene one, and it is the same hygiene gap the app layer has (326 `find.text`
assertions against 139 keys): behaviour pinned by copy instead of by contract.

## 3. Structure of the two large files

### 3.1 `repo.dart` (1,652 lines) — navigable, with one structural wish

One class, nine ruled sections in order: meta, change log (`_apply`, `_write`, `applyRemote`, `snapshotOps`),
matching and pairing, sync bookkeeping, reads, writes, recurring and review, planned costs, bills, bill files. The
longest method is `refreshRecurring` at 85 lines; the write path itself is 15 lines. Every write goes through
`_write`, which is private, and that is the stated reason the class is not split. The reading experience is better
than the line count suggests because the sections match the spec's entities and the doc comments carry the rules
(with stage history that belongs in docs).

Two changes: (a) split by section into `part` files around the one private `_write`, exactly as the controller
already does, so `repo_bills.dart` (360 lines) and `repo_planned.dart` are findable without scrolling; (b) replace
the three hand-kept schema copies (`_entities` map, `_intCols`/`_flagCols`/`_nullable`, `CREATE TABLE` text,
`repo.dart:40-115, 268-315`) with one typed column list from which the DDL, the type check and the snapshot writer are
derived. Version 3 and 4 of the schema history already show the cost of keeping these in step by hand.

### 3.2 `controller.dart` + two `part`s (2,343 lines) — navigable, but the wrong shape to grow

Eight ruled sections, 89 methods, 49 fields; ~30 of the fields are loose UI state (`syncing`, `syncWaiting`,
`syncBlobsWaiting`, `syncDevices`, `syncBadFiles`, `lastImport`, `nudgesDenied`, `cal.*`); 17 `@visibleForTesting`
members, mostly mutable function fields that tests replace (`syncRunner`, `healthCheck`, `keyWriter`, `unlocker`,
`dbOpener`, `pdfParser`, `icsFetcher`, `clipboardWrite`, `billCategorySuggester`). The `part` files reach private
state (`controller_future.dart:478-479` bumps `dataVersion` and clears `_memo`). The design (one `ChangeNotifier`,
derived values memoised per data version and day, pages rebuilt once per version in an `IndexedStack`) is right
for the app's size; the file is what happens when every feature adds a fourth section to the same class.

Change: new features become owned sub-state objects exposed as `Listenable` (`CalendarState` is already the
template), memo keys become typed, and screens receive a per-page view object instead of the controller.

### 3.3 `sync_engine.dart` — one 227-line `run`, deliberately

`run` is the whole sync algorithm in one method with numbered phase comments that match the class doc (state →
upload blobs → upload ops → apply peers → ack → delete blobs → match and snapshot). For an algorithm whose
correctness depends on ordering, one linear method with phase markers is defensible and easier to audit than seven
methods with shared mutable state. Keep it; extract only the per-peer apply loop (phase 2–3, the part with the most
branches) into a method with a precise return type, and add the invariants from the security review as asserts.

## 4. Seams and testability without a DI framework

Core: `WalletRepo.inMemory({now})`, `HlcClock(now:)`, `SyncTransport` with an in-memory implementation that
enforces the relay's rules, `MemoryLogSink`. App: constructor parameters on `WalletController.load` (opener, exists,
setAside, isPlaintext, claim, keyReader, isLocked, clock) and the mutable function fields above. Every widget test
builds a real in-memory repo; there are no mocks of the repository anywhere, which is why the tests are
behavioural rather than brittle.

Verdict: enough for this codebase, and cheaper than Riverpod or `get_it` would be at 12k lines. Two inconsistencies
to fix: `KeyStore` is all-static, so it is injected as function pointers while every other capability is an
instance behind a `default*()`; and the function-field seams are a second public API with no contract (a test can
set `pdfParser` to anything). Group them into one `WalletControllerDeps` record passed to `load`, so the seam set
is one type with one doc comment.

## 5. Boundaries — enforced, with one gap

- `wallet_core` and `wallet_importer` have no Flutter dependency in their pubspecs, so a Flutter import is a
  compile error, not a lint. `dart:io` appears only in the `*_io.dart` halves behind conditional exports, and a
  dart2js + dart2wasm compile of the barrel (`tool/web_smoke.dart`) is the proof. Holds.
- The app imports only the two barrels (no `package:wallet_core/src/...` anywhere). Holds.
- `wallet_core` re-exports four importer types through its own barrel, so the app sees one API. Good.
- `relay` depends on nothing from the app or packages. Holds.
- The gap: `app/test/platform_test.dart` enforces "plugins only in their files" by regex with a hand-kept allowlist
  (`notifier.dart`, `bill_inputs_native.dart`); a new native file must be added to the test by hand or the test
  fails, which is safe but undocumented. Document it in the file header.

## 6. Static sweep findings

### 6.1 Duplication, by payoff

1. **Page-or-dialog chooser, three hand copies plus one generic.** `review.dart:37-48`, `scan_bill.dart:20-31`,
   `upcoming.dart:18-29` are the same 11-line block (width 520/560/600 and the height clamp differ);
   `widgets/sheets.dart:16-65` (`showSheet`) is the fourth variant.
2. **Cents to field text, seven copies.** `_plain(int cents)` at `budgets.dart:27`, `bill_sheet.dart:58`,
   `calendars_panel.dart:36`, `plan.dart:59`, `sheets.dart:308` and `:88`, `planned_sheets.dart:47`;
   `format.dart` has `money`, `moneyExact` and `parseMoney` but no field-text formatter.
3. **ISO-date regex, ten definitions in nine files** (`repo.dart:114`, `backup.dart:15`, `transfers.dart:8`,
   `matching.dart:22`, `planned.dart:121`, `ics.dart:182`, `bills.dart:221`, `models.dart:528`, importer
   `bills/common.dart:53`) plus the same `ArgumentError` guard three times; `dates.dart` has `isoDate` and
   `parseIso` but no `isIsoDate`.
4. **Amount text-field scaffolding**: `keyboardType: numberWithOptions(decimal: true)` ten times in six files, and
   four different validation sentences for the same rule (`sheets.dart:185`, `planned_sheets.dart:65`,
   `plan.dart:304`, `budgets.dart:104`).
5. **Hand-rolled busy/error state in eight screens** (`_busy`, `_error`, `toast`, the same try/catch/finally shape:
   backup, calendars, unlock, forget-browser, scan, bills, export, planned sheets).
6. **Full-screen dialog app bar** (close icon + 2 px rule) in five places (`main.dart:393`,
   `bill_sheet.dart:557`, `review.dart:101`, `upcoming.dart:115`, `scan_bill.dart:121`).
7. **Touch-target sizes as literals**: `minHeight: 48` eight times, `44` seven times, `Size.fromHeight(52)` eight
   times; none named in `layout.dart`.
8. **Ruled list row re-inlined** in four screens while `common.dart:334-349` already has it.
9. **Refusal copy owned by two layers**: the same sentence in a platform file and in the screen or controller
   (`bill_inputs_native.dart` and `scan_bill.dart`; `ics_fetch_io.dart` and `controller_future.dart`).
10. **Gate-page scaffold** (heading, 480 dp box, 52 dp button) in `in_use.dart`, `onboarding.dart`, `unlock.dart`.

### 6.2 Long functions and deep nesting

| Function | Lines | Note |
|---|---|---|
| `SyncEngine.run` (`sync_engine.dart:296-523`) | 228 | Numbered phases; a 60-line local closure; defensible, see 3.3 |
| `_BillSheetState._body` (`bill_sheet.dart:220-443`) | 224 | One widget tree; split into sections |
| `buildTheme` (`theme.dart:156-375`) | 220 | Configuration; acceptable |
| `TodayScreen.build` (`today.dart:53-258`) | 206 | Also filters `wc.txs` in build at `:78` |
| `SearchScreen.build`, `PlanScreen.build`, `BillsPanel.build` | 147, 141, 113 | Widget trees that want sub-widgets |
| `Wallet.load` (relay `wallet.dart:173-277`) | 105 | Restart reconciliation; nesting 4 |
| `_Pdf._run` (`pdf_text.dart:733-832`) | 100 | Nesting 5, the deepest in the repo |

`pdf_text.dart` is 1,095 lines with twelve private classes in one file; it is a parser and should be a folder of its
own (`lexer`, `objects`, `cmap`, `fonts`, `content`), with its fuzz corpus beside it. Deep nesting (five brace
levels) otherwise only in `controller_future.dart:418-482` (`readCalendars`: try inside for inside try inside if).

### 6.3 Naming and API surface

- **Barrel leaks.** `wallet_core.dart` uses `show` on 3 of 23 exports. Public with no references outside their own
  file: `TransferPlan`, `RecurringPayments`, `withinBand`, `levelName`, `logPerf`, `billPayeeWords`, `hexOf`,
  `normalizeForLink`, `euroText`; `BillReminder` and `billReminders` (`bills.dart:421`) have **no callers anywhere**
  including tests (the app test's `nudges.billReminders` is a different member on a fake). Also leaked: `Kind`
  (next to `TxKind`, `UpcomingKind`, the app's `BillImportKind`), `Verdict`, `Affordability`, `SeenBank`, `BadFiles`,
  `FrameStats`, `formatLogRecord`. The importer barrel exports `formatCents` and `fnv1a36`, id-hash internals.
- **Verb drift in `WalletRepo`**: `addManual` (adds a transaction; the noun is missing), `saveGoal` (an upsert)
  beside split `addPlanned`/`updatePlanned` and `importBill`/`updateBill`; `putCachedBlob`/`cachedBlob`/`uncacheBlob`
  beside `blobUploaded`/`blobDeleteDone`; `markExported`/`markReviewDone`/`markPlannedPaid` beside
  `confirmBill`/`decideWish`/`linkBill`; `updateSettings(Map)` untyped while reads return `WalletSettings`.
- **The controller renames the repo**: `editBill`→`updateBill`, `editPlannedCost`→`updatePlanned`,
  `addExpense`→`addManual`, `deleteTx`→`deleteTransaction`, `billById`→`bill`. Three spellings of one concept
  (`planned`/`plannedCost`/`PlannedCost`; `bill`/`billsDb`/`BillsDb`). 117 public methods and 25 getters; `save*`,
  `set*` and `updateSettings` all write settings.
- **Three conventions for nine platform splits**: `_io`/`_web` (six), `_native`/`_web` (two), and `notifier.dart`
  with no suffix; barrels named after the capability or `*_platform.dart` with the interface in a differently named
  file.

### 6.4 Error handling

Disciplined overall: 128 catch sites, 105 with `(e, st)` and `logError`. Findings: `scan_bill.dart:90` and
`controller_future.dart:283` swallow without a log; the importer's readers return null by design but never say why
(`pdf_text.dart:64, 74, 519, 590, 625`, `codes.dart:32`, `text_bill.dart:28`, `einvoice.dart:29`), which makes a
"could not read" report undiagnosable from the device log; `Op.fromJson` (`repo.dart:27-28`) is a bare cast wrapped
by the engine so one malformed op quarantines the whole file (correct, coarse); `controller_future.dart:276`
`CalendarKind.values.byName` throws on an unknown kind in local JSON from a newer build and sits outside the try;
`controller.dart:1098` runs raw SQL from the app (`SELECT count(*), max(hlc) FROM clocks`), the one layering leak in
an error path. Null-assertion density is highest in `ics.dart` and `bills.dart` (21 each).

### 6.5 Dead code, TODOs, stage comments

TODO/FIXME/HACK: none. `// ignore:` directives: one, justified. Stage and decision tags in code comments: 33 sites
(`B5a`, `B6` nine times, `M5`, `F3`, `D3`); the rules they mark matter, the tags mean nothing to a newcomer. Dead:
`BillReminder`/`billReminders`. Needlessly public on the app side: `LeftBarBorder`, `TopRuleBorder`, `ImportLine`,
`SpendingView`, `BillFile`, `BillLists`, `CalendarEntry`, `pickAndImportBills`, `billFileLabel`, `PeriodGrid`, relay
`formatTime`.

### 6.6 Extensibility traces beyond the two experiments

- **A synced entity**: seven to nine files, five touch points in `repo.dart` alone (`_entities`, `_schema`,
  `schemaVersion` and migration, `_intCols`/`_nullable`, read and write methods), the model class, and then
  `search.dart` (`searchAll` takes one named list per entity and `SearchResult` has one field per entity: **search is
  not automatic**, contrary to §6), `export.dart` if exported, the logs privacy allowlist if new field names are
  logged, and on the app side a controller getter plus memo key, a screen, a search section and a sheet. Sync,
  snapshot and backup are automatic as claimed.
- **A platform capability**: interface, `_io`/`_web` pair, barrel, controller field, and two edits to
  `app/test/platform_test.dart` (the native regex and a hard-coded exclusion list). The regex omits
  `device_calendar_plus` and `calendar_source_native.dart`, so the calendar capability is unguarded today; and "only
  one file per capability imports the plugin" does not hold for `path_provider` (five files) or `file_picker`
  (five files).
- **A Plan section**: one line in `plan.dart:236-278`, a panel file, a controller getter, a widget test. The
  best-factored extension point in the app.

### 6.7 Layering

No app import of package internals, no package import of Flutter or the app, relay depends only on
`cryptography`. Money arithmetic in the app is limited to formatting and parsing (`format.dart:46-57, 87-92`; the
rounding rule in `parseMoney` duplicates core's `amountFromText`), the seven `_plain` copies, and one percentage of
a hard-coded 1,500-cent "typical order" computed inside a string in `today.dart:233`. Rule 5 ("no computing from
raw rows in build") has two minor exceptions (`today.dart:78`, `bill_sheet.dart:261`). The `_cached` memo is
string-keyed with an `as T` cast and prefix keys like `'search$query'` can collide with any future key starting with
`search`. Core formats money text in one place for ICS descriptions (`ics.dart:532`).

### 6.8 Concurrency and async

Clean. Fourteen `unawaited(` calls, all deliberate; all five controller timers cancelled on lock and dispose;
search debounce cancelled; 80 `mounted` guards for 126 `setState` calls. Two things to verify rather than bugs:
`controller_future.dart:240` uses a promise chain as a serial queue (`headsUpChain = headsUpChain.then(...)`), which
stays rejected forever if one link throws unless each link catches; `RelayTransport.clockOffsetMs`
(`sync_relay.dart:42`) is shared mutable state across runs, serialised today only by the controller's `syncing` flag.

## 7. Refactor plan, in order

| # | Refactor | Effort | Risk |
|---|---|---|---|
| 1 | Test hygiene: assert `unknownLayoutMessage` or a stable fragment, registry test says "contains" (the ten tests the bank experiment broke); add `device_calendar_plus` and `calendar_source_native.dart` to `platform_test.dart` | 1–2 h | low |
| 2 | `isIsoDate()` in `dates.dart`; delete ten regex copies and three `ArgumentError` copies | 1 h | trivial |
| 3 | `openPageOrDialog(context, screen, {width, maxHeight})` in `widgets/sheets.dart`; one `DialogAppBar`; named 44/48/52 constants in `layout.dart` | 2–3 h | low (the 320/360/1280 sweeps protect it) |
| 4 | Barrel hygiene: `show` lists on every `wallet_core` export, in-file helpers private, delete `BillReminder`/`billReminders`, drop `formatCents`/`fnv1a36` from the importer barrel, rename `Kind` to `BudgetKind` | ½ day | low (the compiler finds every site) |
| 5 | `MoneyField` widget plus `centsToFieldText` in `format.dart` with one validation sentence; move the `parseMoney` rounding rule to core beside `amountFromText` | 1 day | low–medium |
| 6 | One verb vocabulary: `addManual`→`addTransaction`, controller `edit*`→`update*`, `addPlannedCost`→`addPlanned`, `billById`→`bill`, one blob scheme; one platform-split suffix (`_io`/`_web`), `notifier.dart`→`nudge_platform_io.dart`; replace the 33 stage tags with doc links | ½ day | low, mechanical |
| 7 | Typed entity schema in `repo.dart` (one column list generating DDL, type check, snapshot, and a `searchable` flag so search becomes automatic); split `repo.dart` into `part` files per section around the private `_write` | 1–2 days | medium (schema history tests exist) |
| 8 | `AsyncAction` mixin for the eight busy/error panels; `repo.clockStats()` behind the one raw SQL in the controller | 1 day | medium (toast ordering) |
| 9 | `WalletControllerDeps` (sync, backup, key, db, clipboard, ics, pdf) replacing the 17 mutable closures and four module globals; controller sub-state objects and per-page view objects; then extract the per-peer apply loop from `SyncEngine.run` with a precise return type | 2–3 days | medium–high; last, after 1–8 shrank the surface |
| 10 | `pdf_text.dart` into its own folder with its fuzz corpus; `bill_sheet.dart` into sections | 1 day | low |

Items 1 to 6 are about two days of low-risk work and would make the remaining real complexity (the sync engine, the
PDF parser, the controller) the only places a new person has to be careful.

## 8. What to keep no matter what

The package boundaries and the web-compile proof; the one private write path and the entity map that make sync,
snapshot and backup automatic; per-key validated settings with "bad value falls back, logged by key only"; the
stateless `BankProfile` with `ImportContext`; real in-memory repositories in every test instead of mocks; the
in-memory relay transport that enforces the relay's rules; the numbered-phase structure of the sync algorithm;
strict analyzer with infos fatal; zero TODOs and a catch discipline most codebases never reach.
