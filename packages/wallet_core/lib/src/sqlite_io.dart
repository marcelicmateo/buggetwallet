// Native SQLite (dart:ffi): what `WalletRepo.open` and `WalletRepo.inMemory` use. The web twin is `sqlite_web.dart`.
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' show OpenMode, sqlite3;

import 'local_db.dart';
import 'logs.dart';

final _log = Logger('bw.db');

/// Opens (or creates) the database file at [path].
CommonDatabase openFileDb(String path) => sqlite3.open(path);

/// A fresh in-memory database.
CommonDatabase openMemoryDb() => sqlite3.openInMemory();

/// Runs [read] in a new isolate on a second connection to the database file at [path] (keyed with [dbKey] when given),
/// read-only (`PRAGMA query_only`) and inside one read transaction, so every query sees one committed state (a WAL
/// snapshot) whatever the main connection commits meanwhile. [read] must be a top-level or static function (it is
/// sent to the isolate). The file must exist (never created here); errors come back as the future's error.
Future<T> readInIsolate<T>(String path, List<int>? dbKey, T Function(CommonDatabase db) read) => Isolate.run(() {
      final db = sqlite3.open(path, mode: OpenMode.readWrite);
      try {
        if (dbKey != null) keyConnection(db, dbKey);
        db
          ..execute('PRAGMA query_only = ON')
          ..execute('PRAGMA busy_timeout = 5000')
          ..execute('BEGIN');
        try {
          return read(db);
        } finally {
          if (!db.autocommit) db.execute('COMMIT'); // a failed read may have ended it: keep its own error
        }
      } finally {
        db.close();
      }
    }, debugName: 'bw.read');

/// Suffix of the plaintext side copy kept while a database file is being encrypted ([openKeyedFileDb]).
const plainCopySuffix = '.plain-copy';

/// Opens the database file at [path] keyed with [dbKey] ([openKeyed]). Converting a plaintext file is crash-safe: once
/// the plaintext database is complete in its main file (WAL checkpointed), it is copied to `<path>.plain-copy` (via a
/// temp file + rename, so the copy exists only when whole), then rekeyed, reopened keyed and checked (row counts per
/// table), and only then the copy is deleted. A copy found at the next open means the conversion was interrupted: the
/// main file (and any `-wal`/`-shm`/`-journal`) is replaced by the copy and the conversion runs again. A failed rekey
/// or check restores the copy at once and rethrows. [step] is a test hook (`copied`, `rekeyed`, `verified`).
CommonDatabase openKeyedFileDb(String path, List<int> dbKey, {void Function(String step)? step}) {
  final copy = File('$path$plainCopySuffix');
  final tmp = File('$path$plainCopySuffix.tmp');
  if (tmp.existsSync()) tmp.deleteSync(); // a copy that never completed: the main file was not touched yet
  if (copy.existsSync()) _restore(path, copy, 'db.encrypt.recovered');
  return openKeyedWith(
    () => sqlite3.open(path),
    dbKey,
    beforeRekey: () {
      File(path).copySync(tmp.path);
      tmp.renameSync(copy.path);
      step?.call('copied');
    },
    step: step,
    onFailed: () => _restore(path, copy, 'db.encrypt.restored'),
    onVerified: () {
      step?.call('verified');
      copy.deleteSync();
    },
  );
}

/// Puts the plaintext side copy back as the database file (no connection may be open on [path]).
void _restore(String path, File copy, String event) {
  for (final s in ['', '-wal', '-shm', '-journal']) {
    final f = File('$path$s');
    if (f.existsSync()) f.deleteSync();
  }
  copy.renameSync(path);
  logEvent(_log, Level.WARNING, event);
}
