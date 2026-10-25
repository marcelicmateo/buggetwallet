// Stage P1 (docs/context/P1_SPEC.md §6): categories across two devices, backup round trip, schema 9 -> 10 and the
// schema 7 fixtures. Written from the spec. All data SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n2.dart';
import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = n2Now;
  final devices = <Device>[];

  Device device(String name) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
    devices.add(d);
    return d;
  }

  Future<void> syncAll(List<Device> ds) async {
    for (var round = 0; round < 3; round++) {
      for (final d in ds) {
        d.deliver(net, Random(round));
        await d.run();
        d.upload(net);
      }
    }
  }

  List<Map<String, Object?>> rows(WalletRepo r) =>
      [for (final x in r.db.select('SELECT * FROM categories ORDER BY id')) Map<String, Object?>.from(x)];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-p1-');
    key = VaultKey.generate();
    net = Net();
    now = n2Now;
  });
  tearDown(() {
    for (final d in devices) {
      d.repo.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  group('two devices', () {
    test('a category and a subcategory added on A reach B with the same rows and clocks', () async {
      final a = device('a'), b = device('b');
      final p = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final c = await a.repo.addCategory(name: 'Food', kind: BudgetKind.flex, parent: p);
      await syncAll([a, b]);
      final t = b.repo.categoryTable();
      expect((t.label(p), t.kindOf(p), t.parentOf(c), t.label(c)), ('Pets', BudgetKind.flex, p, 'Food'));
      expect(t.childrenOf(p), [c]);
      expect(rows(a.repo), rows(b.repo));
    }, timeout: _t);

    test('hide and relabel of a built-in reach the other device', () async {
      final a = device('a'), b = device('b');
      await a.repo.updateCategory('Groceries', name: 'Food shop');
      await a.repo.updateCategory('Shopping', hidden: true);
      await syncAll([a, b]);
      final t = b.repo.categoryTable();
      expect(t.label('Groceries'), 'Food shop');
      expect(t.pickable(), isNot(contains('Shopping')));
      expect(t.kindOf('Groceries'), BudgetKind.flex);
    }, timeout: _t);

    test('different fields edited offline merge; the same field: the later write wins', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await syncAll([a, b]);
      now += 1000;
      await a.repo.updateCategory(id, name: 'Animals');
      now += 1000;
      await b.repo.updateCategory(id, hidden: true);
      now += 1000;
      await a.repo.updateCategory(id, hidden: false);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final t = d.repo.categoryTable();
        expect(t.label(id), 'Animals', reason: d.name);
        expect(t.pickable(), contains(id), reason: d.name);
      }
      expect(rows(a.repo), rows(b.repo));
    }, timeout: _t);

    test('delete on A and undelete on B: the later write wins on both', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await syncAll([a, b]);
      now += 1000;
      await a.repo.deleteCategory(id);
      await syncAll([a, b]);
      expect(b.repo.categoryTable().isLive(id), isFalse);
      now += 1000;
      await b.repo.undeleteCategory(id);
      await syncAll([a, b]);
      expect(a.repo.categoryTable().isLive(id), isTrue);
      expect(rows(a.repo), rows(b.repo));
    }, timeout: _t);

    test('a row using a custom category resolves the same on a device that receives the row first', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final tx = a.repo.addTransaction(date: '2026-10-02', amount: 900, category: id);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final row = d.repo.transactions().firstWhere((t) => t.id == tx);
        expect(d.repo.categorizer().categorize(row).category, id, reason: d.name);
      }
      now += 1000;
      await b.repo.deleteCategory(id);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final row = d.repo.transactions().firstWhere((t) => t.id == tx);
        expect(d.repo.categorizer().categorize(row).category, 'Shopping', reason: d.name);
        expect(row.category, id, reason: 'nothing written to the row');
      }
    }, timeout: _t);

    test('the category op can arrive after the row that uses it: the row falls back, then resolves', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final tx = a.repo.addTransaction(date: '2026-10-02', amount: 900, category: id);
      final row = a.repo.transactions().firstWhere((t) => t.id == tx);
      // B gets the tx op alone first
      final ops = a.repo.snapshotOps();
      b.repo.applyRemote([
        for (final o in ops)
          if (o.entity == 'tx') o
      ]);
      expect(b.repo.categorizer().categorize(b.repo.transactions().firstWhere((t) => t.id == row.id)).category, 'Shopping');
      b.repo.applyRemote([
        for (final o in ops)
          if (o.entity == 'category') o
      ]);
      expect(b.repo.categorizer().categorize(b.repo.transactions().firstWhere((t) => t.id == row.id)).category, id);
    }, timeout: _t);

    test('the same label added offline on both devices: both rows survive and converge identically', () async {
      final a = device('a'), b = device('b');
      final ia = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final ib = await b.repo.addCategory(name: 'pets', kind: BudgetKind.flex);
      await syncAll([a, b]);
      expect(rows(a.repo), rows(b.repo));
      for (final d in [a, b]) {
        expect(d.repo.categoryRows().map((r) => r.id).toSet(), {ia, ib}, reason: '${d.name}: sync cannot refuse');
      }
    }, timeout: _t);

    test('a parent deleted on A while B adds a child: the child is top-level with its own kind, nothing rolls up', () async {
      final a = device('a'), b = device('b');
      final p = await a.repo.addCategory(name: 'Garage', kind: BudgetKind.fixed);
      await syncAll([a, b]);
      now += 1000;
      await a.repo.deleteCategory(p);
      final c = await b.repo.addCategory(name: 'Tyres', kind: BudgetKind.fixed, parent: p);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final t = d.repo.categoryTable();
        expect(t.isLive(p), isFalse, reason: d.name);
        expect(t.isLive(c), isTrue, reason: d.name);
        expect(t.kindOf(c), BudgetKind.fixed, reason: d.name);
        expect(t.topLevel(c), c, reason: d.name);
        expect(t.childrenOf(p), isEmpty, reason: d.name);
        expect(t.pickable(), contains(c), reason: d.name);
        expect(t.spending, contains(c), reason: d.name);
        expect(rollUp({c: 500}, t), {c: 500}, reason: d.name);
      }
      // fixing it: the owner may undelete the parent, and the child follows it again
      now += 1000;
      await a.repo.undeleteCategory(p);
      await syncAll([a, b]);
      expect(b.repo.categoryTable().topLevel(c), p);
      expect(rollUp({c: 500}, b.repo.categoryTable()), {p: 500});
    }, timeout: _t);

    test('a parent deleted on A while B adds a child gives the same totals on both devices in any order', () async {
      final a = device('a'), b = device('b'), c3 = device('c');
      final p = await a.repo.addCategory(name: 'Garage', kind: BudgetKind.flex);
      await syncAll([a, b, c3]);
      now += 1000;
      await a.repo.deleteCategory(p);
      final c = await b.repo.addCategory(name: 'Tyres', kind: BudgetKind.flex, parent: p);
      await syncAll([c3, b, a]);
      await syncAll([a, b, c3]);
      expect(rows(a.repo), rows(b.repo));
      expect(rows(a.repo), rows(c3.repo));
      expect(c3.repo.categoryTable().topLevel(c), c);
    }, timeout: _t);

    test('parent kind changed on one device while a child is added on another: the child follows the parent', () async {
      final a = device('a'), b = device('b');
      final p = await a.repo.addCategory(name: 'Garage', kind: BudgetKind.flex);
      await syncAll([a, b]);
      final c = await b.repo.addCategory(name: 'Tyres', kind: BudgetKind.flex, parent: p);
      a.repo.applyRemote([
        Op('category', p, {'kind': 'fixed'}, const Hlc(9999999999999, 0, 'z').toString())
      ]);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final t = d.repo.categoryTable();
        expect(t.kindOf(p), t.kindOf(c), reason: d.name);
      }
    }, timeout: _t);

    test('a late third device gets every category row', () async {
      final a = device('a'), b = device('b');
      final p = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await b.repo.addCategory(name: 'Garden', kind: BudgetKind.flex);
      await a.repo.addCategory(name: 'Food', kind: BudgetKind.flex, parent: p);
      await a.repo.updateCategory('Groceries', hidden: true);
      await syncAll([a, b]);
      final c = device('c');
      await syncAll([a, b, c]);
      expect(rows(c.repo), rows(a.repo));
      expect(rows(c.repo), hasLength(4));
    }, timeout: _t);
  });

  group('backup', () {
    test('a round trip keeps custom rows, children, overrides and deleted rows with their clocks', () async {
      final a = device('a');
      final p = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final c = await a.repo.addCategory(name: 'Food', kind: BudgetKind.flex, parent: p);
      final gone = await a.repo.addCategory(name: 'Old', kind: BudgetKind.fixed);
      now += 1000;
      await a.repo.updateCategory('Groceries', name: 'Food shop');
      await a.repo.updateCategory('Shopping', hidden: true);
      await a.repo.deleteCategory(gone);
      final file = await backupBytes(a.repo, key);
      final fresh = WalletRepo.inMemory(now: () => now);
      addTearDown(fresh.close);
      expect(fresh.isEmpty, isTrue);
      final count = await restoreBackupBytes(fresh, file, key);
      expect(count, a.repo.snapshotOps().length);
      expect(rows(fresh), rows(a.repo));
      final t = fresh.categoryTable();
      expect((t.label(p), t.parentOf(c), t.label('Groceries')), ('Pets', p, 'Food shop'));
      expect(t.pickable(), isNot(contains('Shopping')));
      expect(t.isLive(gone), isFalse);
      expect(fresh.categoryRows(includeDeleted: true).firstWhere((r) => r.id == gone).deleted, isTrue);
    }, timeout: _t);

    test('a wallet with only a category refuses a restore', () async {
      final a = device('a');
      final b = device('b');
      await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final file = await backupBytes(b.repo, key);
      await expectLater(restoreBackupBytes(a.repo, file, key), throwsStateError);
      expect(a.repo.categoryRows(), hasLength(1));
    }, timeout: _t);

    test('a restored backup reaches another device', () async {
      final a = device('a');
      final p = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final file = await backupBytes(a.repo, key);
      final c = device('c');
      await restoreBackupBytes(c.repo, file, key);
      final d = device('d');
      await syncAll([c, d]);
      expect(d.repo.categoryTable().label(p), 'Pets');
    }, timeout: _t);
  });

  group('schema 9 -> 10', () {
    final dir = Directory('test/fixtures/old_builds');
    final fixKey = VaultKey(List<int>.generate(32, (i) => i + 1));

    String copy(String file) {
      final d = Directory.systemTemp.createTempSync('bw-p1-old-');
      addTearDown(() => d.deleteSync(recursive: true));
      final out = '${d.path}/$file';
      File('${dir.path}/$file').copySync(out);
      return out;
    }

    test('schemaVersion is 10', () => expect(WalletRepo.schemaVersion, 10));

    for (final keyed in [false, true]) {
      final file = 'schema7_${keyed ? 'keyed' : 'plain'}.db';
      test('$file opens at schema 10 with no categories, keeps its rows, and accepts a category', () async {
        final path = copy(file);
        final r = WalletRepo.open(path, dbKey: keyed ? await localDbKey(fixKey) : null);
        addTearDown(r.close);
        expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '10');
        expect(r.categoryRows(includeDeleted: true), isEmpty);
        expect(r.categoryTable().pickable(), CategoryTable.builtIn.pickable());
        expect(r.transactions(includeHidden: true), isNotEmpty);
        expect(r.settings().salary, 150000);
        final id = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
        expect(r.categoryRows().single.id, id);
      }, timeout: _t);
    }

    test('the migration rewrites nothing: no category ops, same pending count on a second open, existing rows keep their category',
        () async {
      final path = copy('schema7_plain.db');
      final first = WalletRepo.open(path);
      expect(first.pendingOps().where((o) => o.$2.entity == 'category'), isEmpty);
      final before = [for (final t in first.transactions(includeHidden: true)) (t.id, t.category)];
      final total = first.pendingOps().length;
      first.close();
      final again = WalletRepo.open(path);
      addTearDown(again.close);
      expect(again.pendingOps().length, total);
      expect([for (final t in again.transactions(includeHidden: true)) (t.id, t.category)], before);
    }, timeout: _t);

    test('categorisation of the old wallet equals the plain Categorizer', () {
      final path = copy('schema7_plain.db');
      final r = WalletRepo.open(path);
      addTearDown(r.close);
      final plain = Categorizer();
      final cz = r.categorizer();
      for (final t in r.transactions(includeHidden: true)) {
        expect(cz.categorize(t).category, plain.categorize(t).category, reason: t.description);
      }
    });

    test('the schema 7 backup restores into a schema 10 wallet with no categories', () async {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      await restoreBackupBytes(r, File('${dir.path}/schema7.bwb').readAsBytesSync(), fixKey);
      expect(r.categoryRows(includeDeleted: true), isEmpty);
      expect(r.transactions(includeHidden: true), isNotEmpty);
    }, timeout: _t);

    test('an upgraded wallet syncs its categories to a new device', () async {
      final path = copy('schema7_plain.db');
      final old = WalletRepo.open(path, now: () => now);
      addTearDown(old.close);
      final oldDev = Device('old', null, key, () => now)..repo = old;
      devices.add(oldDev);
      final fresh = device('fresh');
      final id = await old.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await syncAll([oldDev, fresh]);
      expect(fresh.repo.categoryTable().label(id), 'Pets');
      expect(fresh.repo.transactions(includeHidden: true).length, old.transactions(includeHidden: true).length);
    }, timeout: _t);
  });
}
