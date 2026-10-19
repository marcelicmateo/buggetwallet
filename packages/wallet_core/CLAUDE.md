# wallet_core — notes for Claude

Pure Dart (no Flutter): SQLite repo, field-level change log with HLC, encrypted folder sync, categories,
budget engine. **All money logic lives here**, so it can be unit-tested without the UI.

## Files
- `repo.dart` — `WalletRepo`: schema, reads, and every write. Writes go through `_write(...)` so each one
  becomes a sync op; never `db.execute` an INSERT/UPDATE on a data table directly.
- `budget.dart` — period maths: `PeriodBudget` (safe to spend), `MonthSummary`, `Affordability`.
- `categories.dart` — `Categorizer`: item override → merchant rules → patterns → built-in rules.
- `matching.dart` — `planMatches`: hand-added expense ↔ bank row (same amount, ±3 days, one-to-one), deterministic;
  only a bank row the adding device did not hold yet replaces the entry (`SeenBank`: the entry's synced `seen_bank`,
  per device the highest bank `amount` clock held at add time; older entries: rows written after the entry). A match
  is reopened only when its bank row is deleted, never because the row has not arrived yet; until it arrives, reads
  mark the entry `Tx.matchPending` and it counts (`Tx.live`). `WalletRepo` runs it after imports, deletes and
  `applyRemote` (FolderSync: once per run, `runPendingMatch`), loading only candidate rows.
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

## Known limits (for the sync redesign)
- The same export imported on two devices before they sync: the later import's `amount` clock wins, so a cash entry
  added in between on the first device can be matched to that row although that device held it.
- A damaged sync file skipped while later files from the same device apply: `seen_bank` (per-device maximum) then
  claims rows the adding device never got, those never replace the entry, and the expense counts twice.
- Older builds ignore `seen_bank` and match by the old rule: devices on mixed versions can plan different matches.
- A device that is behind can match a cash entry to an earlier same-amount card payment (±3 days) it never held.

## Tests
- `test/core_test.dart`, one `group` per area. Shared synthetic data in `test/support/synthetic.dart`
  (`n(...)` builds a transaction, `january` is a sample month). Add new feature tests as `test/<feature>_test.dart`.
- Run: `tools/build.sh test` from the repo root (or `tools/build.sh shell`, then `cd packages/wallet_core && dart test`).
