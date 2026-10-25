import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/common.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'bills.dart';
import 'categories.dart';
import 'dates.dart';
import 'hlc.dart';
import 'logs.dart';
import 'matching.dart';
import 'models.dart';
import 'recurring.dart';
import 'schema.dart';
import 'search.dart' show foldText;
import 'sqlite_io.dart' if (dart.library.js_interop) 'sqlite_web.dart' as sqlite;
import 'tags.dart';
import 'transfers.dart';

part 'repo_accounts.dart';
part 'repo_bills.dart';
part 'repo_categories.dart';
part 'repo_blobs.dart';
part 'repo_planned.dart';
part 'repo_settings.dart';
part 'repo_tags.dart';

/// One field-level change. This is what syncs between devices.
class Op {
  final String entity;
  final String id;
  final Map<String, Object?> fields;
  final String hlc;
  const Op(this.entity, this.id, this.fields, this.hlc);

  Map<String, Object?> toJson() => {'e': entity, 'id': id, 'f': fields, 'h': hlc};
  static Op fromJson(Map<String, Object?> j) =>
      Op(j['e'] as String, j['id'] as String, Map<String, Object?>.from(j['f'] as Map), j['h'] as String);
}

class ImportSummary {
  final int added, duplicates, matched, skipped;

  /// Rows whose id this wallet already holds with another amount or description (an id collision: the row is
  /// skipped like a duplicate and logged as `repo.idCollision` with the count only). Counted in [duplicates] too.
  final int collisions;

  /// Pairs of own-account transfers found after this import ([planTransfers]).
  final int transfers;
  const ImportSummary(this.added, this.duplicates, this.matched, this.skipped, {this.transfers = 0, this.collisions = 0});
}

final _log = Logger('bw.repo');

/// The wallet database on one device. All writes go through [_write] so they are
/// recorded as [Op]s and can be synced; remote ops come in through [applyRemote].
class WalletRepo {
  /// The open database (`package:sqlite3/common.dart`, so the same code runs on the native and the WASM build).
  final CommonDatabase db;
  late final String deviceId;
  late final HlcClock clock;
  bool _created = false;

  WalletRepo._(this.db, int Function()? now, String? givenId) {
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute(schemaSql);
    // Columns added after the first release (CREATE TABLE IF NOT EXISTS leaves an older table as it was).
    for (final e in entitySchema.values) {
      final have = {for (final r in db.select('PRAGMA table_info(${e.table})')) r['name'] as String};
      for (final c in e.columns) {
        if (!have.contains(c.name)) db.execute('ALTER TABLE ${e.table} ADD COLUMN ${c.ddl}');
      }
    }
    if (givenId != null && !_deviceIdPattern.hasMatch(givenId)) {
      throw ArgumentError.value('(hidden)', 'deviceId', 'must be 1..48 of A-Z a-z 0-9');
    }
    var dev = _meta('device_id');
    if (dev == null) {
      dev = givenId ?? newDeviceId();
      _setMeta('device_id', dev);
      _created = true;
    } else if (givenId != null && givenId != dev) {
      // H6: this install has its own id (kept next to the key, not in the database), so a copied database does not
      // write into another install's seq stream. The old id's outbox and everything else go out again as this id's
      // first connect (the whole state, clocks unchanged), and the old id's own files are read like a peer's.
      _setMeta('device_id', givenId);
      final unsent = db.select('SELECT COUNT(*) AS n FROM outbox').first['n'] as int;
      // The old id's stream stays one this install wrote (SyncEngine.streamsKey: acked as, so it never holds back
      // pruning); the new id starts with no stream and a first connect (SyncEngine.sentKey, streamKey, sendingKey).
      final sent = int.tryParse(_meta('local.syncSent') ?? '');
      final sending = _meta('local.syncSending');
      final wrote = sent != null || sending != null;
      final old = _meta('local.syncStream') ?? dev;
      Object? decode(String key, Object? empty) {
        try {
          return jsonDecode(_meta(key) ?? jsonEncode(empty));
        } on Object catch (e, st) {
          logError(_log, 'repo.streams.unreadable', e, st, fields: {'key': key});
          return empty;
        }
      }

      if (wrote) {
        final streams = decode('local.syncStreams', const []);
        final list = streams is List ? streams : const <Object?>[];
        if (!list.contains(old)) _setMeta('local.syncStreams', jsonEncode([...list, old]));
        // The highest seq this install may have stored there (SyncEngine.streamLastKey): should the stream grow past it,
        // another install (the original of a copied database) writes it, and this install stops acking as it.
        var last = sent ?? 0;
        final sd = decode('local.syncSending', const {});
        final parts = sd is Map ? sd['parts'] : null;
        if (parts is Map) {
          for (final k in parts.keys) {
            last = max(last, int.tryParse('$k') ?? 0);
          }
        }
        final at = decode('local.syncStreamLast', const {});
        _setMeta('local.syncStreamLast', jsonEncode({if (at is Map) ...at, old: last}));
      }
      db.execute("DELETE FROM meta WHERE key IN ('local.syncSent', 'local.syncStream', 'local.syncSending')");
      logEvent(_log, Level.WARNING, 'repo.deviceId.changed', {'outbox': unsent});
      dev = givenId;
    }
    deviceId = dev;
    clock = HlcClock(dev, now: now, last: _meta('hlc'));
    // H7 guard base: the highest wall-clock reading this device wrote with (never a peer's clock): device-local meta
    // `wall_high`, raised by every write (an open changes nothing in the file).
    _wallHigh = int.tryParse(_meta('wall_high') ?? '') ?? 0;
    _dropFolderSync();
    _asInternal(_migrate);
    _purgeUndo();
  }

  /// Bump when a new synced entity or field is added. Version 2 added `goal_contrib`, version 3 `tx.kind_hint` and
  /// `tx.transfer_to` (an older build dropped those fields from the ops it read, so they are replayed once), version 4
  /// the `exchange` hint (Revolut Exchange rows imported by version 3 as `ownTransfer` are rewritten once), version 5
  /// the `recurring` entity, version 6 the `planned` entity, version 7 the `bill` entity, version 8 one settings row
  /// per category budget and merchant pattern (`budget:<category>`, `pattern:<id>`; the maps are migrated once),
  /// version 9: accounts (the `account` entity; no data migration), version 10: categories (the `category` entity:
  /// custom categories, subcategories and built-in overrides; no data migration), version 11: tags (the `tag`,
  /// `txtag` and `ruletag` entities; no data migration).
  static const schemaVersion = 11;

  /// The folder sync's bookkeeping (`peer_files`: which files of the shared folder were read) means nothing on a relay,
  /// whose sequence numbers start over (every device's first relay file is its whole state), so it is dropped once.
  void _dropFolderSync() {
    if (db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'peer_files'").isEmpty) return;
    final n = db.select('SELECT COUNT(*) AS n FROM peer_files').first['n'] as int;
    db.execute('DROP TABLE peer_files');
    logEvent(_log, Level.INFO, 'repo.peerFiles.dropped', {'files': n});
  }

  /// Builds before a synced entity existed skipped its ops but still advanced their sync cursors past the files
  /// holding them. So when an existing database is opened by a build with a newer [schemaVersion], it forgets how far
  /// it applied each device (`sync_cursor`): the next sync starts over like a new device (the latest snapshot when one
  /// of this schema or newer exists, else every file still on the relay), ops already applied change nothing (their
  /// clocks are not newer), and the skipped ones apply. A new database just records the version.
  ///
  /// Below version 4, Revolut Exchange legs were imported with the `ownTransfer` hint, which lets them anchor a pair
  /// across sources; `importBatch` skips known ids and never edits `kind_hint`, so they are rewritten here once to
  /// `exchange` through [_write] (the change syncs) and reconciled at once, which dissolves their pairs.
  void _migrate() {
    final from = int.tryParse(_meta('schema') ?? '') ?? 1;
    if (from >= schemaVersion) return;
    var replay = 0, rehinted = 0, perKey = 0;
    if (!_created) {
      replay = db.select('SELECT COUNT(*) AS n FROM sync_cursor').first['n'] as int;
      db.execute('DELETE FROM sync_cursor');
      if (from < 4) {
        final stale = db.select("SELECT id FROM tx WHERE source = 'revolut' AND bank_type = ? AND kind_hint = ?",
            [revolutExchangeType, TxKind.ownTransfer.name]);
        rehinted = stale.length;
        _writeInternal([
          for (final r in stale) ('tx', r['id'] as String, {'kind_hint': TxKind.exchange.name})
        ]);
      }
      if (from < 8) perKey = WalletRepoSettings(this)._migratePerKeySettings();
    }
    _setMeta('schema', '$schemaVersion');
    logEvent(_log, Level.INFO, 'repo.migrate',
        {'from': from, 'to': schemaVersion, 'new': _created, 'replayDevices': replay, 'rehinted': rehinted, 'perKeySettings': perKey});
    if (rehinted > 0) _reconcileLocal();
  }

  /// Ids given to [open]: letters and digits only (a relay stream name is `<id>-<epoch>`, at most 64 characters).
  static final _deviceIdPattern = RegExp(r'^[A-Za-z0-9]{1,48}$');

  /// A new random device id (16 hex characters, like the ids databases made for themselves before H6), for the app's
  /// key store.
  static String newDeviceId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static WalletRepo _timedOpen(CommonDatabase Function() opener, bool file, int Function()? now, String? deviceId) {
    final t = PerfTimer('repo.open');
    final repo = WalletRepo._(opener(), now, deviceId);
    int count(String table) => repo.db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as int;
    t.done({'file': file, 'new': repo._created, 'tx': count('tx'), 'outbox': count('outbox')});
    return repo;
  }

  /// Opens (or creates) the database file at [path]. Native only: on the web use [fromDatabase] (with `openKeyed`).
  /// With [dbKey] (`localDbKey`) the file is encrypted: opened keyed, a plaintext one converted in place first
  /// (crash-safe, see `openKeyedFileDb`); a key that does not open it is a `WalletDbKeyException`.
  ///
  /// [deviceId] (H6) is this install's id from the app's key store. Null = the id stored in the database (a new
  /// database makes one), as before. Given and different from the stored one, this install takes the given id: the
  /// next sync is a first connect under it (whole state, clocks unchanged). [deviceId] (the getter) of a database
  /// opened without one is the id to move into the key store once.
  static WalletRepo open(String path, {List<int>? dbKey, int Function()? now, String? deviceId}) =>
      _timedOpen(() => dbKey == null ? sqlite.openFileDb(path) : sqlite.openKeyedFileDb(path, dbKey), true, now, deviceId);

  /// A fresh in-memory database (tests). Native only: on the web use [fromDatabase]. [deviceId] as for [open].
  static WalletRepo inMemory({int Function()? now, String? deviceId}) => _timedOpen(sqlite.openMemoryDb, false, now, deviceId);

  /// Wraps an already open [db] (e.g. a `package:sqlite3/wasm.dart` database on the web): the same pragmas and
  /// migrations run as for [open] and [inMemory]. [file] says whether it is a persistent database (logged in
  /// `repo.open`, like [open]) or a throwaway one (like [inMemory]). [close] disposes it. [deviceId] as for [open].
  static WalletRepo fromDatabase(CommonDatabase db, {required bool file, int Function()? now, String? deviceId}) =>
      _timedOpen(() => db, file, now, deviceId);

  /// The device id stored in [db] (meta `device_id`), or null for a database that has none yet. Reads only, no
  /// migration: for the app to move an existing id into its key store before opening.
  static String? storedDeviceId(CommonDatabase db) {
    try {
      final rs = db.select("SELECT value FROM meta WHERE key = 'device_id'");
      return rs.isEmpty ? null : rs.first['value'] as String?;
    } on SqliteException catch (e, st) {
      logError(_log, 'repo.deviceId.unreadable', e, st);
      return null;
    }
  }

  void close() {
    logEvent(_log, Level.FINE, 'repo.close');
    db.close();
  }

  // ---------- meta ----------
  String? _meta(String key) {
    final rs = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String?;
  }

  void _setMeta(String key, String? value) => db.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)', [key, value]);

  /// Device-local values that never sync (e.g. the sync folder path).
  String? localValue(String key) => _meta('local.$key');
  void setLocalValue(String key, String? value) => _setMeta('local.$key', value);

  // ---------- change log ----------
  /// Applies [op] field by field: a field wins if its HLC is newer than the one stored for it ([clocks]).
  ///
  /// Each known field's value is checked first ([_fieldValue]): one of the wrong type (another device's bug, a damaged
  /// op) is ignored and logged as `repo.badField` with the entity and field name only, and its clock is not recorded,
  /// so a later valid write still wins. The decision depends only on the op, so every device makes the same one. The
  /// row is created only when at least one field applies: an op with no usable field leaves nothing behind.
  bool _apply(Op op) {
    final def = entitySchema[op.entity];
    if (def == null) return false;
    final table = def.table;
    final accepted = <String, Object?>{};
    Map<String, String>? stored; // field -> hlc, read once per (entity, id)
    for (final e in op.fields.entries) {
      final col = def.column(e.key);
      if (col == null) continue;
      final v = _fieldValue(col, e.value);
      if (identical(v, _bad)) {
        logEvent(_log, Level.WARNING, 'repo.badField', {'entity': op.entity, 'field': e.key});
        continue;
      }
      stored ??= {
        for (final r in db.select('SELECT field, hlc FROM clocks WHERE entity = ? AND id = ?', [op.entity, op.id]))
          r['field'] as String: r['hlc'] as String
      };
      final have = stored[e.key];
      if (have != null && Hlc.compareStrings(have, op.hlc) >= 0) continue;
      accepted[e.key] = v;
    }
    if (accepted.isEmpty) return false;
    db.execute('INSERT OR IGNORE INTO $table(id) VALUES(?)', [op.id]);
    for (final k in accepted.keys) {
      db.execute('INSERT OR REPLACE INTO clocks(entity, id, field, hlc) VALUES(?, ?, ?, ?)', [op.entity, op.id, k, op.hlc]);
    }
    final sets = accepted.keys.map((k) => '$k = ?').join(', ');
    db.execute('UPDATE $table SET $sets WHERE id = ?', [...accepted.values, op.id]);
    return true;
  }

  static const _bad = Object();

  /// [value] as it is stored in column [col] ([ColumnType]: a 0/1 flag takes a bool or 0/1, an integer column an
  /// int, every other column text), or [_bad] if it has the wrong type. NULL only in a nullable column. A whole
  /// number sent as a float (`12.0`) within the range a double holds exactly is accepted; fractions, huge or
  /// non-finite floats are not.
  static Object? _fieldValue(ColumnDef col, Object? value) {
    if (value == null) return col.nullable ? null : _bad;
    switch (col.type) {
      case ColumnType.flag:
        return switch (value) { true || 1 => 1, false || 0 => 0, _ => _bad };
      case ColumnType.integer:
        const exact = 9007199254740992; // 2^53
        return switch (value) {
          final int v => v,
          final double v when v.isFinite && v == v.roundToDouble() && v.abs() <= exact => v.toInt(),
          _ => _bad,
        };
      case ColumnType.text:
        return value is String ? value : _bad;
    }
  }

  /// Nesting depth of [_asInternal]: while above 0, [_write] skips the clock guard.
  int _internalDepth = 0;

  /// The highest wall-clock reading of this device (meta `wall_high`): the owner-write guard compares with it.
  late int _wallHigh;

  /// Runs [body] as an internal write path (H7): the open-time migration, `_reconcile` (pairing, matching, field-pair
  /// repairs, bill links), `refreshRecurring`, `runPendingMatch` and its clean-ups. Their writes are not the owner's,
  /// so a wall clock behind the stored clock never blocks them (the HLC still only moves forward: `tick` takes the
  /// stored clock and counts on).
  T _asInternal<T>(T Function() body) {
    _internalDepth++;
    try {
      return body();
    } finally {
      _internalDepth--;
    }
  }

  /// [_write] for internal paths (no [ClockBehindException]); see [_asInternal]. Migrations of legacy rows use it.
  void _writeInternal(List<(String, String, Map<String, Object?>)> changes) => _asInternal(() => _write(changes));

  /// Every local write: one [Op] per change, applied and queued in the outbox, in one transaction. An owner write (the
  /// public write API the app calls) throws [ClockBehindException] (nothing written) when this device's wall clock is
  /// more than [maxClockDrift] behind the highest reading it made itself (`wall_high`: its clock was set back). Not the
  /// stored HLC: a database holding a far-future clock from a peer (before Stage H) must not lock its owner out, and the
  /// HLC orders the writes anyway. Internal paths go through [_writeInternal] / [_asInternal] and are never refused.
  void _write(List<(String, String, Map<String, Object?>)> changes) {
    if (changes.isEmpty) return;
    final wall = clock.now();
    final behind = _wallHigh - wall;
    if (_internalDepth == 0 && behind > maxClockDrift.inMilliseconds) {
      logEvent(_log, Level.WARNING, 'repo.clockBehind', {'ops': changes.length, 'behindMin': behind ~/ 60000});
      throw const ClockBehindException();
    }
    final t = PerfTimer('repo.write');
    _tx(() {
      for (final (entity, id, fields) in changes) {
        final op = Op(entity, id, fields, clock.tick().toString());
        _apply(op);
        db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
      }
      _setMeta('hlc', clock.last.toString());
      if (wall > _wallHigh) _setMeta('wall_high', '$wall');
    });
    if (wall > _wallHigh) _wallHigh = wall;
    t.done({
      'ops': changes.length,
      'entities': {for (final c in changes) c.$1}.join(',')
    });
  }

  T _tx<T>(T Function() body) {
    db.execute('BEGIN');
    try {
      final r = body();
      db.execute('COMMIT');
      return r;
    } catch (e, st) {
      // Marked first: on SQLITE_FULL / IOERR / NOMEM / BUSY SQLite may have rolled back already, and the original error is
      // what the app must see (a ROLLBACK error would replace it).
      if (e is SqliteException) _writeErrors[e] = true;
      logError(_log, 'repo.rollback', e, st, level: Level.SEVERE);
      if (!db.autocommit) {
        try {
          db.execute('ROLLBACK');
        } on SqliteException catch (re, rst) {
          logError(_log, 'repo.rollback.failed', re, rst, level: Level.SEVERE);
        }
      }
      rethrow;
    }
  }

  /// Errors thrown out of a rolled-back write transaction ([_tx]), marked on the error object itself: no type change for
  /// callers, and unlike a stack-frame name it survives inlining and minified web builds.
  static final _writeErrors = Expando<bool>('writeFailed');

  /// True when [error] came out of a write this repo rolled back, so nothing it tried to write was saved (the app's
  /// "Couldn't save"). Reads never mark their errors.
  static bool isWriteError(Object error) => _writeErrors[error] ?? false;

  /// Ops written on this device that have not been exported yet, oldest first.
  List<(int, Op)> pendingOps() => [
        for (final r in db.select('SELECT seq, op FROM outbox ORDER BY seq'))
          (r['seq'] as int, Op.fromJson(jsonDecode(r['op'] as String) as Map<String, Object?>)),
      ];

  void markExported(int upToSeq) {
    db.execute('DELETE FROM outbox WHERE seq <= ?', [upToSeq]);
    logEvent(_log, Level.FINE, 'repo.markExported', {'upTo': upToSeq, 'removed': db.updatedRows});
  }

  /// Applies ops from another device. Returns how many changed something here.
  ///
  /// A manual entry and its bank row can arrive in either order (imported on another device before the entry
  /// synced), so matching runs after remote changes too; it is deterministic, so every device writes the same
  /// matches. With [match] false (a sync applying many files) it only records that matching is due, and the caller
  /// runs it once at the end with [runPendingMatch].
  ///
  /// With [resend] the ops are also queued in the outbox, clocks unchanged, so this device's next sync carries them
  /// to the other devices like its own writes (a restore from a backup, see `restoreBackup`). Devices that already
  /// hold those fields with the same clocks change nothing when they read them (a clock is only accepted when newer).
  int applyRemote(List<Op> ops, {bool match = true, bool resend = false}) {
    final t = PerfTimer('repo.applyRemote');
    var changed = 0;
    _tx(() {
      for (final op in ops) {
        clock.receive(Hlc.parse(op.hlc));
        if (_apply(op)) changed++;
        if (resend) db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
      }
      _setMeta('hlc', clock.last.toString());
      if (changed > 0) _setMeta('match_pending', '1');
    });
    t.done({'ops': ops.length, 'changed': changed, 'resend': resend});
    if (match && syncCaughtUp) runPendingMatch();
    return changed;
  }

  /// The whole wallet as ops: for every row of every synced entity (deleted rows included, so a restore reproduces
  /// the state exactly) one op per distinct field clock, holding the fields written with that clock and their current
  /// values. A field with no clock (never written: the column default) is left out, so a restore records the same
  /// clocks as this device holds; a row with no clocked field at all gives no op. Device-local values (`local.*`
  /// meta, the outbox, sync cursors) are not included. Ordered by entity, id, clock.
  List<Op> snapshotOps() {
    final t = PerfTimer('repo.snapshot', warnMs: 1000);
    final out = <Op>[];
    for (final e in entitySchema.entries) {
      final entity = e.key;
      final def = e.value;
      final clocks = <String, Map<String, String>>{}; // id -> field -> hlc
      for (final r in db.select('SELECT id, field, hlc FROM clocks WHERE entity = ? ORDER BY id', [entity])) {
        if ((r['id'], r['field'], r['hlc']) case (final String id, final String f, final String h)) {
          if (def.column(f) != null) (clocks[id] ??= {})[f] = h;
        }
      }
      for (final r in db.select('SELECT * FROM ${def.table} ORDER BY id')) {
        final id = r['id'] as String;
        final byClock = <String, Map<String, Object?>>{};
        for (final MapEntry(key: f, value: h) in (clocks[id] ?? const {}).entries) {
          (byClock[h] ??= {})[f] = r[f];
        }
        final hlcs = byClock.keys.toList()..sort(Hlc.compareStrings);
        for (final h in hlcs) {
          out.add(Op(entity, id, byClock[h]!, h));
        }
      }
    }
    t.done({'ops': out.length});
    return out;
  }

  /// Whether nothing has been put into this wallet yet: no transactions, goals, goal contributions, wishes, recurring
  /// bills, planned costs, bills (receipts, slips), accounts, categories (overrides included), tags, tag links, rule
  /// tags, merchant rules (deleted rows count: they were data once) and no synced settings. Only such a wallet may
  /// take a restore from a backup; anything else merges through the sync folder.
  bool get isEmpty {
    for (final e in entitySchema.values) {
      if (db.select('SELECT 1 FROM ${e.table} LIMIT 1').isNotEmpty) return false;
    }
    return true;
  }

  // ---------- matching and pairing (hand-added entries ↔ bank rows, own transfers) ----------
  /// Each row's first write, for [planMatches] and `seen_bank`: the clock of its `amount`. Only the write that creates a row sets it
  /// (importBatch, addTransaction; matching, categories and deletes never touch it), and the clocks table converges to the
  /// same value on every device. If the same bank row is imported on two devices before they sync, the later import
  /// wins (highest HLC per field), so the row counts as written at that later import.
  static const _writtenJoin = "LEFT JOIN clocks c ON c.entity = 'tx' AND c.id = tx.id AND c.field = 'amount'";

  /// Matches hand-added expenses to bank rows ([planMatches]) and writes the changes. Returns the new matches.
  ///
  /// Loads the manual entries, the bank rows they point at, and for each open entry ([openEntries]) only the bank
  /// rows that could replace it, so a large history costs little. Logged as `repo.match` on `bw.perf` once per run.
  int _matchManual() {
    final t = PerfTimer('repo.match');
    final written = <String, String>{}, seenBank = <String, String>{};
    List<Tx> rows(String where, [List<Object?> args = const []]) {
      final out = <Tx>[];
      for (final r in db.select('SELECT tx.*, c.hlc AS written FROM tx $_writtenJoin WHERE $where', args)) {
        final tx = Tx.fromRow(r);
        if (r['written'] case final String h) written[tx.id] = h;
        if (r['seen_bank'] case final String v) seenBank[tx.id] = v;
        out.add(tx);
      }
      return out;
    }

    const live = 'tx.manual = 0 AND tx.deleted = 0';
    final manual = rows('tx.manual = 1 AND tx.deleted = 0');
    // Every row an entry points at, deleted ones included: only a deleted target (or one that is not a bank row, or
    // was paired as an own transfer) reopens its entry. A target this device has not received yet keeps the match
    // (no unmatch/rematch churn).
    final targets = rows('tx.id IN (SELECT matched_to FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to IS NOT NULL)');
    final open = openEntries(manual, {
      for (final b in targets)
        if (b.manual || b.deleted || b.transferTo != null) b.id
    });
    if (open.isEmpty) {
      _clearMatchPending();
      t.done({'manual': manual.length, 'open': 0, 'bank': 0, 'added': 0});
      return 0;
    }
    final bank = {for (final b in targets) b.id: b};
    for (final m in open) {
      final since = written[m.id];
      if (since == null || !isIsoDate(m.date)) continue;
      // Candidates for this entry only: same amount, within the window, and not on its device when it was added.
      // Without a seen_bank value, only rows written in or after the entry's millisecond (comparing the 15-digit
      // millis prefix as text is safe for any counter).
      final seen = SeenBank.of(since, seenBank[m.id]);
      final window = [m.amount, addDays(m.date, -matchDays), addDays(m.date, matchDays)];
      for (final b in seen.recorded
          ? rows('$live AND tx.amount = ? AND tx.date BETWEEN ? AND ?', window)
          : rows('$live AND tx.amount = ? AND tx.date BETWEEN ? AND ? AND c.hlc >= ?', [...window, since.split(':').first])) {
        if (written[b.id] case final String at when seen.unseen(at)) bank[b.id] = b;
      }
    }
    final cz = categorizer(withTags: false);
    final plan = planMatches(manual, [...bank.values], (b) {
      final k = cz.table.kindOf(cz.autoCategory(b));
      return k == BudgetKind.flex || k == BudgetKind.fixed;
    }, written, seenBank: seenBank);
    _write([
      for (final e in plan.matchedTo.entries) ('tx', e.key, {'matched_to': e.value}),
      for (final e in plan.bankCategory.entries) ('tx', e.key, {'category': e.value}),
    ]);
    _clearMatchPending();
    t.done({
      'manual': manual.length,
      'open': open.length,
      'bank': bank.length,
      'added': plan.added,
      'unmatched': plan.matchedTo.values.where((v) => v == null).length,
      'categories': plan.bankCategory.length,
    });
    return plan.added;
  }

  void _clearMatchPending() => db.execute("DELETE FROM meta WHERE key = 'match_pending'");

  /// A live bank row that needs a transfer partner: no `transfer_to`, or a link that no longer holds because the
  /// partner here is deleted, is a manual row, points elsewhere, or neither side is a hinted own transfer (mirrors
  /// `openTransfers`; a partner not here at all keeps the link). `x` is the row's alias.
  static String _openTransfer(String x) => '($x.manual = 0 AND $x.deleted = 0 AND $x.amount != 0 AND ($x.transfer_to IS NULL '
      'OR $x.transfer_to = $x.id OR EXISTS (SELECT 1 FROM tx p WHERE p.id = $x.transfer_to AND (p.deleted = 1 OR p.manual = 1 '
      "OR IFNULL(p.transfer_to, '') != $x.id OR ($x.kind_hint IS NOT '$_own' AND p.kind_hint IS NOT '$_own')))))";
  static const _own = 'ownTransfer';

  /// Pairs own-account transfers ([planTransfers]) and writes the links. Returns the new pairs.
  ///
  /// Loads only the rows that can pair: open rows with an open opposite-amount row of the same currency in another
  /// source within [transferDays], one of the two a hinted own transfer (a self-join on `amount`, indexed), plus open
  /// rows with a stale link (to clear it; a pair with no hint on either side is stale) and the rows those links point
  /// at (so the plan checks them the same way). Logged as `repo.transfers` on `bw.perf`.
  int _pairTransfers() {
    final t = PerfTimer('repo.transfers');
    final rows = <String, Tx>{};
    void load(String sql, [List<Object?> args = const []]) {
      for (final r in db.select(sql, args)) {
        final tx = Tx.fromRow(r);
        rows[tx.id] = tx;
      }
    }

    load('SELECT DISTINCT a.* FROM tx a JOIN tx b ON b.amount = -a.amount AND b.currency = a.currency AND b.source != a.source '
        "AND b.date BETWEEN date(a.date, '-$transferDays days') AND date(a.date, '+$transferDays days') AND ${_openTransfer('b')} "
        "WHERE a.date != '' AND (a.kind_hint = '$_own' OR b.kind_hint = '$_own') AND ${_openTransfer('a')}");
    final candidates = rows.length;
    load('SELECT a.* FROM tx a WHERE a.transfer_to IS NOT NULL AND ${_openTransfer('a')}');
    final targets = [
      for (final r in rows.values)
        if (r.transferTo case final String to when !rows.containsKey(to)) to
    ];
    if (targets.isNotEmpty) {
      load('SELECT * FROM tx WHERE id IN (${List.filled(targets.length, '?').join(',')})', targets);
    }
    final plan = planTransfers([...rows.values]);
    _write([
      for (final e in plan.transferTo.entries) ('tx', e.key, {'transfer_to': e.value})
    ]);
    t.done({'candidates': candidates, 'rows': rows.length, 'paired': plan.paired, 'reopened': plan.reopened});
    return plan.paired;
  }

  /// After rows changed (import, delete, remote ops): pairs own-account transfers, then matches hand-added expenses
  /// (a paired row is a transfer, so it is no longer a payment a cash entry could be), then links confirmed bills to
  /// their payments ([planBillLinks]). Returns (pairs, matches).
  (int, int) _reconcile() => _asInternal(() {
        final pairs = _pairTransfers();
        final matches = _matchManual();
        _repairFieldPairs();
        _autoLinkBills();
        return (pairs, matches);
      });

  /// Device-local: whether this device's last sync run was caught up (`'1'`/`'0'`, written by `SyncEngine` after every
  /// run; absent = never synced, which counts as caught up).
  static const caughtUpKey = 'syncCaughtUp';

  /// False while the last sync run was not caught up (a peer file waiting or refused): rows this device has not
  /// received yet may be the right partners, and a pair or match once made is never re-planned.
  bool get syncCaughtUp => localValue(caughtUpKey) != '0';

  /// After a local change of rows (import, delete, a migration rewrite): pairing and matching at once when
  /// [syncCaughtUp], else only marked due ([runPendingMatch] runs it on the next caught-up sync). Returns (pairs,
  /// matches), (0, 0) when deferred.
  (int, int) _reconcileLocal() {
    if (syncCaughtUp) return _reconcile();
    _setMeta('match_pending', '1');
    logEvent(_log, Level.INFO, 'repo.match.deferred');
    return (0, 0);
  }

  /// Runs transfer pairing and matching if ops applied with `applyRemote(match: false)` changed something since it
  /// last ran (also after a crash mid-sync: the flag is stored). `SyncEngine.run` calls it once, only when caught up.
  void runPendingMatch() {
    if (_meta('match_pending') == null) return;
    _asInternal(() {
      _reconcile();
      refreshRecurring(_today());
      dropOrphanBlobs();
      _purgeBlobCache();
    });
  }

  /// Today's date on this device's clock (the one the HLC uses, so tests can set it).
  String _today() => isoDate(DateTime.fromMillisecondsSinceEpoch(clock.now()));

  // ---------- sync bookkeeping (device-local, never synced) ----------
  /// How far this device applied each other device's relay files (device id → last applied seq; absent = none).
  /// Advanced file by file by `SyncEngine`, raised to a snapshot's covers; a schema bump clears it ([_migrate]).
  Map<String, int> syncCursors() => {
        for (final r in db.select('SELECT device, seq FROM sync_cursor')) r['device'] as String: r['seq'] as int,
      };

  /// Sets [device]'s cursor; 0 forgets it (the relay lost that device's files, which start again at 1).
  void setSyncCursor(String device, int seq) => seq <= 0
      ? db.execute('DELETE FROM sync_cursor WHERE device = ?', [device])
      : db.execute('INSERT OR REPLACE INTO sync_cursor(device, seq) VALUES(?, ?)', [device, seq]);

  /// Records that relay file [seq] of [device] (this device's own uploads included) held [ops] ops, for the snapshot
  /// rule ("500 ops behind the newest snapshot").
  void recordSyncFile(String device, int seq, int ops) =>
      db.execute('INSERT OR REPLACE INTO sync_files(device, seq, ops) VALUES(?, ?, ?)', [device, seq, ops]);

  /// Ops in recorded files not covered by [covers] (device → seq; a device not in it covers nothing).
  int syncOpsAfter(Map<String, int> covers) {
    var n = 0;
    for (final r in db.select('SELECT device, seq, ops FROM sync_files')) {
      if ((r['seq'] as int) > (covers[r['device']] ?? 0)) n += r['ops'] as int;
    }
    return n;
  }

  /// Forgets recorded files that [covers] covers.
  void forgetSyncFiles(Map<String, int> covers) {
    for (final MapEntry(key: d, value: s) in covers.entries) {
      db.execute('DELETE FROM sync_files WHERE device = ? AND seq <= ?', [d, s]);
    }
  }

  // ---------- reads ----------
  /// Rows with [Tx.matchPending]: a manual entry matched to a bank row this device does not hold yet (missing, or only
  /// a partial row without a date, which reads leave out) counts until that row arrives. Matching keeps such a match
  /// (no writes), so on every device the expense counts exactly once.
  static const _txSelect = 'SELECT tx.*, (tx.manual = 1 AND tx.matched_to IS NOT NULL AND NOT EXISTS '
      "(SELECT 1 FROM tx b WHERE b.id = tx.matched_to AND b.date != '')) AS match_pending FROM tx";

  List<Tx> transactions({bool includeHidden = false}) {
    final t = PerfTimer('repo.transactions');
    final rows = db.select('$_txSelect WHERE tx.date != \'\' ORDER BY tx.date DESC, tx.id DESC');
    final out = <Tx>[];
    for (final r in rows) {
      final tx = Tx.fromRow(r);
      if (includeHidden || tx.live) out.add(tx);
    }
    t.done({'rows': rows.length, 'live': out.length});
    return out;
  }

  Tx? transaction(String id) {
    final rs = db.select('$_txSelect WHERE tx.id = ?', [id]);
    return rs.isEmpty ? null : Tx.fromRow(rs.first);
  }

  /// Live goals. [Goal.saved] is [goalTotal]: the stored `saved` column plus the goal's live contributions.
  List<Goal> goals() {
    final adds = <String, List<int>>{};
    for (final r in db.select('SELECT c.goal_id, c.amount FROM goal_contrib c JOIN goals g ON g.id = c.goal_id '
        'WHERE c.deleted = 0 AND g.deleted = 0')) {
      if ((r['goal_id'], r['amount']) case (final String g, final int a)) (adds[g] ??= []).add(a);
    }
    return [
      for (final r in db.select('SELECT * FROM goals WHERE deleted = 0 ORDER BY sort, id'))
        if (Goal.fromRow(r) case final g) g.withSaved(goalTotal(g.saved, adds[g.id] ?? const [])),
    ];
  }

  /// The live contributions of goal [goalId] (none while it is deleted or not here), oldest first. A row without a
  /// valid amount (only a partial or damaged op arrived) is not listed; it counts 0.
  List<GoalContribution> goalContributions(String goalId) => [
        for (final r in db.select(
            'SELECT c.*, k.hlc AS created FROM goal_contrib c JOIN goals g ON g.id = c.goal_id AND g.deleted = 0 '
            "JOIN clocks k ON k.entity = 'goal_contrib' AND k.id = c.id AND k.field = 'amount' "
            'WHERE c.goal_id = ? AND c.deleted = 0 ORDER BY c.date, created, c.id',
            [goalId]))
          GoalContribution.fromRow(r),
      ];

  /// Goal [id]'s saved total, deleted or not, unclamped and as shown ([goalTotal]); null if there is no such row.
  (int, int)? _goalSaved(String id) {
    final rs = db.select('SELECT saved FROM goals WHERE id = ?', [id]);
    if (rs.isEmpty) return null;
    final base = switch (rs.first['saved']) { final int v => v, _ => 0 };
    final adds = [
      for (final r in db.select('SELECT amount FROM goal_contrib WHERE goal_id = ? AND deleted = 0', [id]))
        if (r['amount'] case final int a) a,
    ];
    return (goalTotal(base, adds, clamped: false), goalTotal(base, adds));
  }

  List<WishItem> wishlist() => [for (final r in db.select('SELECT * FROM wish WHERE deleted = 0 ORDER BY added')) WishItem.fromRow(r)];

  /// Recurring bills that are not deleted: candidates and confirmed ones, plus dismissed ones with [includeDismissed].
  /// Ordered by `nextDue`, then label, then id.
  /// A bill in a deleted custom category reads with the category its own payment gets now: the categorizer's answer
  /// for its `lastPaidTx` row (so a PBZ standing order reads Loan, like the row itself, and is never reserved on top of
  /// the fixed plan); without one (a bill not paid since it was confirmed), the payee's latest live bank outflow.
  /// Without any row: [Categorizer.resolveStored] (the payee's merchant rule, patterns and built-in rules on its
  /// label, else Shopping). The stored row is unchanged.
  List<RecurringBill> recurringBills({bool includeDismissed = false}) {
    Map<String, Tx>? latest; // payee -> latest live bank outflow, read only when a bill needs it
    return _resolved([
      for (final r in db.select(
          "SELECT * FROM recurring WHERE deleted = 0 ${includeDismissed ? '' : "AND status != 'dismissed'"} ORDER BY next_due, label, id"))
        r,
    ], (cz, r) {
      final paid = r['last_paid_tx'] is String ? transaction(r['last_paid_tx'] as String) : null;
      final row = paid ?? (latest ??= _latestOutflowByPayee())[r['payee']];
      if (row != null) return cz.categoryOf(row);
      return cz.resolveStored(r['category'] as String?, key: r['payee'] as String?, text: '${r['label'] ?? ''}', orElse: 'Shopping');
    }, RecurringBill.fromRow);
  }

  /// Per payee key ([merchantKey]) its latest live bank outflow (date, then id).
  Map<String, Tx> _latestOutflowByPayee() {
    final out = <String, Tx>{};
    for (final t in transactions()) {
      if (!t.live || t.manual || t.amount >= 0) continue;
      final k = merchantKey(t);
      final have = out[k];
      if (have == null || t.date.compareTo(have.date) > 0 || (t.date == have.date && t.id.compareTo(have.id) > 0)) out[k] = t;
    }
    return out;
  }

  /// [rows] as [make] builds them, each `category` that is a deleted or unknown custom id replaced by [resolve]'s
  /// answer first (P1: resolved when read, never written). The categorizer is built only when some row needs it.
  List<T> _resolved<T>(
      List<Map<String, Object?>> rows, String? Function(Categorizer, Map<String, Object?>) resolve, T Function(Map<String, Object?>) make) {
    final table = categoryTable();
    bool dead(Map<String, Object?> r) => r['category'] is String && table.isDeadCustom(r['category'] as String);
    if (!rows.any(dead)) return [for (final r in rows) make(r)];
    final cz = categorizer(withTags: false);
    return [
      for (final r in rows) dead(r) ? make({...r, 'category': resolve(cz, r)}) : make(r),
    ];
  }

  /// Planned costs (§4.3), ordered by date, then title, then id: the open ones with a date, or with [includeClosed]
  /// every row, paid, skipped (dismissed calendar events included) and deleted ones too ([PlannedCost.deleted]). Pass
  /// `includeClosed: true` to [upcoming] so a calendar event with any row is never suggested again.
  /// One in a deleted custom category reads with its automatic one ([Categorizer.resolveStored] on its title), or
  /// none; the stored row is unchanged.
  List<PlannedCost> plannedCosts({bool includeClosed = false}) => _resolved([
        for (final r in db.select(
            "SELECT * FROM planned ${includeClosed ? '' : "WHERE deleted = 0 AND status = 'open' AND date != ''"} ORDER BY date, title, id"))
          r,
      ], (cz, r) => cz.resolveStored(r['category'] as String?, text: '${r['title'] ?? ''}'), PlannedCost.fromRow);

  Map<String, String> merchantRules() => {
        for (final r in db.select('SELECT id, category FROM merchant_rules WHERE deleted = 0 AND category IS NOT NULL'))
          if ((r['id'], r['category']) case (final String id, final String c)) id: c,
      };

  /// The stored settings ([_readSettings]: per-key budget and pattern rows, legacy maps only as a fallback).
  WalletSettings settings() => _readSettings(db, table: categoryTable());

  /// Built-ins plus the stored category rows ([categoryRows], deleted ones included: a row pointing at one falls back).
  CategoryTable categoryTable() => CategoryTable.from(categoryRows(includeDeleted: true));

  /// The categorizer for the current settings, rules and categories. With [withTags] (the default) it also holds one
  /// read of the tag tables ([WalletRepoTags.tagContext]), so [Categorizer.categorize] fills [CategorizedTx.tags].
  Categorizer categorizer({bool withTags = true}) {
    final table = categoryTable();
    final st = _readSettings(db, table: table);
    return Categorizer(
        merchantRules: merchantRules(),
        patterns: st.merchantPatterns,
        rentCashThreshold: st.rentCashThreshold,
        table: table,
        tagContext: withTags ? tagContext() : null);
  }

  // ---------- writes ----------
  /// Writes whole-value settings ([_settingChanges]: `categoryBudgets`, `merchantPatterns` and per-key rows throw
  /// [ArgumentError]; use [WalletRepoSettings.setCategoryBudget] and [WalletRepoSettings.setMerchantPattern]).
  void updateSettings(Map<String, Object?> changes) => _write(_settingChanges(changes));

  /// Imports a normalized batch. Already-known ids are skipped; `kindHint` is stored (`kind_hint`), `account` never is.
  /// A known id whose stored row has another amount or description is an id collision ([ImportSummary.collisions]):
  /// skipped all the same (never overwritten) and logged as `repo.idCollision` with the count only.
  /// Then own-account transfers are paired across sources ([planTransfers]) and hand-added expenses with the same
  /// amount within 3 days are matched to a bank row their device did not hold when they were added, which keeps their
  /// category ([planMatches]).
  ImportSummary importBatch(ImportBatch batch) {
    final t = PerfTimer('repo.importBatch', warnMs: 500);
    final known = <String, (Object?, Object?)>{
      for (final r in db.select('SELECT id, amount, description FROM tx')) r['id'] as String: (r['amount'], r['description'])
    };
    // In batch order: a stored id, or one an earlier row of this batch took, is a duplicate (the first row wins and is
    // never overwritten); with another amount or description it is also a collision.
    final fresh = <NormalizedTransaction>[];
    var collisions = 0;
    for (final n in batch.transactions) {
      if (known[n.id] case (final amount, final description)) {
        if (amount != n.amountMinor || description != n.description) collisions++;
        continue;
      }
      known[n.id] = (n.amountMinor, n.description);
      fresh.add(n);
    }

    // The count only: never the ids, amounts or descriptions.
    if (collisions > 0) logEvent(_log, Level.WARNING, 'repo.idCollision', {'source': batch.source, 'count': collisions});
    final changes = <(String, String, Map<String, Object?>)>[];
    for (final n in fresh) {
      changes.add((
        'tx',
        n.id,
        {
          'source': n.source,
          'date': n.date,
          'amount': n.amountMinor,
          'currency': n.currency,
          'bank_type': n.bankType,
          'description': n.description,
          if (n.kindHint case final k?) 'kind_hint': k.name, // never `account`: it names the owner's account
          'manual': 0,
          // Never 'deleted': a new row is live through the column default, and writing deleted: 0 here with a
          // fresh HLC would undo a delete made on another device that this one has not synced yet. Only
          // deleteTransaction (and a future undelete) write that field.
        }
      ));
    }
    _write(changes);
    final (transfers, matched) = _reconcileLocal();
    refreshRecurring(_today());
    final s = ImportSummary(fresh.length, batch.transactions.length - fresh.length, matched, batch.skipped,
        transfers: transfers, collisions: collisions);
    t.done({
      'source': batch.source,
      'rows': batch.transactions.length,
      'added': s.added,
      'dupes': s.duplicates,
      'matched': s.matched,
      'transfers': s.transfers,
      'collisions': collisions,
      'skipped': s.skipped
    });
    return s;
  }

  String _newId(String prefix) {
    final r = Random.secure();
    return '$prefix${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 20).toRadixString(36)}';
  }

  /// The `seen_bank` value for an entry added now ([SeenBank]): per device, the highest `amount` clock of the bank
  /// rows (live or deleted) this device holds. Grouped in SQL by the node part of the clock (position 23 on: 15 millis
  /// digits, `:`, 5 counter digits, `:`), so each group's strings have one width and MAX is their HLC maximum;
  /// [SeenBank.encode] then takes the maximum per node exactly.
  String _seenBank() => SeenBank.encode([
        for (final r in db.select('SELECT MAX(c.hlc) AS h FROM clocks c JOIN tx ON tx.id = c.id '
            "WHERE c.entity = 'tx' AND c.field = 'amount' AND tx.manual = 0 GROUP BY substr(c.hlc, 23)"))
          r['h'] as String,
      ]);

  /// A hand-entered expense (positive [amount] = money spent). Records which bank rows this device holds now
  /// (`seen_bank`, in the same op): none of them is this entry's row, but a bank row imported on another device that
  /// has not synced yet may be ([planMatches]).
  String addTransaction({required String date, required int amount, required String category, String note = '', String currency = 'EUR'}) {
    final id = _newId('m');
    final seen = _seenBank();
    _write([
      (
        'tx',
        id,
        {
          'source': 'manual',
          'date': date,
          'amount': -amount,
          'currency': currency,
          'category': category,
          'note': note,
          'manual': 1,
          'deleted': 0,
          'seen_bank': seen,
        }
      ),
    ]);
    // No matching here: a bank row already in the wallet is never this entry's row (planMatches). The entry is
    // matched by the next import here, or by a sync that brings a bank row this device did not hold.
    return id;
  }

  void setCategory(String txId, String? category) => _write([
        ('tx', txId, {'category': category})
      ]);

  /// Deletes a row. A hand-added expense that this bank row replaced counts again (and may be matched by a later
  /// bank row): see [planMatches]. The other side of an own transfer it was paired with is open again ([planTransfers]).
  void deleteTransaction(String txId) {
    _purgeUndo();
    // Read before any write: the links this row holds are cleared below (not caught up) or by [_reconcileLocal].
    final matched = [
      for (final r in db.select('SELECT id FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to = ?', [txId])) r['id'] as String
    ];
    final partners = [
      for (final r in db.select('SELECT id FROM tx WHERE deleted = 0 AND transfer_to = ? AND id != ?', [txId, txId])) r['id'] as String
    ];
    _write([
      ('tx', txId, {'deleted': 1})
    ]);
    if (!syncCaughtUp) {
      // New pairs and matches wait for a caught-up sync, but the links this row held are undone at once: that needs
      // only its own deletion, and a cash entry it replaced must count again now (exact money).
      _write([
        for (final r in db.select('SELECT id FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to = ?', [txId]))
          ('tx', r['id'] as String, {'matched_to': null}),
        for (final r in db.select('SELECT id FROM tx WHERE transfer_to = ? AND id != ?', [txId, txId]))
          ('tx', r['id'] as String, {'transfer_to': null}),
      ]);
    }
    // A bill paid by this row is unpaid again at once (its planned row reopens and reserves): exact money.
    final today = _today();
    final paid = [
      for (final r in db.select('SELECT * FROM bills WHERE deleted = 0 AND linked_tx = ?', [txId])) Bill.fromRow(r)
    ];
    _write([
      for (final b in paid) ..._billWrites(b, {'linked_tx': null}, today),
    ]);
    // Device-local, for undeleteTransaction: automatic linking takes only bank rows (a cash expense made from a bill
    // would come back without its bill: reserved and counted, twice), and while not caught up nothing re-links a
    // match or a pair (the entry and the row would both count).
    if (paid.isNotEmpty || matched.isNotEmpty || partners.isNotEmpty) {
      _setMeta(
          '$_undoKey$txId',
          jsonEncode({
            'at': clock.now(),
            'bills': [for (final b in paid) b.id],
            'matched': matched,
            'transfer': partners,
          }));
    }
    _reconcileLocal();
  }

  /// Meta key prefix (device-local, never synced), value JSON with `at` (wall ms) and id lists `bills`, `matched` and
  /// `transfer`: the bills [deleteTransaction] unlinked from a row, the hand-added entries it replaced
  /// (`matched_to`) and its own-transfer partners (`transfer_to`), for its undo. Removed by the undo, or after
  /// [_undoKeep] ([_purgeUndo], at open and on every delete).
  static const _undoKey = 'undo.';
  static const _undoKeep = Duration(days: 1);

  /// Drops the [_undoKey] records older than [_undoKeep] (or unreadable): the app's Undo lasts seconds.
  void _purgeUndo() {
    final cutoff = clock.now() - _undoKeep.inMilliseconds;
    final old = <String>[];
    for (final r in db.select('SELECT key, value FROM meta WHERE substr(key, 1, ${_undoKey.length}) = ?', [_undoKey])) {
      final at = _undoRecord(r['value'] as String?)?.at;
      if (at == null || at < cutoff) old.add(r['key'] as String);
    }
    for (final k in old) {
      db.execute('DELETE FROM meta WHERE key = ?', [k]);
    }
    if (old.isNotEmpty) logEvent(_log, Level.FINE, 'repo.undo.purged', {'records': old.length});
  }

  /// An [_undoKey] value; null when it is not one.
  static ({int? at, List<String> bills, List<String> matched, List<String> transfer})? _undoRecord(String? v) {
    try {
      final j = v == null ? null : jsonDecode(v);
      if (j is! Map) return null;
      List<String> ids(Object? l) => l is List ? l.whereType<String>().toList() : const <String>[];
      return (at: j['at'] is int ? j['at'] as int : null, bills: ids(j['bills']), matched: ids(j['matched']), transfer: ids(j['transfer']));
    } on FormatException catch (e, st) {
      logError(_log, 'repo.undo.badRecord', e, st);
      return null;
    }
  }

  /// Undo of [deleteTransaction] (Stage I): writes `deleted: 0` (an owner write, synced), so the row is live again with
  /// every other field as it is now (a hand-added entry keeps its `matched_to`). Per DESIGN_DECISIONS §4.10 only this
  /// write revives a deleted row, and the later of it and the delete (by HLC) wins on every device; edits made
  /// elsewhere meanwhile stay (per field). From this device's undo record, in the same write: the bill the delete
  /// unlinked is linked again when it is still live and unlinked and no other live bill holds the row (a cash expense
  /// made from a bill is never linked automatically); each hand-added entry it replaced gets `matched_to` back and each
  /// own-transfer partner `transfer_to` back when that field is still null and the entry or partner is live (while not
  /// caught up nothing re-links them, so the money would count twice). Pairing, matching and bill links then run as
  /// after any change of rows ([_reconcileLocal]). A live row: nothing is written. Throws [ArgumentError] for an id
  /// this wallet does not hold.
  void undeleteTransaction(String txId) {
    final rs = db.select('SELECT deleted, transfer_to FROM tx WHERE id = ?', [txId]);
    if (rs.isEmpty) throw ArgumentError('No such transaction.');
    if (rs.first['deleted'] == 0) return;
    final today = _today();
    final relink = <Bill>[];
    final rematch = <String>[], repair = <String>[];
    if (_undoRecord(_meta('$_undoKey$txId')) case final u?) {
      final held = db.select('SELECT 1 FROM bills WHERE deleted = 0 AND linked_tx = ?', [txId]).isNotEmpty;
      for (final id in u.bills) {
        final b = db.select('SELECT * FROM bills WHERE id = ? AND deleted = 0 AND linked_tx IS NULL', [id]);
        if (!held && b.isNotEmpty) relink.add(Bill.fromRow(b.first));
      }
      for (final id in u.matched) {
        if (db.select('SELECT 1 FROM tx WHERE id = ? AND manual = 1 AND deleted = 0 AND matched_to IS NULL', [id]).isNotEmpty) {
          rematch.add(id);
        }
      }
      for (final id in u.transfer) {
        if (db.select('SELECT 1 FROM tx WHERE id = ? AND deleted = 0 AND transfer_to IS NULL', [id]).isNotEmpty) repair.add(id);
      }
    }
    _write([
      ('tx', txId, {'deleted': 0}),
      // One bill per payment row (the field-pair repair would unlink the others anyway).
      for (final b in relink.take(1)) ..._billWrites(b, {'linked_tx': txId}, today),
      for (final id in rematch) ('tx', id, {'matched_to': txId}),
      for (final id in repair) ('tx', id, {'transfer_to': txId}),
      // Its own side, when a caught-up repair cleared it meanwhile (a pair is always written on both rows).
      if (repair.length == 1 && rs.first['transfer_to'] == null) ('tx', txId, {'transfer_to': repair.single}),
    ]);
    db.execute('DELETE FROM meta WHERE key = ?', ['$_undoKey$txId']);
    logEvent(_log, Level.INFO, 'repo.undelete',
        {'entity': 'tx', 'bills': relink.take(1).length, 'matches': rematch.length, 'transfers': repair.length});
    _reconcileLocal();
  }

  /// The id of a bill's planned row (`bill:<billId>`, the same on every device).
  static String billPlannedId(String billId) => '${PlannedSource.bill.name}:$billId';

  void setMerchantRule(String key, String category) => _write([
        ('rule', key, {'category': category, 'deleted': 0})
      ]);

  /// Creates or edits a goal. [saved] is the total the user sees: a new goal stores it as its base (the `saved`
  /// column); for an existing goal it is never written back. A different total becomes ONE contribution of the
  /// difference, so an add made meanwhile on another device still counts (A +50 and B +30 offline: both). An
  /// unchanged total writes no contribution. [saved] is clamped to ±[Goal.maxSaved]. The difference is taken from the
  /// unclamped total and written as at most [Goal.maxContribution]: from a total beyond the cap (only reachable with
  /// adds on several devices at once) a set can take a second edit to land exactly.
  String saveGoal({String? id, required String name, required int target, required int saved, required int monthly, int? sort}) {
    final gid = id ?? _newId('g');
    final want = saved.clamp(-Goal.maxSaved, Goal.maxSaved);
    final now = id == null ? null : _goalSaved(gid);
    _write([
      (
        'goal',
        gid,
        {
          'name': name,
          'target': target,
          if (now == null) 'saved': want,
          'monthly': monthly,
          'sort': sort ?? DateTime.now().millisecondsSinceEpoch,
          'deleted': 0
        }
      ),
      if (now != null && want != now.$2) _contribution(gid, (want - now.$1).clamp(-Goal.maxContribution, Goal.maxContribution)),
    ]);
    return gid;
  }

  (String, String, Map<String, Object?>) _contribution(String goalId, int cents, {String? date, String? id}) =>
      ('goal_contrib', id ?? _newId('c'), {'goal_id': goalId, 'amount': cents, 'date': date ?? isoDate(DateTime.now()), 'deleted': 0});

  /// Adds [cents] (negative for a correction) to goal [goalId]'s saved total as its own synced row, dated [date]
  /// (`YYYY-MM-DD`, default today). Returns the contribution id, or null when nothing is written: for 0, or for a
  /// goal deleted here (it was removed meanwhile, e.g. by a sync, so there is nothing to add to and the goal is not
  /// brought back). Throws [ArgumentError] for a goal that never existed here, a bad date, or a total that would
  /// leave ±[Goal.maxSaved] (adds made at the same time on other devices can still pass it: reads clamp).
  String? addGoalContribution(String goalId, int cents, {String? date}) {
    if (date != null) requireIsoDate(date);
    final rs = db.select('SELECT deleted FROM goals WHERE id = ?', [goalId]);
    if (rs.isEmpty) throw ArgumentError('No such goal.');
    if (rs.first['deleted'] != 0 || cents == 0) return null;
    final (raw, _) = _goalSaved(goalId)!;
    if (cents.abs() > Goal.maxContribution || (raw + cents).abs() > Goal.maxSaved && (raw + cents).abs() > raw.abs()) {
      throw ArgumentError('The goal total is limited to the cap either way.');
    }
    final c = _contribution(goalId, cents, date: date);
    _write([c]);
    return c.$2;
  }

  void deleteGoal(String id) => _write([
        ('goal', id, {'deleted': 1})
      ]);

  /// Undo of [deleteGoal] (Stage I): writes `deleted: 0` (an owner write, synced), so the goal is back as it is now,
  /// with its contributions (hidden while it was deleted, never removed). Like [saveGoal], the later of this write and
  /// a delete (by HLC) wins (DESIGN_DECISIONS §4.10). A live goal: nothing is written. Throws [ArgumentError] for an
  /// id this wallet does not hold.
  void undeleteGoal(String id) {
    final rs = db.select('SELECT deleted FROM goals WHERE id = ?', [id]);
    if (rs.isEmpty) throw ArgumentError('No such goal.');
    if (rs.first['deleted'] == 0) return;
    _write([
      ('goal', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'goal'});
  }

  /// The payday transfer: adds each goal's monthly amount to its saved total, as a contribution. For a pay
  /// [period] the row id is fixed per goal and period, so paying the same period on two devices (or twice) counts
  /// once. With no period each call adds a new row: never default to the `periodStart` setting, which can be stale
  /// (the app only sets it when missing), so two paydays would share one id and the second would pay nothing.
  void payGoals({String? period}) {
    final p = period;
    _write([
      for (final g in goals())
        if (g.monthly != 0)
          _contribution(g.id, g.monthly.clamp(-Goal.maxContribution, Goal.maxContribution), id: p == null ? null : 'pay:${g.id}:$p'),
    ]);
  }

  String addWish(String name, int price) {
    final id = _newId('w');
    _write([
      ('wish', id, {'name': name, 'price': price, 'added': DateTime.now().millisecondsSinceEpoch, 'status': 'waiting', 'deleted': 0}),
    ]);
    return id;
  }

  void decideWish(String id, String status) => _write([
        ('wish', id, {'status': status, 'decided': DateTime.now().millisecondsSinceEpoch})
      ]);

  // ---------- recurring bills and the weekly review ----------

  /// Brings the recurring bills up to date with the rows held now; runs after every import and sync (once per sync run,
  /// with [runPendingMatch]). Deterministic: devices holding the same rows and bills write the same values.
  ///
  /// - New candidates ([detectRecurring]) are added, keyed `rec:<payee>` ([RecurringBill.idFor]); a payee with a row
  ///   already (candidate, confirmed, dismissed or deleted) is never added again. The creation op carries no `status`
  ///   or `deleted` (the column defaults apply), so a device that detects the payee late cannot undo a dismiss or
  ///   delete made elsewhere.
  /// - A candidate's expected amount, due date, label and category follow the latest detection, so one confirmed
  ///   months later starts from a current due date. A confirmed or dismissed bill's amount, due date and label are
  ///   never rewritten by detection. A row with an empty `payee` (a status op that arrived before the creation op)
  ///   is filled from the detection whatever its status.
  /// - A confirmed bill's `category` follows the payee's current categorization (its latest live bank outflow through
  ///   the categorizer: user override, rules, built-in patterns), so a merchant rule made after the confirm moves the
  ///   bill with it and [RecurringBill.coveredByPlan] stays true to the plan (owner rule: never reserved and planned).
  /// - A confirmed bill is marked paid when a bank row with its payee key lands within ± [recurringDays] of `nextDue`
  ///   with an outflow within [recurringPercent] of `expectedAmount` ([planRecurringPayments]): `lastPaidTx` = that
  ///   row, `nextDue` = the row's date + `intervalDays` (from the real payment, like detection, so a bill paid on the
  ///   15th stays matched month after month), `expectedAmount` unchanged; cycle after cycle when several payments are
  ///   here. The bank row keeps its category: nothing is reclassified.
  void refreshRecurring(String today) => _asInternal(() => _refreshRecurring(today));

  void _refreshRecurring(String today) {
    requireIsoDate(today);
    final t = PerfTimer('repo.recurring');
    final rows = transactions();
    if (rows.isEmpty) {
      // Nothing to detect or pay (and no settings read, which a wallet without rows has no reason for).
      t.done({'rows': 0});
      return;
    }
    final existing = {for (final r in db.select('SELECT * FROM recurring')) r['id'] as String: RecurringBill.fromRow(r)};
    final deleted = {for (final r in db.select('SELECT id FROM recurring WHERE deleted = 1')) r['id'] as String};
    final cz = categorizer(withTags: false);
    final currency = settings().currency; // only rows in the wallet's currency make or pay a bill
    final categorized = [for (final r in rows) cz.categorize(r)];
    final detected = detectRecurring(categorized, today: today, currency: currency);
    // The latest live bank outflow per payee: its category is the payee's current one. A row whose own category is a
    // deleted or unknown custom id ([CategoryTable.isDeadCustom]) only falls back on this device's table, so it never
    // decides a stored category (P1: nothing is written for a fallback; two devices with different tables never loop).
    final latest = <String, CategorizedTx>{};
    final deadLast = <String>{}; // payees whose latest row (any) is such a row
    final latestAny = <String, CategorizedTx>{};
    bool newer(CategorizedTx t, CategorizedTx? have) =>
        have == null || t.date.compareTo(have.date) > 0 || (t.date == have.date && t.tx.id.compareTo(have.tx.id) > 0);
    for (final t in categorized) {
      if (!t.tx.live || t.tx.manual || t.amount >= 0 || t.kind == BudgetKind.transfer || t.tx.currency != currency) continue;
      final key = merchantKey(t.tx);
      if (newer(t, latestAny[key])) latestAny[key] = t;
      if (t.tx.category case final c? when cz.table.isDeadCustom(c)) continue;
      if (newer(t, latest[key])) latest[key] = t;
    }
    for (final MapEntry(:key, :value) in latestAny.entries) {
      if (value.tx.category case final c? when cz.table.isDeadCustom(c)) deadLast.add(key);
    }
    final changes = <(String, String, Map<String, Object?>)>[];
    // The bills as they stand after the detection updates below (before payments).
    final current = {for (final e in existing.entries) e.key: e.value};
    var added = 0, updated = 0;
    for (final d in detected) {
      final have = existing[d.id];
      // A candidate whose latest row falls back takes the payee's latest other row's category (or keeps its own).
      final c = deadLast.contains(d.payee) ? d.copyWith(category: latest[d.payee]?.category ?? have?.category ?? d.category) : d;
      if (have == null) {
        added++;
        changes.add(('recurring', c.id, _candidateFields(c)));
      } else if ((have.status == 'candidate' || have.payee.isEmpty) && !deleted.contains(c.id)) {
        final want = _candidateFields(c), has = _candidateFields(have);
        final diff = {
          for (final e in want.entries)
            if (has[e.key] != e.value && !(e.key == 'category' && cz.table.isDeadCustom(have.category))) e.key: e.value
        };
        if (diff.isNotEmpty) {
          updated++;
          changes.add(('recurring', c.id, diff));
          current[c.id] = c.copyWith(
              status: have.status,
              lastPaidTx: have.lastPaidTx,
              category: cz.table.isDeadCustom(have.category) ? have.category : c.category);
        }
      }
    }
    var recategorized = 0;
    var bills = <RecurringBill>[];
    for (final b in current.values) {
      if (!b.confirmed || deleted.contains(b.id) || b.payee.isEmpty) continue;
      final category = latest[b.payee]?.category;
      // Never over a stored deleted custom category: it is resolved when read, and an undelete brings it back.
      if (category != null && category != b.category && !cz.table.isDeadCustom(b.category)) {
        recategorized++;
        changes.add(('recurring', b.id, {'category': category}));
        current[b.id] = b.copyWith(category: category);
      }
      bills.add(current[b.id]!);
    }
    var paid = 0;
    // One payment per bill per pass; repeated so a history import with several cycles catches up (bounded).
    for (var pass = 0; pass < 120 && bills.isNotEmpty; pass++) {
      final plan = planRecurringPayments(bills, rows, currency: currency);

      if (plan.isEmpty) break;
      bills = [
        for (final b in bills)
          if (plan.paidBy[b.id] case final Tx row) b.copyWith(lastPaidTx: row.id, nextDue: addDays(row.date, b.intervalDays)) else b
      ];
      paid += plan.paidBy.length;
    }
    for (final b in bills) {
      final was = current[b.id]!;
      if (b.nextDue != was.nextDue || b.lastPaidTx != was.lastPaidTx) {
        changes.add(('recurring', b.id, {'next_due': b.nextDue, 'last_paid_tx': b.lastPaidTx}));
      }
    }
    _write(changes);
    t.done({
      'rows': rows.length,
      'bills': existing.length,
      'candidates': detected.length,
      'added': added,
      'updated': updated,
      'recategorized': recategorized,
      'paid': paid,
    });
  }

  /// The fields a new candidate is created with: no `status` and no `deleted`, see [refreshRecurring].
  static Map<String, Object?> _candidateFields(RecurringBill c) => {
        'payee': c.payee,
        'label': c.label,
        'category': c.category,
        'expected_amount': c.expectedAmount,
        'interval_days': c.intervalDays,
        'next_due': c.nextDue,
      };

  void _setRecurring(String id, Map<String, Object?> fields) {
    if (db.select('SELECT 1 FROM recurring WHERE id = ?', [id]).isEmpty) throw ArgumentError('No such bill.');
    _write([('recurring', id, fields)]);
  }

  /// The owner says this candidate is a bill: from now on it is reserved in the period budget until paid.
  void confirmRecurring(String id) => _setRecurring(id, {'status': 'confirmed'});

  /// The owner says this is not a bill: hidden from [recurringBills] (unless asked for) and never detected again.
  void dismissRecurring(String id) => _setRecurring(id, {'status': 'dismissed'});

  /// Removes a bill; its payee is never detected again (the row stays, deleted).
  void deleteRecurring(String id) => _setRecurring(id, {'deleted': 1});

  /// The owner skips the bill's current cycle (no payment is coming, or it was paid in a way the match cannot see):
  /// `nextDue` moves one `intervalDays` on from its current value, so the bill is no longer due or reserved in this
  /// period and the match looks for the next payment around the new date. No bank row is needed. `lastPaidTx` (the
  /// row that paid the previous cycle) stays as it is: the skipped cycle has none. Synced like every write; an
  /// unknown id is an [ArgumentError], a bill with no due date yet (see [refreshRecurring]) a [StateError].
  Future<void> skipRecurring(String id) async {
    final r = db.select('SELECT * FROM recurring WHERE id = ?', [id]);
    if (r.isEmpty) throw ArgumentError('No such bill.');
    final b = RecurringBill.fromRow(r.first);
    if (!isIsoDate(b.nextDue)) throw StateError('The bill has no due date yet.');
    _write([
      ('recurring', id, {'next_due': addDays(b.nextDue, b.intervalDays)})
    ]);
    logEvent(_log, Level.INFO, 'recurring.skip', {'intervalDays': b.intervalDays});
  }

  /// The weekly review was done on [today]: `lastReview` = today, `reviewStreak` grows by one when the previous review
  /// was less than 14 days before, i.e. no weekly review day was skipped in between (else starts again at 1). Done
  /// twice on one day changes nothing.
  void markReviewDone(String today) {
    requireIsoDate(today);
    final st = settings();
    final last = st.lastReview;
    if (last == today) return;
    final streak = last != null && daysBetween(last, today) < 14 ? st.reviewStreak + 1 : 1;
    updateSettings({'lastReview': today, 'reviewStreak': streak.clamp(0, WalletSettings.maxStreak)});
    logEvent(_log, Level.INFO, 'review.done', {'streak': streak});
  }
}
