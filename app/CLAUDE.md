# app — notes for Claude

Flutter UI for Android, iOS, Windows, macOS, Linux. **No money logic here**: calculations belong in
`wallet_core` (with unit tests); the app formats and displays them.

## Files
- `lib/main.dart` — app shell, bottom navigation (Today, Spending, Wishlist, Goals, Plan).
- `lib/src/controller.dart` — `WalletController` (ChangeNotifier): owns the `WalletRepo`, the cached lists,
  sync timers. Screens call controller methods; the controller calls the repo and `notifyListeners()`.
- Derived values (`period()`, `payPeriods()`, `spending(month)`) are cached in the controller per `dataVersion` (bumped by
  `reload()`) and day: never compute from `txs` in `build()`. `HomeShell` builds the five pages once per data version and day
  (`'${dataVersion}|${today()}'`), so a tab switch only moves the `IndexedStack` (keep it that way: 20,000 rows made every
  switch miss frames). The controller takes a clock (`forTest(clock:)`); `checkDay()` (resume, 2-minute timer) notifies when
  the day changed, so a wallet without a sync folder also moves on at midnight.
- `lib/src/file_chooser.dart` — `FileChooser`: the system file/folder/save dialogs behind one injectable class. They can throw
  (Linux without xdg-desktop-portal), so every call site catches, logs the type and shows `chooserFailedMessage`.
- `lib/src/screens/*.dart` — one file per tab. `lib/src/widgets/` — `charts.dart` (fl_chart), `common.dart`,
  `sheets.dart` (bottom sheets: add expense, transaction details, goal).
- `lib/src/format.dart` — money/date formatting and parsing (unit-tested in `test/widget_test.dart`).
- `key_store.dart` — wallet key in the system keystore (phones) or a private file (desktop).
- `logging.dart` — `AppLog`: console (`debugPrint` → logcat) + `RotatingFileSink` in `<app support>/logs/`, error hooks,
  frame/memory/lifecycle monitors, `logNav` (UI actions), `loggedRoute` (sheets), `fileExt`. `main.dart`'s `bootstrap()`
  sets it up and logs the `app.start` phases. Plan › Diagnostics (`screens/diagnostics.dart`): level, save, clear.
- `storage_access.dart` — Android "All files access" channel for the Syncthing folder.

## Rules
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
- `test/` — formatting and widget tests. Run: `tools/build.sh test` (format check, `flutter analyze`, `flutter test`).
