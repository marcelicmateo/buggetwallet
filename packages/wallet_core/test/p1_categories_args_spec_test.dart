// Stage P1 (docs/context/P1_SPEC.md §2, §4, §6): the pieces whose exact signature the spec leaves open. They are kept
// apart so that a different parameter name breaks only this file: `monthlySummaryCsv(..., table:)`,
// `categoryShare(..., rollUp: true, table:)` and `CategoryTable.duplicateOf(id)`. All data SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n2.dart';
import 'support/sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 60));

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => n2Now));
  tearDown(() => repo.close());

  List<CategorizedTx> categorized() {
    final cz = repo.categorizer();
    return repo.transactions().map(cz.categorize).toList();
  }

  group('CSV', () {
    test('with the built-in table the CSV is byte-identical to today', () {
      repo.importBatch(january);
      repo.addTransaction(date: '2026-01-21', amount: 1234, category: 'Groceries');
      final txs = categorized();
      expect(monthlySummaryCsv(txs, currency: 'EUR', table: CategoryTable.builtIn), monthlySummaryCsv(txs, currency: 'EUR'));
      expect(monthlySummaryCsv(txs, currency: 'EUR').split('\n').first, monthlySummaryCsvHeader);
    });

    test('the header lists every spending label; an old child row is its own column (T1)', () async {
      final pets = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final food = await repo.addCategory(name: 'Food', kind: BudgetKind.flex);
      repo.applyRemote([
        Op('category', food, {'parent': pets}, const Hlc(9999999999999, 0, 'z').toString())
      ]);
      final gifts = await repo.addCategory(name: 'Gifts received', kind: BudgetKind.income);
      repo.addTransaction(date: '2026-09-01', amount: 1000, category: pets);
      repo.addTransaction(date: '2026-09-02', amount: 250, category: food);
      repo.addTransaction(date: '2026-09-03', amount: 300, category: 'Groceries');
      repo.addTransaction(date: '2026-10-04', amount: 111, category: food);
      final t = repo.categoryTable();
      final csv = monthlySummaryCsv(categorized(), currency: 'EUR', table: t).split('\n');
      expect(csv.first, monthlySummaryCsvHeaderFor(t));
      expect(csv.first, 'month,${t.spending.map(t.label).join(',')},total');
      expect(csv.first.split(','), containsAll(['Pets', 'Food']));
      expect(csv.first.split(','), isNot(contains('Gifts received')));
      expect(gifts, isNotEmpty);
      final cols = csv.first.split(',');
      List<String> cells(String line) => line.split(',');
      final sep = cells(csv[1]);
      expect(sep.first, '2026-09');
      expect(sep[cols.indexOf('Pets')], '10.00');
      expect(sep[cols.indexOf('Food')], '2.50');
      expect(sep[cols.indexOf('Groceries')], '3.00');
      expect(sep.last, '15.50');
      final oct = cells(csv[2]);
      expect(oct.first, '2026-10');
      expect(oct[cols.indexOf('Pets')], '0.00');
      expect(oct[cols.indexOf('Food')], '1.11');
      expect(oct.last, '1.11');
    }, timeout: _t);

    test('a deleted custom category is not a column', () async {
      final pets = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await repo.deleteCategory(pets);
      final header = monthlySummaryCsv(categorized(), currency: 'EUR', table: repo.categoryTable());
      expect(header, isNot(contains(pets)));
    }, timeout: _t);
  });

  group('categoryShare with rollUp', () {
    final range = DateRange(start: '2026-10-01', end: '2026-10-31');

    test('T1: rollUp: true changes nothing for an old child row (every category is top-level)', () async {
      final pets = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final food = await repo.addCategory(name: 'Food', kind: BudgetKind.flex);
      repo.applyRemote([
        Op('category', food, {'parent': pets}, const Hlc(9999999999999, 0, 'z').toString())
      ]);
      repo.addTransaction(date: '2026-10-01', amount: 1000, category: pets);
      repo.addTransaction(date: '2026-10-02', amount: 250, category: food);
      repo.addTransaction(date: '2026-10-03', amount: 750, category: 'Groceries');
      final txs = categorized();
      final t = repo.categoryTable();
      final plain = categoryShare(txs, range, currency: 'EUR');
      expect({for (final s in plain.slices) s.category: s.spent}, {pets: 1000, food: 250, 'Groceries': 750});
      final rolled = categoryShare(txs, range, currency: 'EUR', rollUp: true, table: t);
      expect({for (final s in rolled.slices) s.category: s.spent}, {pets: 1000, food: 250, 'Groceries': 750});
      expect(rolled.total, plain.total);
      expect(rolled.slices.fold<int>(0, (s, x) => s + x.permille), 1000);
    }, timeout: _t);

    test('with the built-in table rollUp: true changes nothing', () {
      repo.importBatch(january);
      final r = DateRange(start: '2026-01-01', end: '2026-01-31');
      final txs = categorized();
      final a = categoryShare(txs, r, currency: 'EUR');
      final b = categoryShare(txs, r, currency: 'EUR', rollUp: true, table: CategoryTable.builtIn);
      expect([for (final s in b.slices) (s.category, s.spent, s.permille)], [for (final s in a.slices) (s.category, s.spent, s.permille)]);
      expect(b.total, a.total);
    });
  });

  group('sync duplicates', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-p1d-');
      key = VaultKey.generate();
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.repo.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => n2Now);
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

    test('the same label added offline on both devices: the larger id is duplicateOf the smaller, not offered', () async {
      final a = device('a'), b = device('b');
      final ia = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final ib = await b.repo.addCategory(name: 'PETS', kind: BudgetKind.flex);
      await syncAll([a, b]);
      final smallest = ia.compareTo(ib) < 0 ? ia : ib;
      final other = smallest == ia ? ib : ia;
      for (final d in [a, b]) {
        final t = d.repo.categoryTable();
        expect(t.duplicateOf(smallest), isNull, reason: d.name);
        expect(t.duplicateOf(other), smallest, reason: d.name);
        expect(t.pickable(), contains(smallest), reason: d.name);
        expect(t.pickable(), isNot(contains(other)), reason: d.name);
      }
    }, timeout: _t);

    test('a custom label equal to a built-in label: the built-in wins, the custom one is duplicateOf it', () async {
      final a = device('a'), b = device('b');
      // Offline on both: A adds "Pets" while B relabels Shopping to "Pets" (each is unique where it is made).
      final id = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await b.repo.updateCategory('Shopping', name: 'Pets');
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final t = d.repo.categoryTable();
        expect(t.duplicateOf(id), 'Shopping', reason: d.name);
        expect(t.duplicateOf('Shopping'), isNull, reason: d.name);
        expect(t.pickable(), isNot(contains(id)), reason: d.name);
        expect(t.spending, contains(id), reason: 'duplicates stay in spending while live');
      }
    }, timeout: _t);

    test('different labels are never duplicates; a built-in id is never one', () async {
      final a = device('a');
      final x = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final y = await a.repo.addCategory(name: 'Garden', kind: BudgetKind.flex);
      final t = a.repo.categoryTable();
      expect((t.duplicateOf(x), t.duplicateOf(y), t.duplicateOf('Groceries')), (null, null, null));
    }, timeout: _t);
  });
}
