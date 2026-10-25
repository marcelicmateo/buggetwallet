// Stage P1 (core builder): custom categories and subcategories (schema 10), CategoryTable, rollUp, the callers that
// switched to the table, two devices and backup. All data is SYNTHETIC.
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 12:00 UTC.
const _noon = 1791633600000;

CategorizedTx _c(String id, String date, int cents, String category, CategoryTable t, {String currency = 'EUR'}) => CategorizedTx(
    Tx(id: id, source: 'pbz', date: date, amount: cents, currency: currency, description: 'Synthetic'), category, t.kindOf(category));

/// Synthetic rows over three months in built-in categories (income, fixed, flex, transfers, a refund, another currency).
List<CategorizedTx> _builtInMonths() {
  final t = CategoryTable.builtIn;
  var i = 0;
  final out = <CategorizedTx>[];
  for (final m in ['2026-07', '2026-08', '2026-09']) {
    out.addAll([
      _c('s${i++}', '$m-10', 150000, 'Salary', t),
      _c('s${i++}', '$m-11', -55000, 'Rent', t),
      _c('s${i++}', '$m-12', -2340, 'Groceries', t),
      _c('s${i++}', '$m-13', -1999, 'Groceries', t),
      _c('s${i++}', '$m-14', 500, 'Groceries', t),
      _c('s${i++}', '$m-15', -4500, 'Eating out', t),
      _c('s${i++}', '$m-16', -10000, 'Internal transfer', t),
      _c('s${i++}', '$m-17', -1200, 'Games & apps', t, currency: 'USD'),
      _c('s${i++}', '$m-18', 30000, 'Extra income', t),
      _c('s${i++}', '$m-19', -333, 'Bank fees', t),
    ]);
  }
  return out;
}

void main() {
  group('CategoryTable.builtIn is today\'s behaviour', () {
    final t = CategoryTable.builtIn;
    test('kinds, spending, labels, pickable and order equal the globals', () {
      for (final c in categories.keys) {
        expect(t.kindOf(c), kindOf(c));
        expect(t.isSpending(c), spendingCategories.contains(c));
        expect(t.label(c), c);
        expect(t.isLive(c), isTrue);
        expect(t.topLevel(c), c);
        expect(t.parentOf(c), isNull);
      }
      expect(t.kindOf('Nope'), kindOf('Nope'));
      expect(t.isSpending('Nope'), isFalse);
      expect(t.isLive('Nope'), isFalse);
      expect(t.label('Nope'), 'Nope');
      expect(t.spending, spendingCategories);
      expect(t.pickable(), categories.keys.toList());
      expect(t.pickable(kinds: {BudgetKind.flex}), flexCategories);
      expect(monthlySummaryCsvHeaderFor(t), 'month,${spendingCategories.join(',')},total');
      expect(monthlySummaryCsvHeader, 'month,${spendingCategories.join(',')},total');
    });

    test('monthSummary, budgetVsActual, CSV and categoryShare give identical results with and without the table', () {
      final rows = _builtInMonths();
      final budgets = {'Groceries': 5000, 'Rent': 55000, 'Eating out': 1000};
      expect(
          rollUp(monthSummary(rows, '2026-09', currency: 'EUR').byCategory, t), monthSummary(rows, '2026-09', currency: 'EUR').byCategory);
      final a = budgetVsActual(rows, '2026-09', budgets, today: '2026-09-20', currency: 'EUR');
      final b = budgetVsActual(rows, '2026-09', budgets, today: '2026-09-20', currency: 'EUR', table: t);
      String lines(BudgetVsActual x) => '${[
            for (final l in x.lines) '${l.category}|${l.budget}|${l.actual}|${l.average6}'
          ].join(';')}|${x.budgetTotal}|${x.actualTotal}|${x.remainingTotal}';
      expect(lines(b), lines(a));
      expect(monthlySummaryCsv(rows, currency: 'EUR', table: t), monthlySummaryCsv(rows, currency: 'EUR'));
      final r = DateRange(start: '2026-07-01', end: '2026-09-30');
      String share(CategoryShare s) => [for (final x in s.slices) '${x.category}|${x.spent}|${x.permille}'].join(';');
      expect(share(categoryShare(rows, r, currency: 'EUR', rollUp: true, table: t)), share(categoryShare(rows, r, currency: 'EUR')));
      expect(suggestBudgets(rows, '2026-10', currency: 'EUR', table: t), suggestBudgets(rows, '2026-10', currency: 'EUR'));
    });

    test('the repo with no category rows categorizes the synthetic month exactly as the built-in Categorizer', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.importBatch(january);
      final plain = Categorizer();
      final cz = r.categorizer();
      for (final x in r.transactions(includeHidden: true)) {
        expect(cz.categorize(x).category, plain.categorize(x).category);
        expect(cz.categorize(x).kind, plain.categorize(x).kind);
      }
    });
  });

  group('the table', () {
    test('a child takes its parent\'s kind, rolls up, and is listed after its parent', () {
      final t = CategoryTable.from(const [
        CategoryRow(id: 'kaaaaaaaaaaaa', name: 'Pet food', kind: BudgetKind.income, parent: 'Groceries', position: 0),
        CategoryRow(id: 'kbbbbbbbbbbbb', name: 'Pets', kind: BudgetKind.flex, position: 30),
        CategoryRow(id: 'kcccccccccccc', name: 'Vet', kind: BudgetKind.flex, parent: 'kbbbbbbbbbbbb', position: 1),
        CategoryRow(id: 'kdddddddddddd', name: 'Toys', kind: BudgetKind.flex, parent: 'kbbbbbbbbbbbb', position: 0),
      ]);
      expect(t.kindOf('kaaaaaaaaaaaa'), BudgetKind.flex, reason: 'the kind is read from the parent');
      expect(t.topLevel('kcccccccccccc'), 'kbbbbbbbbbbbb');
      expect(t.childrenOf('kbbbbbbbbbbbb'), ['kdddddddddddd', 'kcccccccccccc']);
      final p = t.pickable();
      expect(p.indexOf('kaaaaaaaaaaaa'), p.indexOf('Groceries') + 1);
      expect(p.sublist(p.length - 3), ['kbbbbbbbbbbbb', 'kdddddddddddd', 'kcccccccccccc']);
      expect(t.spending, [...spendingCategories, 'kbbbbbbbbbbbb']);
      expect(t.isSpending('kcccccccccccc'), isTrue);
      final sums = rollUp({'kcccccccccccc': 101, 'kbbbbbbbbbbbb': 7, 'kdddddddddddd': -3, 'Groceries': 50, 'kaaaaaaaaaaaa': 1}, t);
      expect(sums, {'kbbbbbbbbbbbb': 105, 'Groceries': 51});
    });

    test('relabel and hide a built-in: the id stays, the kind is fixed by the built-in', () {
      final t = CategoryTable.from(const [
        CategoryRow(id: 'Groceries', name: 'Food shop', kind: BudgetKind.income, parent: 'Rent', hidden: true, deleted: true),
      ]);
      expect(t.label('Groceries'), 'Food shop');
      expect(t.kindOf('Groceries'), BudgetKind.flex);
      expect(t.parentOf('Groceries'), isNull);
      expect(t.isLive('Groceries'), isTrue);
      expect(t.pickable(), isNot(contains('Groceries')));
      expect(t.spending, contains('Groceries'));
    });

    test('one level only: a chain or a cycle from a sync race leaves the inner rows top-level', () {
      final t = CategoryTable.from(const [
        CategoryRow(id: 'k000000000001', name: 'A', parent: 'k000000000002'),
        CategoryRow(id: 'k000000000002', name: 'B', parent: 'k000000000003'),
        CategoryRow(id: 'k000000000003', name: 'C'),
        CategoryRow(id: 'k000000000004', name: 'D', parent: 'k000000000005'),
        CategoryRow(id: 'k000000000005', name: 'E', parent: 'k000000000004'),
      ]);
      expect(t.parentOf('k000000000002'), 'k000000000003');
      expect(t.parentOf('k000000000001'), isNull);
      expect(t.parentOf('k000000000004'), isNull);
      expect(t.parentOf('k000000000005'), isNull);
    });

    test('duplicates: a built-in label wins, then the smallest id; siblings only among siblings', () {
      final t = CategoryTable.from(const [
        CategoryRow(id: 'k000000000009', name: 'groceries'),
        CategoryRow(id: 'k000000000002', name: 'Kućni ljubimci'),
        CategoryRow(id: 'k000000000001', name: 'KUCNI LJUBIMCI'),
        CategoryRow(id: 'k000000000003', name: 'Vet', parent: 'k000000000001'),
        CategoryRow(id: 'k000000000004', name: 'vet', parent: 'k000000000001'),
        CategoryRow(id: 'k000000000005', name: 'Vet', parent: 'Groceries'),
      ]);
      expect(t.duplicateOf('k000000000009'), 'Groceries');
      expect(t.duplicateOf('k000000000002'), 'k000000000001');
      expect(t.duplicateOf('k000000000001'), isNull);
      expect(t.duplicateOf('k000000000004'), 'k000000000003');
      expect(t.duplicateOf('k000000000005'), isNull);
      expect(t.pickable(), isNot(anyOf(contains('k000000000009'), contains('k000000000002'), contains('k000000000004'))));
    });
  });

  group('repo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('add, relabel, hide, move and delete; ids are k + 12 hex', () async {
      final pets = await r.addCategory(name: '  Pets ', kind: BudgetKind.flex);
      expect(pets, matches(RegExp(r'^k[0-9a-f]{12}$')));
      final vet = await r.addCategory(name: 'Vet', kind: BudgetKind.flex, parent: pets);
      final t = r.categoryTable();
      expect(t.label(pets), 'Pets');
      expect(t.childrenOf(pets), [vet]);
      expect(t.pickable().last, vet);
      await r.updateCategory('Groceries', name: 'Food', hidden: true);
      expect(r.categoryTable().label('Groceries'), 'Food');
      expect(r.categoryTable().pickable(), isNot(contains('Groceries')));
      await r.updateCategory(vet, clearParent: true);
      expect(r.categoryTable().parentOf(vet), isNull);
      await r.updateCategory(vet, parent: pets);
      expect(r.categoryTable().parentOf(vet), pets);
      await expectLater(r.deleteCategory(pets), throwsArgumentError, reason: 'it has a live child');
      await r.deleteCategory(vet);
      await r.deleteCategory(pets);
      expect(r.categoryRows().map((x) => x.id), ['Groceries']);
      expect(r.categoryRows(includeDeleted: true), hasLength(3));
      await expectLater(r.deleteCategory('Groceries'), throwsArgumentError);
    }, timeout: _t);

    test('rules: name length, one level, kind, built-in parent, uniqueness with case and accents', () async {
      await expectLater(r.addCategory(name: '  ', kind: BudgetKind.flex), throwsArgumentError);
      await expectLater(r.addCategory(name: 'x' * 41, kind: BudgetKind.flex), throwsArgumentError);
      final a = await r.addCategory(name: 'x' * 40, kind: BudgetKind.flex);
      await expectLater(r.addCategory(name: 'Child', kind: BudgetKind.fixed, parent: 'Groceries'), throwsArgumentError);
      final c = await r.addCategory(name: 'Child', kind: BudgetKind.fixed, parent: 'Rent');
      await expectLater(r.addCategory(name: 'Grandchild', kind: BudgetKind.fixed, parent: c), throwsArgumentError);
      await expectLater(r.addCategory(name: 'GROCERIES', kind: BudgetKind.flex), throwsArgumentError);
      await r.addCategory(name: 'Kućni', kind: BudgetKind.flex);
      await expectLater(r.addCategory(name: 'kucni', kind: BudgetKind.flex), throwsArgumentError);
      await expectLater(r.addCategory(name: 'child', kind: BudgetKind.fixed, parent: 'Rent'), throwsArgumentError);
      await r.addCategory(name: 'child', kind: BudgetKind.fixed, parent: 'Loan');
      await expectLater(r.updateCategory('Groceries', parent: 'Rent'), throwsArgumentError);
      await expectLater(r.updateCategory('Rent', parent: a), throwsArgumentError);
      final b = await r.addCategory(name: 'B', kind: BudgetKind.fixed);
      await expectLater(r.updateCategory(b, parent: c), throwsArgumentError, reason: 'the parent is a child');
      await r.addCategory(name: 'B child', kind: BudgetKind.fixed, parent: b);
      await expectLater(r.updateCategory(b, parent: 'Rent'), throwsArgumentError, reason: 'b has children');
      await expectLater(r.updateCategory(a, parent: 'Rent'), throwsArgumentError, reason: 'flex under fixed');
      await expectLater(r.updateCategory('Rent', name: 'groceries'), throwsArgumentError);
      await expectLater(r.updateCategory(a, position: -1), throwsArgumentError);
      await expectLater(r.updateCategory('k000000000000', name: 'Z'), throwsArgumentError);
    }, timeout: _t);

    test('at most 200 live custom categories; undelete counts too', () async {
      String? last;
      for (var i = 0; i < CategoryRow.maxCustom; i++) {
        last = await r.addCategory(name: 'C$i', kind: BudgetKind.flex);
      }
      await expectLater(r.addCategory(name: 'One more', kind: BudgetKind.flex), throwsArgumentError);
      await r.deleteCategory(last!);
      final x = await r.addCategory(name: 'One more', kind: BudgetKind.flex);
      await expectLater(r.undeleteCategory(last), throwsArgumentError);
      await r.deleteCategory(x);
      await r.undeleteCategory(last);
      expect(r.categoryTable().isLive(last), isTrue);
    }, timeout: _t);

    test('an override pointing at a deleted custom id falls back, and comes back after undelete', () async {
      r.importBatch(january);
      final pets = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final lidl = r.transactions().firstWhere((x) => x.description.contains('LIDL'));
      final manual = r.addTransaction(date: '2026-01-21', amount: 700, category: pets);
      r.setCategory(lidl.id, pets);
      String cat(String id) => r.categorizer().categorize(r.transactions(includeHidden: true).firstWhere((x) => x.id == id)).category;
      expect((cat(lidl.id), cat(manual)), (pets, pets));
      await r.deleteCategory(pets);
      expect((cat(lidl.id), cat(manual)), ('Groceries', 'Shopping'));
      expect(r.transactions().firstWhere((x) => x.id == lidl.id).category, pets, reason: 'nothing is rewritten');
      await r.undeleteCategory(pets);
      expect((cat(lidl.id), cat(manual)), (pets, pets));
    }, timeout: _t);

    test('a merchant pattern and a merchant rule to a custom category', () async {
      r.importBatch(january);
      final pets = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
      r.setMerchantPattern(pets, 'lidl');
      final lidl = r.transactions().firstWhere((x) => x.description.contains('LIDL'));
      expect(r.categorizer().categorize(lidl).category, pets);
      expect(() => r.setMerchantPattern('k000000000000', 'x'), throwsArgumentError);
      await r.deleteCategory(pets);
      expect(r.categorizer().categorize(lidl).category, 'Groceries');
      final fee = r.transactions().firstWhere((x) => x.amount == -33);
      final food = await r.addCategory(name: 'Fees too', kind: BudgetKind.flex);
      r.setMerchantRule(merchantKey(fee), food);
      expect(r.categorizer().categorize(fee).category, food);
    }, timeout: _t);

    test('budgets: top-level custom yes, a child is refused, children roll up into the parent', () async {
      final pets = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final vet = await r.addCategory(name: 'Vet', kind: BudgetKind.flex, parent: pets);
      final income = await r.addCategory(name: 'Side job', kind: BudgetKind.income);
      r.setCategoryBudget(pets, 10000);
      expect(r.settings().categoryBudgets[pets], 10000);
      expect(() => r.setCategoryBudget(vet, 500), throwsArgumentError);
      expect(() => r.setCategoryBudget(income, 500), throwsArgumentError);
      final t = r.categoryTable();
      final rows = [_c('x1', '2026-09-03', -2000, vet, t), _c('x2', '2026-09-04', -1500, pets, t), _c('x3', '2026-09-05', -999, vet, t)];
      final b = budgetVsActual(rows, '2026-09', r.settings().categoryBudgets, today: '2026-09-30', currency: 'EUR', table: t);
      expect([for (final l in b.lines) (l.category, l.budget, l.actual)], [(pets, 10000, 4499)]);
      expect(monthSummary(rows, '2026-09', currency: 'EUR').byCategory, {vet: 2999, pets: 1500}, reason: 'per row id for drill-down');
      expect(
          categoryShare(rows, DateRange(start: '2026-09-01', end: '2026-09-30'), currency: 'EUR', rollUp: true, table: t)
              .slices
              .single
              .spent,
          4499);
      await r.deleteCategory(vet);
      await r.deleteCategory(pets);
      expect(r.settings().categoryBudgets.containsKey(pets), isFalse, reason: 'a deleted category has no budget');
      await r.undeleteCategory(pets);
      expect(r.settings().categoryBudgets[pets], 10000, reason: 'the stored row was kept');
    }, timeout: _t);

    test('CSV header and columns with custom top-level categories', () async {
      final pets = await r.addCategory(name: 'Pets, cats', kind: BudgetKind.flex);
      final vet = await r.addCategory(name: 'Vet', kind: BudgetKind.flex, parent: pets);
      await r.addCategory(name: 'Side job', kind: BudgetKind.income);
      final t = r.categoryTable();
      expect(monthlySummaryCsvHeaderFor(t), 'month,${spendingCategories.join(',')},"Pets, cats",total');
      final csv =
          monthlySummaryCsv([_c('x1', '2026-09-03', -2000, vet, t), _c('x2', '2026-09-04', -1, pets, t)], currency: 'EUR', table: t);
      final line = csv.split('\n')[1].split(',');
      expect(line.first, '2026-09');
      expect(line[line.length - 2], '20.01');
      expect(line.last, '20.01');
    }, timeout: _t);

    test('a custom fixed category is covered by the plan and never reserved again', () async {
      final parking = await r.addCategory(name: 'Parking', kind: BudgetKind.fixed, parent: 'Rent');
      final t = r.categoryTable();
      const p = PlannedCost(id: 'p1', title: 'Synthetic', date: '2026-10-12', amount: 4000, category: 'kffffffffffff');
      final q = PlannedCost(id: 'p2', title: 'Synthetic', date: '2026-10-12', amount: 4000, category: parking);
      expect(q.coveredByPlanIn(t), isTrue);
      expect(plannedReserves(q, const [], const {}, table: t), isFalse);
      expect(p.coveredByPlanIn(t), isFalse);
      expect(plannedReserves(p, const [], const {}, table: t), isTrue);
    }, timeout: _t);
  });

  group('two devices, backup, schema', () {
    late VaultKey key;
    late Net net;
    var clock = _noon;
    setUp(() {
      key = VaultKey.generate();
      net = Net();
      clock = _noon;
    });

    Future<void> settle(List<Device> ds) async {
      for (var i = 0; i < 3; i++) {
        for (final d in ds) {
          clock += 1000;
          d.deliver(net, Random(1));
          await d.run();
        }
      }
    }

    test('the same label added offline on both devices: both rows survive, one is a duplicate, not offered', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final x = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final y = await b.repo.addCategory(name: 'pets', kind: BudgetKind.flex);
      await settle([a, b]);
      expect(dump(a.repo)['categories'], dump(b.repo)['categories']);
      final t = a.repo.categoryTable();
      final (keep, dup) = x.compareTo(y) < 0 ? (x, y) : (y, x);
      expect((t.isLive(x), t.isLive(y)), (true, true));
      expect(t.duplicateOf(dup), keep);
      expect(t.pickable(), contains(keep));
      expect(t.pickable(), isNot(contains(dup)));
      expect(b.repo.categoryTable().duplicateOf(dup), keep);
    }, timeout: _t);

    test('a parent deleted on A while B adds a child: the child is top-level with its own kind', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final pets = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.fixed);
      await settle([a, b]);
      await a.repo.deleteCategory(pets);
      final vet = await b.repo.addCategory(name: 'Vet', kind: BudgetKind.fixed, parent: pets);
      await settle([a, b]);
      for (final d in [a, b]) {
        final t = d.repo.categoryTable();
        expect(t.isLive(pets), isFalse);
        expect(t.parentOf(vet), isNull);
        expect(t.topLevel(vet), vet);
        expect(t.kindOf(vet), BudgetKind.fixed);
        expect(t.spending, contains(vet));
        expect(rollUp({vet: 5}, t), {vet: 5});
      }
      expect(dump(a.repo)['categories'], dump(b.repo)['categories']);
    }, timeout: _t);

    test('backup round trip keeps custom rows and overrides', () async {
      final a = Device('A', null, key, () => clock);
      addTearDown(a.close);
      final pets = await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await a.repo.addCategory(name: 'Vet', kind: BudgetKind.flex, parent: pets);
      await a.repo.updateCategory('Cash', hidden: true, name: 'Pocket money', position: 3);
      final file = await backupBytes(a.repo, key);
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, file, key);
      expect(dump(fresh, clocks: false)['categories'], dump(a.repo, clocks: false)['categories']);
      expect(fresh.categoryTable().pickable(), a.repo.categoryTable().pickable());
      expect(fresh.isEmpty, isFalse);
    }, timeout: _t);

    test('schema 9 → 10: a schema 9 database gains the categories table on open', () async {
      final dir = Directory.systemTemp.createTempSync('bw_p1_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/w.db';
      var r = WalletRepo.open(path);
      r.importBatch(january);
      r.db.execute('DROP TABLE categories');
      r.db.execute("UPDATE meta SET value = '9' WHERE key = 'schema'");
      r.close();
      r = WalletRepo.open(path);
      addTearDown(r.close);
      expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '10');
      expect(r.categoryRows(includeDeleted: true), isEmpty);
      expect(r.transactions(), isNotEmpty);
      await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
      expect(r.categoryRows(), hasLength(1));
    }, timeout: _t);
  });
}
