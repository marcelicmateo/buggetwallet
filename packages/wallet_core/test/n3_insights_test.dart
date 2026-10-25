// N3 graph data and drill-down (docs/context/N3_SPEC.md §2–4 + clarifications). Synthetic data only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart';

DateRange dr(String s, String e) => DateRange(start: s, end: e);

const today = '2026-10-25';
const eur = 'EUR';

void main() {
  group('spendingByMonth', () {
    final txs = [
      row('2026-08-14', -1000, 'Groceries'), // before r
      row('2026-08-15', -500, 'Groceries'),
      row('2026-08-20', 200, 'Groceries'), // refund
      row('2026-08-20', -5000, 'Internal transfer'),
      row('2026-08-10', 150000, 'Salary'),
      row('2026-08-21', -400, 'Rent'), // fixed counts
      row('2026-08-22', -700, 'Groceries', deleted: true),
      row('2026-08-23', -900, 'Groceries', currency: 'USD'),
      row('2026-10-10', -300, 'Eating out'),
      row('2026-10-11', -999, 'Eating out'), // after r
    ];

    test('days outside r are left out, empty months appear, partial flags', () {
      final bars = spendingByMonth(txs, dr('2026-08-15', '2026-10-10'), currency: eur, today: today);
      expect([for (final b in bars) b.month], ['2026-08', '2026-09', '2026-10']);
      expect([for (final b in bars) b.spent], [700, 0, 300]);
      expect([for (final b in bars) b.partial], [true, false, true]);
    });

    test('the current month is partial even when wholly inside r', () {
      final bars = spendingByMonth(txs, dr('2026-09-01', '2026-10-31'), currency: eur, today: today);
      expect([for (final b in bars) (b.month, b.spent, b.partial)], [('2026-09', 0, false), ('2026-10', 1299, true)]);
    });

    test('a range inside one month gives one bar', () {
      final bars = spendingByMonth(txs, dr('2026-08-20', '2026-08-20'), currency: eur, today: today);
      expect([for (final b in bars) (b.month, b.spent, b.partial)], [('2026-08', -200, true)]);
    });

    test('matches monthSummary for whole months', () {
      final bars = spendingByMonth(txs, dr('2026-08-01', '2026-08-31'), currency: eur, today: today);
      expect(bars.single.spent, monthSummary(txs, '2026-08', currency: eur).out);
    });
  });

  group('categoryShare', () {
    test('permille adds up to 1000 (largest remainder), ties by name', () {
      final txs = [
        row('2026-09-02', -100, 'Shopping'),
        row('2026-09-02', -100, 'Groceries'),
        row('2026-09-02', -100, 'Eating out'),
      ];
      final s = categoryShare(txs, dr('2026-09-01', '2026-09-30'), currency: eur);
      expect([for (final c in s.slices) (c.category, c.spent, c.permille)],
          [('Eating out', 100, 334), ('Groceries', 100, 333), ('Shopping', 100, 333)]);
      expect(s.total, 300);
    });

    test('permille with many small slices sums to exactly 1000', () {
      final cats = flexCategories.take(7).toList();
      final txs = [
        for (var i = 0; i < cats.length; i++) row('2026-09-0${i + 1}', -(1 + i * 37), cats[i]),
      ];
      final s = categoryShare(txs, dr('2026-09-01', '2026-09-30'), currency: eur);
      expect(s.slices.fold<int>(0, (a, c) => a + c.permille), 1000);
      expect(s.slices.fold<int>(0, (a, c) => a + c.spent), s.total);
      for (var i = 1; i < s.slices.length; i++) {
        expect(s.slices[i - 1].spent >= s.slices[i].spent, isTrue);
      }
      // Each slice is within one thousandth of its exact share.
      for (final c in s.slices) {
        expect((c.permille - c.spent * 1000 / s.total).abs() < 1, isTrue);
      }
    });

    test('refunds subtract; net ≤ 0 is left out; transfers and income count nowhere; foreign reported', () {
      final txs = [
        row('2026-09-02', -1000, 'Groceries'),
        row('2026-09-03', 250, 'Groceries'),
        row('2026-09-04', -300, 'Shopping'),
        row('2026-09-05', 300, 'Shopping'), // nets to 0
        row('2026-09-06', 500, 'Health & care'), // refund only
        row('2026-09-07', -9000, 'Internal transfer'),
        row('2026-09-08', 150000, 'Salary'),
        row('2026-09-09', -700, 'Groceries', currency: 'USD'),
        row('2026-09-09', -100, 'Internal transfer', currency: 'USD'),
        row('2026-09-10', 2000, 'Salary', currency: 'GBP'),
        row('2026-10-01', -400, 'Groceries'), // outside r
      ];
      final s = categoryShare(txs, dr('2026-09-01', '2026-09-30'), currency: eur);
      expect([for (final c in s.slices) (c.category, c.spent, c.permille)], [('Groceries', 750, 1000)]);
      expect(s.total, 750);
      expect(s.foreignByCurrency, {'USD': -700, 'GBP': 2000});
    });

    test('nothing spent: no slices, total 0', () {
      final s = categoryShare([row('2026-09-02', 500, 'Groceries')], dr('2026-09-01', '2026-09-30'), currency: eur);
      expect(s.slices, isEmpty);
      expect(s.total, 0);
      expect(s.foreignByCurrency, isEmpty);
    });

    test('sums across several months equal the monthSummary sums', () {
      final txs = bigWalletRows('2026-10-25', days: 120, perDay: 6);
      final r = dr('2026-07-01', '2026-09-30');
      final s = categoryShare(txs, r, currency: eur);
      final want = <String, int>{};
      for (final m in ['2026-07', '2026-08', '2026-09']) {
        for (final e in monthSummary(txs, m, currency: eur).byCategory.entries) {
          want[e.key] = (want[e.key] ?? 0) + e.value;
        }
      }
      expect({
        for (final c in s.slices) c.category: c.spent
      }, {
        for (final e in want.entries)
          if (e.value > 0) e.key: e.value
      });
      expect(s.slices.fold<int>(0, (a, c) => a + c.permille), 1000);
    });
  });

  group('incomeVsSpending', () {
    test('income, extra, spent and net per month, transfers nowhere, foreign out', () {
      final txs = [
        row('2026-09-10', 150000, 'Salary'),
        row('2026-09-12', 5000, 'Extra income'),
        row('2026-09-13', 9000, 'Internal transfer'),
        row('2026-09-14', -1500, 'Groceries'),
        row('2026-09-15', 200, 'Groceries'),
        row('2026-09-16', -55000, 'Rent'),
        row('2026-09-17', 99999, 'Salary', currency: 'USD'),
        row('2026-10-05', -100, 'Groceries'),
      ];
      final out = incomeVsSpending(txs, dr('2026-08-01', '2026-10-31'), currency: eur, today: today);
      expect([
        for (final m in out) (m.month, m.income, m.extra, m.spent, m.net, m.partial)
      ], [
        ('2026-08', 0, 0, 0, 0, false),
        ('2026-09', 150000, 5000, 56300, 98700, false),
        ('2026-10', 0, 0, 100, -100, true),
      ]);
    });

    test('a partial month counts only its days inside r', () {
      final txs = [row('2026-09-10', 150000, 'Salary'), row('2026-09-20', -100, 'Groceries')];
      final out = incomeVsSpending(txs, dr('2026-09-15', '2026-09-30'), currency: eur, today: today);
      expect([for (final m in out) (m.income, m.spent, m.net, m.partial)], [(0, 100, -100, true)]);
    });
  });

  group('budgetVsActualSeries', () {
    test('budgeted, actual and over of the budgeted categories; current month so far', () {
      final budgets = {'Groceries': 1000, 'Eating out': 500};
      final txs = [
        row('2026-08-02', -1500, 'Groceries'),
        row('2026-08-03', -200, 'Eating out'),
        row('2026-08-04', -9999, 'Shopping'), // no budget
        row('2026-08-05', 100, 'Groceries'), // refund
        row('2026-08-06', -50, 'Groceries', currency: 'USD'),
        row('2026-10-01', -600, 'Eating out'),
        row('2026-10-02', -300, 'Eating out', deleted: true),
      ];
      final out = budgetVsActualSeries(txs, dr('2026-08-01', '2026-10-31'), budgets, today: today, currency: eur);
      expect([
        for (final b in out) (b.month, b.budgeted, b.actual, b.over)
      ], [
        ('2026-08', 1500, 1600, 400),
        ('2026-09', 1500, 0, 0),
        ('2026-10', 1500, 600, 100),
      ]);
    });

    test('over adds per category; a category under budget does not offset another', () {
      final budgets = {'Groceries': 1000, 'Eating out': 1000};
      final txs = [row('2026-09-02', -1500, 'Groceries'), row('2026-09-03', -100, 'Eating out')];
      final b = budgetVsActualSeries(txs, dr('2026-09-01', '2026-09-30'), budgets, today: today, currency: eur).single;
      expect((b.budgeted, b.actual, b.over), (2000, 1600, 500));
    });

    test('no budgets: zeros for every month', () {
      final out = budgetVsActualSeries([row('2026-09-02', -1500, 'Groceries')], dr('2026-09-01', '2026-10-31'), const {},
          today: today, currency: eur);
      expect([for (final b in out) (b.budgeted, b.actual, b.over)], [(0, 0, 0), (0, 0, 0)]);
    });
  });

  group('drill-down', () {
    final r = dr('2026-09-01', '2026-10-31');
    final txs = [
      row('2026-09-02', -1000, 'Groceries', desc: 'POS LIDL ZAGREB 0001', id: 'g1'),
      row('2026-10-03', -500, 'Groceries', desc: 'POS LIDL ZAGREB 0002', id: 'g2'),
      row('2026-10-04', 200, 'Groceries', desc: 'POS LIDL ZAGREB 0002', id: 'g3'), // refund
      row('2026-09-05', -1300, 'Groceries', desc: 'POS KONZUM 0000 ZAGREB', id: 'g4'),
      row('2026-09-06', -100, 'Groceries', source: 'manual', id: 'g5'), // cash, no note
      row('2026-09-07', -150, 'Groceries', desc: '12345', id: 'g6'), // nothing left after cleaning
      row('2026-09-08', -400, 'Groceries', source: 'manual', note: 'Market', id: 'g7'),
      row('2026-09-09', -800, 'Shopping', desc: 'POS LIDL ZAGREB 0003', id: 's1'), // other category
      row('2026-09-10', -9000, 'Internal transfer', desc: 'POS LIDL ZAGREB', id: 't1'),
      row('2026-09-11', -700, 'Groceries', desc: 'POS LIDL ZAGREB', currency: 'USD', id: 'f1'),
      row('2026-09-12', -600, 'Groceries', desc: 'POS LIDL ZAGREB', deleted: true, id: 'd1'),
      row('2026-08-31', -333, 'Groceries', desc: 'POS LIDL ZAGREB', id: 'o1'), // outside r
    ];

    test('merchantsIn groups by merchantKey; Other; sorted by spent then label', () {
      final m = merchantsIn('Groceries', txs, r, currency: eur);
      expect([
        for (final x in m) (x.key, x.label, x.spent, x.count, x.lastDate)
      ], [
        ('konzum_zagreb', 'KONZUM 0000 ZAGREB', 1300, 1, '2026-09-05'),
        ('lidl_zagreb', 'LIDL ZAGREB 0002', 1300, 3, '2026-10-04'),
        ('market', 'Market', 400, 1, '2026-09-08'),
        ('', 'Other', 250, 2, '2026-09-07'),
      ]);
    });

    test('rowsFor sums match their totals exactly, newest first', () {
      final totals = merchantsIn('Groceries', txs, r, currency: eur);
      for (final t in totals) {
        final rows = rowsFor('Groceries', t.key, txs, r, currency: eur);
        expect(rows.length, t.count);
        expect(rows.fold<int>(0, (s, x) => s + x.amount), -t.spent);
        for (var i = 1; i < rows.length; i++) {
          expect(rows[i - 1].date.compareTo(rows[i].date) >= 0, isTrue);
        }
      }
      final all = rowsFor('Groceries', null, txs, r, currency: eur);
      expect([for (final x in all) x.tx.id], ['g3', 'g2', 'g7', 'g6', 'g5', 'g4', 'g1']);
      final share = categoryShare(txs, r, currency: eur).slices.firstWhere((s) => s.category == 'Groceries');
      expect(all.fold<int>(0, (s, x) => s + x.amount), -share.spent);
    });

    test('rowsFor on the big wallet matches categoryShare for every category', () {
      final big = bigWalletRows('2026-10-25', days: 200, perDay: 6);
      final range = dr('2026-06-15', '2026-10-25');
      for (final s in categoryShare(big, range, currency: eur).slices) {
        final merchants = merchantsIn(s.category, big, range, currency: eur);
        expect(merchants.fold<int>(0, (a, m) => a + m.spent), s.spent);
        for (final m in merchants) {
          expect(rowsFor(s.category, m.key, big, range, currency: eur).fold<int>(0, (a, x) => a + x.amount), -m.spent);
        }
      }
    });

    test('merchantTrend per month, same shape as spendingByMonth', () {
      final trend = merchantTrend('Groceries', 'lidl_zagreb', txs, dr('2026-08-01', '2026-10-31'), currency: eur, today: today);
      expect([for (final b in trend) (b.month, b.spent, b.partial)],
          [('2026-08', 333, false), ('2026-09', 1000, false), ('2026-10', 300, true)]);
      final none = merchantTrend('Groceries', 'nobody', txs, r, currency: eur, today: today);
      expect([for (final b in none) b.spent], [0, 0]);
    });

    test('compareCategory: this month, last month, the 6 months before ÷ 6', () {
      final rows = [
        row('2026-10-02', -600, 'Groceries'),
        row('2026-09-02', -300, 'Groceries'),
        row('2026-04-02', -600, 'Groceries'),
        row('2026-03-31', -9000, 'Groceries'), // 7 months before: not in the average
        row('2026-09-03', -50, 'Groceries', currency: 'USD'),
        row('2026-09-04', -5000, 'Internal transfer'),
      ];
      final c = compareCategory('Groceries', rows, '2026-10', currency: eur);
      expect((c.thisMonth, c.lastMonth, c.average6), (600, 300, 150));
      expect(c.average6, averageByCategory(rows, '2026-10', currency: eur)['Groceries']);
      final jan = compareCategory('Groceries', [row('2025-12-05', -1200, 'Groceries')], '2026-01', currency: eur);
      expect((jan.thisMonth, jan.lastMonth, jan.average6), (0, 1200, 200));
      final empty = compareCategory('Shopping', rows, '2026-10', currency: eur);
      expect((empty.thisMonth, empty.lastMonth, empty.average6), (0, 0, 0));
    });

    test('biggestRows: by size, ties newest date then id; refunds, transfers, foreign out', () {
      final rows = [
        row('2026-10-01', -500, 'Groceries', id: 'a'),
        row('2026-10-03', -500, 'Shopping', id: 'c'),
        row('2026-10-03', -500, 'Groceries', id: 'b'),
        row('2026-10-02', -900, 'Rent', id: 'd'),
        row('2026-10-02', 2000, 'Groceries', id: 'e'), // refund
        row('2026-10-02', -9000, 'Internal transfer', id: 'f'),
        row('2026-10-02', -8000, 'Groceries', currency: 'USD', id: 'g'),
        row('2026-10-02', -7000, 'Groceries', deleted: true, id: 'h'),
        row('2026-10-02', 150000, 'Salary', id: 'i'),
        row('2026-11-01', -9999, 'Groceries', id: 'j'), // outside r
      ];
      final range = dr('2026-10-01', '2026-10-31');
      expect([for (final t in biggestRows(rows, range, currency: eur)) t.tx.id], ['d', 'b', 'c', 'a']);
      expect([for (final t in biggestRows(rows, range, limit: 2, currency: eur)) t.tx.id], ['d', 'b']);
      expect(biggestRows(rows, range, limit: 0, currency: eur), isEmpty);
    });
  });

  test('performance: every function for months12 on ~10k rows (loose: < 500 ms)', () {
    final txs = bigWalletRows(today);
    expect(txs.length, greaterThan(9000));
    const st = WalletSettings(paydayDay: 10);
    final sw = Stopwatch()..start();
    final r = rangeFor(RangeKind.months12, today, st, txs: txs);
    shiftRange(r, RangeKind.months12, -1, st, txs: txs, today: today);
    rangeFor(RangeKind.payPeriod, today, st, txs: txs);
    spendingByMonth(txs, r, currency: eur, today: today);
    final share = categoryShare(txs, r, currency: eur);
    incomeVsSpending(txs, r, currency: eur, today: today);
    budgetVsActualSeries(txs, r, {'Groceries': 30000, 'Eating out': 10000}, today: today, currency: eur);
    final top = share.slices.first.category;
    final merchants = merchantsIn(top, txs, r, currency: eur);
    rowsFor(top, merchants.first.key, txs, r, currency: eur);
    merchantTrend(top, merchants.first.key, txs, r, currency: eur, today: today);
    compareCategory(top, txs, '2026-10', currency: eur);
    biggestRows(txs, r, currency: eur);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(500));
  });
}
