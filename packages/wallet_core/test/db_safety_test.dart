// Database safety: reopening, databases made by older builds, rollback on failure, outbox and clock bookkeeping.
// All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

/// The schema exactly as the first v2 commit (fef6998, repo.dart) created it.
const _schemaV2_0 = '''
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

Map<String, Set<String>> _columns(Database db) => {
      for (final t in db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
        t['name'] as String: {for (final c in db.select('PRAGMA table_info(${t['name']})')) c['name'] as String},
    };

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bw-db-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('reopen', () {
    test('everything survives close and reopen: data, device id, outbox, clock, file numbers, applied files', () async {
      final path = '${tmp.path}/wallet.db';
      var t = 1767225600000;
      var r = WalletRepo.open(path, now: () => t);
      r.importBatch(january);
      r.addManual(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      r.updateSettings({'salary': 150000, 'paydayDay': 12});
      r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 0, monthly: 5000, sort: 1);
      r.addWish('Synthetic thing', 9000);
      r.setMerchantRule('lidl_hrvatska_zagreb', 'Groceries');
      final id = r.deviceId, data = dump(r), pending = r.pendingOps().length, last = r.clock.last.toString();
      final file = r.nextFileNumber();
      r.close();

      t = 0; // the wall clock went backwards (e.g. a dead RTC battery)
      r = WalletRepo.open(path, now: () => t);
      expect(r.deviceId, id);
      expect(dump(r), data);
      expect(r.pendingOps().length, pending);
      expect(r.clock.last.toString(), last);
      expect(r.nextFileNumber(), file + 1);
      r.updateSettings({'salary': 160000});
      expect(r.pendingOps().last.$2.hlc.compareTo(last), greaterThan(0), reason: 'new edits must still win over older ones');
      expect(r.settings().salary, 160000);
      r.close();
    });

    test('files applied before a restart are not applied again; exported ops are not exported again', () async {
      final key = VaultKey.generate();
      final folder = Directory('${tmp.path}/sync')..createSync();
      final a = WalletRepo.inMemory();
      a.importBatch(january);
      await FolderSync(folder.path, key).run(a);
      final path = '${tmp.path}/b.db';
      var b = WalletRepo.open(path);
      b.updateSettings({'rent': 1});
      expect((await FolderSync(folder.path, key).run(b)).filesRead, 1);
      b.close();
      b = WalletRepo.open(path);
      final again = await FolderSync(folder.path, key).run(b);
      expect((again.sent, again.filesRead), (0, 0));
      expect(b.transactions().length, january.transactions.length);
      b.close();
      a.close();
    });
  });

  group('older databases', () {
    test('a database written by the first v2 build opens, reads and accepts new writes', () {
      final path = '${tmp.path}/v2_0.db';
      final db = sqlite3.open(path);
      db.execute(_schemaV2_0);
      db.execute(
          "INSERT INTO meta(key, value) VALUES('device_id', '00112233aabbccdd'), ('hlc', '000001767225600000:00003:00112233aabbccdd'), ('file_seq', '4')");
      db.execute(
          "INSERT INTO tx(id, source, date, amount, bank_type, description) VALUES('260117hpzdpn', 'pbz', '2026-01-17', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB')");
      db.execute(
          "INSERT INTO tx(id, source, date, amount, category, note, manual) VALUES('mabc', 'manual', '2026-01-18', -450, 'Eating out', 'synthetic', 1)");
      db.execute("INSERT INTO settings(id, value) VALUES('salary', '150000'), ('merchantPatterns', '[[\"Groceries\",\"corner\"]]')");
      db.execute("INSERT INTO goals(id, name, target, saved, monthly) VALUES('g1', 'Synthetic fund', 100000, 2000, 5000)");
      db.execute("INSERT INTO wish(id, name, price, added) VALUES('w1', 'Synthetic thing', 9000, 1767225600000)");
      db.execute(
          "INSERT INTO clocks(entity, id, field, hlc) VALUES('setting', 'salary', 'value', '000001767225600000:00003:00112233aabbccdd')");
      db.dispose();

      final r = WalletRepo.open(path, now: () => 1767225600000 - 5000);
      expect(r.deviceId, '00112233aabbccdd');
      expect(r.transactions().length, 2);
      expect(r.settings().salary, 150000);
      expect(r.settings().merchantPatterns, [
        ['Groceries', 'corner']
      ]);
      expect(r.goals().single.saved, 2000);
      expect(r.wishlist().single.status, 'waiting');
      r.updateSettings({'salary': 160000});
      expect(r.settings().salary, 160000, reason: 'the stored clock must not make a new edit lose');
      expect(r.nextFileNumber(), 5);
      final cols = _columns(r.db);
      for (final e in entityTables.values) {
        expect(cols[e.$1], containsAll(e.$2), reason: e.$1);
      }
      r.close();
    });

    test('missing tables (a database with only meta and tx) are created on open', () {
      final path = '${tmp.path}/partial.db';
      final db = sqlite3.open(path);
      db.execute(_schemaV2_0.split('CREATE INDEX').first);
      db.execute("INSERT INTO tx(id, source, date, amount, description) VALUES('260117x', 'pbz', '2026-01-17', -100, 'Synthetic')");
      db.dispose();
      final r = WalletRepo.open(path);
      expect(r.transactions().single.id, '260117x');
      expect(r.goals(), isEmpty);
      expect(r.settings().salary, 0);
      r.saveGoal(name: 'Synthetic', target: 1, saved: 0, monthly: 1, sort: 0);
      expect(r.pendingOps().length, 1);
      r.close();
    });

    test('no column of the first v2 schema was dropped or renamed', () {
      final old = sqlite3.openInMemory()..execute(_schemaV2_0);
      final r = WalletRepo.inMemory();
      final now = _columns(r.db);
      for (final e in _columns(old).entries) {
        expect(now[e.key], containsAll(e.value), reason: e.key);
      }
      old.dispose();
      r.close();
    });

    test('every syncable column in the current schema can be written by a remote op', () {
      final r = WalletRepo.inMemory();
      for (final e in entityTables.entries) {
        final fields = {for (final c in e.value.$2) c: c == 'deleted' || c == 'manual' ? 0 : (c == 'amount' || c == 'target' ? 1 : 'x')};
        expect(r.applyRemote([Op(e.key, 'id-${e.key}', fields, const Hlc(5, 0, 'n').toString())]), 1, reason: e.key);
      }
      r.close();
    });
  });

  group('rollback', () {
    test('an import that fails halfway writes nothing (rows, matches, outbox, clocks, stored clock)', () {
      final r = WalletRepo.inMemory();
      r.addManual(date: '2026-01-17', amount: 2340, category: 'Eating out');
      final before = (dump(r), bookkeeping(r), r.db.select("SELECT value FROM meta WHERE key = 'hlc'").first['value']);
      r.db.execute(
          "CREATE TEMP TRIGGER boom BEFORE UPDATE ON tx WHEN NEW.description = 'Synthetic boom' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      final batch =
          ImportBatch(source: 'pbz', transactions: [...january.transactions, n('2026-01-25', -100, 'POS plaćanje', 'Synthetic boom')]);
      expect(() => r.importBatch(batch), throwsA(isA<SqliteException>()));
      expect(dump(r), before.$1);
      expect(bookkeeping(r), before.$2);
      expect(r.db.select("SELECT value FROM meta WHERE key = 'hlc'").first['value'], before.$3);
      r.db.execute('DROP TRIGGER boom');
      final s = r.importBatch(batch);
      expect((s.added, s.matched), (8, 1));
    });

    test('a remote batch that fails halfway applies nothing', () {
      final r = WalletRepo.inMemory();
      final before = dump(r);
      final ops = [
        Op('setting', 'salary', const {'value': '1'}, const Hlc(5, 0, 'n').toString()),
        const Op('setting', 'rent', {'value': '2'}, 'garbage'),
      ];
      expect(() => r.applyRemote(ops), throwsA(isA<FormatException>()));
      expect(dump(r), before);
      expect(r.settings().salary, 0);
    });

    test('the repo stays usable after a failed write', () {
      final r = WalletRepo.inMemory();
      r.db.execute("CREATE TEMP TRIGGER boom BEFORE UPDATE ON goals WHEN NEW.name = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      expect(() => r.saveGoal(name: 'boom', target: 1, saved: 0, monthly: 1, sort: 0), throwsA(isA<SqliteException>()));
      r.saveGoal(name: 'Synthetic', target: 1, saved: 0, monthly: 1, sort: 0);
      expect(r.goals().single.name, 'Synthetic');
      expect(r.pendingOps().length, 1);
    });
  });

  group('outbox and clocks', () {
    test('random local writes: outbox in order, clocks = newest op per field, tables = last writer wins', () {
      final rnd = Random(fuzzSeed(99));
      for (var it = 0; it < fuzzIterations(20); it++) {
        var t = 1767225600000;
        final r = WalletRepo.inMemory(now: () => t);
        r.importBatch(january);
        final ids = r.transactions().map((x) => x.id).toList();
        for (var k = 0; k < 60; k++) {
          t += rnd.nextInt(3) - 1; // the clock stalls and steps back now and then
          switch (rnd.nextInt(5)) {
            case 0:
              r.setCategory(ids[rnd.nextInt(ids.length)], ['Groceries', 'Shopping', null][rnd.nextInt(3)]);
            case 1:
              r.updateSettings({'salary': rnd.nextInt(9999)});
            case 2:
              r.deleteTransaction(ids[rnd.nextInt(ids.length)]);
            case 3:
              r.setMerchantRule('lidl', 'Groceries');
            default:
              r.saveGoal(id: 'g${rnd.nextInt(3)}', name: 'Synthetic', target: 100, saved: rnd.nextInt(50), monthly: 10, sort: 0);
          }
        }
        final pending = r.pendingOps();
        final seqs = pending.map((p) => p.$1).toList(), hlcs = pending.map((p) => p.$2.hlc).toList();
        expect(seqs, [...seqs]..sort());
        expect(hlcs, [...hlcs]..sort(), reason: 'iteration $it: HLCs must follow write order');
        expect(hlcs.toSet().length, hlcs.length);
        expect(r.clock.last.toString(), hlcs.last);
        // clocks hold the newest HLC per field; values match last-writer-wins over the outbox.
        final newest = <String, String>{};
        for (final (_, op) in pending) {
          for (final f in op.fields.keys) {
            newest['${op.entity}|${op.id}|$f'] = op.hlc;
          }
        }
        final clocks = {for (final row in r.db.select('SELECT * FROM clocks')) '${row['entity']}|${row['id']}|${row['field']}': row['hlc']};
        expect(clocks, newest);
        expect(lwwDiff(r, lastWriterWins(pending.map((p) => p.$2))), isEmpty);

        // markExported removes exactly the exported ops.
        final cut = seqs[seqs.length ~/ 2];
        r.markExported(cut);
        expect(r.pendingOps().map((p) => p.$1), seqs.where((s) => s > cut));
        r.markExported(seqs.last);
        expect(r.pendingOps(), isEmpty);
        // Remote ops never land in the outbox.
        r.applyRemote([
          Op('setting', 'rent', const {'value': '5'}, Hlc(t + 99999, 0, 'peer').toString())
        ]);
        expect(r.pendingOps(), isEmpty);
        expect(jsonDecode(r.db.select("SELECT value FROM settings WHERE id = 'rent'").first['value'] as String), 5);
        r.close();
      }
    });
  });
}
