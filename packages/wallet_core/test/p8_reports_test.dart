// Stage P8 reports (core-builder): periodReports, categoryByPeriod, savedByWaiting. SYNTHETIC data only; expected
// values are worked out by hand from docs/context/P8_SPEC.md and checked against periodSummaries.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

Tx _tx(String date, int cents, String category, {String currency = 'EUR', bool deleted = false}) => Tx(
    id: 'p8-${_seq++}',
    source: 'pbz',
    date: date,
    amount: cents,
    currency: currency,
    description: 'Synthetic row',
    category: category,
    deleted: deleted);

const _custom = 'kaaaaaaaaaaaa'; // a custom fixed main tag
const _child = 'kbbbbbbbbbbbb'; // an old child of Groceries (T1: counts on its own)
final _table = CategoryTable.from(const [
  CategoryRow(id: _custom, name: 'Childcare', kind: BudgetKind.fixed, position: 40),
  CategoryRow(id: _child, name: 'Fruit', kind: BudgetKind.flex, parent: 'Groceries', position: 41),
]);

const _today = '2026-10-20';
const _st = WalletSettings(categoryBudgets: {'Groceries': 30000}); // paydayDay 15, EUR

/// Three pay periods: 08-15..09-15, 09-15..10-15, 10-15.. (running, end 11-15).
List<Tx> _rows() => [
      _tx('2026-08-15', 200000, 'Salary'),
      _tx('2026-08-16', -60000, 'Rent'),
      _tx('2026-08-20', -12000, 'Groceries'),
      _tx('2026-08-21', -3000, _child),
      _tx('2026-08-25', 1000, 'Groceries'), // refund lowers flex
      _tx('2026-09-01', 5000, 'Extra income'),
      _tx('2026-09-15', 200000, 'Salary'),
      _tx('2026-09-16', -60000, 'Rent'),
      _tx('2026-09-17', -40000, _custom),
      _tx('2026-09-18', -35000, 'Groceries'), // over the 300 € budget
      _tx('2026-09-19', -20000, 'Internal transfer'), // transfer: out of every sum
      _tx('2026-09-20', -10000, 'Shopping', currency: 'USD'), // foreign: out of every sum
      _tx('2026-09-21', -9999, 'Groceries', deleted: true),
      _tx('2026-09-22', -10000, 'Shopping'), // split below: 2500 Groceries + 7500 Rent
      _tx('2026-10-15', 200000, 'Salary'),
      _tx('2026-10-16', -4000, 'Groceries'),
      _tx('2026-10-21', -7000, 'Groceries'), // after today: not counted yet
    ];

List<CategorizedTx> _expanded(List<Tx> rows) {
  final split = rows.firstWhere((t) => t.date == '2026-09-22');
  return Categorizer(table: _table, splits: {
    split.id: const [SplitPart(amount: -2500, category: 'Groceries'), SplitPart(amount: -7500, category: 'Rent')],
  }).expandAll(rows);
}

void main() {
  group('periodReports', () {
    final txs = _expanded(_rows());
    final reports = periodReports(txs, _st, _today, table: _table);
    final sums = periodSummaries(txs, _st, _today);

    test('same periods, income and out as periodSummaries; fixed + flex == out; net == PeriodSummary.net', () {
      expect(reports.map((r) => r.start), sums.map((s) => s.start));
      for (var i = 0; i < sums.length; i++) {
        final r = reports[i], s = sums[i];
        expect(r.end, s.end);
        expect(r.running, s.running);
        expect(r.income, s.income);
        expect(r.fixed + r.flex, s.out);
        expect(r.out, s.out);
        expect(r.net, s.net);
      }
    });

    test('hand-worked values: split by parts, custom fixed tag, refunds, transfers and foreign rows out', () {
      String v(PeriodReport r) => '${r.start} ${r.end} ${r.running} ${r.income} ${r.fixed} ${r.flex} ${r.net}';
      expect(reports.map(v), [
        '2026-08-15 2026-09-15 false 205000 60000 14000 131000',
        '2026-09-15 2026-10-15 false 200000 107500 37500 55000',
        '2026-10-15 2026-11-15 true 200000 0 4000 196000',
      ]);
    });

    test('the split payment counts by its parts, not whole', () {
      final whole = periodReports(Categorizer(table: _table).expandAll(_rows()), _st, _today, table: _table);
      expect(whole[1].fixed, 100000, reason: 'whole: Shopping is flex');
      expect(whole[1].flex, 45000);
      expect(reports[1].fixed, 107500);
      expect(reports[1].out, whole[1].out, reason: 'the payment total is unchanged');
    });

    test('without the custom table the custom tag reads as flex, the total stays', () {
      final r = periodReports(txs, _st, _today, table: CategoryTable.builtIn);
      expect(r[1].fixed, 67500);
      expect(r[1].out, reports[1].out);
    });

    test('count limits to the newest periods; empty wallet gives none', () {
      final last = periodReports(txs, _st, _today, table: _table, count: 1);
      expect(last.single.start, '2026-10-15');
      expect(last.single.running, isTrue);
      expect(periodReports(const [], _st, _today, table: _table), isEmpty);
      expect(periodReports(txs, _st, _today, table: _table, count: 0), isEmpty);
    });
  });

  group('categoryByPeriod', () {
    final txs = _expanded(_rows());

    test('spent per period equals the period summary for the tag; the budget is the monthly one', () {
      final g = categoryByPeriod('Groceries', txs, _st, _today, table: _table);
      final sums = periodSummaries(txs, _st, _today);
      expect(g.map((c) => c.start), sums.map((s) => s.start));
      for (var i = 0; i < g.length; i++) {
        expect(g[i].spent, rollUp(sums[i].byCategory, _table)['Groceries'] ?? 0);
        expect(g[i].end, sums[i].end);
        expect(g[i].running, sums[i].running);
      }
      expect(g.map((c) => c.spent), [11000, 37500, 4000], reason: 'refund lowers it, split part counts, row after today not');
      expect(g.map((c) => c.budget), [30000, 30000, 30000]);
      expect(g.map((c) => c.overBy), [0, 7500, 0]);
      expect(g.map((c) => c.over), [false, true, false]);
    });

    test('T1: an old child counts as its own tag (rollUp is the identity), not in its stored parent', () {
      final child = categoryByPeriod(_child, txs, _st, _today, table: _table);
      expect(child.map((c) => c.spent), [3000, 0, 0]);
      expect(child.first.budget, isNull);
    });

    test('no budget: null, overBy 0', () {
      final s = categoryByPeriod('Shopping', txs, _st, _today, table: _table);
      expect(s.every((c) => c.budget == null && c.overBy == 0 && !c.over), isTrue);
      expect(s.map((c) => c.spent), [0, 0, 0], reason: 'the split moved the payment out; the USD row never counts');
    });

    test('custom fixed tag and a tag with no rows', () {
      expect(categoryByPeriod(_custom, txs, _st, _today, table: _table).map((c) => c.spent), [0, 40000, 0]);
      expect(categoryByPeriod('Games & apps', txs, _st, _today, table: _table).map((c) => c.spent), [0, 0, 0]);
    });

    test('a budget of 0 makes any spend over', () {
      const st = WalletSettings(categoryBudgets: {'Groceries': 0});
      final g = categoryByPeriod('Groceries', txs, st, _today, table: _table);
      expect(g.map((c) => c.overBy), [11000, 37500, 4000]);
    });

    test('partial (running) period counts only up to today', () {
      final later = categoryByPeriod('Groceries', txs, _st, '2026-10-21', table: _table);
      expect(later.last.spent, 11000);
      expect(later.last.running, isTrue);
    });
  });

  group('savedByWaiting', () {
    WishItem w(String id, int price, String status, int? decided) =>
        WishItem(id: id, name: 'Synthetic', price: price, added: 0, status: status, decided: decided);
    final wishes = [
      w('a', 12000, 'skipped', 1000), // from: inclusive
      w('b', 3000, 'skipped', 1999),
      w('c', 5000, 'skipped', 2000), // to: exclusive
      w('d', 7000, 'bought', 1500),
      w('e', 9000, 'waiting', null),
      w('f', 4000, 'skipped', 999),
      w('g', 8000, 'skipped', null), // no decided time: never in a range
    ];

    test('skipped in [from, to) counted; bought and waiting never', () {
      final s = savedByWaiting(wishes, fromMillis: 1000, toMillis: 2000);
      expect((s.count, s.cents), (2, 15000));
    });

    test('empty range and empty list', () {
      final s = savedByWaiting(wishes, fromMillis: 2000, toMillis: 2000);
      expect((s.count, s.cents), (0, 0));
      final e = savedByWaitingAll(const []);
      expect((e.count, e.cents), (0, 0));
    });

    test('all time: every skipped wish with a decided time', () {
      final s = savedByWaitingAll(wishes);
      expect((s.count, s.cents), (4, 24000));
    });

    test('a deleted wish (from a sync) is not in the wishlist and never counts', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final keep = r.addWish('Synthetic one', 2500);
      final gone = r.addWish('Synthetic two', 4100);
      r.decideWish(keep, 'skipped');
      r.decideWish(gone, 'skipped');
      expect(savedByWaitingAll(r.wishlist()).cents, 6600);
      r.applyRemote([
        Op('wish', gone, const {'deleted': 1}, Hlc(DateTime.now().millisecondsSinceEpoch + 60000, 0, 'peer').toString())
      ]);
      final s = savedByWaitingAll(r.wishlist());
      expect((s.count, s.cents), (1, 2500));
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(savedByWaiting(r.wishlist(), fromMillis: now - 3600000, toMillis: now + 1).count, 1);
    });
  });
}
