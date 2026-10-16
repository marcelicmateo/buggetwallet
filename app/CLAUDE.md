# app — notes for Claude

Flutter UI for Android, iOS, Windows, macOS, Linux. **No money logic here**: calculations belong in
`wallet_core` (with unit tests); the app formats and displays them.

## Files
- `lib/main.dart` — app shell, bottom navigation (Today, Spending, Wishlist, Goals, Plan).
- `lib/src/controller.dart` — `WalletController` (ChangeNotifier): owns the `WalletRepo`, the cached lists,
  sync timers. Screens call controller methods; the controller calls the repo and `notifyListeners()`.
- `lib/src/screens/*.dart` — one file per tab. `lib/src/widgets/` — `charts.dart` (fl_chart), `common.dart`,
  `sheets.dart` (bottom sheets: add expense, transaction details, goal).
- `lib/src/format.dart` — money/date formatting and parsing (unit-tested in `test/widget_test.dart`).
- `key_store.dart` — wallet key in the system keystore (phones) or a private file (desktop).
- `storage_access.dart` — Android "All files access" channel for the Syncthing folder.

## Rules
- New screen state comes from the controller; don't open the database from a widget.
- Text is short and plain (the owner often uses the app by voice and on a phone).
- Android release builds are signed by the fixed key (see root `CLAUDE.md`); don't touch signing here.

## Tests
- `test/` — formatting and widget tests. Run: `tools/build.sh test` (format check, `flutter analyze`, `flutter test`).
