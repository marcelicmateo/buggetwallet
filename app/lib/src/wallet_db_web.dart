import 'package:sqlite3/wasm.dart';
import 'package:wallet_core/wallet_core.dart';

import 'core_shim.dart';
import 'wallet_db_base.dart';

final _log = Logger('bw.app');

const _dbName = 'budget-wallet';
WasmSqlite3? _sqlite;

/// The wallet in the browser: SQLite compiled to WebAssembly (`sqlite3.wasm`, served next to index.html) on an IndexedDB
/// file system. Changes are in memory until [WalletDb.persist] flushes them to IndexedDB.
Future<WalletDb> openWalletDb() async {
  final sqlite = _sqlite ??= await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final fs = await IndexedDbFileSystem.open(dbName: _dbName);
  sqlite.registerVirtualFileSystem(fs, makeDefault: true);
  final repo = walletRepoFromDatabase(sqlite.open('/wallet.db'), file: true);
  return WalletDb(
    repo,
    persist: fs.flush,
    forget: () async {
      // The repo is already closed. Drop the file system, then the whole IndexedDB database.
      sqlite.unregisterVirtualFileSystem(fs);
      await fs.close();
      try {
        await IndexedDbFileSystem.deleteDatabase(_dbName);
      } catch (e, st) {
        logError(_log, 'db.forgetFailed', e, st);
        rethrow;
      }
    },
  );
}
