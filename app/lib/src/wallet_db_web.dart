import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:sqlite3/wasm.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:web/web.dart' as web;

import 'wallet_db_base.dart';

final _log = Logger('bw.app');

const _dbName = 'budget-wallet';
const _lockName = 'bw-wallet';
WasmSqlite3? _sqlite;
bool _lockHeld = false;

/// One tab at a time: the IndexedDB file system keeps its own copy of the pages and writes them back later, so a second tab
/// would overwrite the first one's changes. Takes the Web Lock `bw-wallet` for the life of the page (never released; the browser
/// frees it when the tab closes). Throws [WalletInUse] when another tab holds it. Browsers without Web Locks are not guarded.
Future<void> _takeTabLock() async {
  if (_lockHeld) return; // this page took it already (reopening after "Forget this browser")
  final navigator = web.window.navigator as JSObject;
  if (!navigator.has('locks')) return;
  final granted = Completer<bool>();
  final held = Completer<JSAny?>(); // never completes: the lock is kept as long as the page lives
  JSAny? onLock(JSAny? lock) {
    if (lock == null) {
      granted.complete(false);
      return null;
    }
    granted.complete(true);
    return held.future.toJS;
  }

  final request = web.window.navigator.locks.request(_lockName, web.LockOptions(ifAvailable: true), onLock.toJS);
  unawaited(request.toDart.then<void>((_) {}, onError: (Object e, StackTrace st) {
    if (!granted.isCompleted) granted.completeError(e, st);
  }));
  if (!await granted.future) throw const WalletInUse();
  _lockHeld = true;
}

/// The wallet in the browser: SQLite compiled to WebAssembly (`sqlite3.wasm`, served next to index.html) on an IndexedDB
/// file system. Changes are in memory until [WalletDb.persist] flushes them to IndexedDB.
Future<WalletDb> openWalletDb() async {
  await _takeTabLock();
  final sqlite = _sqlite ??= await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final fs = await IndexedDbFileSystem.open(dbName: _dbName);
  sqlite.registerVirtualFileSystem(fs, makeDefault: true);
  final repo = WalletRepo.fromDatabase(sqlite.open('/wallet.db'), file: true);
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
