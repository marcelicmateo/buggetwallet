// Encrypted local database (§4.9): SQLite3MultipleCiphers keyed with a raw 256-bit key derived from the wallet key.
// Web-safe (package:sqlite3/common.dart only); the native file conversion with its side copy is in `sqlite_io.dart`.
import 'dart:typed_data';

import 'package:sqlite3/common.dart';

import 'logs.dart';
import 'vault.dart';

final _log = Logger('bw.db');

/// HKDF info of the local database key (never reused for the relay id or token).
const localDbKeyInfo = 'bw-local-db-v1';

/// The 32-byte key of this wallet's local database: HKDF-SHA256(wallet key, `bw-local-db-v1`). Same on every device
/// holding the wallet key, so no extra prompt is needed.
Future<Uint8List> localDbKey(VaultKey key) => deriveKey(key, localDbKeyInfo);

/// The key does not open this database (it was encrypted with another wallet key). The file is left as it was.
class WalletDbKeyException implements Exception {
  final String message;
  const WalletDbKeyException(this.message);
  @override
  String toString() => 'WalletDbKeyException: $message';
}

/// Returns [open]() keyed with [dbKey]. A plaintext database (older builds, or new and empty) is encrypted in place
/// first. [open] may be called more than once (a connection cannot be un-keyed). Web-safe (CommonDatabase).
///
/// Order: the database is first opened keyed (the normal case); only when that cannot read it is it opened without a
/// key: readable = plaintext → converted with `PRAGMA rekey` (after `journal_mode=DELETE`: sqlite3mc refuses to encrypt
/// a WAL database, and the switch checkpoints the WAL into the main file), then reopened keyed and checked (same row
/// count in every table); not readable either → [WalletDbKeyException]. A new or empty database is keyed from the start.
///
/// Crash safety without file copies (the web path): the rekey is one write transaction on the rollback journal (an
/// encrypt-in-place rewrites every page; a reserve-size change runs as a VACUUM, also one transaction), so an interrupted
/// conversion leaves a hot journal of plaintext pages; the next open's keyed attempt cannot read it, the unkeyed one
/// rolls it back to the plaintext database and converts again. Checked once by hand (R6a, sqlite3mc 2.6.1, native, same
/// code as the wasm build): a 53 MB plaintext database, the converting process killed with SIGKILL after 20 ms to 2.4 s
/// (two kills left a hot journal): every next `openKeyed` returned all rows, `integrity_check` ok. Probing with the wrong
/// keying never loses an un-checkpointed WAL (both ways, `test/local_db_test.dart`). The native `WalletRepo.open` adds
/// a side copy on top (`sqlite_io.dart`).
/// A failed check after the rekey is a [StateError] (nothing is returned that holds fewer rows than before).
CommonDatabase openKeyed(CommonDatabase Function() open, List<int> dbKey) => openKeyedWith(open, dbKey);

/// [openKeyed] with the native side-copy steps: [beforeRekey] runs once the plaintext database is complete in its main
/// file (WAL checkpointed and removed) and before it is changed; [onFailed] when the rekey threw or the check failed
/// (before the error propagates); [onVerified] after the check passed. [step] is a test hook called with `rekeyed`.
CommonDatabase openKeyedWith(
  CommonDatabase Function() open,
  List<int> dbKey, {
  void Function()? beforeRekey,
  void Function()? onFailed,
  void Function()? onVerified,
  void Function(String step)? step,
}) {
  if (dbKey.length != 32) throw ArgumentError.value(dbKey.length, 'dbKey', 'must be 32 bytes');
  final pragmaKey = "\"x'${dbKey.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join()}'\"";
  final t = PerfTimer('db.openKeyed');
  final keyed = open();
  final bool ok;
  try {
    keyed.execute('PRAGMA key = $pragmaKey');
    ok = _readable(keyed);
  } catch (_) {
    keyed.close();
    rethrow;
  }
  if (ok) {
    t.done({'converted': false});
    return keyed;
  }
  keyed.close();

  final plain = open();
  var plainOpen = true;
  try {
    if (!_readable(plain)) {
      logEvent(_log, Level.WARNING, 'db.key.wrong');
      throw const WalletDbKeyException('the key does not open this database');
    }
    final before = _rowCounts(plain);
    final mode = plain.select('PRAGMA journal_mode=DELETE').first.values.first;
    if (mode == 'wal') throw StateError('local database busy: cannot leave WAL mode to encrypt it');
    beforeRekey?.call();
    try {
      plain.execute('PRAGMA rekey = $pragmaKey');
    } catch (e, st) {
      logError(_log, 'db.encrypt.failed', e, st);
      plain.close();
      plainOpen = false;
      onFailed?.call();
      rethrow;
    }
    step?.call('rekeyed');
    plain.close();
    plainOpen = false;

    final db = open();
    try {
      db.execute('PRAGMA key = $pragmaKey');
      final after = _readable(db) ? _rowCounts(db) : null;
      if (after == null || !_sameCounts(before, after)) {
        logEvent(_log, Level.SEVERE, 'db.encrypt.checkFailed', {'tables': before.length});
        throw StateError('local database encryption check failed');
      }
    } catch (_) {
      db.close();
      onFailed?.call();
      rethrow;
    }
    try {
      onVerified?.call();
    } catch (_) {
      db.close();
      rethrow;
    }
    t.done({'converted': true, 'tables': before.length, 'rows': before.values.fold<int>(0, (a, b) => a + b)});
    logEvent(_log, Level.INFO, 'db.encrypt', {'tables': before.length});
    return db;
  } finally {
    if (plainOpen) plain.close();
  }
}

/// Whether [db] can read its schema: false for "file is not a database" (wrong key, a key on a plaintext file, no key
/// on an encrypted one); other errors are rethrown (the caller closes [db]).
bool _readable(CommonDatabase db) {
  try {
    db.select('SELECT count(*) FROM sqlite_master');
    return true;
  } on SqliteException catch (e) {
    if ((e.extendedResultCode & 0xff) == 26) return false;
    rethrow;
  }
}

Map<String, int> _rowCounts(CommonDatabase db) => {
      for (final r in db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"))
        r['name'] as String: db.select('SELECT count(*) AS n FROM "${r['name']}"').first['n'] as int,
    };

bool _sameCounts(Map<String, int> a, Map<String, int> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
