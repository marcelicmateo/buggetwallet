import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'categories.dart';
import 'dates.dart';
import 'hlc.dart';
import 'logs.dart';
import 'matching.dart';
import 'models.dart';
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
CREATE TABLE IF NOT EXISTS clocks(entity TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, hlc TEXT NOT NULL, PRIMARY KEY(entity, id, field));
CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS peer_files(device TEXT NOT NULL, file TEXT NOT NULL, PRIMARY KEY(device, file));
''';

final _log = Logger('bw.repo');
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// The wallet database on one device. All writes go through [_write] so they are
/// recorded as [Op]s and can be synced; remote ops come in through [applyRemote].
class WalletRepo {
  final Database db;
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
    _migrate();
  }

  /// Bump when a new synced entity or field is added. Version 2 added `goal_contrib`, version 3 `tx.kind_hint` and
  /// `tx.transfer_to` (an older build dropped those fields from the ops it read, so they are replayed once), version 4
  /// the `exchange` hint (Revolut Exchange rows imported by version 3 as `ownTransfer` are rewritten once).
  static const schemaVersion = 4;

  /// Builds before a synced entity existed skipped its ops but still marked the peer files holding them as read. So
  /// when an existing database is opened by a build with a newer [schemaVersion], it forgets which peer files it read
  /// (`peer_files`): the next sync reads every file once more, ops already applied change nothing (their clocks are
  /// not newer), and the skipped ones apply. A new database just records the version.
  ///
  /// Below version 4, Revolut Exchange legs were imported with the `ownTransfer` hint, which lets them anchor a pair
  /// across sources; `importBatch` skips known ids and never edits `kind_hint`, so they are rewritten here once to
  /// `exchange` through [_write] (the change syncs) and reconciled at once, which dissolves their pairs.
  void _migrate() {
    final from = int.tryParse(_meta('schema') ?? '') ?? 1;
    if (from >= schemaVersion) return;
    var replay = 0, rehinted = 0;
    if (!_created) {
      replay = db.select('SELECT COUNT(*) AS n FROM peer_files').first['n'] as int;
      db.execute('DELETE FROM peer_files');
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
        {'from': from, 'to': schemaVersion, 'new': _created, 'replayFiles': replay, 'rehinted': rehinted});
    if (rehinted > 0) _reconcile();
  }

  static WalletRepo _timedOpen(Database Function() opener, bool file, int Function()? now) {
    final t = PerfTimer('repo.open');
    final repo = WalletRepo._(opener(), now);
    int count(String table) => repo.db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as int;
    t.done({'file': file, 'new': repo._created, 'tx': count('tx'), 'outbox': count('outbox')});
    return repo;
  }

  static WalletRepo open(String path, {int Function()? now}) => _timedOpen(() => sqlite3.open(path), true, now);
  static WalletRepo inMemory({int Function()? now}) => _timedOpen(sqlite3.openInMemory, false, now);

  void close() {
    logEvent(_log, Level.FINE, 'repo.close');
    db.dispose();
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
  static const _intCols = {'amount', 'target', 'saved', 'monthly', 'sort', 'price', 'added', 'decided'};
  static const _flagCols = {'manual', 'deleted'};
  static const _nullable = {
    'tx': {'category', 'note', 'matched_to', 'seen_bank', 'kind_hint', 'transfer_to'},
    'goal': {'name'},
    'wish': {'name', 'decided'},
    'setting': {'value'},
    'rule': {'category'},
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
  int applyRemote(List<Op> ops, {bool match = true}) {
    final t = PerfTimer('repo.applyRemote');
    var changed = 0;
    _tx(() {
      for (final op in ops) {
        clock.receive(Hlc.parse(op.hlc));
        if (_apply(op)) changed++;
      }
      _setMeta('hlc', clock.last.toString());
      if (changed > 0) _setMeta('match_pending', '1');
    });
    t.done({'ops': ops.length, 'changed': changed});
    if (match) runPendingMatch();
    return changed;
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
  /// (a paired row is a transfer, so it is no longer a payment a cash entry could be). Returns (pairs, matches).
  (int, int) _reconcile() {
    final pairs = _pairTransfers();
    return (pairs, _matchManual());
  }

  /// Runs transfer pairing and matching if ops applied with `applyRemote(match: false)` changed something since it
  /// last ran (also after a crash mid-sync: the flag is stored). [FolderSync.run] calls it once after applying all files.
  void runPendingMatch() {
    if (_meta('match_pending') != null) _reconcile();
  }

  bool peerFileSeen(String device, String file) =>
      db.select('SELECT 1 FROM peer_files WHERE device = ? AND file = ?', [device, file]).isNotEmpty;
  void markPeerFile(String device, String file) =>
      db.execute('INSERT OR IGNORE INTO peer_files(device, file) VALUES(?, ?)', [device, file]);

  int nextFileNumber() {
    final n = int.tryParse(_meta('file_seq') ?? '0') ?? 0;
    _setMeta('file_seq', '${n + 1}');
    return n + 1;
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
    final (transfers, matched) = _reconcile();
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
    _reconcile();
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
}
