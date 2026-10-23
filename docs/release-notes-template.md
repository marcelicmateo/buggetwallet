# Release notes template

Copy into the GitHub release body. Delete the sections that do not apply; keep the three standing notes.

## Budget Wallet <version>

### What's new
- <one line per user-visible change, in the owner's words>

### Fixes
- <one line per fix>

### Before you update

- **Update every device before the relay prunes a silent one (90 days).** A device upgraded later replays from a snapshot. A device on an older version
  keeps working on its own data but may be unable to read what newer devices write until it is updated.
- **Schema bump (only when the database schema version changes).** The first start after the update migrates the local
  database and replays the change log once; this can take a moment on a large wallet. Do not close the app meanwhile.
  Older versions cannot open a migrated database, so there is no downgrade: install over the app, never uninstall
  (uninstalling wipes the wallet). State the old and new schema numbers here: <old> -> <new>.
- **Relay restore warning.** If you restore the relay from a backup, restore the whole data folder from one moment. A
  half-restored relay can hand devices older sealed files than they already have; restoring the relay does not undo
  changes already merged on a device. After a restore, open the app on each device and check Plan > Sync before
  editing anything.

### Install
- Android: download `BudgetWallet-android.apk` and install it over the existing app (same signing key, the wallet stays).
- Linux: unpack `BudgetWallet-linux-x64.tar.gz` and run `bundle/budget_wallet`.

### Known issues
- <none, or one line each>
