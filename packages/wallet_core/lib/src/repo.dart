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
import 'sqlite_io.dart' if (dart.library.js_interop) 'sqlite_web.dart' as sqlite;
import 'transfers.dart';

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

  /// Pairs of own-account transfers found after this import ([planTransfers]).
  final int transfers;
  const ImportSummary(this.added, this.duplicates, this.matched, this.skipped, {this.transfers = 0});
}

/// Table name and syncable columns per entity.
const Map<String, (String, List<String>)> _entities = {
  'tx': (
    'tx',
    [
      'source', 'date', 'amount', 'currency', 'bank_type', 'description', 'category', 'note', 'manual', 'matched_to', 'deleted',
      'seen_bank',
      'kind_hint', 'transfer_to', // v3: the importer's TxKind name, written once by importBatch; the other side of an own transfer
    ]
  ),
  'goal': ('goals', ['name', 'target', 'saved', 'monthly', 'sort', 'deleted']),
  'wish': ('wish', ['name', 'price', 'added', 'status', 'decided', 'deleted']),
  'setting': ('settings', ['value', 'deleted']),
  'rule': ('merchant_rules', ['category', 'deleted']),
  // Amounts added to a goal's saved total, one row each (see [WalletRepo.addGoalContribution]).
  'goal_contrib': ('goal_contrib', ['goal_id', 'amount', 'date', 'deleted']),
  // Recurring bills (v5): detected candidates and the owner's confirm/dismiss decisions (see [RecurringBill]).
  'recurring': (
    'recurring',
    ['payee', 'label', 'category', 'expected_amount', 'interval_days', 'next_due', 'status', 'last_paid_tx', 'deleted']
  ),
  // Planned costs (v6, §4.3): hand-added, calendar events given an amount or dismissed (see [PlannedCost]).
  'planned': ('planned', ['title', 'date', 'amount', 'category', 'source', 'source_ref', 'status', 'paid_tx', 'deleted']),
  // Bills (v7, stage B): receipts, slips, e-invoices, PDFs and photos (see [Bill]).
  'bill': (
    'bills',
    [
      'source', 'status', 'external_id', 'date', 'due_date', 'payee', 'iban', 'reference', 'description', 'category', 'note', //
      'total', 'currency', 'items', 'unsure', 'linked_tx', 'warranty_until', 'return_by', 'blob', 'blob_type', 'blob_bytes', 'deleted',
    ]
  ),
};

const _schema = '''
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS tx(
  id TEXT PRIMARY KEY, source TEXT NOT NULL DEFAULT '', date TEXT NOT NULL DEFAULT '', amount INTEGER NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'EUR', bank_type TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
  category TEXT, note TEXT, manual INTEGER NOT NULL DEFAULT 0, matched_to TEXT, deleted INTEGER NOT NULL DEFAULT 0, seen_bank TEXT,
  kind_hint TEXT, transfer_to TEXT);
CREATE INDEX IF NOT EXISTS tx_date ON tx(date);
CREATE INDEX IF NOT EXISTS tx_amount ON tx(amount);
CREATE TABLE IF NOT EXISTS goals(id TEXT PRIMARY KEY, name TEXT, target INTEGER NOT NULL DEFAULT 0, saved INTEGER NOT NULL DEFAULT 0,
  monthly INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS wish(id TEXT PRIMARY KEY, name TEXT, price INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'waiting', decided INTEGER, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, value TEXT, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS merchant_rules(id TEXT PRIMARY KEY, category TEXT, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS goal_contrib(id TEXT PRIMARY KEY, goal_id TEXT NOT NULL DEFAULT '', amount INTEGER NOT NULL DEFAULT 0,
  date TEXT NOT NULL DEFAULT '', deleted INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS goal_contrib_goal ON goal_contrib(goal_id);
CREATE TABLE IF NOT EXISTS recurring(id TEXT PRIMARY KEY, payee TEXT NOT NULL DEFAULT '', label TEXT NOT NULL DEFAULT '',
  category TEXT NOT NULL DEFAULT '', expected_amount INTEGER NOT NULL DEFAULT 0, interval_days INTEGER NOT NULL DEFAULT 30,
  next_due TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'candidate', last_paid_tx TEXT, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS planned(id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', date TEXT NOT NULL DEFAULT '', amount INTEGER,
  category TEXT, source TEXT NOT NULL DEFAULT 'manual', source_ref TEXT, status TEXT NOT NULL DEFAULT 'open', paid_tx TEXT,
  deleted INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS planned_date ON planned(date);
CREATE TABLE IF NOT EXISTS bills(id TEXT PRIMARY KEY, source TEXT NOT NULL DEFAULT 'manual', status TEXT NOT NULL DEFAULT 'review',
  external_id TEXT, date TEXT, due_date TEXT, payee TEXT, iban TEXT, reference TEXT, description TEXT, category TEXT, note TEXT,
  total INTEGER, currency TEXT NOT NULL DEFAULT 'EUR', items TEXT NOT NULL DEFAULT '[]', unsure INTEGER NOT NULL DEFAULT 0, linked_tx TEXT,
  warranty_until TEXT, return_by TEXT, blob TEXT, blob_type TEXT, blob_bytes INTEGER, deleted INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS bills_date ON bills(date);
CREATE INDEX IF NOT EXISTS bills_linked ON bills(linked_tx);
CREATE TABLE IF NOT EXISTS blob_cache(hash TEXT PRIMARY KEY, sealed BLOB NOT NULL, used_at INTEGER NOT NULL, bytes INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS blob_outbox(hash TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS blob_delete(hash TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS clocks(entity TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, hlc TEXT NOT NULL, PRIMARY KEY(entity, id, field));
CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_cursor(device TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_files(device TEXT NOT NULL, seq INTEGER NOT NULL, ops INTEGER NOT NULL, PRIMARY KEY(device, seq));
''';

final _log = Logger('bw.repo');
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// The wallet database on one device. All writes go through [_write] so they are
/// recorded as [Op]s and can be synced; remote ops come in through [applyRemote].
class WalletRepo {
  /// The open database (`package:sqlite3/common.dart`, so the same code runs on the native and the WASM build).
  final CommonDatabase db;
  late final String deviceId;
  late final HlcClock clock;
  bool _created = false;

  WalletRepo._(this.db, int Function()? now) {
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute(_schema);
    // Columns added after the first release (CREATE TABLE IF NOT EXISTS leaves an older table as it was).
    final txCols = {for (final r in db.select('PRAGMA table_info(tx)')) r['name'] as String};
    for (final col in ['seen_bank', 'kind_hint', 'transfer_to']) {
      if (!txCols.contains(col)) db.execute('ALTER TABLE tx ADD COLUMN $col TEXT');
    }
    var dev = _meta('device_id');
    if (dev == null) {
      final r = Random.secure();
      dev = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _setMeta('device_id', dev);
      _created = true;
    }
    deviceId = dev;
    clock = HlcClock(dev, now: now, last: _meta('hlc'));
    _dropFolderSync();
    _migrate();
  }

  /// Bump when a new synced entity or field is added. Version 2 added `goal_contrib`, version 3 `tx.kind_hint` and
  /// `tx.transfer_to` (an older build dropped those fields from the ops it read, so they are replayed once), version 4
  /// the `exchange` hint (Revolut Exchange rows imported by version 3 as `ownTransfer` are rewritten once), version 5
  /// the `recurring` entity, version 6 the `planned` entity, version 7 the `bill` entity.
  static const schemaVersion = 7;

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
    var replay = 0, rehinted = 0;
    if (!_created) {
      replay = db.select('SELECT COUNT(*) AS n FROM sync_cursor').first['n'] as int;
      db.execute('DELETE FROM sync_cursor');
      if (from < 4) {
        final stale = db.select("SELECT id FROM tx WHERE source = 'revolut' AND bank_type = ? AND kind_hint = ?",
            [revolutExchangeType, TxKind.ownTransfer.name]);
        rehinted = stale.length;
        _write([
          for (final r in stale) ('tx', r['id'] as String, {'kind_hint': TxKind.exchange.name})
        ]);
      }
    }
    _setMeta('schema', '$schemaVersion');
    logEvent(_log, Level.INFO, 'repo.migrate',
        {'from': from, 'to': schemaVersion, 'new': _created, 'replayDevices': replay, 'rehinted': rehinted});
    if (rehinted > 0) _reconcileLocal();
  }

  static WalletRepo _timedOpen(CommonDatabase Function() opener, bool file, int Function()? now) {
    final t = PerfTimer('repo.open');
    final repo = WalletRepo._(opener(), now);
    int count(String table) => repo.db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as int;
    t.done({'file': file, 'new': repo._created, 'tx': count('tx'), 'outbox': count('outbox')});
    return repo;
  }

  /// Opens (or creates) the database file at [path]. Native only: on the web use [fromDatabase] (with `openKeyed`).
  /// With [dbKey] (`localDbKey`) the file is encrypted: opened keyed, a plaintext one converted in place first
  /// (crash-safe, see `openKeyedFileDb`); a key that does not open it is a `WalletDbKeyException`.
  static WalletRepo open(String path, {List<int>? dbKey, int Function()? now}) =>
      _timedOpen(() => dbKey == null ? sqlite.openFileDb(path) : sqlite.openKeyedFileDb(path, dbKey), true, now);

  /// A fresh in-memory database (tests). Native only: on the web use [fromDatabase].
  static WalletRepo inMemory({int Function()? now}) => _timedOpen(sqlite.openMemoryDb, false, now);

  /// Wraps an already open [db] (e.g. a `package:sqlite3/wasm.dart` database on the web): the same pragmas and
  /// migrations run as for [open] and [inMemory]. [file] says whether it is a persistent database (logged in
  /// `repo.open`, like [open]) or a throwaway one (like [inMemory]). [close] disposes it.
  static WalletRepo fromDatabase(CommonDatabase db, {required bool file, int Function()? now}) => _timedOpen(() => db, file, now);

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
    final def = _entities[op.entity];
    if (def == null) return false;
    final (table, cols) = def;
    final accepted = <String, Object?>{};
    for (final e in op.fields.entries) {
      if (!cols.contains(e.key)) continue;
      final v = _fieldValue(op.entity, e.key, e.value);
      if (identical(v, _bad)) {
        logEvent(_log, Level.WARNING, 'repo.badField', {'entity': op.entity, 'field': e.key});
        continue;
      }
      final rs = db.select('SELECT hlc FROM clocks WHERE entity = ? AND id = ? AND field = ?', [op.entity, op.id, e.key]);
      if (rs.isNotEmpty && Hlc.compareStrings(rs.first['hlc'] as String, op.hlc) >= 0) continue;
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

  /// Column types, for checking synced values: integer columns, 0/1 flags (a bool is stored as 0/1), and the
  /// columns that may hold NULL. Every other synced column is text.
  static const _intCols = {'amount', 'target', 'saved', 'monthly', 'sort', 'price', 'added', 'decided', 'expected_amount', 'interval_days', 'total', 'unsure', 'blob_bytes'};
  static const _flagCols = {'manual', 'deleted'};
  static const _nullable = {
    'tx': {'category', 'note', 'matched_to', 'seen_bank', 'kind_hint', 'transfer_to'},
    'goal': {'name'},
    'wish': {'name', 'decided'},
    'setting': {'value'},
    'rule': {'category'},
    'recurring': {'last_paid_tx'},
    'planned': {'amount', 'category', 'source_ref', 'paid_tx'},
    'bill': {
      'external_id', 'date', 'due_date', 'payee', 'iban', 'reference', 'description', 'category', 'note', 'total', 'linked_tx', //
      'warranty_until', 'return_by', 'blob', 'blob_type', 'blob_bytes',
    },
  };

  /// [value] as it is stored for [entity].[field], or [_bad] if it has the wrong type. A whole number sent as a
  /// float (`12.0`) within the range a double holds exactly is accepted; fractions, huge or non-finite floats are not.
  static Object? _fieldValue(String entity, String field, Object? value) {
    if (value == null) return _nullable[entity]?.contains(field) == true ? null : _bad;
    if (_flagCols.contains(field)) {
      return switch (value) { true || 1 => 1, false || 0 => 0, _ => _bad };
    }
    if (_intCols.contains(field)) {
      const exact = 9007199254740992; // 2^53
      return switch (value) {
        final int v => v,
        final double v when v.isFinite && v == v.roundToDouble() && v.abs() <= exact => v.toInt(),
        _ => _bad,
      };
    }
    return value is String ? value : _bad;
  }

  void _write(List<(String, String, Map<String, Object?>)> changes) {
    if (changes.isEmpty) return;
    final t = PerfTimer('repo.write');
    _tx(() {
      for (final (entity, id, fields) in changes) {
        final op = Op(entity, id, fields, clock.tick().toString());
        _apply(op);
        db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
      }
      _setMeta('hlc', clock.last.toString());
    });
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
      logError(_log, 'repo.rollback', e, st, level: Level.SEVERE);
      db.execute('ROLLBACK');
      rethrow;
    }
  }

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
    for (final e in _entities.entries) {
      final entity = e.key;
      final (table, cols) = e.value;
      final clocks = <String, Map<String, String>>{}; // id -> field -> hlc
      for (final r in db.select('SELECT id, field, hlc FROM clocks WHERE entity = ? ORDER BY id', [entity])) {
        if ((r['id'], r['field'], r['hlc']) case (final String id, final String f, final String h)) {
          if (cols.contains(f)) (clocks[id] ??= {})[f] = h;
        }
      }
      for (final r in db.select('SELECT * FROM $table ORDER BY id')) {
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
  /// bills, planned costs, bills (receipts, slips), merchant rules (deleted rows count: they were data once) and no synced settings. Only such a wallet may
  /// take a restore from a backup; anything else merges through the sync folder.
  bool get isEmpty {
    for (final table in ['tx', 'goals', 'goal_contrib', 'wish', 'recurring', 'planned', 'bills', 'merchant_rules', 'settings']) {
      if (db.select('SELECT 1 FROM $table LIMIT 1').isNotEmpty) return false;
    }
    return true;
  }

  /// Each row's first write, for [planMatches] and `seen_bank`: the clock of its `amount`. Only the write that creates a row sets it
  /// (importBatch, addManual; matching, categories and deletes never touch it), and the clocks table converges to the
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
      if (since == null || !_isoDate.hasMatch(m.date)) continue;
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
    final cz = categorizer();
    final plan = planMatches(manual, [...bank.values], (b) {
      final k = kindOf(cz.autoCategory(b));
      return k == Kind.flex || k == Kind.fixed;
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
  (int, int) _reconcile() {
    final pairs = _pairTransfers();
    final matches = _matchManual();
    _autoLinkBills();
    return (pairs, matches);
  }

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
    _reconcile();
    refreshRecurring(_today());
    _purgeBlobCache();
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
  List<RecurringBill> recurringBills({bool includeDismissed = false}) => [
        for (final r in db.select(
            "SELECT * FROM recurring WHERE deleted = 0 ${includeDismissed ? '' : "AND status != 'dismissed'"} ORDER BY next_due, label, id"))
          RecurringBill.fromRow(r),
      ];

  /// Planned costs (§4.3), ordered by date, then title, then id: the open ones with a date, or with [includeClosed]
  /// every row, paid, skipped (dismissed calendar events included) and deleted ones too ([PlannedCost.deleted]). Pass
  /// `includeClosed: true` to [upcoming] so a calendar event with any row is never suggested again.
  List<PlannedCost> plannedCosts({bool includeClosed = false}) => [
        for (final r in db.select(
            "SELECT * FROM planned ${includeClosed ? '' : "WHERE deleted = 0 AND status = 'open' AND date != ''"} ORDER BY date, title, id"))
          PlannedCost.fromRow(r),
      ];

  Map<String, String> merchantRules() => {
        for (final r in db.select('SELECT id, category FROM merchant_rules WHERE deleted = 0 AND category IS NOT NULL'))
          if ((r['id'], r['category']) case (final String id, final String c)) id: c,
      };

  WalletSettings settings() {
    final m = <String, Object?>{};
    for (final r in db.select('SELECT id, value FROM settings WHERE deleted = 0')) {
      final v = r['value'], k = r['id'] as String;
      if (v is! String) continue;
      try {
        m[k] = jsonDecode(v);
      } on FormatException {
        // A damaged value: that setting falls back to its default. The key only, never the value; once per value.
        logInvalidSetting(k, 'json:$v');
      }
    }
    final s = WalletSettings.fromMap(m);
    return s;
  }

  Categorizer categorizer() {
    final st = settings();
    return Categorizer(merchantRules: merchantRules(), patterns: st.merchantPatterns, rentCashThreshold: st.rentCashThreshold);
  }

  // ---------- writes ----------
  void updateSettings(Map<String, Object?> changes) {
    _write([
      for (final e in changes.entries) ('setting', e.key, {'value': jsonEncode(e.value), 'deleted': 0})
    ]);
  }

  /// Imports a normalized batch. Already-known ids are skipped; `kindHint` is stored (`kind_hint`), `account` never is.
  /// Then own-account transfers are paired across sources ([planTransfers]) and hand-added expenses with the same
  /// amount within 3 days are matched to a bank row their device did not hold when they were added, which keeps their
  /// category ([planMatches]).
  ImportSummary importBatch(ImportBatch batch) {
    final t = PerfTimer('repo.importBatch', warnMs: 500);
    final known = <String>{for (final r in db.select('SELECT id FROM tx')) r['id'] as String};
    final fresh = batch.transactions.where((t) => !known.contains(t.id)).toList();
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
    final s = ImportSummary(fresh.length, batch.transactions.length - fresh.length, matched, batch.skipped, transfers: transfers);
    t.done({
      'source': batch.source,
      'rows': batch.transactions.length,
      'added': s.added,
      'dupes': s.duplicates,
      'matched': s.matched,
      'transfers': s.transfers,
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
  String addManual({required String date, required int amount, required String category, String note = '', String currency = 'EUR'}) {
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
    _write([
      for (final r in db.select('SELECT * FROM bills WHERE deleted = 0 AND linked_tx = ?', [txId]))
        ..._billWrites(Bill.fromRow(r), {'linked_tx': null}, today),
    ]);
    _reconcileLocal();
  }

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
    if (date != null && !_isoDate.hasMatch(date)) throw ArgumentError('The date is not YYYY-MM-DD.');
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
  void refreshRecurring(String today) {
    if (!_isoDate.hasMatch(today)) throw ArgumentError('The date is not YYYY-MM-DD.');
    final t = PerfTimer('repo.recurring');
    final rows = transactions();
    if (rows.isEmpty) {
      // Nothing to detect or pay (and no settings read, which a wallet without rows has no reason for).
      t.done({'rows': 0});
      return;
    }
    final existing = {for (final r in db.select('SELECT * FROM recurring')) r['id'] as String: RecurringBill.fromRow(r)};
    final deleted = {for (final r in db.select('SELECT id FROM recurring WHERE deleted = 1')) r['id'] as String};
    final cz = categorizer();
    final categorized = [for (final r in rows) cz.categorize(r)];
    final detected = detectRecurring(categorized, today: today);
    // The latest live bank outflow per payee: its category is the payee's current one.
    final latest = <String, CategorizedTx>{};
    for (final t in categorized) {
      if (!t.tx.live || t.tx.manual || t.amount >= 0 || t.kind == Kind.transfer) continue;
      final key = merchantKey(t.tx);
      final have = latest[key];
      if (have == null || t.date.compareTo(have.date) > 0 || (t.date == have.date && t.tx.id.compareTo(have.tx.id) > 0)) {
        latest[key] = t;
      }
    }
    final changes = <(String, String, Map<String, Object?>)>[];
    // The bills as they stand after the detection updates below (before payments).
    final current = {for (final e in existing.entries) e.key: e.value};
    var added = 0, updated = 0;
    for (final c in detected) {
      final have = existing[c.id];
      if (have == null) {
        added++;
        changes.add(('recurring', c.id, _candidateFields(c)));
      } else if ((have.status == 'candidate' || have.payee.isEmpty) && !deleted.contains(c.id)) {
        final want = _candidateFields(c), has = _candidateFields(have);
        final diff = {
          for (final e in want.entries)
            if (has[e.key] != e.value) e.key: e.value
        };
        if (diff.isNotEmpty) {
          updated++;
          changes.add(('recurring', c.id, diff));
          current[c.id] = c.copyWith(status: have.status, lastPaidTx: have.lastPaidTx);
        }
      }
    }
    var recategorized = 0;
    var bills = <RecurringBill>[];
    for (final b in current.values) {
      if (!b.confirmed || deleted.contains(b.id) || b.payee.isEmpty) continue;
      final category = latest[b.payee]?.category;
      if (category != null && category != b.category) {
        recategorized++;
        changes.add(('recurring', b.id, {'category': category}));
        current[b.id] = b.copyWith(category: category);
      }
      bills.add(current[b.id]!);
    }
    var paid = 0;
    // One payment per bill per pass; repeated so a history import with several cycles catches up (bounded).
    for (var pass = 0; pass < 120 && bills.isNotEmpty; pass++) {
      final plan = planRecurringPayments(bills, rows);
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
    if (!_isoDate.hasMatch(b.nextDue)) throw StateError('The bill has no due date yet.');
    _write([
      ('recurring', id, {'next_due': addDays(b.nextDue, b.intervalDays)})
    ]);
    logEvent(_log, Level.INFO, 'recurring.skip', {'intervalDays': b.intervalDays});
  }

  // ---------- planned costs (§4.3) ----------

  /// The row id of a planned cost from a source: `<source>:<ref>` (the same on every device, so two devices confirming
  /// or dismissing one calendar event write one row, last writer wins per field), else a new random `p…` id.
  String _plannedId(PlannedSource source, String? sourceRef) =>
      sourceRef != null && sourceRef.isNotEmpty ? '${source.name}:$sourceRef' : _newId('p');

  static void _checkPlanned({String? date, int? amount}) {
    if (date != null && !(_isoDate.hasMatch(date) && isoDate(parseIso(date)) == date)) throw ArgumentError('Bad date.');
    if (amount != null && (amount <= 0 || amount > WalletSettings.maxAmount)) throw ArgumentError('Bad amount.');
  }

  /// Adds an open planned cost and returns its id. [amount] (positive cents) null = no amount yet: listed, never
  /// reserved. With a [sourceRef] (a calendar event's [calendarEventRef]) the id is `<source>:<sourceRef>`: confirming an
  /// event that was dismissed before (or confirmed on another device) reopens and overwrites that one row. A bad
  /// [date] or an amount ≤ 0 is an [ArgumentError].
  String addPlanned(
      {required String title,
      required String date,
      int? amount,
      String? category,
      PlannedSource source = PlannedSource.manual,
      String? sourceRef}) {
    _checkPlanned(date: date, amount: amount);
    final id = _plannedId(source, sourceRef);
    _write([
      (
        'planned',
        id,
        {
          'title': title,
          'date': date,
          'amount': amount,
          'category': category,
          'source': source.name,
          'source_ref': sourceRef,
          'status': PlannedStatus.open.name,
          'paid_tx': null,
          'deleted': 0,
        }
      )
    ]);
    logEvent(_log, Level.INFO, 'planned.add', {'source': source.name, 'withAmount': amount != null});
    return id;
  }

  void _setPlanned(String id, Map<String, Object?> fields, String event) {
    if (db.select('SELECT 1 FROM planned WHERE id = ?', [id]).isEmpty) throw ArgumentError('No such planned cost.');
    if (fields.isEmpty) return;
    _write([('planned', id, fields)]);
    logEvent(_log, Level.INFO, event);
  }

  /// Changes the given fields only (null = unchanged); [clearAmount] / [clearCategory] set those to none. Unknown id,
  /// bad date or amount ≤ 0: [ArgumentError].
  void updatePlanned(String id,
      {String? title, String? date, int? amount, String? category, bool clearAmount = false, bool clearCategory = false}) {
    _checkPlanned(date: date, amount: amount);
    _setPlanned(
        id,
        {
          if (title != null) 'title': title,
          if (date != null) 'date': date,
          if (clearAmount) 'amount': null else if (amount != null) 'amount': amount,
          if (clearCategory) 'category': null else if (category != null) 'category': category,
        },
        'planned.update');
  }

  /// The owner picked [txId] as the transaction that paid it ([paidCandidates]): no longer listed or reserved.
  void markPlannedPaid(String id, String txId) => _setPlanned(id, {'status': PlannedStatus.paid.name, 'paid_tx': txId}, 'planned.paid');

  /// Not coming: no longer listed or reserved.
  void skipPlanned(String id) => _setPlanned(id, {'status': PlannedStatus.skipped.name}, 'planned.skip');

  /// Back to open (undo of Paid or Skip): `paid_tx` cleared.
  void reopenPlanned(String id) => _setPlanned(id, {'status': PlannedStatus.open.name, 'paid_tx': null}, 'planned.reopen');

  /// Removes it (the row stays, deleted, so the calendar event it came from is not suggested again).
  void deletePlanned(String id) => _setPlanned(id, {'deleted': 1}, 'planned.delete');

  /// "No cost" on a calendar suggestion: a synced row `calendar:<sourceRef>` {source calendar, sourceRef, date,
  /// status skipped}, so no device suggests that event again. Writes no title (the column default '' until a confirm
  /// on another device brings one: that title is kept when the two merge). If the event already has a row (confirmed
  /// earlier, here or elsewhere), only its status becomes skipped.
  void dismissCalendarEvent(String sourceRef, String date) {
    if (sourceRef.isEmpty) throw ArgumentError('No event ref.');
    _checkPlanned(date: date);
    final id = _plannedId(PlannedSource.calendar, sourceRef);
    final exists = db.select('SELECT 1 FROM planned WHERE id = ?', [id]).isNotEmpty;
    _write([
      (
        'planned',
        id,
        exists
            ? {'status': PlannedStatus.skipped.name}
            : {
                'date': date,
                'source': PlannedSource.calendar.name,
                'source_ref': sourceRef,
                'status': PlannedStatus.skipped.name,
                'deleted': 0,
              }
      )
    ]);
    logEvent(_log, Level.INFO, 'planned.dismiss', {'existed': exists});
  }

  // ---------- bills (stage B, docs/context/BILLS_API.md §2) ----------

  /// Live bills (deleted ones too with [includeDeleted]), newest first: by date (or due date), then id.
  List<Bill> bills({bool includeDeleted = false}) => [
        for (final r in db.select('SELECT * FROM bills ${includeDeleted ? '' : 'WHERE deleted = 0'} '
            "ORDER BY COALESCE(date, due_date, '') DESC, id"))
          Bill.fromRow(r),
      ];

  /// One bill by id (deleted ones included), or null.
  Bill? bill(String id) {
    final rs = db.select('SELECT * FROM bills WHERE id = ?', [id]);
    return rs.isEmpty ? null : Bill.fromRow(rs.first);
  }

  Bill _liveBill(String id) {
    final b = bill(id);
    if (b == null || b.deleted) throw ArgumentError('No such bill.');
    return b;
  }

  static bool _okDate(String? d) => d != null && _isoDate.hasMatch(d) && isoDate(parseIso(d)) == d;
  static bool _okTotal(int? t) => t != null && t > 0 && t <= WalletSettings.maxAmount;

  /// Adds a bill read from a code, file or photo as status review and returns (id, isNew). With an external id the id
  /// is [Bill.idFor] it, so the same bill read on two devices is one row. A bill already here (same external id) keeps
  /// what it has: a bill in review gets only its empty fields filled, a confirmed one only its file (when it had none)
  /// and its items (when empty); its money fields never change. A deleted one is brought back as a new review bill
  /// with the values read now (isNew true). Values a reader got wrong are left out, never thrown: a date that is not a
  /// real `YYYY-MM-DD`, a total ≤ 0, items past the limits (cut to [maxBillItems], names to [maxBillItemName]). A
  /// [file] the bill does not take is dropped again (never uploaded, or deleted on the relay). A [file] type outside
  /// [blobTypes]: [ArgumentError].
  (String, bool) importBill(NormalizedBill b, {BlobRef? file}) {
    if (file != null && !blobTypes.contains(file.type)) throw ArgumentError('Unknown file type.');
    String? text(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
    final items = [
      for (final i in b.items.take(maxBillItems))
        BillItem(
            name: i.name.length > maxBillItemName ? i.name.substring(0, maxBillItemName) : i.name, quantity: i.quantity, amount: i.amount)
    ];
    final read = <String, Object?>{
      'source': b.source.name,
      'external_id': text(b.externalId),
      'date': _okDate(b.date) ? b.date : null,
      'due_date': _okDate(b.dueDate) ? b.dueDate : null,
      'payee': text(b.payee),
      'iban': text(b.iban),
      'reference': text(b.reference),
      'description': text(b.description),
      'total': _okTotal(b.total) ? b.total : null,
      'currency': RegExp(r'^[A-Z]{3}$').hasMatch(b.currency) ? b.currency : 'EUR',
      'items': encodeBillItems(items),
      'unsure': b.unsure < 0 ? 0 : b.unsure,
      if (file != null) ...{'blob': file.hash, 'blob_type': file.type, 'blob_bytes': file.bytes},
    };
    final ext = read['external_id'] as String?;
    final id = ext != null ? Bill.idFor(ext) : _newId('b');
    final old = ext != null ? bill(id) : null;
    final String event;
    var isNew = true, fileUsed = file != null;
    if (old == null) {
      // No status or deleted here: a late import on another device must never undo a confirm or delete made elsewhere
      // (the column defaults are review and live).
      _write([
        (
          'bill',
          id,
          {
            for (final e in read.entries)
              if (e.value != null) e.key: e.value
          }
        )
      ]);
      event = 'bills.import';
    } else if (old.deleted) {
      _write([
        (
          'bill',
          id,
          {
            for (final c in _entities['bill']!.$2) c: null,
            ...read,
            'items': read['items'] ?? '[]',
            'status': BillStatus.review.name,
            'deleted': 0,
          }
        )
      ]);
      event = 'bills.revive';
    } else {
      isNew = false;
      final row = db.select('SELECT * FROM bills WHERE id = ?', [id]).first;
      bool empty(String k) => row[k] == null || row[k] == '' || (k == 'items' && (decodeBillItems(row[k]) ?? const []).isEmpty);
      const never = {'source', 'currency', 'unsure', 'external_id'};
      final allowed = old.confirmed ? const {'items', 'blob', 'blob_type', 'blob_bytes'} : read.keys.toSet();
      final fill = <String, Object?>{
        for (final e in read.entries)
          if (allowed.contains(e.key) && !never.contains(e.key) && e.value != null && empty(e.key)) e.key: e.value,
      };
      if (row['blob'] != null) fill.removeWhere((k, _) => k.startsWith('blob'));
      fileUsed = fill.containsKey('blob');
      _write([if (fill.isNotEmpty) ('bill', id, fill)]);
      event = 'bills.reimport';
    }
    if (file != null && !fileUsed) _dropBlob(file.hash);
    logEvent(_log, Level.INFO, event, {'source': b.source.name, 'file': fileUsed, 'items': items.length});
    return (id, isNew);
  }

  /// Changes the given fields only (null = unchanged); the clear flags set those to none. A bad date, a total ≤ 0 or
  /// items past the limits: [ArgumentError]. A confirmed bill's planned row follows ([_billWrites]).
  void updateBill(String id,
      {String? date,
      String? dueDate,
      int? total,
      String? payee,
      String? iban,
      String? reference,
      String? description,
      String? category,
      String? note,
      List<BillItem>? items,
      String? warrantyUntil,
      String? returnBy,
      bool clearDueDate = false,
      bool clearWarranty = false,
      bool clearReturnBy = false,
      bool clearCategory = false}) {
    for (final d in [date, dueDate, warrantyUntil, returnBy]) {
      if (d != null && !_okDate(d)) throw ArgumentError('Bad date.');
    }
    if (total != null && !_okTotal(total)) throw ArgumentError('Bad amount.');
    final itemsText = items == null ? null : encodeBillItems(items);
    if (items != null && itemsText == null) throw ArgumentError('Too many items or a name too long.');
    final b = _liveBill(id);
    final fields = <String, Object?>{
      if (date != null) 'date': date,
      if (clearDueDate) 'due_date': null else if (dueDate != null) 'due_date': dueDate,
      if (total != null) 'total': total,
      if (payee != null) 'payee': payee,
      if (iban != null) 'iban': iban,
      if (reference != null) 'reference': reference,
      if (description != null) 'description': description,
      if (clearCategory) 'category': null else if (category != null) 'category': category,
      if (note != null) 'note': note,
      if (itemsText != null) 'items': itemsText,
      if (clearWarranty) 'warranty_until': null else if (warrantyUntil != null) 'warranty_until': warrantyUntil,
      if (clearReturnBy) 'return_by': null else if (returnBy != null) 'return_by': returnBy,
    };
    if (fields.isEmpty) return;
    _write(_billWrites(b, fields, _today()));
    logEvent(_log, Level.INFO, 'bills.update', {'fields': fields.length});
  }

  /// The owner checked the bill: review → confirmed. Needs a date and a total > 0, else [ArgumentError]. A due date
  /// from today on gives it a planned row (reserved until paid); a matching bank row may now link it ([planBillLinks]):
  /// at once while [syncCaughtUp], else at the next caught-up sync.
  void confirmBill(String id) {
    final b = _liveBill(id);
    if (!_okDate(b.date)) throw ArgumentError('The bill needs a date.');
    if (!_okTotal(b.total)) throw ArgumentError('The bill needs a total.');
    _write(_billWrites(b, {if (!b.confirmed) 'status': BillStatus.confirmed.name}, _today()));
    logEvent(_log, Level.INFO, 'bills.confirm', {'source': b.source.name});
    if (syncCaughtUp) {
      _autoLinkBills();
    } else {
      _setMeta('match_pending', '1');
    }
  }

  /// The owner picked [txId] as the bill's payment. A transaction already linked to another bill, an unknown or
  /// deleted transaction or bill: [ArgumentError]. The paying row's category never changes.
  void linkBill(String id, String txId) {
    final b = _liveBill(id);
    final t = transaction(txId);
    if (t == null || t.deleted) throw ArgumentError('No such transaction.');
    if (db.select('SELECT 1 FROM bills WHERE deleted = 0 AND linked_tx = ? AND id != ?', [txId, id]).isNotEmpty) {
      throw ArgumentError('That payment belongs to another bill.');
    }
    _write(_billWrites(b, {'linked_tx': txId}, _today()));
    logEvent(_log, Level.INFO, 'bills.link', {'auto': false});
  }

  /// Not paid by that transaction after all: unpaid again (its planned row reopens). Unknown bill: [ArgumentError].
  void unlinkBill(String id) {
    final b = _liveBill(id);
    if (!b.paid) return;
    _write(_billWrites(b, {'linked_tx': null}, _today()));
    logEvent(_log, Level.INFO, 'bills.unlink');
  }

  /// Deletes the bill (the row stays, deleted; the same code read again brings it back as new) and its planned row;
  /// its file is dropped from this device and deleted on the relay at the next sync, unless another live bill points
  /// to it. Unknown bill: [ArgumentError].
  void deleteBill(String id) {
    final b = _liveBill(id);
    _write(_billWrites(b, {'deleted': 1}, _today()));
    if (b.blob case final h?) _dropBlob(h);
    logEvent(_log, Level.INFO, 'bills.delete', {'file': b.blob != null});
  }

  /// A cash receipt: one write holds the hand-added expense (−total on the bill's date, [category], payee as
  /// description, `seen_bank` like [addManual]), the link, and the confirm when the bill was in review (adding it as
  /// money is the owner's check). No date or total, or already paid: [ArgumentError]. Returns the expense's id.
  String addExpenseFromBill(String id, {required String category}) {
    final b = _liveBill(id);
    if (!_okDate(b.date)) throw ArgumentError('The bill needs a date.');
    if (!_okTotal(b.total)) throw ArgumentError('The bill needs a total.');
    if (b.paid) throw ArgumentError('The bill is already paid.');
    final txId = _newId('m');
    _write([
      (
        'tx',
        txId,
        {
          'source': 'manual',
          'date': b.date,
          'amount': -b.total!,
          'currency': b.currency,
          'description': b.payee ?? '',
          'category': category,
          'note': '',
          'manual': 1,
          'deleted': 0,
          'seen_bank': _seenBank(),
        }
      ),
      ..._billWrites(b, {'linked_tx': txId, if (!b.confirmed) 'status': BillStatus.confirmed.name}, _today()),
    ]);
    logEvent(_log, Level.INFO, 'bills.cashExpense');
    return txId;
  }

  /// The id of a bill's planned row (`bill:<billId>`, the same on every device).
  static String billPlannedId(String billId) => '${PlannedSource.bill.name}:$billId';

  /// The writes for [fields] on bill [b], plus what keeps its planned row in step: a confirmed, unpaid, live bill with
  /// a total and a due date has one open row (created only while the due date is today or later; an existing row
  /// follows edits); a paid bill's row is marked paid with the payment; a deleted bill's row, or one whose due date or
  /// total is gone, is deleted. Nothing is written for a row already as it should be.
  List<(String, String, Map<String, Object?>)> _billWrites(Bill b, Map<String, Object?> fields, String today) {
    final n = Bill.fromRow({...db.select('SELECT * FROM bills WHERE id = ?', [b.id]).first, ...fields});
    final pid = billPlannedId(b.id);
    final rs = db.select('SELECT * FROM planned WHERE id = ?', [pid]);
    final p = rs.isEmpty ? null : PlannedCost.fromRow(rs.first);
    Map<String, Object?> want;
    if (n.deleted || !n.confirmed || !_okTotal(n.total) || !_okDate(n.dueDate)) {
      want = p == null || p.deleted ? const {} : {'deleted': 1};
    } else if (n.paid) {
      want = p == null || p.deleted ? const {} : {'status': PlannedStatus.paid.name, 'paid_tx': n.linkedTx};
    } else if ((p == null || p.deleted) && n.dueDate!.compareTo(today) < 0) {
      want = const {};
    } else {
      want = {
        'title': n.title,
        'date': n.dueDate,
        'amount': n.total,
        'category': n.category,
        'source': PlannedSource.bill.name,
        'source_ref': n.id,
        'status': PlannedStatus.open.name,
        'paid_tx': null,
        'deleted': 0,
      };
    }
    if (rs.isNotEmpty && want.isNotEmpty) {
      final cur = rs.first;
      want = {
        for (final e in want.entries)
          if (cur[e.key] != e.value) e.key: e.value
      };
    }
    return [
      if (fields.isNotEmpty) ('bill', b.id, fields),
      if (want.isNotEmpty) ('planned', pid, want),
    ];
  }

  /// Links confirmed bills to their payments ([planBillLinks]) and closes their planned rows. Runs in [_reconcile]
  /// (only while caught up) and after a confirm. Logged as `bills.autoLink` on `bw.perf` with counts.
  void _autoLinkBills() {
    final open = [
      for (final r in db.select("SELECT * FROM bills WHERE deleted = 0 AND status = 'confirmed' AND linked_tx IS NULL AND total > 0"))
        Bill.fromRow(r)
    ];
    if (open.isEmpty) return;
    final t = PerfTimer('bills.autoLink');
    final totals = {for (final b in open) -b.total!}.toList();
    final rows = [
      for (final r in db.select(
          'SELECT * FROM tx WHERE manual = 0 AND deleted = 0 AND amount IN (${List.filled(totals.length, '?').join(',')})', totals))
        Tx.fromRow(r)
    ];
    final linked = [
      for (final r in db.select('SELECT * FROM bills WHERE deleted = 0 AND linked_tx IS NOT NULL')) Bill.fromRow(r),
    ];
    final plan = planBillLinks([...open, ...linked], rows);
    final today = _today();
    final byId = {for (final b in open) b.id: b};
    _write([
      for (final e in plan.entries) ..._billWrites(byId[e.key]!, {'linked_tx': e.value}, today),
    ]);
    t.done({'bills': open.length, 'rows': rows.length, 'linked': plan.length});
  }

  // ---------- bill files (device-local, never synced or backed up; see BlobStore) ----------

  int _nextBlobUse() => (db.select('SELECT MAX(used_at) AS m FROM blob_cache').first['m'] as int? ?? 0) + 1;

  /// Keeps sealed [bytes] under [hash] in the cache (most recently used), and queues it for upload with [queue].
  void putCachedBlob(String hash, List<int> bytes, {bool queue = false}) {
    db.execute('INSERT OR REPLACE INTO blob_cache(hash, sealed, used_at, bytes) VALUES(?, ?, ?, ?)', [hash, bytes, _nextBlobUse(), bytes.length]);
    if (queue) db.execute('INSERT OR IGNORE INTO blob_outbox(hash) VALUES(?)', [hash]);
  }

  /// The sealed bytes cached for [hash], or null; with [touch] it becomes the most recently used.
  List<int>? cachedBlob(String hash, {bool touch = true}) {
    final rs = db.select('SELECT sealed FROM blob_cache WHERE hash = ?', [hash]);
    if (rs.isEmpty) return null;
    if (touch) db.execute('UPDATE blob_cache SET used_at = ? WHERE hash = ?', [_nextBlobUse(), hash]);
    return rs.first['sealed'] as List<int>;
  }

  /// Removes [hash] from the cache (never one still queued for upload).
  void uncacheBlob(String hash) =>
      db.execute('DELETE FROM blob_cache WHERE hash = ? AND hash NOT IN (SELECT hash FROM blob_outbox)', [hash]);

  /// Drops the least recently used cached files until the cache holds at most [maxBytes] sealed bytes; files still
  /// queued for upload are never dropped. Returns how many were dropped.
  int evictBlobs(int maxBytes) {
    var total = cachedBlobBytes, n = 0;
    if (total <= maxBytes) return 0;
    for (final r in db.select('SELECT hash, bytes FROM blob_cache WHERE hash NOT IN (SELECT hash FROM blob_outbox) ORDER BY used_at')) {
      if (total <= maxBytes) break;
      db.execute('DELETE FROM blob_cache WHERE hash = ?', [r['hash']]);
      total -= r['bytes'] as int;
      n++;
    }
    return n;
  }

  /// Sealed bytes in the cache.
  int get cachedBlobBytes => db.select('SELECT COALESCE(SUM(bytes), 0) AS s FROM blob_cache').first['s'] as int;

  /// Files waiting for upload, in hash order.
  List<String> queuedBlobs() => [for (final r in db.select('SELECT hash FROM blob_outbox ORDER BY hash')) r['hash'] as String];

  /// [hash] is on the relay: no longer queued (it stays cached).
  void blobUploaded(String hash) => db.execute('DELETE FROM blob_outbox WHERE hash = ?', [hash]);

  /// Files to delete on the relay, in hash order.
  List<String> blobDeletes() => [for (final r in db.select('SELECT hash FROM blob_delete ORDER BY hash')) r['hash'] as String];

  /// [hash] was deleted on the relay.
  void blobDeleteDone(String hash) => db.execute('DELETE FROM blob_delete WHERE hash = ?', [hash]);

  /// A file no live bill uses any more: one still queued is simply forgotten (never uploaded), one already uploaded is
  /// queued for deletion on the relay; the cached copy goes either way. Kept while a live bill points to it.
  void _dropBlob(String hash) {
    if (db.select('SELECT 1 FROM bills WHERE deleted = 0 AND blob = ?', [hash]).isNotEmpty) return;
    final queued = db.select('SELECT 1 FROM blob_outbox WHERE hash = ?', [hash]).isNotEmpty;
    db.execute('DELETE FROM blob_outbox WHERE hash = ?', [hash]);
    if (!queued) db.execute('INSERT OR IGNORE INTO blob_delete(hash) VALUES(?)', [hash]);
    db.execute('DELETE FROM blob_cache WHERE hash = ?', [hash]);
    logEvent(_log, Level.FINE, 'blob.drop', {'queued': queued});
  }

  /// Cached files no live bill uses (bills deleted on another device): dropped, except those queued for upload.
  void _purgeBlobCache() {
    db.execute('DELETE FROM blob_cache WHERE hash NOT IN (SELECT hash FROM blob_outbox) '
        'AND hash NOT IN (SELECT blob FROM bills WHERE deleted = 0 AND blob IS NOT NULL)');
    final n = db.updatedRows;
    if (n > 0) logEvent(_log, Level.FINE, 'blob.purge', {'files': n});
  }

  /// The weekly review was done on [today]: `lastReview` = today, `reviewStreak` grows by one when the previous review
  /// was less than 14 days before, i.e. no weekly review day was skipped in between (else starts again at 1). Done
  /// twice on one day changes nothing.
  void markReviewDone(String today) {
    if (!_isoDate.hasMatch(today)) throw ArgumentError('The date is not YYYY-MM-DD.');
    final st = settings();
    final last = st.lastReview;
    if (last == today) return;
    final streak = last != null && daysBetween(last, today) < 14 ? st.reviewStreak + 1 : 1;
    updateSettings({'lastReview': today, 'reviewStreak': streak.clamp(0, WalletSettings.maxStreak)});
    logEvent(_log, Level.INFO, 'review.done', {'streak': streak});
  }
}
