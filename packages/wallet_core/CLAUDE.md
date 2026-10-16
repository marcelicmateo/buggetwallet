# wallet_core — notes for Claude

Pure Dart (no Flutter): SQLite repo, field-level change log with HLC, encrypted folder sync, categories,
budget engine. **All money logic lives here**, so it can be unit-tested without the UI.

## Files
- `repo.dart` — `WalletRepo`: schema, reads, and every write. Writes go through `_write(...)` so each one
  becomes a sync op; never `db.execute` an INSERT/UPDATE on a data table directly.
- `budget.dart` — period maths: `PeriodBudget` (safe to spend), `MonthSummary`, `Affordability`.
- `categories.dart` — `Categorizer`: item override → merchant rules → patterns → built-in rules.
- `models.dart` — `Tx`, `Goal`, `WishItem`, `WalletSettings` (row ↔ object).
- `dates.dart` — `YYYY-MM-DD` string helpers. `hlc.dart`, `vault.dart` (key + encryption), `sync.dart` (FolderSync).
- `logs.dart` — logging (`package:logging`): `logEvent`/`logError` (structured events), `formatLogRecord` (one line,
  errors via `describeError`, which drops SQL parameters, paths and FormatException sources), `RotatingFileSink`,
  `timed`/`timedAsync`/`PerfTimer` (on `bw.perf`), `FrameStats`.

## Rules
- Amounts are `int` cents; expenses negative. Dates are `YYYY-MM-DD` strings.
- New table or field: add it to the entity map at the top of `repo.dart` (so it syncs) and to the schema;
  existing devices must still open old databases (add columns, never rename).
- Pure functions for new calculations (inputs → result object), so tests need no database.
- Keep `vault.dart` / `sync.dart` file formats backward compatible (`BWOP1`, `BW1-` keys).
- Logging: loggers `bw.<area>`; every catch block logs (`logError`). Log counts, durations, sizes, dates, built-in
  categories, setting keys. **Never** amounts, descriptions, merchants, notes, goal/wish names, the key, device ids,
  paths or file names. Noisy per-render logs at FINER. `test/logs_impl_test.dart` checks core logs stay clean.

## Tests
- `test/core_test.dart`, one `group` per area. Shared synthetic data in `test/support/synthetic.dart`
  (`n(...)` builds a transaction, `january` is a sample month). Add new feature tests as `test/<feature>_test.dart`.
- Run: `tools/build.sh test` from the repo root (or `tools/build.sh shell`, then `cd packages/wallet_core && dart test`).
