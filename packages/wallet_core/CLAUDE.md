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

## Rules
- Amounts are `int` cents; expenses negative. Dates are `YYYY-MM-DD` strings.
- New table or field: add it to the entity map at the top of `repo.dart` (so it syncs) and to the schema;
  existing devices must still open old databases (add columns, never rename).
- Pure functions for new calculations (inputs → result object), so tests need no database.
- Keep `vault.dart` / `sync.dart` file formats backward compatible (`BWOP1`, `BW1-` keys).

## Tests
- `test/core_test.dart`, one `group` per area. Shared synthetic data in `test/support/synthetic.dart`
  (`n(...)` builds a transaction, `january` is a sample month). Add new feature tests as `test/<feature>_test.dart`.
- Run: `tools/build.sh test` from the repo root (or `tools/build.sh shell`, then `cd packages/wallet_core && dart test`).
