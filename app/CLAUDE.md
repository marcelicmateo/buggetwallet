# app — notes for Claude

Flutter UI for Android, iOS, Windows, macOS, Linux. **No money logic here**: calculations belong in
`wallet_core` (with unit tests); the app formats and displays them.

## Files
- `lib/main.dart` — app shell (`HomeShell`): bottom bar on compact windows, `NavigationRail` from 600 dp, one shared destinations
  list, Ctrl shortcuts (Ctrl+1..5 tabs, Ctrl+N add expense, Ctrl+R/F5 sync, Ctrl+, Plan; logged as `nav.key`).
  The pages are built once (see below) and the body keeps the same widget shape at every size (keyed `Expanded`), so a
  resize keeps every page's State: never build pages in `build()` or a `LayoutBuilder`.
- `lib/src/layout.dart` — `LayoutSize` (compact < 600, medium 600–1023, expanded ≥ 1024) and `sizeFor(width)`; decide on the
  window width (`MediaQuery.sizeOf`/`LayoutBuilder`), never on the device type. Content max width 720 (medium) / 1040 (expanded);
  `TwoCol(left, right)` = two columns when the content is ≥ 1040 wide (Today, Spending), `NarrowPage` = 720 (Wishlist, Plan).
  `showSheet` opens a dialog (max 480) from 600 dp, a bottom sheet below; callers don't change.
- `lib/src/platform.dart` — `isAndroid/isIOS/isWindows/isMobile/isDesktop/hasKeyboard` from `kIsWeb` + `defaultTargetPlatform`.
  Use these, not `Platform.isX`. Tests set `debugDefaultTargetPlatformOverride` (and must unset it before the test body ends).
- `lib/src/controller.dart` — `WalletController` (ChangeNotifier): owns the `WalletRepo`, the cached lists,
  sync timers. Screens call controller methods; the controller calls the repo and `notifyListeners()`.
- Budgets (E1): `categoryBudgets` (monthly cents per category), `budgetVsActual(month)`, `suggestedBudgets(month)`, `tightestBudget()`
  (cached like `spending()`), `saveCategoryBudgets(map)` (logs `budgets.saved` with the count only). Spending's "Where it goes" bars use the
  budget as the 100 % mark (`CategoryBars(budget:)`: ruled track, hatched `bad` stretch and "over by 12 €" when over, "48 € left" otherwise,
  summary line and a total row under a `TotalRule`); Today shows one tappable line for `tightestBudget()` (`TodayScreen.openSpending`).
- Derived values (`period()`, `payPeriods()`, `spending(month)`) are cached in the controller per `dataVersion` (bumped by
  `reload()`) and day: never compute from `txs` in `build()`. `HomeShell` builds the five pages once per data version and day
  (`'${dataVersion}|${today()}'`), so a tab switch only moves the `IndexedStack` (keep it that way: 20,000 rows made every
  switch miss frames). The controller takes a clock (`forTest(clock:)`); `checkDay()` (resume, 2-minute timer) notifies when
  the day changed, so a wallet without a relay also moves on at midnight.
- Habits (M4): `screens/review.dart` (`openReview` = page on phones, 560 dp dialog from `dialogMin`; `ReviewScreen` = four ruled steps with a
  square tick: Import (`screens/import_flow.dart` `pickAndImport`, shared with Plan), Confirm categories (`reviewRows()`: the rows core counts;
  "Looks right"/"Change" call `confirmCategory` = pin the category + teach the merchant, so the row leaves), Pace (`paceRows()`, tap → Spending),
  Wishlist (`readyWishes()`, `buyWish`/`skipWish` from wishlist.dart); Done → `markReviewDone()`). Today shows the "Weekly review" card while
  `reviewState().due`, "Reviewed · N weeks in a row" after Done, and "Due by payday: 3 bills, 182.40 €" from `period().dueBills`/`reservedBills`
  (bills in a fixed category are named "covered by your plan" and left out of the sum; an unpaid bill past its date says "overdue").
  `screens/habits_panels.dart` = Plan's review-day chips (`setReviewDay`), Expected bills (`recurringBills()`: candidates → Confirm / Not a
  bill; confirmed rows with Paid/Overdue/Covered and Remove) and Nudges (a device-local switch, `setNudges`). The "Due by payday" tap
  switches to Plan and scrolls to Expected bills (`PlanScreen.showBills`, a notifier owned by `HomeShell`).
  Controller log events (counts and enum words only): `review.done`, `review.day`, `recurring.confirm|dismiss|delete`, `nudges.enabled|scheduled`.
- Sync (R5): `controller.dart` keeps `relayUrl` (device-local `relayUrl` value; `setRelay(Uri?)` validates http/https + host, saves, syncs with trigger `relay`;
  `parseRelayAddress(text)`), `syncRunner(Uri relay, key, repo)` (default: `SyncEngine` over `RelayTransport`; tests inject a fake or a `MemoryTransport` run),
  `healthCheck(Uri)` / `testRelay(Uri)` ("Test connection"), `syncNow`, and after each run `syncCaughtUp`, `syncWaiting`, `syncDevices`, `syncError`
  (a `SyncException` shows its message, anything else a generic one), `syncBadFiles`, `lastSync`. Runs: start, resume, 3 s after a change, every 5 min (the
  2-minute timer only checks the day), Ctrl+R/F5 (toast without an address), on web too. Logs say `sync.relay {set}`, never the address.
  `sync_status.dart` = pure texts (`syncStatusLine`, `lastSeenText`, `clockText`, `relayTestFailureText`); `screens/sync_panel.dart` = Plan › Sync (address field, Save
  address, Test connection, Sync now, status line, devices, Show wallet key). Onboarding join takes the key plus an optional relay address (`joinWallet(…, relay:)`).
  Android: INTERNET permission and cleartext HTTP (LAN/VPN); no storage permission, no `budget_wallet/storage` channel.
- Polish (M5): Plan › Backup (`screens/backup_panel.dart`: "Back up now" = `wc.backupDownload()` → `FileChooser.saveBackup` (the system save dialog on every platform; a cancel
  shows nothing), "Restore from backup…" only while `walletIsEmpty`: `pickBackupFile()` → confirm → `restoreBackupFile(bytes)` → toast with the row count; the core
  functions sit behind `backupBytesWriter/backupBytesReader` so tests use fakes) and Plan › Export (`screens/export_panel.dart`: range chips This period/year/Everything,
  `exportTransactions(range)`/`exportSummary()` return an `ExportFile` (UTF-8 with BOM) saved through `FileChooser.saveText`). Search (`screens/search.dart`
  `SearchPane`): the icon in Spending's header or Ctrl+F (`HomeShell._searchRequest`) swaps the page for a pinned field + ruled result sections via an
  `IndexedStack` (the page keeps its scroll); 2+ characters, 150 ms debounce, `wc.search(q)` cached per data version; goal/wish/bill rows jump to their tab.
  Log events (counts only): `backup.done|restored|failed`, `export.transactions|summary|saved`, `search.run`.
- Future spending (F3): `controller_future.dart` (a `part` of controller.dart: `extension FutureSpending` + `CalendarState` `wc.cal`): planned costs
  (`plannedOpen/plannedEverything`, `upcomingItems(from,to)` cached per data version + `cal.version`, `upcomingRange(next:)` = the pay period or the next one,
  `comingUp()`, `countedIn`, `addPlannedCost/editPlannedCost/confirmSuggestion/dismissSuggestion/markPlannedPaid/skipPlanned/deletePlanned`,
  `paidCandidatesFor`), heads-ups (`headsUpLines()`, synced `headsUpCents/headsUpDays` via `saveHeadsUp`, device-local `headsUpNotify`, `rescheduleHeadsUps()`
  after every reload, nudge reschedule and resume; `NudgePlatform.scheduleHeadsUps/cancelHeadsUps`: channel `headsup`, ids 1000..1019, 09:00 local on
  date - days, text `headsUpBody` has no title or amount; `AndroidNudges.cancelAll` also removes them, so `rescheduleNudges` always ends with `rescheduleHeadsUps`),
  calendars (`CalendarSource` interface in `calendar_source.dart`, `calendar_platform.dart` picks `AndroidCalendars` (plugin `device_calendar_plus`, read calls only; its
  full permission request needs READ and WRITE_CALENDAR declared, the app never writes) or `NoCalendars` on the web/desktop; `.ics` files (`importIcsFile`, 2 MB cap) and
  links (`addIcsLink`, `ics_fetch.dart`, not on the web) are kept as device-local values `icsSources` / `icsText:<id>`, device calendars chosen in `calendarsOn`; `readCalendars`
  reads [today, today+90] at start, resume, choose, import and "Read now", links are fetched again first and a failure keeps the saved copy and shows a message on the entry).
  Screens: `screens/upcoming.dart` (`openUpcoming` page/dialog, `PeriodGrid` month grids with a mark per kind, ruled list with Confirm / Change / No cost, "Set aside" total),
  `screens/planned_sheets.dart` (`PlannedFormSheet` add/edit/confirm, `PlannedEntrySheet` Change / Paid (picker) / Skip / Delete), `screens/calendars_panel.dart` (Plan › Calendars +
  heads-up fields), Today's `comingUpLine` and `headsUp:<key>` lines, Plan › Nudges `headsUpSwitch`, Plan › Export `exportPlanned`, a "Planned costs" section in search.
  F4b: Paid and Skip show a snack bar with Undo (`reopenPlanned`; `toast(actionLabel:, onAction:)`); `fetchIcs` has one overall 60 s timeout, follows up to 5
  redirects by hand and refuses https to http (`resolveRedirect`); an `http://` link is accepted with a warning (`insecureLinkWarning`); `rescheduleHeadsUps` calls
  run one after another; `headsUpSlots` moves a passed slot to the next 09:00 on or before the cost; Android events with status canceled are dropped (`calendarEventsFrom`).
  Logs (counts only): `planned.add|edit|dismiss|paid|skip|reopen|delete`, `calendar.read {calendars, events, unsupported, trigger}`, `calendar.import {ok, kind, reason}`,
  `calendar.access|choose|remove`, `headsup.enabled|scheduled`. Tests: `test/future_spending_test.dart` (`futureWallet`, `FakeCalendars`, `fakeIcs`, `FakeNudges.headsUps` in `test/support/wallet.dart`).
- Bills database (B4; core API in `docs/context/BILLS_API.md`): `controller_bills.dart` (a `part`: `extension BillsDb`) = lists (`billsAll`, `billLists()` To review / Unpaid / Paid,
  `billsToReview`, `billForTx`, `billCandidatesFor`, `searchBills`), adding (`importBillFile(bytes, ext, trigger:)` = pdf → text + on Android page render + code scan, xml → e-invoice,
  jpg/png → Android codes then OCR / elsewhere kept unread; the original goes to `BlobStore.add` (pictures sized to JPEG 2560 px first); no code or text in the file → `externalId`
  `file:<hash of the file>` so the same file is one bill; `importScannedCode`, `importPhoto`; results are `BillImport` with a `message` such as "Already in your bills"), Share to app
  (`startSharing()` from `HomeShell`, results on `sharedBillResults` → SnackBar), the bill sheet actions (`editBill`, `setBillDates`, `confirmBill` needs date + total, `linkBill`,
  `unlinkBill`, `deleteBill`, `addBillAsExpense`, `billFile` = this device then the relay), reminders (`_rescheduleBillRemindersNow`, run inside `rescheduleHeadsUps`' chain, same switch as the
  heads-ups; ids 1020..1039, channel `bills`, text "A return window ends in N days" / "A warranty ends in N days") and the Upcoming rows (`billDateItems`).
  The camera, OCR, PDF pages and Share are behind `bill_inputs.dart` (`BillCamera`, `PictureReader`, `PdfPages`, `ShareInbox`, `BillInputs`, `BillInputs.none()`); `bill_platform.dart` picks
  `bill_inputs_native.dart` (the only file that imports `mobile_scanner`, `google_mlkit_text_recognition`, `receive_sharing_intent`; Android only) or `bill_inputs_web.dart`. The app's own
  channel `budget_wallet/bills` (MainActivity.kt) renders PDF pages (`PdfRenderer`, ≤ 5 pages, PNG at dpi, background thread) and sizes pictures (`toJpeg`, EXIF turned upright).
  Screens: `screens/bills_panel.dart` (Plan › Bills, `pickAndImportBills`), `screens/bill_sheet.dart` (`openBill`, `BillSheet`: an "Unsure" mark on every field of a pdf/photo bill in review,
  Paid by… / Paid in cash, warranty / return-by, `BillFileScreen` = zoomable picture, rendered PDF pages or Save file…, "The file is on the relay; sync to fetch it"),
  `screens/scan_bill.dart` (`scanBillFlow`, `ScanBillScreen`: camera + Take photo = `RepaintBoundary.toImage` of the preview), Add expense › Scan bill (only with a camera), Today's
  `billsToReview` row, the receipt mark on `TxTile(hasBill:)` + "Open bill" in `TxSheet`, Upcoming warranty / return-by rows (`billDateKind`), a "Bills" section in search.
  Logs (counts and enum words only): `bills.import {trigger, source, isNew, read, unsure, items, kept}`, `bill.confirm|edit|dates|link|unlink|delete|cashExpense|file`, `share.received {files}`,
  `scan.cameraFailed {code}`, `bills.remindersScheduled {count}`. Android: CAMERA (declared by mobile_scanner, asked when Scan bill opens), `singleTask` + SEND/SEND_MULTIPLE filters
  for pdf and image; no storage permission. Tests: `test/bills_test.dart` with `test/support/bills.dart` (`FakeBillInputs`, `billsWallet`, `smallPdf`).
  **While `lib/src/bills_shim.dart` exists** the core and readers are stand-ins (see its header); delete it when B1 is merged.
- Nudges: `nudges.dart` (pure: ~14 funny, encouraging lines with no digits or names, `nudgeFor(date)`, `nudgeSlots(now)` = 15:00 on
  weekdays and 11:00 on Sunday for 4 weeks, `NudgePlatform`/`NoNudges`) and `notifier.dart` (native-only: `AndroidNudges` with
  `flutter_local_notifications`, one inexact `zonedSchedule` per slot, no exact-alarm permission; the time zone name comes from
  the `budget_wallet/timezone` channel in MainActivity; POST_NOTIFICATIONS is asked when the switch is turned on). Everything but
  Android gets `NoNudges` (the switch is off with a note). The controller schedules again on start and resume. A reminder never
  carries amounts, merchants or names. Tests use `FakeNudges` (`test/support/wallet.dart`) through `forTest(nudges:)`.
- Save-key prompt (S3): `screens/key_backup.dart` (`KeyBackupSheet` via `showSheet`: why, QR + key text, Copy key, "I saved it" → type the last 4 characters, Later; `KeyBackupRow` = Today's
  notice). Controller: `keyBackupRowVisible`, `takeKeyBackupPrompt()` (true once after `createWallet`; `HomeShell.initState` opens the sheet), `confirmKeyBackup(typed)`,
  `snoozeKeyBackup()` (7 days), `copyKeyBackup()` (clipboard cleared after 60 s if it still holds the key; `clipboardWrite/Read` swappable in tests). Device-local values
  `keyBackupConfirmed`, `keyBackupSnoozedUntil`; `joinWallet` marks confirmed. Logs `key.backup {shown|copied|confirmed|snoozed}`, nothing else. Tests: `test/key_backup_test.dart`.
  Tests that need a clean Today call `wc.snoozeKeyBackup()`; integration helpers call `wc.takeKeyBackupPrompt()` after `createWallet`.
- `lib/src/file_chooser.dart` — `FileChooser`: the system file/folder/save dialogs behind one injectable class. They can throw
  (Linux without xdg-desktop-portal), so every call site catches, logs the type and shows `chooserFailedMessage`.
- `lib/src/theme.dart` — the D3 Ledger theme (`docs/design/ledger-spec.md`): `WalletColors` (paper/ink tokens incl. `lineStrong`; light and
  night ledger, following the system), `contrastRatio`, `numStyle` (IBM Plex Mono + tabular figures: every amount uses it), `buildTheme`
  (all component themes live there: buttons radius 3, chips/inputs radius 2, dialog/sheet/nav/snackbar), `accentOutlined` (the old tonal
  button), `marginLineColor`. Fonts: six unmodified IBM Plex TTFs in `assets/fonts/` + `OFL.txt` (licence registered in `main()`;
  source and version in `third_party/fonts/README.md`). No `Card`, no pills, no shadows: ruled lines instead.
- `lib/src/screens/*.dart` — one file per tab; `budgets.dart` is Plan's "Budgets per category" panel (`BudgetsPanel`: one field per fixed/flex
  category, empty = no budget, "Suggest" fills only empty fields, only edited fields are saved, nothing written when nothing changed). `lib/src/widgets/` — `charts.dart` (fl_chart charts, `CategoryBars`, `RuledBar`, `PaceBar`),
  `common.dart` (`Panel` = ruled section, `SectionHead`, `Eyebrow`, `Heading`, `TotalRule`/`DoubleRule`, `TxTile` + `TxHeaderRow`
  (Date | Particulars | Amount columns, stacked above text scale 1.15), `LineItem`, `Rows`, `SplitRow`, `HeadingRow`, `Tag`, `LedgerLogo`,
  `NavBarFrame` (bar top rule + accent mark), `MarginLine` (red margin rule, wide windows only), `toast`),
  `sheets.dart` (bottom sheets: add expense, transaction details, goal).
- `lib/src/format.dart` — money/date formatting and parsing (unit-tested in `test/widget_test.dart`).
- `key_store.dart` — wallet key: `key_store_io.dart` = system keystore (phones) or a private file (desktop); `key_store_web.dart` = the
  browser (see Web build). Same members everywhere: `read`, `write(key, {passphrase})`, `forget`, `isLocked`, `unlock`.
- `logging.dart` — `AppLog`: console (`debugPrint` → logcat) + a `LogBackend` (`log_backend_io.dart`: `RotatingFileSink` in
  `<app support>/logs/`; `log_backend_web.dart`: `MemoryLogSink`), error hooks,
  frame/memory/lifecycle monitors, `logNav` (UI actions), `loggedRoute` (sheets), `fileExt`. `main.dart`'s `bootstrap()`
  sets it up and logs the `app.start` phases. Plan › Diagnostics (`screens/diagnostics.dart`): level, save, clear.

## Web build (`flutter build web`, localhost only)
Same app and wallet logic; the files that touch the OS come in pairs chosen by `dart.library.js_interop` (`x.dart` re-exports
`x_io.dart` or `x_web.dart`; nothing on the web path imports `dart:io`):
- `wallet_db.dart` — `openWalletDb()` → `WalletDb {repo, persist(), forget()}`. io: `wallet.db` in the support folder (`persist` does
  nothing, `forget` deletes the file). web: `sqlite3.wasm` (served next to `index.html`) on an `IndexedDbFileSystem('budget-wallet')`;
  changes sit in memory until `persist()` = `fs.flush()`; `forget` closes, drops the file system and deletes the IndexedDB database.
  The controller flushes from `notifyListeners()` (once within 800 ms of the first change) and in `persistNow()` (tab hidden/inactive/paused
  via `HomeShell`'s lifecycle listener). Nothing can be flushed synchronously on `beforeunload`; a hidden tab is the last safe point.
  One tab only: web `openWalletDb()` first takes the Web Lock `bw-wallet` (`ifAvailable`, kept for the page's life); if another tab has it, it throws
  `WalletInUse` and `WalletController.load` returns `inUseElsewhere` (empty in-memory repo, nothing opened) → `InUseScreen` (Reload = `page_reload.dart`).
- `key_store_web.dart` + `key_vault.dart` (pure Dart, tested on the VM with maps for the two storages): the key is wrapped with a
  passphrase (PBKDF2-HMAC-SHA256, 310000 rounds, random 16-byte salt, then core's `seal`) into localStorage as
  `bwk1.<rounds>.<salt>.<sealed>`; unlocking puts the plain key into sessionStorage (this tab only). `KeyStore.isLocked` = wrapped key
  but nothing in sessionStorage → `UnlockScreen` (`wc.locked`, `wc.unlock`, `WrongPassphrase`). Onboarding on web asks for a passphrase
  (2 fields, ≥ 8 characters) after "Start a new wallet" / "Use my wallet key". Logs: `store: 'browser'`, found/locked flags only.
- `log_backend_web.dart` — `MemoryLogSink` (1 MB, newest lines); Plan › Diagnostics "Save logs…" downloads them through `FileChooser.saveText`.
- `nudge_platform_web.dart` (`NoNudges`). Plan hides Nudges when `isWeb` and adds "This browser"
  (Show wallet key, Forget this browser → `ForgetBrowserSheet` → `wc.forgetBrowser()`: deletes database + key, opens an empty database, app
  returns to onboarding). Backup works the same everywhere (see Polish above).
  File downloads in a browser return null from `FilePicker.saveFile`, so `FileChooser` answers with the file name there.
- `platform.dart` `isWeb` (= `kIsWeb`; tests set `debugIsWebOverride = true` to run the web branches on the VM and must reset it).
- Tests: `test/web_test.dart` (screens, controller paths, flush with fakes), `test/key_vault_test.dart` (wrap/unwrap, locked state). The
  browser itself (IndexedDB, downloads, wasm) is covered by `tools/build.sh web-test`, not by the VM tests.

## Encrypted local database in the app (R6b)
The wallet database opens **only once the key is known**, always keyed with `localDbKey(key)` (`wallet_db.dart`: `claimWalletDb()`,
`walletDbExists()`, `setAsideWalletDb(stamp)`, `openWalletDb(dbKey)` → `WalletDb {repo, converted, persist, forget}`).
`WalletController.load` claims the web tab lock, reads the key, then: key found → keyed open (an older plaintext file is converted on that
start; logs `db.open {keyed, converted, ms}`); no key (onboarding, web locked) → `WalletRepo.inMemory()` placeholder (`_dbPending`),
and `createWallet` / `joinWallet` / `unlock` write the key, open the file db (`_openFileDb`) and switch to it (`_useDb`: relay URL and
data reload from it). `forgetBrowser` deletes the db + key and goes back to the placeholder (a new IndexedDB VFS name comes with the next open).
**Never lose data:** (join with no stored key and a plaintext file never converts it: it is set aside first, and create/join set aside *before* writing the key; web forget deletes only `/wallet.db`, set-aside copies stay) a `wallet.db` that exists with no key, or that the key does not open (`WalletDbKeyException`), is left untouched
(`hasUnopenedDb`; onboarding shows "An older wallet is on this device. Join with its key to open it."). Joining with the key that opens it uses
it; creating a wallet (or joining with another key) moves it to `wallet.db.unopened-<yyyy-mm-dd>` (+ `-wal`/`-shm`/`-journal`/`.plain-copy`;
web: copied inside IndexedDB) and logs `db.setAside` (no paths). Web: one `IndexedDbFileSystem` per generation (`vfsName` `indexeddb-<n>`),
registered without `makeDefault`, opened via `openKeyed(() => sqlite.open('/wallet.db', vfs: 'multipleciphers-<name>'), dbKey)`.
Tests: `test/db_open_test.dart` (load/create/join/unlock/forget flows with a fake disk), `test/wallet_db_io_test.dart` (real files in a temp
folder via `walletDbDirOverride`), `test/web/wallet_db_web_test.dart` (`tools/build.sh web-test`: real IndexedDB, wrong key, converted
unkeyed db, set aside, forget + reopen).

## Encrypted database plumbing (stage R1)
`sqlite3` 3.x + `hooks: user_defines: sqlite3: source: sqlite3mc` in `pubspec.yaml` (also in `packages/wallet_core/pubspec.yaml` for
`dart test`) = SQLite3 Multiple Ciphers on Android, Linux and (via `sqlite3mc.wasm`, pinned in `dev/sqlite3-wasm.sha256`, served as
`sqlite3.wasm`) the web; `sqlite3_flutter_libs` is gone. Key right after open: `db.execute('PRAGMA key = "x\'<64 hex>\'"')`; wrong or missing
key fails on the first read (`SqliteException` 26 "file is not a database"); plaintext → encrypted in place: open unkeyed, `PRAGMA rekey = "<key>"`.
**Web: the key only works on the wrapped VFS** `sqlite.open(path, vfs: 'multipleciphers-${fs.name}')` after `registerVirtualFileSystem(fs)`
(no `makeDefault`); the default VFS says "Encryption is not supported by the VFS". After `unregisterVirtualFileSystem`, open the next
`IndexedDbFileSystem` with another `vfsName`. Proofs: `packages/wallet_core/test/encrypted_db_test.dart`, `test/web/encrypted_db_test.dart`.

## Rules
- **No `dart:io` in `main.dart`, `screens/`, `widgets/`, `layout.dart` or `platform.dart`** (they must build for the web;
  `test/platform_test.dart` checks it). File and folder work goes into the native-only files
  (`controller.dart` via `wallet_db.dart`, `key_store_io.dart`, `log_backend_io.dart`, `file_chooser.dart`). OS facts for logs: `nativeInfo()`.
- New screen state comes from the controller; don't open the database from a widget.
- Text is short and plain (the owner often uses the app by voice and on a phone).
- Android release builds are signed by the fixed key (see root `CLAUDE.md`); don't touch signing here.
- Log new actions and every catch block (`logEvent`/`logError`/`logNav`, loggers `bw.<area>`). Safe fields only:
  counts, ms, sizes, built-in categories, dates, setting keys, enum words. Never amounts, descriptions, merchants,
  notes, goal/wish names, the key, paths or file names. `integration_test/screens_test.dart` checks the emulator log.

## Tests
- `integration_test/perf_test.dart` + `test_driver/perf_driver.dart` (host side) + `test_driver/perf_budget.dart` (pure budgets,
  unit-tested in `test/`): profile-mode frame performance, `tools/build.sh perf`. Actions are `binding.traceAction`
  reports keyed `perf_<action>`; add an action there and the driver picks it up. Budgets (`PerfBudget`, per-action map
  `budgets` in the driver) are set from baseline runs in `history/perf.jsonl`. It needs `flutter drive --profile`, so
  outside it the test skips itself (`desktop-test` and `emulator.sh` run every file).
- `test/adaptive_test.dart` (four window sizes × two text scales), `test/adaptive_edge_test.dart` (boundaries, shortcuts, dialogs,
  resizing), helpers in `test/support/layout.dart`; `integration_test/adaptive_test.dart` takes desktop screenshots at
  1280×800, 1920×1080 and 800×1280 (`tools/build.sh desktop-test adaptive`). Tests find tabs with `tapTab`/`navTab`: they work for the bar and the rail.
- `test/budgets_plan_test.dart` (the editor), `test/budgets_screens_test.dart` (Spending rows, Today line, controller caching); the
  `budgetWallet()` helper in `test/support/wallet.dart` has a fixed clock (20 Oct 2026) and known amounts.
- `test/habits_test.dart` (controller, Today card and bills line, ReviewScreen steps, Plan chips/bills/nudges, layout at 320 dp @ 2.0, 360 and
  1280), `test/nudges_test.dart` (texts, slots), `test/notifier_test.dart` (the Android plugin through its method channel); the
  `habitsWallet()` helper (20 Oct 2026, a bill candidate, three unconfirmed card rows, a ready wish) and `FakeNudges` are in `test/support/wallet.dart`.
- `test/theme_*_test.dart` — the Ledger theme: contrast ratios of every token, structure (no `Card`, nav by width, Panel without radius), text
  scale 2.0 at 320/360 with the real fonts, amounts in Plex Mono with tabular figures and a shared right edge, the six font files and `OFL.txt`.
- `test/sync_relay_test.dart` (texts, controller, two controllers through one `MemoryTransport`, Plan › Sync, join with an address), `test/backup_test.dart` (save/restore through a fake chooser).
- `test/` — formatting and widget tests. Run: `tools/build.sh test` (format check, `flutter analyze`, `flutter test`).
