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
  const ImportSummary(this.added, this.duplicates, this.matched, this.skipped);
}

/// Table name and syncable columns per entity.
const Map<String, (String, List<String>)> _entities = {
  'tx': ('tx', ['source', 'date', 'amount', 'currency', 'bank_type', 'description', 'category', 'note', 'manual', 'matched_to', 'deleted']),
  'goal': ('goals', ['name', 'target', 'saved', 'monthly', 'sort', 'deleted']),
  'wish': ('wish', ['name', 'price', 'added', 'status', 'decided', 'deleted']),
  'setting': ('settings', ['value', 'deleted']),
  'rule': ('merchant_rules', ['category', 'deleted']),
};

const _schema = '''
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS tx(
  id TEXT PRIMARY KEY, source TEXT NOT NULL DEFAULT '', date TEXT NOT NULL DEFAULT '', amount INTEGER NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'EUR', bank_type TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
  category TEXT, note TEXT, manual INTEGER NOT NULL DEFAULT 0, matched_to TEXT, deleted INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS tx_date ON tx(date);
CREATE TABLE IF NOT EXISTS goals(id TEXT PRIMARY KEY, name TEXT, target INTEGER NOT NULL DEFAULT 0, saved INTEGER NOT NULL DEFAULT 0,
  monthly INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS wish(id TEXT PRIMARY KEY, name TEXT, price INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'waiting', decided INTEGER, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, value TEXT, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS merchant_rules(id TEXT PRIMARY KEY, category TEXT, deleted INTEGER NOT NULL DEFAULT 0);
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
    var dev = _meta('device_id');
    if (dev == null) {
      final r = Random.secure();
      dev = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _setMeta('device_id', dev);
      _created = true;
    }
    deviceId = dev;
    clock = HlcClock(dev, now: now, last: _meta('hlc'));
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
  bool _apply(Op op) {
    final def = _entities[op.entity];
    if (def == null) return false;
    final (table, cols) = def;
    db.execute('INSERT OR IGNORE INTO $table(id) VALUES(?)', [op.id]);
    final accepted = <String, Object?>{};
    for (final e in op.fields.entries) {
      if (!cols.contains(e.key)) continue;
      final rs = db.select('SELECT hlc FROM clocks WHERE entity = ? AND id = ? AND field = ?', [op.entity, op.id, e.key]);
      if (rs.isNotEmpty && Hlc.compareStrings(rs.first['hlc'] as String, op.hlc) >= 0) continue;
      accepted[e.key] = e.value is bool ? ((e.value as bool) ? 1 : 0) : e.value;
      db.execute('INSERT OR REPLACE INTO clocks(entity, id, field, hlc) VALUES(?, ?, ?, ?)', [op.entity, op.id, e.key, op.hlc]);
    }
    if (accepted.isEmpty) return false;
    final sets = accepted.keys.map((k) => '$k = ?').join(', ');
    db.execute('UPDATE $table SET $sets WHERE id = ?', [...accepted.values, op.id]);
    return true;
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

  /// Each row's first write, for [planMatches]: the clock of its `amount`. Only the write that creates a row sets it
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
    final written = <String, String>{};
    List<Tx> rows(String where, [List<Object?> args = const []]) {
      final out = <Tx>[];
      for (final r in db.select('SELECT tx.*, c.hlc AS written FROM tx $_writtenJoin WHERE $where', args)) {
        final tx = Tx.fromRow(r);
        if (r['written'] case final String h) written[tx.id] = h;
        out.add(tx);
      }
      return out;
    }

    const live = 'tx.manual = 0 AND tx.deleted = 0';
    final manual = rows('tx.manual = 1 AND tx.deleted = 0');
    final targets = rows('$live AND tx.id IN (SELECT matched_to FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to IS NOT NULL)');
    final open = openEntries(manual, {for (final b in targets) b.id});
    if (open.isEmpty) {
      _clearMatchPending();
      t.done({'manual': manual.length, 'open': 0, 'bank': 0, 'added': 0});
      return 0;
    }
    final bank = {for (final b in targets) b.id: b};
    for (final m in open) {
      final since = written[m.id];
      if (since == null || !_isoDate.hasMatch(m.date)) continue;
      // Candidates for this entry only: same amount, within the window, written in or after its millisecond (the
      // exact HLC order is planMatches' job; comparing the 15-digit millis prefix as text is safe for any counter).
      for (final b in rows('$live AND tx.amount = ? AND tx.date BETWEEN ? AND ? AND c.hlc >= ?',
          [m.amount, addDays(m.date, -matchDays), addDays(m.date, matchDays), since.split(':').first])) {
        bank[b.id] = b;
      }
    }
    final cz = categorizer();
    final plan = planMatches(manual, [...bank.values], (b) {
      final k = kindOf(cz.autoCategory(b));
      return k == Kind.flex || k == Kind.fixed;
    }, written);
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

  /// Runs matching if ops applied with `applyRemote(match: false)` changed something since it last ran (also after a
  /// crash mid-sync: the flag is stored). [FolderSync.run] calls it once after applying all files.
  void runPendingMatch() {
    if (_meta('match_pending') != null) _matchManual();
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
  List<Tx> transactions({bool includeHidden = false}) {
    final t = PerfTimer('repo.transactions');
    final rows = db.select('SELECT * FROM tx WHERE date != \'\' ORDER BY date DESC, id DESC');
    final out = <Tx>[];
    for (final r in rows) {
      final tx = Tx.fromRow(r);
      if (includeHidden || tx.live) out.add(tx);
    }
    t.done({'rows': rows.length, 'live': out.length});
    return out;
  }

  Tx? transaction(String id) {
    final rs = db.select('SELECT * FROM tx WHERE id = ?', [id]);
    return rs.isEmpty ? null : Tx.fromRow(rs.first);
  }

  List<Goal> goals() => [for (final r in db.select('SELECT * FROM goals WHERE deleted = 0 ORDER BY sort, id')) Goal.fromRow(r)];

  List<WishItem> wishlist() => [for (final r in db.select('SELECT * FROM wish WHERE deleted = 0 ORDER BY added')) WishItem.fromRow(r)];

  Map<String, String> merchantRules() => {
        for (final r in db.select('SELECT id, category FROM merchant_rules WHERE deleted = 0 AND category IS NOT NULL'))
          r['id'] as String: r['category'] as String,
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

  /// Imports a normalized batch. Already-known ids are skipped. Hand-added expenses with the
  /// same amount within 3 days are then matched to a bank row written after them, which keeps their category
  /// ([planMatches]).
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
          'manual': 0,
          // Never 'deleted': a new row is live through the column default, and writing deleted: 0 here with a
          // fresh HLC would undo a delete made on another device that this one has not synced yet. Only
          // deleteTransaction (and a future undelete) write that field.
        }
      ));
    }
    _write(changes);
    final matched = _matchManual();
    final s = ImportSummary(fresh.length, batch.transactions.length - fresh.length, matched, batch.skipped);
    t.done({
      'source': batch.source,
      'rows': batch.transactions.length,
      'added': s.added,
      'dupes': s.duplicates,
      'matched': s.matched,
      'skipped': s.skipped
    });
    return s;
  }

  String _newId(String prefix) {
    final r = Random.secure();
    return '$prefix${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 20).toRadixString(36)}';
  }

  /// A hand-entered expense (positive [amount] = money spent).
  String addManual({required String date, required int amount, required String category, String note = '', String currency = 'EUR'}) {
    final id = _newId('m');
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
          'deleted': 0
        }
      ),
    ]);
    // No matching here: a bank row already in the wallet is never this entry's row (planMatches). The entry is
    // matched by the next import, here or on another device, that brings a bank row written after it.
    return id;
  }

  void setCategory(String txId, String? category) => _write([
        ('tx', txId, {'category': category})
      ]);

  /// Deletes a row. A hand-added expense that this bank row replaced counts again (and may be matched by a later
  /// bank row): see [planMatches].
  void deleteTransaction(String txId) {
    _write([
      ('tx', txId, {'deleted': 1})
    ]);
    _matchManual();
  }

  void setMerchantRule(String key, String category) => _write([
        ('rule', key, {'category': category, 'deleted': 0})
      ]);

  String saveGoal({String? id, required String name, required int target, required int saved, required int monthly, int? sort}) {
    final gid = id ?? _newId('g');
    _write([
      (
        'goal',
        gid,
        {
          'name': name,
          'target': target,
          'saved': saved,
          'monthly': monthly,
          'sort': sort ?? DateTime.now().millisecondsSinceEpoch,
          'deleted': 0
        }
      ),
    ]);
    return gid;
  }

  void deleteGoal(String id) => _write([
        ('goal', id, {'deleted': 1})
      ]);

  /// Adds each goal's monthly amount to its saved total (the payday transfer).
  void payGoals() => _write([
        for (final g in goals()) ('goal', g.id, {'saved': g.saved + g.monthly})
      ]);

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
