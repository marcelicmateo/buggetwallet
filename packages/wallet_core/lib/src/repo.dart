import 'dart:convert';
import 'dart:math';

import 'package:cryptography/dart.dart' show DartSha256;
import 'package:sqlite3/common.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'accounts.dart';
import 'bills.dart';
import 'budget.dart' show reviewStreak;
import 'categories.dart';
import 'changes.dart';
import 'dates.dart';
import 'hlc.dart';
import 'import_preview.dart';
import 'logs.dart';
import 'matching.dart';
import 'models.dart';
import 'planned.dart' show isSafeCents, legacyRowCapCents, maxAmountCents;
import 'recurring.dart';
import 'rules.dart';
import 'schema.dart';
import 'search.dart' show foldText;
import 'splits.dart';
import 'sqlite_io.dart' if (dart.library.js_interop) 'sqlite_web.dart' as sqlite;
import 'tags.dart';
import 'transfers.dart';

part 'repo_accounts.dart';
part 'repo_bills.dart';
part 'repo_categories.dart';
part 'repo_changes.dart';
part 'repo_blobs.dart';
part 'repo_import.dart';
part 'repo_iou.dart';
part 'repo_meta.dart';
part 'repo_planned.dart';
part 'repo_recurring.dart';
part 'repo_settings.dart';
part 'repo_sync_apply.dart';
part 'repo_splits.dart';
part 'repo_tags.dart';
part 'repo_tx.dart';

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

  /// Rows left out because the amount is beyond ±[maxAmountCents] (Q3, [isSafeCents]); not in [duplicates].
  final int tooLarge;

  /// Rows left out because their id was in `importBatch`'s `skip` set (the owner's Skip, Q4); not in [duplicates].
  final int skippedByOwner;

  /// The bank balance checks this import recorded (Q5), by account id: one per balance the file states
  /// (`ImportBatch.bankBalances`) that has a live bank account of its source and currency.
  final Map<String, BalanceCheck> bankChecks;

  const ImportSummary(this.added, this.duplicates, this.matched, this.skipped,
      {this.transfers = 0, this.collisions = 0, this.tooLarge = 0, this.skippedByOwner = 0, this.bankChecks = const {}});
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
    _migrateBlobTables();
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
  /// `txtag` and `ruletag` entities; no data migration), version 12: recurring bills beyond monthly (P4: `recurring`
  /// gains `min_amount`, `max_amount`, `ends_on`, `manual`; no data migration), version 13: split transactions (P6:
  /// the `split` entity; no data migration), version 14: recurring income (P9: `recurring` gains `direction`; no data
  /// migration), version 15: bill-file invariants (P14: no synced change; the local `blob_outbox`, `blob_delete` and
  /// `blob_own` tables become `blob_cache.uploaded`, [_migrateBlobTables]; snapshots of this schema carry declared
  /// blob sets), version 16: attachments (P16b: `bills` gains `attached_tx`; no data migration), version 17: IOUs (Q8:
  /// the `iou` and `iou_part` entities; no data migration), version 18: weekly reviews as dated rows (V3: the `review`
  /// entity; no data migration, the legacy `lastReview` / `reviewStreak` settings stay the streak's base).
  static const schemaVersion = 18;

  /// Device-local, set once by the schema-15 migration ([_migrateBlobTables]): the next sync runs PUT every cached file
  /// a live bill points to again (api-3 builds deleted files on the relay), cleared once all of them were stored.
  static const blobReuploadKey = 'blobReupload';

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

  /// Device-local values that never sync (e.g. the sync folder path).
  String? localValue(String key) => _meta('local.$key');
  void setLocalValue(String key, String? value) => _setMeta('local.$key', value);

  /// Nesting depth of [_asInternal]: while above 0, [_write] skips the clock guard.
  int _internalDepth = 0;

  int _dataVersion = 0;

  /// [stateDigest]'s last result and the [dataVersion] it was computed at; how many real computations ran.
  (int, String)? _digestCache;
  int _digestRuns = 0;

  /// Set by [_apply] when a field was written in the open transaction; [_tx] turns it into a [dataVersion] step on
  /// commit and drops it on rollback.
  bool _dataPending = false;

  /// Goes up by one on every committed transaction that wrote wallet data: a local write ([_write]) or ops applied from
  /// another device or a backup ([applyRemote], snapshots, restore and merge), whatever their clocks. Never on sync
  /// bookkeeping (cursors, the outbox, `meta`, local values) or on an apply that changed nothing (a re-sent file, a
  /// refused one, a dry run). In memory only: starts at 0 each time the database is opened.
  int get dataVersion => _dataVersion;

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
    // Every way out of a transaction clears it (commit, rollback, a dry run's rollback).
    assert(!_dataPending, 'a data write left a transaction without clearing its mark');
    db.execute('BEGIN');
    try {
      final r = body();
      db.execute('COMMIT');
      if (_dataPending) _dataVersion++;
      _dataPending = false;
      return r;
    } catch (e, st) {
      _dataPending = false;
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

  /// Device-local: whether this device's last sync run was caught up (`'1'`/`'0'`, written by `SyncEngine` after every
  /// run; absent = never synced, which counts as caught up).
  static const caughtUpKey = 'syncCaughtUp';

  /// False while the last sync run was not caught up (a peer file waiting or refused): rows this device has not
  /// received yet may be the right partners, and a pair or match once made is never re-planned.
  bool get syncCaughtUp => localValue(caughtUpKey) != '0';

  /// Today's date on this device's clock (the one the HLC uses, so tests can set it).
  String _today() => isoDate(DateTime.fromMillisecondsSinceEpoch(clock.now()));

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
  /// Ordered by `nextDue`, then label, then id. P9: recurring incomes are in this list too ([RecurringBill.isIncome]);
  /// a list of bills filters them out (`computePeriod`, `upcoming`, `plannedIcs` and bill coverage ignore them).
  /// A bill in a deleted custom category reads with the category its own payment gets now: the categorizer's answer
  /// for its `lastPaidTx` row (so a PBZ standing order reads Loan, like the row itself, and is never reserved on top of
  /// the fixed plan); without one (a bill not paid since it was confirmed), the payee's latest live bank outflow.
  /// Without any row: [Categorizer.resolveStored] (the payee's merchant rule, patterns and built-in rules on its
  /// label, else Shopping). The stored row is unchanged.
  List<RecurringBill> recurringBills({bool includeDismissed = false}) {
    Map<String, Tx>? latest; // payee -> latest live bank outflow, read only when a bill needs it
    return _resolved([
      for (final r in db.select(
          "SELECT * FROM recurring WHERE deleted = 0 ${includeDismissed ? '' : 'AND status NOT IN (${RecurringBill.dismissedStored})'} "
          'ORDER BY next_due, label, id'))
        r,
    ], (cz, r) {
      final paid = r['last_paid_tx'] is String ? transaction(r['last_paid_tx'] as String) : null;
      final payee = r['payee'] is String && (r['payee'] as String).isNotEmpty ? r['payee'] as String : null; // '' = manual, no payee
      // An income (P9) never takes a bill's outflow category: its landed row, else the stored one or Extra income.
      final income = r['direction'] == RecurringBill.directionIn;
      final row = paid ?? (payee == null || income ? null : (latest ??= _latestOutflowByPayee())[payee]);
      if (row != null) return cz.categoryOf(row);
      return cz.resolveStored(r['category'] as String?,
          key: income ? null : payee, text: income ? '' : '${r['label'] ?? ''}', orElse: income ? 'Extra income' : 'Shopping');
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

  /// The stored settings ([_readSettings]: per-key budget and pattern rows, legacy maps only as a fallback).
  WalletSettings settings() => _readSettings(db, table: categoryTable());

  /// Built-ins plus the stored category rows ([categoryRows], deleted ones included: a row pointing at one falls back).
  CategoryTable categoryTable() => CategoryTable.from(categoryRows(includeDeleted: true));

  /// The categorizer for the current settings, rules and categories. With [withTags] (the default) it also holds one
  /// read of the tag tables ([WalletRepoTags.tagContext]), so [Categorizer.categorize] fills [CategorizedTx.tags], and
  /// one read of the live splits ([WalletRepoSplits.splits], P6) for [Categorizer.expand]. Without it (the internal
  /// whole-payment paths: matching, recurring) [Categorizer.expand] gives whole payments.
  Categorizer categorizer({bool withTags = true}) {
    final table = categoryTable();
    final st = _readSettings(db, table: table);
    return Categorizer(
        merchantRules: merchantRules(),
        patternRules: st.patternRules,
        rentCashThreshold: st.rentCashThreshold,
        table: table,
        tagContext: withTags ? tagContext() : null,
        splits: withTags ? splits() : const {},
        iouTx: WalletRepoIou(this).iouLinkedTx());
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
  ///
  /// [revive] (P12): ids of rows `setCsvMapping(force: true)` deleted. A deleted row whose id is in it and in the batch
  /// (same amount and description) is undeleted through [_write] and counted as added, so a forced layout change that
  /// reads some rows to the same ids never leaves them deleted. Only those ids: a row deleted for any other reason stays.
  ///
  /// Q3: a row beyond ±[maxAmountCents] ([isSafeCents]) is never written ([ImportSummary.tooLarge]). Q4: rows whose id
  /// is in [skip] (the owner's Skip in the import preview, `previewImport`) are not written at all
  /// ([ImportSummary.skippedByOwner]). Q5: for each balance the file states ([ImportBatch.bankBalances]) the live bank
  /// account of that source and currency gets a device-local check (`recordBankCheck`, [ImportSummary.bankChecks]);
  /// the balance itself never changes (correcting it is the owner's tap on `correctBalance`).
  ImportSummary importBatch(ImportBatch batch, {Set<String> revive = const {}, Set<String> skip = const {}}) {
    final t = PerfTimer('repo.importBatch', warnMs: 500);
    final c = _classifyBatch(batch, revive: revive, skip: skip);
    final collisions = c.count(_RowFate.collision), tooLarge = c.count(_RowFate.tooLarge), skipped = c.count(_RowFate.skipped);
    // The count only: never the ids, amounts or descriptions.
    if (collisions > 0) logEvent(_log, Level.WARNING, 'repo.idCollision', {'source': sourceLogKey(batch.source), 'count': collisions});
    if (tooLarge > 0) logEvent(_log, Level.WARNING, 'repo.tooLarge', {'source': sourceLogKey(batch.source), 'count': tooLarge});
    final changes = <(String, String, Map<String, Object?>)>[];
    final revived = <String>[];
    var fresh = 0;
    for (final (i, n) in batch.transactions.indexed) {
      switch (c.fates[i]) {
        case _RowFate.fresh:
          fresh++;
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
        case _RowFate.revived:
          revived.add(n.id);
        default:
          break;
      }
    }
    for (final id in revived) {
      changes.add(('tx', id, {'deleted': 0}));
    }
    _write(changes);
    final (transfers, matched) = _reconcileLocal();
    refreshRecurring(_today());
    final checks = _recordBankChecks(batch);
    final added = fresh + revived.length;
    final s = ImportSummary(added, batch.transactions.length - added - tooLarge - skipped, matched, batch.skipped,
        transfers: transfers, collisions: collisions, tooLarge: tooLarge, skippedByOwner: skipped, bankChecks: checks);
    t.done({
      'source': sourceLogKey(batch.source), // `csv` for a mapped CSV: the shape id is a hash of header names
      'rows': batch.transactions.length,
      'added': s.added,
      if (revived.isNotEmpty) 'revived': revived.length,
      'dupes': s.duplicates,
      'matched': s.matched,
      'transfers': s.transfers,
      'collisions': collisions,
      'skipped': s.skipped,
      if (tooLarge > 0) 'tooLarge': tooLarge,
      if (skipped > 0) 'ownerSkipped': skipped,
      if (checks.isNotEmpty) 'bankChecks': checks.length,
    });
    return s;
  }

  /// What [importBatch] (and `previewImport`) does with each row of [batch], in batch order, from one read of the
  /// stored ids: beyond ±[maxAmountCents] → tooLarge; in [skip] → skipped; a stored id, or one an earlier row of this
  /// batch took (the first row wins and is never overwritten) → duplicate, or collision with another amount or
  /// description, or revived when deleted, in [revive] and the same; else fresh.
  ({List<_RowFate> fates, int Function(_RowFate) count}) _classifyBatch(ImportBatch batch,
      {Set<String> revive = const {}, Set<String> skip = const {}}) {
    final known = <String, (Object?, Object?)>{};
    final deleted = <String>{};
    for (final r in db.select('SELECT id, amount, description, deleted FROM tx')) {
      final id = r['id'] as String;
      known[id] = (r['amount'], r['description']);
      if (r['deleted'] != 0) deleted.add(id);
    }
    final fates = <_RowFate>[];
    for (final n in batch.transactions) {
      if (!isSafeCents(n.amountMinor)) {
        fates.add(_RowFate.tooLarge);
      } else if (skip.contains(n.id)) {
        fates.add(_RowFate.skipped);
      } else if (known[n.id] case (final amount, final description)) {
        if (amount != n.amountMinor || description != n.description) {
          fates.add(_RowFate.collision);
        } else if (revive.contains(n.id) && deleted.remove(n.id)) {
          fates.add(_RowFate.revived);
        } else {
          fates.add(_RowFate.duplicate);
        }
      } else {
        known[n.id] = (n.amountMinor, n.description);
        fates.add(_RowFate.fresh);
      }
    }
    return (fates: fates, count: (f) => fates.where((x) => x == f).length);
  }

  String _newId(String prefix) {
    final r = Random.secure();
    return '$prefix${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 20).toRadixString(36)}';
  }

  /// A hand-entered expense (positive [amount] = money spent). Records which bank rows this device holds now
  /// (`seen_bank`, in the same op): none of them is this entry's row, but a bank row imported on another device that
  /// has not synced yet may be ([planMatches]).
  /// An [amount] beyond ±[maxAmountCents] ([isSafeCents]) is an [ArgumentError] (Q3), nothing written.
  String addTransaction({required String date, required int amount, required String category, String note = '', String currency = 'EUR'}) {
    if (!isSafeCents(amount)) throw ArgumentError('The amount is over the allowed amount.');
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

  /// The id of a bill's planned row (`bill:<billId>`, the same on every device).
  static String billPlannedId(String billId) => '${PlannedSource.bill.name}:$billId';

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
    // A payee a live manual bill uses is never detected (P4: no duplicate of the owner's own bill); per direction, so
    // a manual income does not hide the payee's bill, nor a manual bill its income (P9).
    String dirKey(RecurringBill b) => '${b.isIncome ? 'in' : 'out'}:${b.payee}';
    final manualPayees = {
      for (final b in existing.values)
        if (b.manual && b.payee.isNotEmpty && !deleted.contains(b.id)) dirKey(b)
    };
    final detected = [
      for (final d in detectRecurring(categorized, today: today, currency: currency))
        if (!manualPayees.contains(dirKey(d))) d
    ];
    // The latest live bank outflow per payee: its category is the payee's current one. A row whose own category is a
    // deleted or unknown custom id ([CategoryTable.isDeadCustom]) only falls back on this device's table, so it never
    // decides a stored category (P1: nothing is written for a fallback; two devices with different tables never loop).
    // P9: an income's category follows the payee's latest live bank inflow of kind extra, the same way.
    bool newer(CategorizedTx t, CategorizedTx? have) =>
        have == null || t.date.compareTo(have.date) > 0 || (t.date == have.date && t.tx.id.compareTo(have.tx.id) > 0);
    ({Map<String, CategorizedTx> latest, Set<String> deadLast}) latestBy(bool Function(CategorizedTx) rowOf) {
      final latest = <String, CategorizedTx>{};
      final deadLast = <String>{}; // payees whose latest row (any) is such a row
      final latestAny = <String, CategorizedTx>{};
      for (final t in categorized) {
        if (!t.tx.live || t.tx.manual || t.kind == BudgetKind.transfer || t.tx.currency != currency || !rowOf(t)) continue;
        final key = merchantKey(t.tx);
        if (newer(t, latestAny[key])) latestAny[key] = t;
        if (t.tx.category case final c? when cz.table.isDeadCustom(c)) continue;
        if (newer(t, latest[key])) latest[key] = t;
      }
      for (final MapEntry(:key, :value) in latestAny.entries) {
        if (value.tx.category case final c? when cz.table.isDeadCustom(c)) deadLast.add(key);
      }
      return (latest: latest, deadLast: deadLast);
    }

    final outflows = latestBy((t) => t.amount < 0);
    final inflows = latestBy((t) => t.amount > 0 && t.kind == BudgetKind.extra);
    Map<String, CategorizedTx> latestFor(RecurringBill b) => b.isIncome ? inflows.latest : outflows.latest;
    final changes = <(String, String, Map<String, Object?>)>[];
    // The bills as they stand after the detection updates below (before payments).
    final current = {for (final e in existing.entries) e.key: e.value};
    var added = 0, updated = 0;
    for (final d in detected) {
      final have = existing[d.id];
      // A candidate whose latest row falls back takes the payee's latest other row's category (or keeps its own).
      final c = (d.isIncome ? inflows : outflows).deadLast.contains(d.payee)
          ? d.copyWith(category: latestFor(d)[d.payee]?.category ?? have?.category ?? d.category)
          : d;
      if (have == null) {
        added++;
        // An income's creation op carries its status (`in:candidate`) so a build before P9 never takes it for a bill
        // candidate (P9 review); a bill's carries none (the column default applies).
        changes.add(
            ('recurring', c.id, {..._candidateFields(c), if (c.isIncome) 'status': RecurringBill.storedStatus('candidate', income: true)}));
      } else if ((have.status == 'candidate' || have.payee.isEmpty) && !deleted.contains(c.id)) {
        final want = _candidateFields(c), has = _candidateFields(have);
        final diff = {
          for (final e in want.entries)
            if (has[e.key] != e.value && !(e.key == 'category' && (have.ownCategory || cz.table.isDeadCustom(have.category))))
              e.key: e.value
        };
        if (diff.isNotEmpty) {
          updated++;
          changes.add(('recurring', c.id, diff));
          // The detection's fields over the stored row; the owner's fields (range, end, own category) stay.
          current[c.id] = RecurringBill(
              id: c.id,
              payee: c.payee,
              label: c.label,
              category: have.ownCategory || cz.table.isDeadCustom(have.category) ? have.category : c.category,
              expectedAmount: c.expectedAmount,
              intervalDays: c.intervalDays,
              nextDue: c.nextDue,
              status: have.status,
              lastPaidTx: have.lastPaidTx,
              minAmount: have.minAmount,
              maxAmount: have.maxAmount,
              endsOn: have.endsOn,
              manual: have.manual,
              ownCategory: have.ownCategory,
              direction: c.direction);
        }
      }
    }
    var recategorized = 0;
    var bills = <RecurringBill>[];
    for (final b in current.values) {
      if (!b.confirmed || deleted.contains(b.id) || b.payee.isEmpty || b.finished) continue;
      final category = latestFor(b)[b.payee]?.category;
      // Never over a stored deleted custom category: it is resolved when read, and an undelete brings it back. A
      // manual bill keeps the category the owner gave it.
      if (!b.manual && !b.ownCategory && category != null && category != b.category && !cz.table.isDeadCustom(b.category)) {
        recategorized++;
        changes.add(('recurring', b.id, {'category': category}));
        current[b.id] = b.copyWith(category: category);
      }
      bills.add(current[b.id]!);
    }
    var paid = 0;
    // Q8: a payment linked to an IOU (money lent or paid back) never pays a bill or lands an income.
    final payRows = cz.iouTx.isEmpty
        ? rows
        : [
            for (final r in rows)
              if (!cz.iouTx.contains(r.id)) r
          ];
    // One payment per bill per pass; repeated so a history import with several cycles catches up (bounded).
    for (var pass = 0; pass < 120 && bills.isNotEmpty; pass++) {
      final plan = planRecurringPayments(bills, payRows, currency: currency);

      if (plan.isEmpty) break;
      // A single payment anchors the next cycle on its own date; parts adding up on the cycle's due date.
      bills = [
        for (final b in bills)
          if (plan.paidBy[b.id] case final Tx row)
            b.copyWith(lastPaidTx: row.id, nextDue: addDays(plan.paidInParts.contains(b.id) ? b.nextDue : row.date, b.intervalDays))
          else
            b
      ];
      paid += plan.paidBy.length;
    }
    // P9: an income whose cycle passed (due + tolerance before today) with no landing moves on, cycle by cycle, so a
    // missed income is not expected for ever (its later money, if any, still counts when it lands).
    var missed = 0;
    for (var i = 0; i < bills.length; i++) {
      var x = bills[i];
      if (!x.isIncome) continue;
      for (var n = 0; n < 400 && isIsoDate(x.nextDue) && addDays(x.nextDue, x.tolerance).compareTo(today) < 0; n++) {
        x = x.copyWith(nextDue: addDays(x.nextDue, x.intervalDays));
        missed++;
      }
      bills[i] = x;
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
      'missedIncome': missed,
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
        if (c.isIncome) 'direction': RecurringBill.directionIn,
      };

  void _setRecurring(String id, Map<String, Object?> fields) {
    if (db.select('SELECT 1 FROM recurring WHERE id = ?', [id]).isEmpty) throw ArgumentError('No such bill.');
    _write([('recurring', id, fields)]);
  }

  /// [status] as stored for row [id]: an income's carries the `in:` prefix ([RecurringBill.storedStatus]).
  void _setRecurringStatus(String id, String status) {
    final r = db.select('SELECT * FROM recurring WHERE id = ?', [id]);
    if (r.isEmpty) throw ArgumentError('No such bill.');
    _write([
      ('recurring', id, {'status': RecurringBill.storedStatus(status, income: RecurringBill.fromRow(r.first).isIncome)})
    ]);
  }

  /// The owner says this candidate is a bill: from now on it is reserved in the period budget until paid. For an
  /// income (P9): it counts once its money lands.
  void confirmRecurring(String id) => _setRecurringStatus(id, 'confirmed');

  /// The owner says this is not a bill: hidden from [recurringBills] (unless asked for) and never detected again.
  void dismissRecurring(String id) => _setRecurringStatus(id, 'dismissed');

  /// Removes a bill; its payee is never detected again (the row stays, deleted).
  void deleteRecurring(String id) => _setRecurring(id, {'deleted': 1});

  /// Undo of [deleteRecurring] (bill or income): writes `deleted: 0` (synced; the later of it and a delete by HLC wins).
  /// The row comes back with its other fields as they were (status, due date, last payment). An unknown id is an
  /// [ArgumentError]; a live row writes nothing. A deleted row is never re-created or updated by detection meanwhile
  /// ([refreshRecurring] keeps every existing id, deleted included).
  void undeleteRecurring(String id) {
    final r = db.select('SELECT * FROM recurring WHERE id = ?', [id]);
    if (r.isEmpty) throw ArgumentError('No such bill.');
    if (r.first['deleted'] != 1) return;
    _write([
      ('recurring', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'recurring.undelete', {'income': RecurringBill.fromRow(r.first).isIncome});
  }

  /// The owner skips the bill's current cycle (no payment is coming, or it was paid in a way the match cannot see):
  /// `nextDue` moves one `intervalDays` on from its current value (a monthly instalment plan: one calendar month,
  /// [RecurringBill.stepFrom]), so the bill is no longer due or reserved in this
  /// period and the match looks for the next payment around the new date. No bank row is needed. `lastPaidTx` (the
  /// row that paid the previous cycle) stays as it is: the skipped cycle has none. Synced like every write; an
  /// unknown id is an [ArgumentError], a bill with no due date yet (see [refreshRecurring]) a [StateError].
  Future<void> skipRecurring(String id) async {
    final r = db.select('SELECT * FROM recurring WHERE id = ?', [id]);
    if (r.isEmpty) throw ArgumentError('No such bill.');
    final b = RecurringBill.fromRow(r.first);
    if (!isIsoDate(b.nextDue)) throw StateError('The bill has no due date yet.');
    _write([
      ('recurring', id, {'next_due': b.stepFrom(b.nextDue)})
    ]);
    logEvent(_log, Level.INFO, 'recurring.skip', {'intervalDays': b.intervalDays});
  }

  /// The weekly review was done on [today] (V3, schema 18): writes the synced `review` row of that date (id = done =
  /// [today]), so two devices reviewing on different days before syncing keep both days and the streak is read from the
  /// rows ([reviewDates], [reviewStreak]). No counter is written; the legacy `lastReview` / `reviewStreak` settings are
  /// never written again (they stay the base the rows continue). Done twice on one day changes nothing (no new op).
  void markReviewDone(String today) {
    requireIsoDate(today);
    final row = db.select('SELECT done, deleted FROM reviews WHERE id = ?', [today]);
    // Already live and intact: nothing to write. A damaged `done` (from another device's op) is written again.
    if (row.isNotEmpty && row.first['deleted'] == 0 && row.first['done'] == today) return;
    _write([
      ('review', today, {'done': today, 'deleted': 0})
    ]);
    final dates = reviewDates();
    final st = settings();
    final streak = reviewStreak(dates, legacyLast: st.lastReview, legacyStreak: st.reviewStreak);
    logEvent(_log, Level.INFO, 'review.done', {'streak': streak, 'reviews': dates.length});
  }

  /// The dates of the live `review` rows (V3), ascending, each once; a row whose `done` is not a `YYYY-MM-DD` date (a
  /// damaged op from another device) is skipped.
  List<String> reviewDates() => {
        for (final r in db.select('SELECT done FROM reviews WHERE deleted = 0 ORDER BY done'))
          if (r['done'] case final String d when isIsoDate(d)) d
      }.toList();
}
