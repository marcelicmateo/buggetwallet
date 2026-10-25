// The typed entity schema: what repo.dart, the snapshot writer, applyRemote's type check, isEmpty and search derive
// from it. All data is SYNTHETIC.
import 'dart:io';

import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

/// The DDL exactly as the last hand-written schema (schema version 7, commit 82f94b3) ran it.
const _schemaV7 = '''
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
  next_due TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'candidate', last_paid_tx TEXT, deleted INTEGER NOT NULL DEFAULT 0,
  min_amount INTEGER, max_amount INTEGER, ends_on TEXT, manual INTEGER NOT NULL DEFAULT 0, own_category INTEGER NOT NULL DEFAULT 0, direction TEXT);
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
CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', source TEXT, currency TEXT NOT NULL DEFAULT 'EUR',
  opening INTEGER NOT NULL DEFAULT 0, opening_date TEXT NOT NULL DEFAULT '', deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS categories(id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT '', parent TEXT,
  position INTEGER, hidden INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS tags(id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', position INTEGER, hidden INTEGER NOT NULL DEFAULT 0,
  deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS tx_tags(id TEXT PRIMARY KEY, tx TEXT NOT NULL DEFAULT '', tag TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS rule_tags(id TEXT PRIMARY KEY, payee TEXT NOT NULL DEFAULT '', tag TEXT NOT NULL DEFAULT '',
  deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS tx_splits(id TEXT PRIMARY KEY, parts TEXT NOT NULL DEFAULT '[]', deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS blob_cache(hash TEXT PRIMARY KEY, sealed BLOB NOT NULL, used_at INTEGER NOT NULL, bytes INTEGER NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS clocks(entity TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, hlc TEXT NOT NULL, PRIMARY KEY(entity, id, field));
CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_cursor(device TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_files(device TEXT NOT NULL, seq INTEGER NOT NULL, ops INTEGER NOT NULL, PRIMARY KEY(device, seq));
''';

String _norm(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').replaceAll('( ', '(').trim();

Map<String, Set<String>> _columns(CommonDatabase db) => {
      for (final t in db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
        t['name'] as String: {for (final c in db.select('PRAGMA table_info(${t['name']})')) c['name'] as String}
    };

void main() {
  group('entitySchema', () {
    test('generates the DDL the hand-written schema v7 ran (whitespace aside)', () {
      expect(_norm(schemaSql), _norm(_schemaV7));
    });

    test('agrees with the independent entity list of the test support (tables and syncable columns, in order)', () {
      expect(entitySchema.keys.toList(), entityTables.keys.toList());
      for (final e in entityTables.entries) {
        expect(entitySchema[e.key]!.table, e.value.$1, reason: e.key);
        expect(entitySchema[e.key]!.columnNames, e.value.$2, reason: e.key);
      }
    });

    test('every synced table has id TEXT PRIMARY KEY, a deleted flag (a tag link: its state) and no column twice', () {
      for (final e in entitySchema.values) {
        if (e.table == 'tx_tags') {
          // T1: a link is never deleted; removing it writes state `off`.
          expect(e.column('deleted'), isNull);
          expect(e.column('state')?.type, ColumnType.text);
        } else {
          expect(e.column('deleted')?.type, ColumnType.flag, reason: e.table);
        }
        expect(e.column('id'), isNull, reason: '${e.table}: id is implicit');
        expect(e.columnNames.toSet().length, e.columns.length, reason: e.table);
        expect(e.createSql, startsWith('CREATE TABLE IF NOT EXISTS ${e.table}(id TEXT PRIMARY KEY, '));
      }
    });

    test('column DDL: nullable columns have no default, the others NOT NULL with theirs', () {
      expect(const ColumnDef('note', nullable: true).ddl, 'note TEXT');
      expect(const ColumnDef('source').ddl, "source TEXT NOT NULL DEFAULT ''");
      expect(const ColumnDef('currency', defaultSql: "'EUR'").ddl, "currency TEXT NOT NULL DEFAULT 'EUR'");
      expect(const ColumnDef.integer('amount').ddl, 'amount INTEGER NOT NULL DEFAULT 0');
      expect(const ColumnDef.integer('total', nullable: true).ddl, 'total INTEGER');
      expect(const ColumnDef.integer('interval_days', defaultSql: '30').ddl, 'interval_days INTEGER NOT NULL DEFAULT 30');
      expect(const ColumnDef.flag('deleted').ddl, 'deleted INTEGER NOT NULL DEFAULT 0');
    });
  });

  group('derived from the schema', () {
    test('applyRemote checks each value by its column type: null only in nullable columns, ints in integer ones', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      var n = 0;
      for (final e in entitySchema.entries) {
        for (final c in e.value.columns) {
          final id = 'row${n++}';
          var tick = 0;
          Op op(Object? v) => Op(e.key, id, {c.name: v}, Hlc(5, ++tick, 'n').toString());
          final reason = '${e.key}.${c.name}';
          expect(r.applyRemote([op(null)]), c.nullable ? 1 : 0, reason: '$reason null');
          switch (c.type) {
            case ColumnType.flag:
              expect(r.applyRemote([op(true)]), 1, reason: '$reason bool');
              expect(r.applyRemote([op('x')]), 0, reason: '$reason text in a flag');
              expect(r.applyRemote([op(2)]), 0, reason: '$reason 2 in a flag');
            case ColumnType.integer:
              expect(r.applyRemote([op(7)]), 1, reason: '$reason int');
              expect(r.applyRemote([op('7')]), 0, reason: '$reason text in an int');
              expect(r.applyRemote([op(7.5)]), 0, reason: '$reason fraction');
            case ColumnType.text:
              expect(r.applyRemote([op('x')]), 1, reason: '$reason text');
              expect(r.applyRemote([op(7)]), 0, reason: '$reason int in text');
          }
        }
      }
    });

    test('one op: a field with an older clock loses while another with no stored clock wins (clocks read once per row)', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      expect(
          r.applyRemote([
            Op('goal', 'g', {'name': 'new'}, const Hlc(9, 0, 'a').toString())
          ]),
          1);
      expect(
          r.applyRemote([
            Op('goal', 'g', {'name': 'old', 'target': 500}, const Hlc(5, 0, 'b').toString())
          ]),
          1);
      final g = r.goals().single;
      expect((g.name, g.target), ('new', 500));
      expect(r.db.select("SELECT field, hlc FROM clocks WHERE entity = 'goal' AND id = 'g' ORDER BY field").map((x) => x['hlc']),
          [const Hlc(9, 0, 'a').toString(), const Hlc(5, 0, 'b').toString()]);
    });

    test('a column missing from any synced table (not only tx) is added on open, with its type and default', () {
      final tmp = Directory.systemTemp.createTempSync('bw-schema-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/old.db';
      WalletRepo.open(path).close();
      final db = sqlite3.open(path);
      db.execute('ALTER TABLE goals DROP COLUMN sort');
      db.execute('ALTER TABLE bills DROP COLUMN blob_bytes');
      db.execute('ALTER TABLE recurring DROP COLUMN interval_days');
      db.execute("INSERT INTO goals(id, name) VALUES('g1', 'Synthetic')");
      db.close();
      final r = WalletRepo.open(path);
      addTearDown(r.close);
      final cols = _columns(r.db);
      for (final e in entityTables.values) {
        expect(cols[e.$1], containsAll(e.$2), reason: e.$1);
      }
      expect(r.db.select('SELECT sort FROM goals').single['sort'], 0, reason: 'the default fills the old row');
      final info = r.db.select('PRAGMA table_info(recurring)').firstWhere((c) => c['name'] == 'interval_days');
      expect((info['type'], info['notnull'], info['dflt_value']), ('INTEGER', 1, '30'));
    });

    test('isEmpty looks at every synced table, deleted rows included', () {
      for (final e in entitySchema.entries) {
        final r = WalletRepo.inMemory();
        expect(r.isEmpty, isTrue);
        final gone = e.value.column('deleted') == null ? "state) VALUES('x', 'off')" : "deleted) VALUES('x', 1)";
        r.db.execute('INSERT INTO ${e.value.table}(id, $gone');
        expect(r.isEmpty, isFalse, reason: e.key);
        r.close();
      }
    });
  });

  group('search by schema', () {
    test('searchableColumns lists the flagged columns; entities without any give none', () {
      expect(searchableColumns('tx'), ['amount', 'description', 'category', 'note']);
      expect(searchableColumns('goal'), ['name', 'target', 'saved']);
      expect(searchableColumns('recurring'), ['label', 'category', 'expected_amount']);
      expect(searchableColumns('setting'), isEmpty);
      expect(searchableColumns('nope'), isEmpty);
    });

    test('searchRows: folded text on text columns, exact cents on integer ones, deleted rows and blank queries never', () {
      final rows = [
        {'id': 'a', 'title': 'Čišćenje', 'amount': 1250, 'category': null, 'deleted': 0},
        {'id': 'b', 'title': 'Other', 'amount': 1250, 'category': 'Home', 'deleted': 1},
        {'id': 'c', 'title': 'Other', 'amount': null, 'category': 'Home', 'deleted': 0},
      ];
      List<Object?> ids(String q) => searchRows('planned', q, rows).map((r) => r['id']).toList();
      expect(ids('cisc'), ['a']);
      expect(ids('12,50'), ['a'], reason: 'b is deleted');
      expect(ids('home'), ['c']);
      expect(ids('   '), isEmpty);
      expect(
          searchRows('setting', 'x', [
            {'id': 's', 'value': 'x', 'deleted': 0}
          ]),
          isEmpty,
          reason: 'no searchable column');
    });

    test('searchAll takes raw rows per entity next to the typed lists and keeps the typed result unchanged', () {
      final r = searchAll('fund', txs: const [], goals: const [], wishlist: const [], bills: const [], rows: {
        'goal': [
          {'id': 'g', 'name': 'Synthetic fund', 'target': 1, 'saved': 0, 'deleted': 0}
        ],
        'wish': [
          {'id': 'w', 'name': 'Nothing', 'price': 1, 'deleted': 0}
        ],
      });
      expect(r.isEmpty, isFalse);
      expect(r.rows['goal']!.single['id'], 'g');
      expect(r.rows['wish'], isEmpty);
      expect(r.goals, isEmpty);
      expect(SearchResult.empty.isEmpty, isTrue);
      expect(searchAll('fund', txs: const [], goals: const [], wishlist: const [], bills: const []).isEmpty, isTrue);
    });
  });
}
