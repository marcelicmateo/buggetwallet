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
  the day changed, so a wallet without a sync folder also moves on at midnight.
- `lib/src/file_chooser.dart` — `FileChooser`: the system file/folder/save dialogs behind one injectable class. They can throw
  (Linux without xdg-desktop-portal), so every call site catches, logs the type and shows `chooserFailedMessage`.
- `lib/src/theme.dart` — the D3 Ledger theme (`docs/design/ledger-spec.md`): `WalletColors` (paper/ink tokens incl. `lineStrong`; light and
  night ledger, following the system), `contrastRatio`, `numStyle` (IBM Plex Mono + tabular figures: every amount uses it), `buildTheme`
  (all component themes live there: buttons radius 3, chips/inputs radius 2, dialog/sheet/nav/snackbar), `accentOutlined` (the old tonal
  button), `marginLineColor`. Fonts: six unmodified IBM Plex TTFs in `assets/fonts/` + `OFL.txt` (licence registered in `main()`;
  source and version in `third_party/fonts/README.md`). No `Card`, no pills, no shadows: ruled lines instead.
- `lib/src/budget_shim.dart` — TEMPORARY stand-in for the wallet_core budget API of feature E1 (`BudgetVsActual`, `budgetVsActual`,
  `suggestBudgets`, budgets read from the settings table). Delete it when core is merged, with every line marked `SHIM`.
- `lib/src/screens/*.dart` — one file per tab; `budgets.dart` is Plan's "Budgets per category" panel (`BudgetsPanel`: one field per fixed/flex
  category, empty = no budget, "Suggest" fills only empty fields, only edited fields are saved, nothing written when nothing changed). `lib/src/widgets/` — `charts.dart` (fl_chart charts, `CategoryBars`, `RuledBar`, `PaceBar`),
  `common.dart` (`Panel` = ruled section, `SectionHead`, `Eyebrow`, `Heading`, `TotalRule`/`DoubleRule`, `TxTile` + `TxHeaderRow`
  (Date | Particulars | Amount columns, stacked above text scale 1.15), `LineItem`, `Rows`, `SplitRow`, `HeadingRow`, `Tag`, `LedgerLogo`,
  `NavBarFrame` (bar top rule + accent mark), `MarginLine` (red margin rule, wide windows only), `toast`),
  `sheets.dart` (bottom sheets: add expense, transaction details, goal).
- `lib/src/format.dart` — money/date formatting and parsing (unit-tested in `test/widget_test.dart`).
- `key_store.dart` — wallet key in the system keystore (phones) or a private file (desktop).
- `logging.dart` — `AppLog`: console (`debugPrint` → logcat) + `RotatingFileSink` in `<app support>/logs/`, error hooks,
  frame/memory/lifecycle monitors, `logNav` (UI actions), `loggedRoute` (sheets), `fileExt`. `main.dart`'s `bootstrap()`
  sets it up and logs the `app.start` phases. Plan › Diagnostics (`screens/diagnostics.dart`): level, save, clear.
- `storage_access.dart` — Android "All files access" channel for the Syncthing folder.

## Rules
- **No `dart:io` in `main.dart`, `screens/`, `widgets/`, `layout.dart` or `platform.dart`** (they must build for the web later;
  `test/platform_test.dart` checks it). File and folder work goes into the controller or the native-only files
  (`controller.dart`, `key_store.dart`, `logging.dart`, `file_chooser.dart`). OS facts for logs: `nativeInfo()`.
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
- `test/theme_*_test.dart` — the Ledger theme: contrast ratios of every token, structure (no `Card`, nav by width, Panel without radius), text
  scale 2.0 at 320/360 with the real fonts, amounts in Plex Mono with tabular figures and a shared right edge, the six font files and `OFL.txt`.
- `test/` — formatting and widget tests. Run: `tools/build.sh test` (format check, `flutter analyze`, `flutter test`).
