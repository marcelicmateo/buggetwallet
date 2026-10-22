# Budget Wallet — Independent System Design Review

Reviewed: branch `v2` review snapshot as of 2026-10-22 (380 commits, 2026-10-16 to 2026-10-22). Starting point:
`docs/TECHNICAL_SPEC.md`, checklists in §13. Method: the spec was read in full; the code was read directly for the
write path, schema, vault, sync engine, relay, controller, main screens, importer, tooling and tests; three parallel
deep dives (app/UI, sync/crypto/relay, importer/domain/quality) fed this document, and every finding marked [bug]
was re-verified against the source by the author of this file. All paths are relative to the repository root.

Companions: `docs/UI_UX_DESIGN_REVIEW.md` (designer's pass with frames from the running app), `docs/FEATURE_PARITY_REVIEW.md` (fintech product pass against the 2026 peer set) `docs/SECURITY_REVIEW.md` (ranked security findings), `docs/CODE_ARCHITECTURE_REVIEW.md` (extensibility claims tested by doing them, structure, refactor plan) and `docs/SYSTEM_ARCHITECTURE_REVIEW.md` (protocol conformance, versions, conflict semantics, pruning proof, capacity, failure matrix, decision records).

How to read: every design choice carries a verdict, **KEEP** or **CHANGE**, a reason, and where useful a product
that chose differently. Severity tags: [bug] wrong today; [risk] will go wrong under a realistic condition;
[change] better design available at low cost; [keep] a decision worth defending. Section 1 is the summary and the
action list; sections 2 to 9 follow the spec's structure and answer its §13 checklists; section 10 is how I would
build it from zero; section 11 is the recommendation.

## 1. Executive summary

**Verdict: continue on this codebase. Do not restart, and do not adopt a different sync or state approach.** The
decisions that are expensive to change later are right and already in place: offline-first with a dumb E2E relay,
one write path feeding a field-level change log with hybrid logical clocks, pure-Dart core with money logic kept
out of the app, integer cents and UTC date strings, "suggest, the owner confirms" as a product rule, and a
ledger design system enforced by contrast and overflow tests. The replication kernel is correct in the code read and
is backed by randomised multi-device convergence tests; the relay cannot read or forge anything.

What is wrong is at the edges, and almost all of it is cheap: two money bugs the owner will hit in the first month
(foreign-currency rows counted as euros; the past-payday state), one data-loss bug under concurrency (category
budgets stored as a single map), three identity gaps in sync (no relay identity, device id inside the database, an
unbounded clock), missing crypto and storage hygiene (no associated data, cipher not pinned, Android backup and
cleartext defaults, debug-key fallback), two relay denial-of-service holes, and a product mismatch (calendar-month
budgets on payday periods). The process that built this in six days is impressive and has one blind spot: nothing
has run on a real phone and no human has used it for a pay period.

### 1.1 Scorecard by discipline (spec §13)

| Discipline | Verdict | Biggest keep | Biggest change |
|---|---|---|---|
| System design | Sound | Offline-first, dumb relay, one write path | Relay identity + device id per install; blob invariants |
| UI/UX | Sound, two structural changes | "Owner confirms" language; Ledger tokens; 320 dp × 2.0 tests | Plan as index + sub-pages; Bills gets a tab; add action everywhere |
| System architecture | Sound kernel, edge bugs | Per-field LWW + delta rows + ack-gated pruning | Per-key settings; bounded HLC; AAD on sealed files |
| Feature parity | Fair table, real gaps | Payday safe-to-spend + bills with documents | Custom categories; currency filter; splits; reports screen |
| Code architecture | Sound, accumulating | Package boundaries enforced by tests; pure core | Controller sub-states and view objects; typed schema; type tokens |
| Security | Narrow goal met, hygiene missing | XChaCha20 + HKDF + Ed25519 with independent test vectors | allowBackup, network security config, FLAG_SECURE, cipher pin, creation token |
| Quality/process | Above norm, over-tooled | Spec tests from API docs; convergence fuzz; log privacy | CI on push for packages; trim 3k lines of tooling; real-device stage |

### 1.2 Action list

**Before the owner's live test (M6), each under a day:**

1. [bug] Count only rows in the wallet currency in `computePeriod`, `monthSummary`, `periodSummaries`; show the rest
   as "foreign, not counted" (`budget.dart:115-133`, `periods.dart:98-110`).
2. [bug] Add an explicit "payday passed" state instead of `daysLeft.clamp(1, …)` pouring the remaining flex into
   today (`budget.dart:114`, `today.dart:128`).
3. [bug] One settings row per category budget and per merchant pattern (`controller.dart:590-591`,
   `models.dart:380-382`).
4. [bug] `allowBackup="false"` or `dataExtractionRules` excluding the database; fail the release build without a
   keystore (`AndroidManifest.xml:15-19`, `build.gradle.kts:62`).
5. [risk] Require the full PBZ header row in `PbzProfile.detect` so another bank's export fails instead of importing
   empty (`pbz.dart:36`).
6. [risk] Relay id in `GET state`, stored with the upload marker; treat a change as first connect
   (`sync_engine.dart:578-580`).
7. [risk] Treat a 409 on an own sequence as "another install uses this device id" and move the device id out of the
   database (`sync_engine.dart:610-615`, `repo.dart:128-136`).
8. [change] Bound the HLC: quarantine files more than an hour ahead, refuse local writes behind the stored clock
   (`hlc.dart:57-71`).
9. [change] AAD on `seal` and a `BWOP2` magic; pin the SQLite cipher with `PRAGMA cipher` (`vault.dart:215`,
   `local_db.dart:269`).
10. [risk] Creation token or wallet allow-list on the relay; `--trust-proxy` for the rate limiter
    (`relay_server.dart:446-518, 206-211`).

**Next stage (product):**

11. Align category budgets to the pay period or label the difference (`budget.dart:301-347`).
12. Custom categories; recurring detection with period classes and amount ranges (`recurring.dart:323-329`).
13. Plan → payday plan + a Settings index with sub-pages; Bills as a tab; persistent add action.
14. "Merge from backup" on the existing `applyRemote(resend: true)` path; blobs in backups or a loud note.
15. Decimal style setting for display (`format.dart:33-54`); tests keyed on `ValueKey`s before any localisation.
16. Make the matching auto-link a confirmation, or amend spec rules 2 and 3 to name it as the exception.

**Hygiene (any time):**

17. CI on every push for lint and package tests; pub `workspace:`; trim the timing and history tooling.
18. Typed entity schema generating `CREATE TABLE`, validators and snapshot; generalise column migration.
19. Controller sub-state objects and per-page view objects; split `bill_sheet.dart`; type tokens in `theme.dart`.
20. Test additions: memory-vs-real relay equivalence, the sync scenario gaps, old-build DB fixtures,
    `meetsGuideline` accessibility checks, mutation testing on pure packages, fail (not skip) on missing fonts.

### 1.3 Spec §13 checklist answers in one place

| Checklist item | Answer |
|---|---|
| Every feature usable with the relay down? | Yes, except evicted bill documents (relay-only) and web sync (none). State both. |
| §4 failure behaviour matches `sync_*_test.dart`? | Yes for relay down, wiped, damaged file, stuck device. Not covered: relay switched A→B→A, cloned device id. |
| Single-owner assumption explicit where it matters? | Yes; it is load-bearing for trust, LWW without authorship and one public key per wallet. |
| Daily flow two taps, weekly review five minutes? | Two taps plus typing from Today; three from any other tab. Review: plausible, untested by a human. |
| Ledger tokens and contrast at scale 2.0? | Colour holds (tested). Type ramp is 87 inline literals, not tokens. |
| "Owner confirms" visible wherever a number is guessed? | Yes, uniformly; one exception: matching auto-links hand-added expenses without a tap. |
| Plan's long scroll and web "no sync" acceptable? | Plan: no, split it. Web: acceptable if parked or given sync; today it is a third storage stack for localhost. |
| HKDF labels, file format, signed text match the protocol doc? | Yes, with known-answer tests and an independent signer. |
| LWW per field right for every entity? | No: map-valued settings lose concurrent edits; pairwise bill links lack repair. |
| Snapshot and pruning cannot lose an op? | Holds for an honest relay. |
| §8 table fair? | Broadly; three generous cells (rules "never amount-based", single currency, YNAB encryption). |
| Gaps acceptable for the intended user? | Bank connection and Android-only: yes. Single currency: no, because foreign rows corrupt the number today. |
| Package dependency rule enforced? | Yes, by regex tests over source; one `file_picker` type leak into four screens. |
| Adding a bank profile and a synced setting as small as claimed? | Yes for both; column migration is generalised only for `tx`. |
| Constructor seams enough without DI? | Yes at this size; the controller's test surface is the cost. |
| Large `repo.dart` and `controller.dart` navigable? | Repo yes (outline is clear); controller is a 2,343-line god object with parts mutating privates. |
| Threat model covers the deployment? | Yes, minus: no relay identity, clone of device id, unauthenticated creation, proxy-collapsed rate limit. |
| Nonce reuse impossible? | Yes (192-bit random nonce per seal). |
| TOFU and 24 h offset acceptable? | TOFU yes with a creation token; the 24 h cap covers only signatures, the HLC is unbounded. |
| Desktop key, clipboard, Android backup tracked? | Tracked; Android backup is a bug, not a limit; add FLAG_SECURE and the umask window. |
| Parsers safe on hostile input? | Yes for PDF, XML, ICS, XLS; `.xlsx` inflates fully before the cell cap. |
| Log privacy tests cover every event? | Per package yes; integration harness also scans the app log. |

## 2. System design (spec §4, checklist §13 "System design")

### 2.1 Offline-first with a dumb relay — KEEP

Each device holds the complete wallet in an encrypted SQLite file; the relay stores only sealed per-device op
files, snapshots and blobs; the app works for weeks without the network. For a single-owner, several-devices
product this is the right shape, and it is the shape the best-regarded privacy apps converged on:

| Product | Model | Server knows |
|---|---|---|
| Budget Wallet | per-device append-only op log, dumb relay, E2E sealed | wallet id, device ids, seqs, sizes |
| Actual Budget | per-client CRDT messages, sync server (optionally E2E), merkle-trie catch-up | account, budget ids, (ciphertext if E2E) |
| Obsidian Sync / Standard Notes | E2E item store, server coordinates versions | item ids, sizes, timestamps |
| Firefly III / YNAB | server is the source of truth | everything |
| Syncthing | peer-to-peer block sync, no server | nothing (relays see ciphertext) |

The project sits where Actual Budget with E2E would sit, but with a protocol small enough (146-line spec, ~1,200-line
server) that one person can hold it in their head. That is a real advantage over adopting a general-purpose sync
backend (PowerSync, ElectricSQL, Supabase) that would put a server with schema knowledge in the loop and break the
"nothing but ciphertext leaves the device" promise.

Checklist: "can every feature be used with the relay down?" Almost. Two exceptions worth stating in the spec:
- Bill documents are a content-addressed blob cache with LRU eviction (`BlobStore.maxCacheBytes`, `repo.evictBlobs`).
  A bill whose photo/PDF was evicted locally cannot be opened while the relay is down. Acceptable, but it is the one
  place where the device is not self-sufficient; the spec should say so and the bill sheet should say "stored on your
  relay" rather than fail silently.
- Web has no sync at all. It is a full *client* but not a full *device*; the spec is honest about this.

### 2.2 One write path (`WalletRepo._write`) feeding a field-level change log — KEEP (the best decision in the codebase)

`_write` applies the op locally through the same `_apply` used for remote ops, records a clock per field and queues
the op in the outbox, all inside one SQLite transaction (`repo.dart:316-350`). Consequences that make the rest cheap:
sync, snapshot, backup and restore are all "replay ops"; a new entity is one row in the `_entities` map plus a
`CREATE TABLE`. This is exactly the structure Actual Budget uses (`crdt/messages`, `applyMessages`), and it is the
reason that project could add features for years without touching sync.

Two things I would change:
- The entity map (`repo.dart:40-70`), the `_intCols` / `_flagCols` / `_nullable` sets (`repo.dart:268-315`) and the
  `CREATE TABLE` text are three hand-kept copies of the same schema. One typed entity definition (column name, type,
  nullable) that generates all three would remove a class of "added the column in two of three places" bugs that the
  spec's own schema history already shows (versions 3 and 4 replay fields an older build dropped).
- `_apply` runs one `SELECT` per field per op against `clocks` (`repo.dart:250`). Fine at 20,000 rows; at a
  100,000-op replay from an empty device this is the hot path. A `(entity, id) → {field: hlc}` lookup per op, or a
  single `SELECT ... WHERE entity=? AND id=?`, halves the work for free.

### 2.3 Derived values computed at read, never persisted — KEEP, with a caveat

Safe-to-spend, budgets, upcoming, suggestions are pure functions over rows, cached per `dataVersion` in the
controller. Rule changes and syncs show on the next reload with no migration of derived data. YNAB and Actual persist
category balances and need repair tools; this design does not. Caveat: the controller is the only cache, and it is a
"recompute everything on any change" cache (`dataVersion++` on every reload). At 20,000 rows the perf test says it
is fine; at 10 years of two accounts it will still be fine. Do not add incremental caching until a measurement says so.

### 2.4 Deterministic ids for convergence — KEEP, but document the collision domains

`rec:<payee>`, `calendar:<ref>`, `bill:<hash of externalId>`, tx = `yymmdd + hash(date|amount|description) + occurrence`.
Two devices that detect/import the same thing produce the same row without coordination. This is the right tool
(same as Actual's deterministic schedule ids and Syncthing's content hashes). The risk is in the inputs: a bank
changing description formatting between exports changes every id and re-import duplicates history. The importer's
golden tests pin today's ids, but there is no "second export of the same month from a newer bank template" fixture.
Add one per bank; it is the most likely real-world failure of the import path.

### 2.5 Single-owner, many-devices assumption — explicit, and load-bearing

The whole trust model (one key, HKDF children, no per-op identity), LWW-per-field without authorship, and the
relay's one public key per wallet all depend on "every device is the owner". The spec states this and lists the
shared-household wallet as "the largest change" (§12). Agreed. If a household feature ever becomes a requirement,
the honest answer is a second wallet per person plus a shared one, not multi-user inside one wallet.

### 2.6 Where the system design is weaker than it looks

1. **The relay is a single point of metadata and availability, with no TLS by default.** The spec mitigates with
   "use a VPN". Tailscale makes that reasonable for one owner, but a self-hosted product should ship TLS out of the box
   (a Caddy sidecar in the quadlet, or `tailscale serve` in setup.md as the default path, not a footnote).
2. **No relay identity in the protocol.** Seq numbers alone drive cursors; a wiped-and-reused relay can make a device
   skip files (§11 "Sync" limit). A random relay-instance id returned by `GET state` and stored per device would turn
   that silent skip into a detected reset. Cheap, and it removes a documented data-loss path.
3. **Bill blobs are outside the op log.** They have their own outbox, delete queue, own-set and cache tables
   (`blob_*`). That is a second, smaller replication system with its own failure modes (orphans, "files waiting").
   It was probably the right call to keep 16 MiB files out of op files, but it doubles the sync surface a maintainer
   has to reason about. Alternative used by Ente and Obsidian: treat attachments as sealed objects referenced by hash
   from the op log, uploaded before the op that references them is *acked*, never deleted by the client (server-side
   GC from reachable hashes). Simpler invariants than the current four tables.
4. **Web is a third platform with its own storage stack** (sqlite3 WASM on IndexedDB, PBKDF2-wrapped key, no sync,
   one-tab lock). It costs real complexity for a "localhost only" use case. If the owner does not use it daily,
   park it like iOS; if they do, give it sync (the relay client is pure Dart and already compiles to wasm).

## 3. Product and money model (spec §2, §3, §8)

### 3.1 Payday-period safe-to-spend as the primary number — KEEP

`computePeriod` (`budget.dart:109-182`) is a pure function and reads exactly as the spec's formula: flex = income −
fixed − goals − reserved bills − reserved planned; allowance today = (flex − spent before today) / days left; safe
today = allowance − spent today. That is the "Daily Budget Original" / Pennies model (remaining ÷ days left, unspent
rolls forward) placed on a payday period instead of a calendar month, with reserved future costs subtracted. YNAB and
Actual show category balances and leave the per-day arithmetic to the user; Firefly III has no daily number at all.
For one household on a fixed salary day this is the right primary number and the project's strongest product idea.

### 3.2 Two bugs a first month of real use will hit — verified in code

1. **Non-EUR rows are summed at face value.** No money path filters on currency: `grep currency` over `budget.dart`,
   `periods.dart` and `categories.dart` finds no filter, while the Revolut profile stores the row currency
   (`revolut.dart:62-72`). Exchanges between own balances are correctly treated as transfers, but a card payment from
   a USD or GBP balance lands in safe-to-spend as if it were euros. Fix now: count only `currency == settings.currency`
   and show the rest as "foreign, not counted"; convert later if multi-currency ever lands.
2. **Payday passed, salary not yet imported.** `daysLeft = daysBetween(today, end).clamp(1, 1000)`
   (`budget.dart:114`). From day one after the expected payday the whole remaining flex becomes today's allowance and
   Today prints "1 day to <past date>" (`today.dart:128`) until a salary row exists, because the "Salary landed" card
   is gated on one (`controller.dart:515`). Imports are weekly, so this state is routinely visible for days. Needs an
   explicit "payday passed: import or start the new month" state.

### 3.3 Design choices in the money model

- **Integer cents, UTC-only `YYYY-MM-DD` strings compared lexically** (`dates.dart:172-182`): KEEP. DST and time
  zones cannot move a transaction between days. Same choice as Actual Budget.
- **Calendar-month budgets on payday-period everything else**: CHANGE. `budgetVsActual` (`budget.dart:301-347`)
  paces by day of month while safe-to-spend, reserves, goals and the payday checklist run payday to payday. With a
  payday on the 15th, "Groceries 300 €" splits across two periods and Today and Spending disagree about "behind
  pace". Either align budgets to the period (`periodSummaries` already has per-category sums) or label the
  difference in the UI. YNAB and Actual are consistently calendar-month; this app is consistently payday except here.
- **Matching of hand-added expenses to bank rows** (`matching.dart:133-184`): equal amount, ± 3 days, and the
  adding device had not seen the bank row (`SeenBank`, encoded per node in HLC). Ingenious, deterministic and well
  tested (`matching_test.dart:97-247`), but it *is* amount-based evidence and it writes `matched_to` without a tap,
  which strains spec rules 2 ("never on amount alone") and 3 ("owner confirms"). Actual Budget does the same window
  match but presents it as a reconciliation suggestion. Either amend the rules to name this exception or make the
  link a one-tap confirmation. The transfer pairing (`transfers.dart:215, 287`) honours the rule: a hint is required.
- **Recurring detection** (`recurring.dart:323-329`): 3+ payments, every gap 30 ± 3 days, all within 10 % of the
  median, seven-month window. That excludes quarterly and annual bills (insurance, registration), weekly ones and any
  utility that swings more than 10 %. Firefly III bills carry an amount range plus a frequency from weekly to yearly;
  Actual schedules have ± N days and approximate amounts. CHANGE: period classes plus a range.
- **Negative flex and affordability** (`budget.dart:408-414`): with `planDaily ≤ 0` every wish is "affordable now".
  Guard.
- **Income in parts**: `incomeMode == 'received'` follows the first part of a split salary until the second lands;
  `_samePaydayDays = 20` (`periods.dart:29`) groups only for period detection, not for income.
- **Categories are a hard-coded list of 20** (`categories.dart:11-32`) with Croatian merchant regexes compiled into
  production code (`:52-69`). No custom categories. Every competitor in §8 allows them; this is the parity gap a
  daily user hits first, before multi-currency.

### 3.4 Feature parity (spec §8) — mostly fair, three cells generous

The table is honest about the big gaps (no bank connection, single currency, Android only on mobile). Three cells
read generously: "Rules: never amount-based" (see matching above); "Multi-currency: single currency" undersells the
bug in 3.2; YNAB's "n/a" for local encryption is fair only as "cloud". Missing for a daily driver, roughly in order
of pain: custom categories; split transactions (one supermarket row = groceries + household); currency handling;
reports beyond Spending (the net-per-month and trend data exist in `periodSummaries`/`trendNet`, there is no
screen); account balances and reconciliation (no account entity by design, `repo.dart:754`); recurring income beyond
one salary; loan amortisation (`loanEnd` is a `YYYY-MM` string, nothing computed, `models.dart:370`); attachments on
transactions, not only bills; undo on delete; home-screen widgets. Where it is genuinely ahead and no competitor
matches: payday-period safe-to-spend with reserved future costs and the owner-confirms rule, HUB-3 and fiscal-QR bill
ingestion with line items and sealed storage, and a relay that holds only ciphertext including the documents.

## 4. Import pipeline and parsers (spec §6 extension points)

### 4.1 Hand-written readers — KEEP, because the constraint makes them the only option

`wallet_importer` must stay Flutter-free and compile to wasm. No maintained pure-Dart `.xls` reader exists (`excel`
and `spreadsheet_decoder` read `.xlsx`/`.ods` only), and `syncfusion_flutter_pdf`, `pdfrx`/PDFium and platform PDFKit
are Flutter or native. The 345-line BIFF8 reader handles OLE2 FAT/mini-FAT with loop guards
(`xls_reader.dart:102-140`), SST `CONTINUE` records including the option-byte restart (`:223-265`), and a 2M-cell
sparse cap (`grid.dart:3-31`), with real edge tests (`xls_edge_test.dart:59-142, 281, 321`). The 1,095-line PDF text
extractor has hard caps (20 MB, 5M ops, 64 MB inflated, 2M chars, `pdf_text.dart:25-34`), a never-throw shell
(`:38-91`), page-tree cycle guards (`:634-640`) and bounded XObject recursion (`:815-820`). Its heuristics are crude
(new line when |Δy| > 1, no x-ordering, no Type0 without ToUnicode) but adequate for generator PDFs. LibreOffice and
SheetJS take the same approach; Apache POI is the heavy alternative. The hand-written RRULE subset in `ics.dart`
(619 lines, step budgets `:63-73`, 29 spec tests) beats pulling in `package:rrule` with its `time_machine` dependency.

Gaps: no `FILEPASS` detection (a password-protected `.xls` reads as "damaged"); `importBankFile` has no byte cap
(`importer.dart:34`) and `XlsxReader` inflates `sharedStrings.xml` and `sheet1.xml` fully before the cell cap applies
(`xlsx_reader.dart:19-45`), so a zip-bomb `.xlsx` is bounded only by whatever the app caps on pick; the PDF path has
no corpus of real bills beyond four synthetic fixtures and no test for right-aligned amount columns, which is where
labelled-total extraction fails. Fuzzing is real: 200 + 300 mutated fixtures per run (`bills_test.dart:294, 368`)
and `importer_fuzz_test.dart` running in isolates with timeouts and log-leak checks.

### 4.2 Deterministic ids — KEEP the scheme, add a collision guard, fix one detector

`yymmdd + FNV-1a(date|amount|description)[+_n]` (`ids.dart:20-24`), v1 golden vectors and even a JavaScript
`Math.round` tie emulation (`cells.dart:81-84`) show care for cross-version stability. Two risks:

- A collision is silent: `importBatch` treats a known id as a duplicate and drops the row (`repo.dart:740-741`). The
  occurrence counter `_n` (`profile.dart:64-72`) depends on how many identical rows the export window contains: an
  export cut mid-day with three identical coffees where the previous export had two makes the third `_1`, "duplicate",
  lost. Log `repo.idCollision` and disambiguate when amount or description differ.
- `PbzProfile.detect` accepts any sheet with a `DATUM` cell in the first 15 rows (`pbz.dart:36`) and then maps fixed
  column positions (`:57-74`). Another Croatian bank's export (ZABA, Erste, OTP all have `DATUM`) is detected as PBZ
  and imports as an *empty* batch instead of raising the unknown-layout error; `xls_edge_test.dart:260` pins this
  behaviour. Require the full header tuple on one row.

Actual Budget hashes `date|amount|payee|notes` into `imported_id` and adds a fuzzy pass; Firefly III's importer uses
a configurable column hash. The per-source salt (`ids.dart:29-33`) is ready for new banks. KEEP.


## 5. App layer: code architecture, UI and UX (spec §6, §7, checklists "UI/UX" and "Code architecture")

Numbers from the code: 12,205 lines in 75 files; the controller is 1,344 + 502 (bills part) + 497 (future part) =
2,343 lines in one class; 229 `testWidgets` and 294 `test` cases; 326 `find.text(` versus 139 `find.byKey(`; zero
golden files; zero `textTheme.` uses in screens against 87 inline `fontSize:` literals; six `Semantics(` sites.

### 5.1 State management — KEEP the model, CHANGE the growth strategy

One `ChangeNotifier` (`controller.dart:104`) owns repo, derived caches, timers, sync, key, calendars and bills. Screens
mostly do not subscribe: `BudgetWalletApp.home` is one `ListenableBuilder` (`main.dart:81`) and `HomeShell` rebuilds
the five tabs only when `'$dataVersion|$today'` changes, keeping them alive in an `IndexedStack`. Derived values are
memoised per `(dataVersion, day)` under string keys (`controller.dart:465-480`). Pure functions from `wallet_core` do
the maths. Rule "screens never compute from raw rows in build()" holds, with two trivial exceptions (`today.dart:78`,
`bill_sheet.dart:261`).

Comparison: Riverpod would give fine-grained rebuilds and typed derived providers at the cost of a provider graph or
code generation for what is today one source of truth with one invalidation rule; Bloc would make `syncNow` a state
machine the tests already drive through injected fakes. Cashew (open-source Flutter) went framework-free with a
global database and `StreamBuilder`s and is messier than this; Ivy Wallet (Kotlin) went Hilt + per-screen ViewModels
and pays in boilerplate; Actual Budget's client is a Redux-shaped single store with selectors, the same shape as this
controller. Verdict: KEEP ChangeNotifier + version cache + IndexedStack.

What does not scale is the god object: ~30 loose state fields (`syncing`, `syncWaiting`, `syncBlobsWaiting`,
`syncDevices`, `syncBadFiles`, `lastImport`, `nudgesDenied`, `cal.*` …), `part` files that bump `dataVersion` and
clear `_memo` directly (`controller_future.dart:478-479`), a test-only surface of ~12 mutable function fields
(`syncRunner`, `keyWriter`, `pdfParser`, `icsFetcher`, `clipboardWrite` …), and `forgetBrowser` resetting state
field by field (`controller.dart:905-930`). CHANGE: the next Stage-F-sized feature becomes an owned sub-object
exposed as a `Listenable` (`SyncState`, as `CalendarState` already is), memo keys become typed, no fourth `part`.
Screens should receive a typed per-page view object (`TodayView`) rather than the controller itself.

Error flow: every async entry point catches, logs and writes a plain-English status field. Synchronous writes
(`addExpense`, `saveGoal`, `setCategory`) do not catch; a SQLite failure goes to `runZonedGuarded` and the user sees
nothing. [risk] For an app that promises "each action writes once", surface a write failure.

### 5.2 Navigation and layout — KEEP, with one strategic flag

Navigator 1.0, no `go_router`, tabs are `IndexedStack` state (`main.dart:131`); secondary screens are four imperative
`push(fullscreenDialog)` routes and nineteen `showSheet` calls. No URL per tab on web, no restorable state, no deep
link into a bill. Acceptable for a localhost web and a single-owner phone. If web ever becomes first-class, adopt
`go_router` with `StatefulShellRoute.indexedStack` *before* more imperative routes land (Wonderous and the Flutter
Gallery do this; Cashew uses raw Navigator like this app).

Keyboard shortcuts via `Shortcuts`/`Actions`/`Intent` (`main.dart:105-128`) are better than most Flutter money apps.
Adaptive layout (`layout.dart`, 118 lines): breakpoints 600/1024 from window width, content capped 720/1040, pages
keep state across resize. `showSheet<T>` (`sheets.dart:14-62`) picks a bottom sheet or a 480 dp dialog and callers
never know. KEEP all three. Nits: Upcoming and Review re-implement their own page-or-dialog switch
(`upcoming.dart:15-31`); extract one helper. Cross-tab requests are counting `ValueNotifier<int>`s and Plan scrolls
400 px per frame up to 12 times hunting for a `GlobalKey` in a lazy list (`plan.dart:79-92`). CHANGE (see 5.6).

Share-to-app: Android `ACTION_SEND`/`SEND_MULTIPLE` for PDF and images, `singleTask`, surfaced through a stream and a
toast with "Open". No custom URI scheme; the QR join flow covers device onboarding. KEEP.

### 5.3 Platform splits — KEEP, one leak to close

Nine barrels of the form `export 'x_io.dart' if (dart.library.js_interop) 'x_web.dart'` (key store, wallet db, log
backend, nudges, calendar, bill inputs, PDF parse, ics fetch, page reload), plugin-free interfaces with `No*` null
objects, and `platform_test.dart:60-92` enforcing by regex that `dart:io` and native plugins appear only in the
allowed files. That test is unusual and effective. The one leak: `file_picker`'s `PlatformFile` type escapes through
`FileChooser` into four screens (`backup_panel.dart:3`, `calendars_panel.dart:1`, `bills_panel.dart:4`,
`import_flow.dart:3`). CHANGE: return an app-owned `PickedFile(name, readBytes)`. Inconsistency: `KeyStore` is
all-static, which is why the controller injects function pointers instead of an instance. Cashew imports plugins
straight into widgets; Actual has a platform module boundary like this one.

### 5.4 Theme and design system — KEEP colour, CHANGE type

Colour: `WalletColors extends ThemeExtension` with 17 tokens per brightness (`theme.dart:7-73`), and
`theme_contrast_test.dart` asserts ≥ 4.5:1 text and ≥ 3:1 non-text for every pair in both themes. No raw colours in
screens. Material 3 widgets wearing a non-M3 skin, done through component themes rather than per-widget overrides.
KEEP; this is better token discipline than most shipped apps.

Type: the text theme is set once and never used; 87 inline `fontSize:` literals across 14 distinct sizes. The ledger
spec names a type ramp and the code encodes it as magic numbers. CHANGE: six or seven named `TextStyle` tokens
(eyebrow, meta, body, bodyStrong, heading, hero, monoAmount). Wonderous routes everything through `textTheme`; Cashew
has the same literal sprawl.

Text scaling: tested at scale 2.0 with the real Plex fonts at 320/360 dp in both brightnesses; `TxTile` restacks
above 1.15; hero amounts use `FittedBox(scaleDown)`. KEEP. Accessibility: `StatusLabel` is icon + text, bars and day
cells carry semantics, but minimum touch targets are 44 dp (iOS number) where Android/M3 and the Play pre-launch
scan expect 48; `TxTile` lacks `MergeSemantics` so TalkBack reads five stops per row. CHANGE 44 → 48, merge. Dark mode
follows the system only, no manual toggle (Cashew, Ivy and YNAB offer one). Charts (fl_chart bar + ignored line
chart, dashed running period, hatch painter) are solid. KEEP.

### 5.5 Screens — mostly clean; two files to split

`today.dart` (398) is a stateless composition of cached getters; only presentational logic. KEEP. `upcoming.dart`
(460) decides which sheet owns a row via `plannedIsBill` (`bill_sheet.dart:55`), a business rule that belongs in
core as an enum on the upcoming item. `plan.dart` (389) computes the `lowIncome` heuristic
(`received < salary*0.9 && days ≥ 4`, `plan.dart:143`) and the payday clamp in the widget: money rules in the app,
against spec rule 2. `bill_sheet.dart` (615) has a 200-line `_body`, three sub-sheets in one file and the same
refusal copy repeated three times. CHANGE: split, hoist the message. Six raw `DateTime.now()` calls in widgets
versus the injected clock elsewhere. `gapped()` is reimplemented twice. Shared primitives in `common.dart` (Panel,
SectionHead, StatusLabel, TxTile, DoubleRule …) are each under 40 lines and genuinely reused. KEEP.

### 5.6 UX — the strongest and the weakest parts

- KEEP, and protect in review: **"Suggest, the owner confirms"** is implemented uniformly, not as a one-off: an
  "Unsure" helper and icon on every guessed bill field (`bill_sheet.dart:239-246`), "Suggested from your earlier
  bills" on the category, Confirm/Change/No cost on calendar suggestions, nothing reserved until confirmed, the key
  prompt requires typing the last four characters. YNAB's import approval and Actual's rule suggestions are the
  nearest analogues; neither marks *which field* was guessed. KEEP the impulse interception on add expense
  (`sheets.dart:188-198`).
- CHANGE (moderate): **tab allocation.** Wishlist and Goals are low-frequency and hold two of five slots, while
  Bills, the feature with the most code and the most confirm moments, is buried under Plan behind a scroll hunt.
  Ivy Wallet, Cashew and YNAB all put the add action on every tab. Proposal: Today · Spending · Bills · Save
  (Wishlist + Goals) · Plan, plus a persistent add action. Today's "Add expense" button sits below the fold on a
  640 dp phone at scale 2.0 once the warning and payday panels are present.
- CHANGE: **Plan is a settings dump**: nine panels and an eight-field form in one lazy list. Cashew's "More" and
  Ivy's "Settings" are index pages with sub-pages. Make Plan = payday plan + numbers, and a Settings index (Bills,
  Budgets, Calendars, Reminders, Sync, Backup, Export, Diagnostics) each its own route. That also deletes the
  GlobalKey hunt and the counter notifiers.
- CHANGE (cheap): **number style mismatch for the actual user.** Input accepts `1.234,56` and `12,50`; output
  always prints `1,234.56 €` (`format.dart:33-54`). The CHF option has no symbol. One setting-driven decimal style
  now; full localisation later. No `intl`, no ARB, all strings inline English; tests keyed on copy will make a later
  ARB migration a 300-assertion rewrite, so move tests to `ValueKey`s first.
- Smaller: no Undo on delete transaction or delete goal (planned paid/skip has one); the after-work "delivery hour"
  panel encodes one person's habits, fine for the owner, odd for anyone else.

### 5.7 Android and web defaults — [risk], all cheap to fix

- `android:allowBackup` is unset, so it defaults to true: Auto Backup copies the encrypted database and the secure
  storage prefs while the Keystore master key does not transfer, leaving a restored device with an unreadable file.
  Set `allowBackup="false"` or `dataExtractionRules` excluding the database (Ivy Wallet does; Cashew leaves default).
- `android:usesCleartextTraffic="true"` app-wide for the LAN relay. Use a `network_security_config.xml` that allows
  cleartext only for private ranges or the configured host, so `.ics` fetches stay HTTPS-only.
- Release signing silently falls back to the debug key when the keystore env vars are unset
  (`build.gradle.kts:62`); a CI misconfiguration ships a "release" APK that will not install over the real one. Fail
  the build when no keystore is present for the published ABI flavour.
- `WRITE_CALENDAR` is declared because the plugin demands the pair; Play's data-safety form will list it. The spec's
  own open question (replace the plugin) is the right one.
- Web: Web Locks make the wallet single-tab, persist is debounced 800 ms and forced on hide/pause; the same
  "page frozen before flush" window Actual Budget's web build has. The key is wrapped with PBKDF2-HMAC-SHA256 at
  310,000 iterations (`key_vault.dart:14`); OWASP's current figure for PBKDF2-SHA256 is 600,000 and
  `package:cryptography` ships Argon2id. The `bwk1` version prefix makes a `bwk2` swap cheap. The unwrapped key sits
  in `sessionStorage`, readable by any script on the origin; acceptable for localhost, worth a sentence in §9.

### 5.8 Tests in the app — KEEP the harness, CHANGE the assertions

Structural sweeps (`pumpFull(320×640, scale 2.0)` + a walk over every `RenderFlex` that names the overflowing text,
`test/support/layout.dart:24-45`) are better than goldens for catching overflow; the integration harness asserts
that no synthetic merchant, amount or key text reaches the app log (`harness.dart:28-35`). Both are above the
open-source Flutter-finance norm. Gaps: copy-coupled assertions (326 `find.text`), no `meetsGuideline(
androidTapTargetGuideline / textContrastGuideline)`, and the text-scale test *skips* silently when fonts are missing
(`theme_text_scale_test.dart:17-21`); in CI that must fail.

## 6. Schema, migrations and the repository class (spec §5 "Local database")

- SQLite + hand SQL + entity map + field-level HLC: KEEP (section 2.2). This is Actual Budget's architecture and
  fits better than `drift` would, since the one-write-path rule conflicts with an ORM that wants to own writes and
  `sqlite3/common` already runs native and WASM.
- Additive migration is only half-generalised: new tables come free via `CREATE TABLE IF NOT EXISTS`, but missing
  columns are patched only for `tx` (`repo.dart:128-131`). CHANGE: loop over `_entities` × `PRAGMA table_info`, so
  "one entry in the entity map" stays true for the next column on `bills` or `recurring`.
- A schema bump clears every sync cursor (`repo.dart:173-176`), so each upgrade replays the relay or the latest
  snapshot. Correct; seven bumps in a week says it will happen often. Put it in the release checklist.
- Settings are JSON blobs with LWW per key; `categoryBudgets` is one map under one key (`models.dart:382`, pinned by
  `budget_vs_actual_test.dart:277`: "a later write replaces the whole map"). Two devices editing different
  categories' budgets offline lose one. CHANGE: one setting row per category budget.
- No binary backward-compat fixture: `db_safety_test.dart:96-130` rebuilds "v2.0" from a hand-typed DDL constant,
  not from a `.db` or `.bwb` an old build produced. Commit one per release.
- Search is an in-memory linear fold per query (`search.dart:294-341`); fine at 20k rows, no FTS needed yet.

## 7. Quality: tests, tooling and CI (spec §10)

Measured here: importer 284 tests in 3,912 lines; core 1,079 in 18,395; relay 138 in 2,119; app 524 cases in 13,764
lines, run at three sizes each, which is where the spec's 955 comes from. Zero `matchesGoldenFile`.

KEEP:
- Property tests with brute-force oracles (`budget_invariants_test.dart`), scenario + property matching tests, and
  the 2-to-4-device random convergence test with the "highest HLC per field" oracle (`sync_convergence_test.dart`).
- Spec tests written from the API document before the implementation (`future_spending_spec_test.dart:1-2`,
  `bills_spec_test.dart`). The best practice in the repository.
- Golden id vectors and BIFF8 edge tests; log-privacy tests per package; fuzz tests in isolates with timeouts.
- The Podman image with pinned Flutter 3.47.7, `sqlite3mc` through `hooks.user_defines`, and the pinned wasm hash.
  For an encryption-bearing app, reproducible builds are worth the container.

CHANGE:
- A few invariant tests restate the implementation's formula verbatim (`budget_invariants_test.dart:172-182`) and
  would survive mutants; `mutation_test` for Dart exists and is cheap on pure packages.
- Manual-only CI. Package tests are pure Dart and take minutes; run them on every push. Keep APK, desktop and
  emulator manual.
- `tools/` is about 3,000 lines of Bash and Python (`build.sh` 630, `build_log.py` 374, `live_vm.py` 422,
  `emulator.sh` 258) for a 24k-line product: per-step and per-test JSONL history with medians, flock-guarded run-dir
  pruning, shard ordering by history. Keep `build.sh test|apk|linux|desktop-test` and `live.sh`; drop the history and
  trend machinery unless it has caught a regression. Dart 3.6 `workspace:` in a root pubspec replaces the hand-rolled
  staleness check in `build.sh pub_ready` (`:169-190`).
- The agent process that produced the code (scout → builders → spec tests → reviewer) exists only as prose in the
  spec; `.claude/` holds a local settings file and an empty worktrees folder, and the CLAUDE.md files that steered
  the builders survive only as stale copies under `dist/desktop-test/w*/` on disk (not in git). Commit the agent and
  CLAUDE.md definitions so the process is reproducible, and clean `dist/` out of review snapshots.

Missing entirely: real-device end-to-end (camera, OCR, share, notifications are "compile-proven"), an anonymised
real-bill corpus kept outside the repo, old-build database fixtures, a test for the past-payday state, and golden
tests for the handful of money-formatting widgets where they would pay.

## 8. Process and delivery

Facts from git: 380 commits between 2026-10-16 and 2026-10-22, 376 authored as "Claude", one each by the owner,
a test-writer agent and a CI bot. About 24,000 lines of production Dart and 36,000 lines of tests in six days.
The spec describes the pipeline: scout → builders in worktrees against a frozen API document → spec tests written
from the document → merge → read-only reviewer → fixes with reproducing tests → full run → screenshots read → push.

What this buys and what it costs:

- KEEP: **API document before code** (`docs/context/*_API.md`). It is the reason the packages have clean seams and
  the reason spec tests are independent of the implementation. Most human teams never manage this.
- KEEP: **"every finding fixed with a reproducing test first"** and the per-stage review counts in §10. That is a
  real quality signal, not a vanity one.
- RISK: **nothing has run on a real phone yet.** Camera, OCR, share-to-app, notifications, calendar and the Android
  keystore are "compile-proven and tested with fakes". In my experience the first device run of a Flutter app with six
  platform plugins finds between five and fifteen issues (permission timing, lifecycle on resume, notification
  channels, scoped storage, MLKit model download, back-gesture handling). Treat M6 as a stage with its own budget,
  not a checkbox.
- RISK: **velocity without a user in the loop.** 117 commits on the review day. The code is consistent because one
  generator wrote it; it has not been shaped by friction from use. The single most valuable thing the owner can do
  next is use it for one pay period and write down every moment of doubt. Nothing in this review substitutes for that.
- CHANGE: **CI is manual** ("runs only when the owner starts it"). Free GitHub Actions minutes on a public repo, or
  a self-hosted runner on the relay box, should run `lint + package tests + widget tests` on every push. The Podman
  reproducibility work already makes that a five-line workflow. Keep the long desktop/emulator suites manual.
- CHANGE: **the build tooling is a product of its own** (`tools/build.sh`, timing history, `live.sh`, emulator
  snapshots, LSP-in-container). It is impressive, and it is also 2,000+ lines of Bash/Python that only one machine
  runs. Keep what the owner uses weekly; delete the rest before it rots. A `melos`/pub-workspace layout plus plain
  `flutter test` would onboard a second contributor in an afternoon; the current setup needs a Linux host with
  Podman, Bash 5 and GNU tools and explicitly excludes macOS.

## 9. Sync, cryptography and relay (spec §4, §5, §9; checklists "System architecture" and "Security")

### 9.1 The replication kernel — KEEP (correct in the code read)

Per-device append-only sequence files on a dumb relay; ops `{entity, id, fields, hlc}` applied idempotently with
per-field LWW and tombstones; outbox cleared only after every part of an upload is stored
(`sync_engine.dart:576-633`); peers' files applied strictly in order, each in one SQLite transaction; content-hashed
quarantine retried on content or build change (`sync_problems.dart:625-683`); a stuck peer healed by a snapshot from
a caught-up device after 24 h (`sync_engine.dart:702-736`); snapshot dominance enforced by the relay and pruning
gated on both kept snapshots *and* every device seen in 90 days having acked (`relay/lib/src/wallet.dart:143-169`,
mirrored in `sync_memory.dart:536-553`). I could not construct a case where an honest relay prunes an op before a
live device can obtain it as a file or inside a kept snapshot. Checklist item "snapshot and pruning rules cannot lose
an op": holds.

This is Actual Budget's model (per-field LWW messages with HLC into SQLite) with the merkle-trie catch-up replaced by
per-device sequences, which is what keeps the relay plaintext-free and small. Alternatives considered and rejected
for good reasons: cr-sqlite collides with the `sqlite3mc` build and the WASM target; PowerSync and ElectricSQL need a
server that reads plaintext; Automerge and Yjs have no credible Dart/WASM path and solve a richer problem than flat
budgeting tables need; a hosted E2E store removes the self-hosting premise. Continue on this kernel.

Three places where the design is subtle enough to deserve a comment and a test:

- Delete versus concurrent edit converges to "deleted, with the new category" because `deleted` has its own clock
  and `importBatch` never writes `deleted: 0` on creation (`repo.dart:756-758`). Intentional and right.
- Goal totals as delta rows (`repo.dart:862-883`) are a proper counter under concurrency; Actual's budget amounts are
  raw LWW and lose concurrent offline edits. Better than the comparable.
- Matching, pairing and bill reserve rows are *recomputed on every device* and produce new ops with new clocks. They
  converge only because the computation is deterministic over identical inputs; the convergence test checks they
  settle within four rounds. This is convergence by recomputation, not a CRDT guarantee. Any nondeterminism (map
  order, locale, a float) becomes ping-pong. Assert zero ops on the second full round in the simulation.

### 9.2 Where per-field LWW yields a wrong result — [bug]

`categoryBudgets` and `merchantPatterns` are whole maps stored under one settings key
(`controller.dart:590-591` writes the whole map; `models.dart:380-382`). Two devices offline, one sets a Groceries
budget and the other a Rent budget: the later clock wins the whole map and one budget silently disappears. This
contradicts the spec's own "two devices editing different fields both win". Fix: one settings row per category
(`budget:<category>`) and per pattern. Actual Budget stores each (month, category) budget as its own message for
exactly this reason. Twenty lines; do it before M6.

Related [risk]: pairwise links (`transfer_to`, `matched_to`, `bills.linked_tx`, `planned.paid_tx`) are not atomic
under per-field LWW. Transfers and matches are repaired at read time and recomputed when caught up; `linkBill`
enforces "one payment per bill" only against local state (`repo.dart:1387-1389`), and two devices linking different
bills to the same transaction converge to two bills sharing one payment with no repair. Add the same caught-up repair
and an invariant in the simulation.

### 9.3 Identity gaps — [risk], the most important changes in this layer

1. **No relay identity.** The "first upload" decision is `relayLast < marker` on a bare sequence number
   (`sync_engine.dart:578-580`). Concrete loss: device syncs with relay A to seq 40; the owner points it at new relay B
   (full-state upload, marker becomes 3, outbox cleared); then back to A: 40 ≥ 3, treated as the same relay, only
   pending ops go up, and everything uploaded only to B never reaches A's peers. Silent and data-dependent. Same
   shape when a relay is restored from an older disk image. Fix: a random relay id (or per-wallet creation nonce) in
   `GET state`, stored with the marker; any change means "first connect". Syncthing's IndexID and CloudKit's zone
   change tokens are the references.
2. **Device id lives in the wallet database** (`repo.dart:128-136`). Copying the Linux app directory, or Android's
   default backup and device-to-device transfer (the manifest sets neither `allowBackup="false"` nor
   `dataExtractionRules`, `AndroidManifest.xml:15-19`), yields two installs with one id. Each skips its own id when
   applying peers, each gets 409 on the other's seq and silently retries at the next number
   (`sync_engine.dart:610-615`). Result: two installs that never see each other's edits, no error shown. Fix: keep
   the device id per install next to the key, not in the database, and treat a 409 on an own seq as "another install
   uses this device id" rather than continuing.
3. **HLC accepts unbounded future time** (`hlc.dart:57-71`): `receive` takes the max of wall, last and remote with no
   bound, so one device in 2099 permanently poisons every device's clock; `tick` can never return to wall time, and
   the matching window that compares clocks by millis prefix (`repo.dart:477, 788`) becomes meaningless. The 24 h cap
   the spec mentions applies only to the relay-signature offset (`sync_relay.dart:167-199`). The convergence test
   runs a device a year ahead and proves convergence, not sanity. Actual Budget refuses a remote timestamp more than
   a minute ahead. Fix: quarantine files whose max HLC is more than an hour ahead of local wall time under a new
   `clockDrift` reason, refuse local writes when the wall clock is that far behind the stored clock, and surface it in
   the UI as `clockSkew` already is.
4. **No revocation or rotation.** `wid` and the signing seed are pure functions of the wallet key
   (`sync_relay.dart:53-59`). A lost phone that still holds the key cannot be cut off, and there is no rotation flow.
   Acceptable to defer for one owner, but it must be a named limit in §9 with a sketched procedure (backup → new
   key → restore → re-point devices). Bitwarden and Ente revoke per-device sessions; Syncthing revokes per-device
   certificates.

### 9.4 Cryptography — KEEP the primitives, CHANGE the hygiene

- XChaCha20-Poly1305 with a 24-byte random nonce from the library, Poly1305 tag, `BWOP1|nonce|mac|ct`
  (`vault.dart:207-219`); `Random.secure()` for the key; gzip-then-encrypt with a trailer check. With a 192-bit
  nonce, random generation is right (it would not be with AES-GCM's 96 bits). HKDF-SHA256 with versioned infos and a
  known-answer test. Ed25519 over `bw-relay-v2\nMETHOD\npath\ncovers\nsha256(body)\ntime`, the relay rebuilding the
  path from validated segments, checking the 5-minute window before reading a body, and re-checking the public key
  inside the wallet lock to close the creation race (`relay_server.dart:446-518`); the relay tests use an
  independently written signer and prove a captured request cannot be bent to another path, method, body, covers or
  time (`signing_test.dart:39-111`). KEEP all of it. Nonce reuse checklist item: holds.
- [change] **No associated data and no domain separation.** `seal` passes no AAD (`vault.dart:215`) and sync files,
  snapshots, backups, blobs and the web key wrap share one magic. A relay can serve `d/A/5` as `d/B/3`, an old
  snapshot under a new id, or a backup as a snapshot, all undetected at the crypto layer. Because ops are
  self-describing and LWW is idempotent I could not turn this into corruption (swaps reorder; rollbacks are already
  in the threat model; a snapshot fed as a file fails a cast and is quarantined), so this is hygiene rather than an
  exploit. It is also nearly free: AAD = `"bw-sync-file\n<device>\n<seq>"`, `"bw-snapshot\n<id>"`, `"bw-backup"`,
  `"bw-blob"`, bump to `BWOP2` (the `newerFormat` path already exists, `vault.dart:240-243`). Bitwarden's EncString
  type byte, age's header binding and Tink's associated-data convention all do this.
- [change] Include the relay host in the signed text (AWS SigV4 does) so a request captured against relay A cannot
  be replayed within five minutes against relay B holding the same `wid`; `DELETE blob` is the one case that is not
  idempotent across relays.
- The relay can correlate: a stable 128-bit wallet id, stable device ids, seqs, sizes, times, acks, last-seen, blob
  sizes. It can infer device count, activity rhythm, edit volume, that a receipt photo was just taken, and link the
  wallet across every relay the owner ever uses. Fine for a self-hosted relay and said in the protocol doc; if a
  relay is ever shared, derive `wid` per relay (HKDF with the relay's id as salt).
- Performance: everything is pure Dart (`package:cryptography` XChaCha20, SHA-256 and Ed25519; `cryptography_flutter`
  is not a dependency). Sealing a 15 MiB receipt PDF and hashing it twice on a mid-range phone is in the
  one-to-several-seconds range; the 500 ms `PerfTimer` thresholds suggest this has been noticed. Measure on the
  slowest device before deciding. Platform crypto has no XChaCha, so acceleration means HChaCha20 in Dart plus
  platform ChaCha20-Poly1305.
- Keys at rest: phone in `flutter_secure_storage`, fine. Desktop: a plaintext file written and *then* `chmod 600`
  through `Process.run` (`key_store_io.dart:51-57`), so it exists world-readable under a default umask for a moment
  and the parent directory is unrestricted. Create the directory 0700 first or write a temp name and rename after
  chmod; the roadmap's keyring is the real fix (Bitwarden desktop uses the OS keychain). No `FLAG_SECURE` anywhere,
  so the recents thumbnail and screenshots capture the key and QR on Android; set it while the key sheet is open,
  as Bitwarden and Aegis do. Web: PBKDF2 at 310k iterations (see 5.7) and the unwrapped key in `sessionStorage`
  (`key_vault.dart:186, 203`); in-memory only, re-enter on reload, would be cleaner.

### 9.5 SQLite encryption — KEEP, pin the cipher

`sqlite3mc` through the build hook and a pinned `sqlite3mc.wasm`; raw 32-byte key via `PRAGMA key`
(`local_db.dart:269-274`) so no KDF inside SQLite; conversion does a keyed open first, probes unkeyed only on
NOTADB, checkpoints WAL before `PRAGMA rekey`, verifies row counts and uses temp + rename (`local_db.dart:255-335`,
`sqlite_io.dart:381-410`). Good. [change] No `PRAGMA cipher` or `cipher_*` settings anywhere: the on-disk format
and strength are whatever the hook's compile-time default is today (ChaCha20-Poly1305 per 4 KiB page). Pin it
explicitly before `PRAGMA key` and record it in the spec so a future default change cannot silently alter the format.
[bug] Android backup unconfigured (9.3 item 2 and 5.7): set `allowBackup="false"` and exclude everything, as
Bitwarden and Aegis do.

### 9.6 Relay server — KEEP the shape, close two holes

Pipeline (`relay_server.dart:157-281`): rate limit → OPTIONS → route and name validation → signature headers before
any body → body read with per-request and per-address in-flight caps and polite draining → verify → per-wallet async
mutex → handler; one log line per request with kind, status, bytes and six-character ids only. Storage is plain files
plus `meta.json` via temp + rename, files win over meta on start, strays deleted, `first` rebuilt
(`wallet.dart:52-57, 173-277`). Single isolate, per-wallet serialisation, bodies fully buffered up to 64 MiB: fine
for a home server with 16 wallets. Two-stage container, `--enforce-lockfile`, AOT binary on debian-slim, non-root.
KEEP. Add a HEALTHCHECK against `/v2/health`.

- [risk] **Unauthenticated wallet creation.** Anyone who can reach the port can create 16 junk wallets and the
  owner's next first-connect gets 507 (`limits_cors_log_test.dart:68-93` proves the cap works, which is the
  problem). Together with the acknowledged TOFU squat this is the relay's main denial-of-service surface on a LAN.
  Fix while keeping the relay dumb: a creation token in config sent once as a header on `PUT d/<device>/1`, or an
  allow-list of wallet ids. Syncthing relays and Ente both require out-of-band enrolment.
- [risk] **Rate limiter keyed on `remoteAddress` with no `X-Forwarded-For` handling** (`relay_server.dart:206-211,
  376-396`). The spec's own recommended deployment (TLS reverse proxy) collapses every client into one 20 req/s
  bucket and one 32 MiB in-flight budget: per-attacker isolation disappears and one misbehaving device throttles
  the others. Add a `--trust-proxy` option or document binding to localhost only behind the proxy.
- Minor: `HEAD` returns 405 although `_send` has a HEAD branch; a known device with a missing file on disk returns
  500 rather than a diagnosable status (`:475`).

### 9.7 Backups — KEEP the format, CHANGE the restore rule, state the blob gap

A `.bwb` is the same sealed op set as a relay snapshot, with original clocks (`backup.dart:135-142`); restore applies
through `applyRemote(resend: true)` so the restored state flows to peers. Because ops carry clocks, a restore is just a
merge, and "only into an empty wallet" is a UX guard, not a correctness requirement. CHANGE: keep "Restore" as is and
add an advanced "Merge from backup" on the same code path; the realistic disaster (relay dead, phone lost, laptop
behind) wants exactly that and today forces a detour through a fresh wallet. Actual Budget's restore replaces the file
and resets sync; Bitwarden's import duplicates; this design can merge safely and is not using it. [risk] Backups
contain no blobs (`blob_store.dart:22-24`): relay loss plus restore keeps the bills and loses every photo and PDF.
Include blobs in the backup when they fit, or say so loudly in the backup panel and in §9.

### 9.8 Tests in this layer — KEEP, six additions

Present: randomised convergence of two to four devices with fetch failures, clock skew to ± a year, late joiners and
an LWW oracle (`sync_convergence_test.dart`, 60 seeds by default); property tests for op order and HLC algebra;
quarantine, self-heal, snapshot and prune scenarios; relay tests with a hand-written signer, creation races, restart
recovery and byte-exact limits; end-to-end against the real relay in-process and from the Flutter app. Better than
most hobby projects and many commercial ones.

Missing, in order of value: (1) model equivalence, the same random request sequence through `MemoryTransport` and
the real relay with `state()` diffed after each step, since the two are hand-duplicated rule sets and the fuzz only
exercises the memory one; (2) the scenario gaps above: relay A→B→A, cloned device id, two concurrent runs,
concurrent budget edits, concurrent `linkBill`, a device returning after 90 days, a relay restored from an older
image; (3) relay fault injection between `writeAtomic` and `saveMeta` under concurrent PUTs, disk full, truncated
files; (4) protocol fuzzing asserting "4xx, never 5xx, state unchanged"; (5) fixed-key, fixed-nonce vectors for
`seal` and a nonce-uniqueness sanity test; (6) invariants in the simulation: bill-payment uniqueness, transfer pair
symmetry, `ack ≤ cursor ≤ last`, `covers ≤ cursors`.

## 10. If I started this from zero today

The short version: I would keep the product thesis, the money model, the offline-first + dumb-relay topology, the
pure-Dart core, the one-write-path change log and the ledger design language. I would change the order of work, the
data layer's shape, a few protocol details, and the amount of custom tooling. In detail:

### 10.1 Order of work (what I would ship first)

1. **Week 1: money model as a library, no UI.** `wallet_core` with `computePeriod`, budgets, matching, recurring as
   pure functions over an in-memory list of rows, property-tested (rational invariants: safe-to-spend never changes
   without an op; sum of contributions equals goal.saved; re-import is idempotent). The spec already treats this as the
   centre; I would make it the *only* thing for the first week and seed it with a real export of my own.
2. **Week 2: one platform end to end.** Android only (the owner's daily device), Today + add expense + import, encrypted
   SQLite, no sync. Use it for real from day 10. The first pay period of real use decides the next three months better
   than any review.
3. **Week 3–4: sync.** Only after the schema has survived two weeks of real use. The change log design is right; the
   protocol below is slightly different.
4. **Then** bills, calendars, wishlist, weekly review, desktop. Each as its own stage with an API doc, as the project
   already does.

The current project built everything in six days and will now discover the schema changes real use demands with
seven synced entities and three platforms already attached to them. The additive-only migration rule will hold, but
every "oh, a bill can have two due dates" costs a replay across devices.

### 10.2 Repository and packages

- Pub workspace (Dart 3.6+ `workspace:` in the root pubspec) with `packages/core`, `packages/importer`,
  `packages/sync` (split out of core: engine, relay client, vault; it is the part with the most invariants and the
  least UI churn), `apps/mobile`, `services/relay`. Same dependency rule as now, enforced by `dart analyze` import
  rules (the `*_io`/`*_web` conditional-export pattern is fine).
- One shared `analysis_options.yaml`, default 80/100-column format. 140 columns made the files dense; it also made
  every line count in the spec look smaller than the code is.
- `melos` or plain workspace scripts for `test`, `format`, `analyze`. GitHub Actions on every push for lint, package
  tests and widget tests on `ubuntu-latest` with the Flutter version from `ci/flutter-version.txt`. Keep Podman for the
  release APK (reproducible signing) and for the emulator run, as now.

### 10.3 Data layer

- Keep SQLite + raw SQL + `sqlite3` package. Skip `drift`: the one-write-path discipline conflicts with an ORM that
  wants to own writes, and `sqlite3/common` already runs native and WASM.
- One **typed entity schema** in Dart (`Entity('tx', columns: [Col.text('date'), Col.money('amount'), ...])`) from
  which `CREATE TABLE`, the op field validator, the snapshot writer and the CSV export are generated at runtime. Today
  these are three hand-kept tables in `repo.dart`.
- Keep the op log, HLC per field and LWW, **plus authorship and tombstone semantics by design**: a `deleted` flag
  must dominate later edits to other fields (today a device editing a note on a row another device deleted
  resurrects the field values while the row stays deleted — harmless, but the invariant is implicit). Decide per entity
  whether delete-wins or edit-wins and test it in the multi-device simulation.
- Keep contributions as delta rows. Extend the same idea to anything that is a counter (streaks, "saved by waiting").
- `repo.dart` split by entity into `part` files (as the controller already is) around the one private `_write`. Same
  class, navigable files.

### 10.4 Sync protocol v3 (small changes, big payoff)

- **AAD on every sealed file**: `wid | device | seq` (or `snapshot | id`) as associated data in the AEAD, so a relay
  cannot serve file N as file M or one device's file as another's. Free with XChaCha20-Poly1305.
- **Relay instance id** in `GET state`, stored per device; a changed id means "relay was reset", and the device
  re-uploads and re-reads from zero instead of trusting cursors.
- **Device id per install, outside the database** (next to the key), so a cloned or restored database gets a fresh
  id and replays from a snapshot instead of silently sharing a sequence with its twin.
- **Bounded HLC**: refuse remote clocks more than an hour ahead of wall time (quarantine reason `clockDrift`) and
  refuse local writes when the wall clock is that far behind the stored clock.
- **Per-key settings**: one row per category budget and per merchant pattern; never a map under one key.
- **Blobs referenced from ops, never deleted by clients.** Upload-before-ack, server-side GC from the set of hashes
  referenced by kept snapshots. Removes `blob_outbox`, `blob_delete`, `blob_own` and the orphan cases in §11.
- **TLS by default**: ship the quadlet with a Caddy sidecar or document `tailscale serve` as *the* path, keep plain
  HTTP as the dev mode only.
- Keep Ed25519 request signatures and TOFU (it is the same model as SSH; for one owner it is right), but add a
  one-line "relay fingerprint" the app shows on first connection and keeps, so a squatted or replaced relay is visible.
- Keep snapshots + pruning. Add a property test that no live device can be left behind a prune (random schedules of
  snapshot, ack, prune, offline device).

### 10.5 App layer

- Keep `ChangeNotifier` + one controller and constructor seams. For a 12k-line app with one maintainer, Riverpod
  adds concepts without removing code. The thing to add is not a framework but a **boundary**: screens receive a
  typed view-model object per page (`TodayView`, `UpcomingView`) built by the controller, never the controller
  itself. That is where the current code is weakest (screens reach into the controller and the repo).
- Keep the five tabs and the Ledger design system; it is distinctive and the contrast/scale tests are better than
  most shipped apps. Turn Plan into a grouped index page (Settings-style) as soon as a sixth section lands.
- Keep widget tests at 320 dp × 2.0 text scale. Add a dozen golden tests only for the money-formatting widgets and
  the Today hero; nowhere else.
- Localisation from day one via `flutter_localizations` + ARB even if English is the only language for a year;
  retrofitting strings into 12k lines is the kind of change no one does later.
- Platforms: Android first, Linux second (the owner uses it), web **parked** unless there is a daily reason. Each
  parked platform is a lie in the README until deleted or maintained.

### 10.6 Importer and bills

- Keep own CSV/XLSX readers and the deterministic id scheme; add the "same month, newer bank template" fixture per
  bank and a column-mapping fallback for unknown layouts (already on the roadmap; promote it).
- The hand-written BIFF8 reader and the 1,100-line PDF text extractor are defensible only because the dependency
  policy forbids packages. I would allow `syncfusion`/`pdfrx`-class packages for PDFs *or* keep the extractor but
  treat it as a separate package with its own fuzz corpus and release cadence. Same for HUB-3/fiscal QR decoding.
- Run OCR and PDF parsing in an isolate from day one (the project already moved PDF off the UI isolate after review).

### 10.7 What I would not build

- A second storage stack for the web.
- Custom build-timing history and a containerised LSP. Use the standard toolchain; spend the time on device testing.
- Research projects / trackers (already dropped, agreed).
- Multi-user inside one wallet. Ever. Second wallet instead.

## 11. Recommendation

Continue on this codebase. Do not restart. The decisions that are expensive to change later (offline-first, dumb
relay, one write path, pure core, integer cents, owner-confirms) are the right ones and are already there. The
decisions that are wrong or risky are cheap to change now (AAD, relay instance id, blob invariants, TLS default, typed
schema, view-model boundary, CI on push) and should be done **before** M6 feedback adds features on top of them.

Concretely for the next four weeks: (1) the ten pre-M6 items in §1.2, about a week; (2) the owner's live test on
phone and laptop for one full pay period, with a written log of every moment of doubt and every number that looked
wrong; (3) only then the product changes in §1.2 items 11 to 16, ordered by what the live test surfaced. If the
owner finds after that pay period that the daily number is not trusted, the problem will be in §3 (money model
edges), not in the architecture, and it will be fixable in the core package with the test harness that already exists.
