import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/wasm.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:web/web.dart' as web;

import 'wallet_db_base.dart';

final _log = Logger('bw.app');

const _dbName = 'budget-wallet';
const _lockName = 'bw-wallet';
WasmSqlite3? _sqlite;

/// Where `sqlite3.wasm` is served; a browser test points it at its own server.
@visibleForTesting
Uri sqliteWasmUri = Uri.parse('sqlite3.wasm');
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

/// One IndexedDB file system at a time. Every one gets a new `vfsName` (the wrapper VFS `multipleciphers-<name>` outlives
/// `unregisterVirtualFileSystem`; registering the same name again fails with "null function"). Registered without `makeDefault`:
/// the encryption only works on the wrapped VFS.
int _generation = 0;
IndexedDbFileSystem? _fs;

Future<(WasmSqlite3, IndexedDbFileSystem)> _store() async {
  final sqlite = _sqlite ??= await WasmSqlite3.loadFromUrl(sqliteWasmUri);
  var fs = _fs;
  if (fs == null || fs.isClosed) {
    fs = await IndexedDbFileSystem.open(dbName: _dbName, vfsName: 'indexeddb-${_generation++}');
    sqlite.registerVirtualFileSystem(fs);
    _fs = fs;
  }
  return (sqlite, fs);
}

const _path = '/wallet.db';
const _readOnly = 0x01, _readWriteCreate = 0x02 | 0x04;

/// Takes the tab lock; throws [WalletInUse] when another tab has the wallet. Called first on every start.
Future<void> claimWalletDb() => _takeTabLock();

/// Is there a `wallet.db` in this browser's IndexedDB file system?
Future<bool> walletDbExists({String? dir}) async {
  await _takeTabLock();
  final (_, fs) = await _store();
  return fs.xAccess(_path, 0) != 0;
}

/// Copies `/wallet.db` (and a `-journal`) to `/wallet.db.unopened-<stamp>` and removes the originals. The bytes are copied as
/// they are (encrypted or not); the originals go only after the copy is whole and flushed.
Future<void> setAsideWalletDb(String stamp, {String? dir}) async {
  await _takeTabLock();
  final (_, fs) = await _store();
  var target = '$_path.unopened-$stamp';
  for (var n = 2; fs.xAccess(target, 0) != 0; n++) {
    target = '$_path.unopened-$stamp-$n';
  }
  final moved = <String>[];
  for (final s in ['', '-journal']) {
    if (fs.xAccess('$_path$s', 0) == 0) continue;
    final src = fs.xOpen(Sqlite3Filename('$_path$s'), _readOnly).file;
    final dst = fs.xOpen(Sqlite3Filename('$target$s'), _readWriteCreate).file;
    try {
      final size = src.xFileSize();
      const chunk = 1 << 20;
      for (var off = 0; off < size; off += chunk) {
        final buf = Uint8List(math.min(chunk, size - off));
        src.xRead(buf, off);
        dst.xWrite(buf, off);
      }
      dst.xSync(0);
    } finally {
      src.xClose();
      dst.xClose();
    }
    moved.add('$_path$s');
  }
  await fs.flush();
  for (final f in moved) {
    fs.xDelete(f, 0);
  }
  await fs.flush();
}

/// Is the stored file a plaintext SQLite database? (Read before opening, to log `converted`.)
bool _isPlaintext(IndexedDbFileSystem fs) {
  if (fs.xAccess(_path, 0) == 0) return false;
  final f = fs.xOpen(Sqlite3Filename(_path), _readOnly).file;
  try {
    if (f.xFileSize() < 16) return false;
    final head = Uint8List(16);
    f.xRead(head, 0);
    return String.fromCharCodes(head.sublist(0, 15)) == 'SQLite format 3';
  } finally {
    f.xClose();
  }
}

/// Is the stored wallet an unkeyed one (opening it with any key would convert it)?
Future<bool> walletDbIsPlaintext({String? dir}) async {
  await _takeTabLock();
  final (_, fs) = await _store();
  return _isPlaintext(fs);
}

/// The wallet in the browser: SQLite compiled to WebAssembly (`sqlite3.wasm`, served next to index.html) on an IndexedDB
/// file system, encrypted with [dbKey] (`localDbKey`) through the wrapped VFS. An unkeyed database from an older build is
/// converted. A key that does not open it throws [WalletDbKeyException]. Changes are in memory until [WalletDb.persist]
/// flushes them to IndexedDB.
Future<WalletDb> openWalletDb(Uint8List dbKey, {String? deviceId, String? dir}) async {
  await _takeTabLock();
  final (sqlite, fs) = await _store();
  final converted = _isPlaintext(fs);
  final db = openKeyed(() => sqlite.open(_path, vfs: 'multipleciphers-${fs.name}'), dbKey);
  final repo = WalletRepo.fromDatabase(db, file: true, deviceId: deviceId);
  return WalletDb(
    repo,
    converted: converted,
    persist: fs.flush,
    forget: () async {
      // The repo is already closed. Delete only the wallet file (and its side files): `wallet.db.unopened-*` copies made by
      // [setAsideWalletDb] stay (an older wallet is never deleted). Then drop the file system; the next one gets a new vfsName.
      try {
        for (final s in ['', '-journal', '-wal', '-shm']) {
          if (fs.xAccess('$_path$s', 0) != 0) fs.xDelete('$_path$s', 0);
        }
        await fs.flush();
        sqlite.unregisterVirtualFileSystem(fs);
        if (identical(_fs, fs)) _fs = null;
        await fs.close();
      } catch (e, st) {
        logError(_log, 'db.forgetFailed', e, st);
        rethrow;
      }
    },
  );
}
