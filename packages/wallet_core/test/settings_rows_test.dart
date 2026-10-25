// H3 (schema 8): one settings row per category budget and per merchant pattern, the migration from the legacy maps,
// and two devices editing different entries. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

/// What a schema-7 build wrote: the whole map as one settings row, applied and queued like a local write.
void legacyWrite(WalletRepo r, String key, Object value) => r.applyRemote([
      Op('setting', key, {'value': jsonEncode(value), 'deleted': 0}, r.clock.tick().toString())
    ], resend: true);

Map<String, Object?>? row(WalletRepo r, String id) =>
    r.db.select('SELECT value, deleted FROM settings WHERE id = ?', [id]).map(Map<String, Object?>.from).firstOrNull;

String? clockOf(WalletRepo r, String id) =>
    r.db.select("SELECT hlc FROM clocks WHERE entity = 'setting' AND id = ? AND field = 'value'", [id]).firstOrNull?['hlc'] as String?;

int outbox(WalletRepo r) => r.db.select('SELECT COUNT(*) AS n FROM outbox').first['n'] as int;

List<String> captureLogs() {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  // Without the time prefix: a time can hold digits a private-text check looks for.
  final sub = Logger.root.onRecord.listen(
      (r) => lines.add(formatLogRecord(r).replaceAll(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+[+-]\d\d:\d\d ', multiLine: true), '')));
  addTearDown(() async {
    await sub.cancel();
    Logger.root.level = was;
  });
  return lines;
}

void main() {
  test('schema version 8 or later (9: accounts)', () => expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(8)));

  group('category budgets', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('one row per category: id budget:<category>, value = cents; null leaves a tombstone', () {
      r.setCategoryBudget('Groceries', 30000);
      r.setCategoryBudget('Rent', 0);
      expect(row(r, 'budget:Groceries'), {'value': '30000', 'deleted': 0});
      expect(r.settings().categoryBudgets, {'Groceries': 30000, 'Rent': 0});
      r.setCategoryBudget('Groceries', null);
      expect(row(r, 'budget:Groceries'), {'value': null, 'deleted': 1});
      expect(r.settings().categoryBudgets, {'Rent': 0});
      expect(row(r, 'categoryBudgets'), isNull, reason: 'no legacy map row is written');
    });

    test('an unchanged value writes nothing', () {
      r.setCategoryBudget('Groceries', 30000);
      final n = outbox(r);
      r.setCategoryBudget('Groceries', 30000);
      r.setCategoryBudget('Shopping', null);
      expect(outbox(r), n);
    });

    test('refused: a category that is not spending, negative or too big cents; nothing written', () {
      for (final (c, v) in [
        ('Salary', 100),
        ('Internal transfer', 100),
        ('Nope', 100),
        ('Groceries', -1),
        ('Groceries', WalletSettings.maxBudget + 1)
      ]) {
        expect(() => r.setCategoryBudget(c, v), throwsArgumentError, reason: '$c $v');
      }
      r.setCategoryBudget('Groceries', WalletSettings.maxBudget);
      expect(outbox(r), 1);
    });

    test('updateSettings refuses the maps and the per-key rows, and writes nothing of that call', () {
      for (final k in ['categoryBudgets', 'merchantPatterns', 'budget:Groceries', 'pattern:0123456789abcdef']) {
        expect(() => r.updateSettings({'salary': 1, k: const {}}), throwsArgumentError, reason: k);
      }
      expect(outbox(r), 0);
      expect(r.settings().salary, 0);
    });
  });

  group('merchant patterns', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('row id is a hash of the pattern, value {category, pattern, order}', () {
      r.setMerchantPattern('Groceries', 'corner shop');
      final id = merchantPatternId('corner shop');
      expect(id, matches(RegExp(r'^pattern:[0-9a-f]{16}$')));
      expect(id, isNot(contains('corner')));
      expect(jsonDecode(row(r, id)!['value'] as String), {'category': 'Groceries', 'pattern': 'corner shop', 'order': 0});
    });

    test('new patterns go last; a new category keeps the place; remove and re-add goes last', () {
      r.setMerchantPattern('Groceries', 'a');
      r.setMerchantPattern('Shopping', 'b');
      r.setMerchantPattern('Eating out', 'c');
      expect(r.settings().merchantPatterns, [
        ['Groceries', 'a'],
        ['Shopping', 'b'],
        ['Eating out', 'c']
      ]);
      r.setMerchantPattern('Eating out', 'a');
      expect(r.settings().merchantPatterns.first, ['Eating out', 'a']);
      r.removeMerchantPattern('a');
      expect(row(r, merchantPatternId('a')), {'value': null, 'deleted': 1});
      r.setMerchantPattern('Groceries', 'a');
      expect(r.settings().merchantPatterns.map((p) => p[1]), ['b', 'c', 'a']);
      expect(r.categorizer().merchantCategory('A'), 'Groceries');
    });

    test('refused: unknown category, empty or blank pattern, a pattern that does not compile', () {
      final lines = captureLogs();
      for (final (c, p) in [('Nope', 'x'), ('Groceries', ''), ('Groceries', '  '), ('Groceries', '(synthetic secret')]) {
        expect(() => r.setMerchantPattern(c, p), throwsArgumentError, reason: '$c "$p"');
      }
      expect(outbox(r), 0);
      expect(lines.join('\n'), isNot(contains('synthetic secret')));
    });

    test('removing a pattern that is not set and setting an unchanged one write nothing', () {
      r.setMerchantPattern('Groceries', 'a');
      final n = outbox(r);
      r.setMerchantPattern('Groceries', 'a');
      r.removeMerchantPattern('zzz');
      expect(outbox(r), n);
    });
  });

  group('legacy map rows after the migration', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('an entry without a row reads from the map; one with a row (live or removed) never does', () {
      r.setCategoryBudget('Groceries', 30000);
      r.setCategoryBudget('Shopping', 5000);
      r.setCategoryBudget('Shopping', null);
      legacyWrite(r, 'categoryBudgets', {'Groceries': 1, 'Shopping': 2, 'Eating out': 3, 'Nope': 4});
      expect(r.settings().categoryBudgets, {'Groceries': 30000, 'Eating out': 3});
    });

    test('legacy patterns without a row come after the rows, in their order', () {
      r.setMerchantPattern('Groceries', 'b');
      legacyWrite(r, 'merchantPatterns', [
        ['Shopping', 'b'],
        ['Shopping', 'c'],
        ['Eating out', 'd'],
        ['Eating out', 'c'],
        'junk',
      ]);
      expect(r.settings().merchantPatterns, [
        ['Groceries', 'b'],
        ['Shopping', 'c'],
        ['Eating out', 'd']
      ]);
    });

    test('a damaged pattern row is dropped and logged by key only', () {
      final lines = captureLogs();
      resetInvalidSettingLog();
      r.applyRemote([
        Op(
            'setting',
            merchantPatternId('x'),
            {
              'value': jsonEncode({'category': 'Groceries', 'pattern': 'synthetic x'}),
              'deleted': 0
            },
            r.clock.tick().toString())
      ]);
      r.setMerchantPattern('Shopping', 'y');
      expect(r.settings().merchantPatterns, [
        ['Shopping', 'y']
      ]);
      final warn = lines.where((l) => l.contains('settings.invalid')).toList();
      expect(warn, [endsWith('settings.invalid {"key":"merchantPatterns"}')]);
      expect(lines.join('\n'), isNot(contains('synthetic x')));
    });
  });

  group('migration 7 -> 8', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bw-rows-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    WalletRepo schema7(String path) {
      final r = WalletRepo.open(path);
      legacyWrite(r, 'categoryBudgets', {'Groceries': 30000, 'Rent': 55000, 'Nope': 1});
      legacyWrite(r, 'merchantPatterns', [
        ['Groceries', 'corner'],
        ['Shopping', 'mall'],
        ['Eating out', 'corner'],
      ]);
      r.updateSettings({'salary': 150000});
      r.db.execute("UPDATE meta SET value = '7' WHERE key = 'schema'");
      return r;
    }

    test('the maps become rows with the legacy clock, queued to sync, once; the map rows stay', () {
      final path = '${tmp.path}/w.db';
      final old = schema7(path);
      final before = old.settings();
      final budgetsClock = clockOf(old, 'categoryBudgets'), patternsClock = clockOf(old, 'merchantPatterns');
      final queued = outbox(old);
      old.close();

      final lines = captureLogs();
      final r = WalletRepo.open(path);
      addTearDown(r.close);
      expect(lines.join('\n'), contains('"from":7,"to":${WalletRepo.schemaVersion}'));
      expect(lines.join('\n'), contains('"perKeySettings":4'));
      expect(row(r, 'budget:Groceries'), {'value': '30000', 'deleted': 0});
      expect(row(r, 'budget:Nope'), isNull, reason: 'invalid entries are not migrated');
      expect(clockOf(r, 'budget:Groceries'), budgetsClock);
      expect(clockOf(r, 'budget:Rent'), budgetsClock);
      expect(clockOf(r, merchantPatternId('mall')), patternsClock);
      expect(
          jsonDecode(row(r, merchantPatternId('corner'))!['value'] as String), {'category': 'Groceries', 'pattern': 'corner', 'order': 0});
      expect(row(r, 'categoryBudgets')!['deleted'], 0, reason: 'an older build keeps reading its map');
      expect(outbox(r), queued + 4);
      final s = r.settings();
      expect(s.categoryBudgets, before.categoryBudgets);
      expect(s.merchantPatterns, [
        ['Groceries', 'corner'],
        ['Shopping', 'mall']
      ]);
      expect(s.salary, 150000);

      r.close();
      final again = WalletRepo.open(path);
      addTearDown(again.close);
      expect(outbox(again), queued + 4, reason: 'migrates once');
    });

    test('a crash between the budget and the pattern rows leaves schema 7 and nothing written; the next open migrates once', () {
      final path = '${tmp.path}/w.db';
      final old = schema7(path);
      final queued = outbox(old);
      old.close();
      // A full disk or a killed process while the pattern rows are queued.
      final raw = sqlite3.open(path);
      raw.execute("CREATE TRIGGER crash BEFORE INSERT ON outbox WHEN NEW.op LIKE '%pattern:%' BEGIN SELECT RAISE(ABORT, 'disk full'); END");
      raw.close();
      expect(() => WalletRepo.open(path), throwsA(anything));
      final check = sqlite3.open(path);
      expect(check.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '7');
      expect(check.select("SELECT COUNT(*) AS n FROM settings WHERE id LIKE 'budget:%'").first['n'], 0, reason: 'rolled back');
      check.execute('DROP TRIGGER crash');
      check.close();

      final r = WalletRepo.open(path);
      addTearDown(r.close);
      expect(outbox(r), queued + 4, reason: 'each row queued once');
      expect(r.settings().categoryBudgets, {'Groceries': 30000, 'Rent': 55000});
      expect(r.settings().merchantPatterns.map((p) => p[1]), ['corner', 'mall']);
    });

    test('a legacy row without a clock is migrated with a fresh one', () {
      final path = '${tmp.path}/w.db';
      final old = WalletRepo.open(path);
      old.db.execute("INSERT INTO settings(id, value) VALUES('categoryBudgets', '{\"Groceries\": 100}')");
      old.db.execute("UPDATE meta SET value = '7' WHERE key = 'schema'");
      old.close();
      final r = WalletRepo.open(path);
      addTearDown(r.close);
      expect(row(r, 'budget:Groceries'), {'value': '100', 'deleted': 0});
      expect(clockOf(r, 'budget:Groceries'), isNotNull);
    });

    test('two devices: both converge on the rows, and a budget removed after the first upgrade stays removed', () async {
      var now = 1767225600000;
      final net = Net();
      final key = VaultKey.generate();
      final devices = <Device>[];
      Device device(String name) {
        final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now, dbPath: '${tmp.path}/$name.db');
        devices.add(d);
        return d;
      }

      Future<void> round() async {
        for (final d in devices) {
          now += 1000;
          d.deliver(net, Random(1));
          await d.run();
          d.upload(net);
        }
      }

      addTearDown(() {
        for (final d in devices) {
          d.close();
        }
      });
      final a = device('a'), b = device('b');
      // Both on schema 7 with one shared map.
      legacyWrite(a.repo, 'categoryBudgets', {'Groceries': 30000, 'Rent': 55000});
      await round();
      await round();
      expect(row(b.repo, 'categoryBudgets'), isNotNull);
      for (final d in [a, b]) {
        d.repo.db.execute("UPDATE meta SET value = '7' WHERE key = 'schema'");
      }

      a.reopen(); // a upgrades first and removes a budget
      now += 60000;
      a.repo.setCategoryBudget('Groceries', null);
      a.repo.setCategoryBudget('Eating out', 8000);
      await round();
      b.reopen(); // b upgrades later: its migration replays the old map with the old clock
      await round();
      await round();

      for (final d in [a, b]) {
        expect(d.repo.settings().categoryBudgets, {'Rent': 55000, 'Eating out': 8000}, reason: d.name);
      }
      expect(dump(b.repo)['settings'], dump(a.repo)['settings']);
      List<Map<String, Object?>> settingClocks(WalletRepo r) => [
            for (final c in dump(r)['clocks']!)
              if (c['entity'] == 'setting') c
          ];
      expect(settingClocks(b.repo), settingClocks(a.repo));
    });

    test('a stale map edited on a schema-7 device after the first upgrade never revives or undoes a per-key change', () async {
      var now = 1767225600000;
      final net = Net();
      final key = VaultKey.generate();
      final devices = <Device>[];
      Device device(String name) {
        final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now, dbPath: '${tmp.path}/$name.db');
        devices.add(d);
        return d;
      }

      Future<void> round() async {
        for (final d in devices) {
          now += 1000;
          d.deliver(net, Random(1));
          await d.run();
          d.upload(net);
        }
      }

      addTearDown(() {
        for (final d in devices) {
          d.close();
        }
      });
      final a = device('a'), b = device('b');
      legacyWrite(a.repo, 'categoryBudgets', {'Groceries': 30000, 'Rent': 55000});
      legacyWrite(a.repo, 'merchantPatterns', [
        ['Groceries', 'corner']
      ]);
      await round();
      await round();
      for (final d in [a, b]) {
        d.repo.db.execute("UPDATE meta SET value = '7' WHERE key = 'schema'");
      }
      a.reopen(); // a upgrades, removes one budget, changes another and moves the pattern
      now += 60000;
      a.repo.setCategoryBudget('Groceries', null);
      a.repo.setCategoryBudget('Rent', 60000);
      a.repo.setMerchantPattern('Shopping', 'corner');
      await round(); // b, still on schema 7, receives a's rows
      now += 60000;
      // b's older build edits an unrelated entry: it writes its whole (stale) maps with a newer clock.
      legacyWrite(b.repo, 'categoryBudgets', {'Groceries': 30000, 'Rent': 55000, 'Eating out': 5000});
      legacyWrite(b.repo, 'merchantPatterns', [
        ['Groceries', 'corner'],
        ['Shopping', 'mall']
      ]);
      b.reopen(); // b upgrades: entries with a row are skipped
      await round();
      await round();

      for (final d in [a, b]) {
        expect(d.repo.settings().categoryBudgets, {'Rent': 60000, 'Eating out': 5000}, reason: d.name);
        expect(
            d.repo.settings().merchantPatterns,
            [
              ['Shopping', 'corner'],
              ['Shopping', 'mall']
            ],
            reason: d.name);
      }
      expect(row(b.repo, 'budget:Groceries'), {'value': null, 'deleted': 1});
      expect(dump(b.repo)['settings'], dump(a.repo)['settings']);
    });

    test('two devices edit different budgets at the same time: both edits survive', () async {
      var now = 1767225600000;
      final net = Net();
      final key = VaultKey.generate();
      final a = Device('a', null, key, () => now), b = Device('b', null, key, () => now);
      addTearDown(a.close);
      addTearDown(b.close);
      Future<void> round() async {
        for (final d in [a, b]) {
          now += 1000;
          d.deliver(net, Random(1));
          await d.run();
          d.upload(net);
        }
      }

      a.repo.setCategoryBudget('Groceries', 30000);
      b.repo.setCategoryBudget('Shopping', 10000);
      a.repo.setMerchantPattern('Groceries', 'a');
      b.repo.setMerchantPattern('Shopping', 'b');
      await round();
      await round();
      for (final d in [a, b]) {
        expect(d.repo.settings().categoryBudgets, {'Groceries': 30000, 'Shopping': 10000}, reason: d.name);
        expect(d.repo.settings().merchantPatterns.map((p) => p[1]).toSet(), {'a', 'b'}, reason: d.name);
      }
      expect(a.repo.settings().merchantPatterns, b.repo.settings().merchantPatterns, reason: 'same order on both (ties by id)');
    });
  });
}
