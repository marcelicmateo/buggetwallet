// Database upgrades: for every schema version from 8 on, a database created from that version's DDL (test/fixtures/schema/vN.sql,
// what builds of that version really created) holding one synthetic row per table must open with the current code, keep every
// row, read through the repo API, sync to a fresh device, and survive a second open. The guard test pins the newest snapshot to
// the generated DDL, so a new column forces a snapshot file and a version bump. All data is SYNTHETIC.
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));
const _first = 8;
final _vaultKey = VaultKey(List<int>.generate(32, (i) => i + 1));

String _snapshot(int v) => File('test/fixtures/schema/v$v.sql').readAsStringSync();

String _norm(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').replaceAll('( ', '(').trim();

String _pragmaKey(List<int> k) => 'PRAGMA key = "x\'${k.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"';

/// One synthetic row per data table: table -> (id, columns). Columns the version's table lacks are skipped.
const _rows = <String, (String, Map<String, Object?>)>{
  'tx': (
    'tx-1',
    {'source': 'pbz', 'date': '2026-01-14', 'amount': -1250, 'description': 'Synth Cafe', 'category': 'Eating out', 'note': 'seed'}
  ),
  'goals': ('goal-1', {'name': 'Fund', 'target': 100000, 'saved': 2500, 'monthly': 5000}),
  'wish': ('wish-1', {'name': 'Gadget', 'price': 12000}),
  'settings': ('salary', {'value': '150000'}),
  'merchant_rules': ('synth shop', {'category': 'Shopping'}),
  'goal_contrib': ('gc-1', {'goal_id': 'goal-1', 'amount': 500, 'date': '2026-01-10'}),
  'recurring': (
    'rec-1',
    {'payee': 'Synth Gym', 'label': 'Gym', 'category': 'Health', 'expected_amount': 2500, 'interval_days': 30, 'next_due': '2026-02-01'}
  ),
  'planned': ('plan-1', {'title': 'Synth fee', 'date': '2026-02-05', 'amount': 3000, 'category': 'Bills'}),
  'bills': ('bill-1', {'payee': 'Synth Utility', 'date': '2026-02-01', 'due_date': '2026-02-20', 'total': 4500}),
  'accounts': ('acc-1', {'name': 'Main', 'source': 'pbz', 'currency': 'EUR', 'opening': 1000, 'opening_date': '2026-01-01'}),
  'categories': ('cat-1', {'name': 'Pets', 'kind': 'flex'}),
  'tags': ('tag-1', {'name': 'Trip'}),
  'tx_tags': ('txtag-1', {'tx': 'tx-1', 'tag': 'tag-1', 'state': 'on'}),
  'rule_tags': ('rt-1', {'payee': 'synth cafe', 'tag': 'tag-1'}),
  'tx_splits': ('tx-1', {'parts': '[]'}),
};

/// Creates the database of schema [v] at [path] (encrypted like the app's when [dbKey] is given), seeds it, sets meta.schema.
/// Returns the tables that got a row, with the columns written.
Map<String, Map<String, Object?>> _create(String path, int v, List<int>? dbKey) {
  final db = sqlite3.open(path);
  try {
    if (dbKey != null) {
      db.execute("PRAGMA cipher = 'chacha20'");
      db.execute(_pragmaKey(dbKey));
    }
    db.execute(_snapshot(v));
    final seeded = <String, Map<String, Object?>>{};
    for (final MapEntry(key: table, value: (id, cols)) in _rows.entries) {
      final have = {for (final c in db.select('PRAGMA table_info($table)')) c['name'] as String};
      if (have.isEmpty) continue;
      final used = <String, Object?>{
        'id': id,
        for (final e in cols.entries)
          if (have.contains(e.key)) e.key: e.value
      };
      db.execute('INSERT INTO $table(${used.keys.join(',')}) VALUES(${List.filled(used.length, '?').join(',')})', used.values.toList());
      seeded[table] = used;
      // A real database holds a clock for every field a build wrote; without one the field is "never written" and is not exported.
      final entity = entityTables.entries.firstWhere((e) => e.value.$1 == table).key;
      for (final col in used.keys.where((c) => c != 'id')) {
        db.execute(
            'INSERT INTO clocks(entity, id, field, hlc) VALUES(?, ?, ?, ?)', [entity, id, col, '001767225600000:00000:feedfeedfeedfeed']);
      }
    }
    db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', '$v')");
    return seeded;
  } finally {
    db.close();
  }
}

Map<String, Set<String>> _columnsOf(int v) {
  final db = sqlite3.openInMemory()..execute(_snapshot(v));
  try {
    return {
      for (final t in db.select("SELECT name FROM sqlite_master WHERE type = 'table'"))
        t['name'] as String: {for (final c in db.select('PRAGMA table_info(${t['name']})')) c['name'] as String}
    };
  } finally {
    db.close();
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bw-upg-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('guard: the newest snapshot equals the generated DDL', () {
    final file = File('test/fixtures/schema/v${WalletRepo.schemaVersion}.sql');
    const reason = 'schema changed: add test/fixtures/schema/vN.sql and bump schemaVersion';
    expect(file.existsSync(), isTrue, reason: reason);
    expect(_norm(schemaSql), _norm(file.readAsStringSync()), reason: reason);
  });

  test('every version from $_first to the current one has a snapshot, and no version drops a synced column', () {
    for (var v = _first + 1; v <= WalletRepo.schemaVersion; v++) {
      final old = _columnsOf(v - 1), now = _columnsOf(v);
      for (final MapEntry(key: t, value: c) in old.entries) {
        if (!now.containsKey(t)) continue; // a device-local table may go (v15 dropped the blob bookkeeping tables)
        expect(now[t]!.containsAll(c), isTrue, reason: 'v$v dropped a column of $t');
      }
    }
  });

  for (final keyed in [false, true]) {
    for (var v = _first; v <= WalletRepo.schemaVersion; v++) {
      group('schema $v ${keyed ? 'encrypted' : 'plain'} database', () {
        late String path;
        late List<int>? dbKey;
        late Map<String, Map<String, Object?>> seeded;
        setUp(() async {
          path = '${tmp.path}/w.db';
          dbKey = keyed ? await localDbKey(_vaultKey) : null;
          seeded = _create(path, v, dbKey);
          expect(seeded.keys, containsAll(['tx', 'goals', 'wish', 'settings', 'bills']));
        });

        Map<String, List<Map<String, Object?>>> rawRows() {
          final db = sqlite3.open(path);
          try {
            if (dbKey != null) {
              db.execute("PRAGMA cipher = 'chacha20'");
              db.execute(_pragmaKey(dbKey!));
            }
            return {
              for (final t in seeded.keys) t: [for (final r in db.select('SELECT * FROM $t ORDER BY id')) Map<String, Object?>.from(r)]
            };
          } finally {
            db.close();
          }
        }

        test('opens, keeps every seeded row unchanged, reads through the repo API, and is stamped with the current version', () {
          final before = rawRows();
          final r = WalletRepo.open(path, dbKey: dbKey);
          addTearDown(r.close);
          expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
          for (final t in seeded.keys) {
            final now = [for (final row in r.db.select('SELECT * FROM $t ORDER BY id')) Map<String, Object?>.from(row)];
            expect(now.length, before[t]!.length, reason: '$t: row count');
            for (final col in before[t]!.first.keys) {
              expect(now.first[col], before[t]!.first[col], reason: '$t.$col changed by the upgrade');
            }
          }
          final tx = r.transactions(includeHidden: true).single;
          expect([tx.id, tx.amount, tx.category, tx.note], ['tx-1', -1250, 'Eating out', 'seed']);
          expect(r.settings().salary, 150000);
          expect(r.db.select('SELECT COUNT(*) AS n FROM goals').first['n'], 1);
          expect(r.bills().single.payee, 'Synth Utility');
          if (v >= 9) expect(r.accounts().single.name, 'Main');
          if (v >= 10) expect(r.categoryRows().single.name, 'Pets');
          if (v >= 11) {
            expect(r.tags().single.name, 'Trip');
            expect(r.ruleTags(), isNotEmpty);
          }
          // Columns added after this version exist now, with their defaults.
          if (v < 12) expect(r.db.select('SELECT manual FROM recurring').first['manual'], 0);
          if (v < 14) expect(r.db.select('SELECT direction FROM recurring').first['direction'], isNull);
          if (v < 16) expect(r.db.select('SELECT attached_tx FROM bills').first['attached_tx'], isNull);
          if (v < 18) expect(r.reviewDates(), isEmpty, reason: 'the reviews table is new and empty');
        }, timeout: _t);

        test('the upgraded wallet takes new rows of every newer kind', () async {
          final r = WalletRepo.open(path, dbKey: dbKey);
          addTearDown(r.close);
          r.addTransaction(date: '2026-01-15', amount: -300, category: 'Groceries', note: 'after upgrade');
          expect(r.transactions(includeHidden: true), hasLength(2));
          final id = await r.addAccount(name: 'Card', source: 'revolut', currency: 'EUR', opening: 0, openingDate: '2026-01-01');
          expect(r.accounts().map((a) => a.id), contains(id));
          final tag = await r.addTag('Work');
          expect(r.tagTable().isLive(tag), isTrue);
          final cat = await r.addCategory(name: 'Hobby', kind: BudgetKind.flex);
          expect(r.categoryTable().isLive(cat), isTrue);
          r.markReviewDone('2026-01-15');
          expect(r.reviewDates(), ['2026-01-15']);
        }, timeout: _t);

        test('a second open is a no-op: same rows, no new ops, version unchanged', () {
          final first = WalletRepo.open(path, dbKey: dbKey);
          final ops = first.pendingOps().length;
          final data = dump(first);
          first.close();
          final again = WalletRepo.open(path, dbKey: dbKey);
          addTearDown(again.close);
          expect(again.pendingOps().length, ops, reason: 'the migration queues its ops once');
          expect(dump(again), data);
          expect(again.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
        }, timeout: _t);

        test('the ops replay: the upgraded wallet syncs to a fresh device and both hold the same rows', () async {
          var now = DateTime.utc(2026, 1, 2).millisecondsSinceEpoch;
          final net = Net();
          final old = Device('old', tmp, _vaultKey, () => now, dbPath: path, dbKey: dbKey, net: net, deviceId: 'f1d07e5700000002');
          addTearDown(old.close);
          final fresh = Device('fresh', null, _vaultKey, () => now, net: net, deviceId: 'f1d07e5700000003');
          addTearDown(fresh.close);
          await old.run();
          now += 60000;
          await fresh.run();
          now += 60000;
          await old.run();
          expect(dump(fresh.repo, clocks: false), dump(old.repo, clocks: false));
          expect(fresh.repo.transactions(includeHidden: true).single.amount, -1250);
          expect(fresh.repo.settings().salary, 150000);
          expect(fresh.repo.bills().single.payee, 'Synth Utility');
          // The snapshot of the upgraded wallet restores the same rows into an empty one.
          final copy = WalletRepo.inMemory();
          addTearDown(copy.close);
          copy.applyRemote(old.repo.snapshotOps());
          expect(dump(copy, clocks: false), dump(old.repo, clocks: false));
        }, timeout: _t);
      });
    }
  }

  test('a v12 database as the bump commit created it opens and has recurring.own_category afterwards', () {
    final path = '${tmp.path}/own.db';
    _create(path, 12, null);
    final r = WalletRepo.open(path);
    addTearDown(r.close);
    expect(r.db.select('SELECT own_category FROM recurring').first['own_category'], 0);
  });
}
