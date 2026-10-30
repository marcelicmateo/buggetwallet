// RXc: averageOut, changePermille and reviewsIn, the numbers the new dashboards show. SYNTHETIC data only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

CategorizedTx _foreign(String date, int cents, String category, String currency) => CategorizedTx(
      Tx(id: 'f-$date-$cents', source: 'pbz', date: date, amount: cents, description: 'Synthetic', currency: currency),
      category,
      kindOf(category),
    );

/// The oracle: Σ monthSummary(m).out over the [months] months before [month].
int _sumOfOut(List<CategorizedTx> txs, String month, {int months = 6}) {
  var s = 0;
  for (final m in monthsEnding(month, months + 1).sublist(0, months)) {
    s += monthSummary(txs, m, currency: 'EUR').out;
  }
  return s;
}

int _sumOfAverages(List<CategorizedTx> txs, String month) =>
    averageByCategory(txs, month, currency: 'EUR').values.fold<int>(0, (a, b) => a + b);

void main() {
  group('averageOut', () {
    final txs = [
      ct('2026-02-10', -6000, 'Groceries'),
      ct('2026-03-10', -12000, 'Rent'),
      ct('2026-05-05', -3000, 'Eating out'),
      ct('2026-07-31', -9000, 'Groceries'),
      ct('2026-04-01', 150000, 'Salary'), // income left out
    ];

    test('equals the sum of monthSummary.out over the 6 months before, divided by 6', () {
      expect(averageOut(txs, '2026-08', currency: 'EUR'), 5000); // 30000 / 6
      expect(averageOut(txs, '2026-08', currency: 'EUR'), _sumOfOut(txs, '2026-08') ~/ 6);
    });

    test('rounds like averageByCategory (half away from zero)', () {
      for (final total in [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 29, 31, 6001]) {
        final rows = [ct('2026-05-10', -total, 'Groceries')];
        // one category: both agree exactly
        expect(averageOut(rows, '2026-08', currency: 'EUR'), averageByCategory(rows, '2026-08', currency: 'EUR')['Groceries'],
            reason: 'total $total');
        expect(averageOut(rows, '2026-08', currency: 'EUR'), (total / 6).round());
      }
      expect(averageOut([ct('2026-05-10', -3, 'Groceries')], '2026-08', currency: 'EUR'), 1); // 0.5 -> 1
      expect(averageOut([ct('2026-05-10', 3, 'Groceries')], '2026-08', currency: 'EUR'), -1); // refund: -0.5 -> -1
    });

    test('equals the sum of averageByCategory when no rounding differs, may differ by cents when it does', () {
      expect(averageOut(txs, '2026-08', currency: 'EUR'), _sumOfAverages(txs, '2026-08'));
      // 3 + 3 = 6 cents -> 1 as a total, but each category alone rounds 0.5 up: 1 + 1 = 2.
      final two = [ct('2026-05-10', -3, 'Groceries'), ct('2026-05-11', -3, 'Eating out')];
      expect(averageOut(two, '2026-08', currency: 'EUR'), 1);
      expect(_sumOfAverages(two, '2026-08'), 2);
    });

    test('months without rows count as zero; no rows at all is 0', () {
      expect(averageOut([ct('2026-07-10', -600, 'Groceries')], '2026-08', currency: 'EUR'), 100);
      expect(averageOut(const [], '2026-08', currency: 'EUR'), 0);
    });

    test('refunds lower it', () {
      final withRefund = [...txs, ct('2026-06-10', 3000, 'Groceries')];
      expect(averageOut(withRefund, '2026-08', currency: 'EUR'), 4500);
      expect(averageOut(withRefund, '2026-08', currency: 'EUR'), _sumOfOut(withRefund, '2026-08') ~/ 6);
    });

    test('the month itself, later months and months before the window are excluded', () {
      final rows = [
        ct('2026-08-01', -99999, 'Groceries'), // the month itself
        ct('2026-08-31', -99999, 'Groceries'),
        ct('2026-09-01', -99999, 'Groceries'), // later
        ct('2026-01-31', -99999, 'Groceries'), // 7 months before
        ct('2026-02-01', -600, 'Groceries'), // first month of the window
        ct('2026-07-31', -600, 'Groceries'), // last month of the window
      ];
      expect(averageOut(rows, '2026-08', currency: 'EUR'), 200);
    });

    test('the window crosses the year end', () {
      final rows = [
        ct('2025-10-15', -600, 'Groceries'),
        ct('2025-08-31', -9999, 'Groceries'), // 7 months before March
        ct('2026-03-15', -9999, 'Rent'), // the month itself
      ];
      expect(averageOut(rows, '2026-03', currency: 'EUR'), 100);
    });

    test('foreign currency, transfers, income, extras and deleted rows are excluded', () {
      final rows = [
        ct('2026-05-10', -6000, 'Groceries'),
        _foreign('2026-05-11', -9000, 'Groceries', 'USD'),
        ct('2026-05-12', -9000, 'Internal transfer'),
        ct('2026-05-13', 9000, 'Extra income'),
        ct('2026-05-14', -9000, 'Groceries', deleted: true),
      ];
      expect(averageOut(rows, '2026-08', currency: 'EUR'), 1000);
      expect(averageOut(rows, '2026-08', currency: 'EUR'), _sumOfOut(rows, '2026-08') ~/ 6);
      expect(averageOut(rows, '2026-08', currency: 'USD'), 1500); // only the USD row
    });

    test('months changes the window and the divisor', () {
      final rows = [ct('2026-07-10', -600, 'Groceries'), ct('2026-05-10', -600, 'Groceries')];
      expect(averageOut(rows, '2026-08', months: 3, currency: 'EUR'), 400); // May..July, 1200 / 3
      expect(averageOut(rows, '2026-08', months: 1, currency: 'EUR'), 600);
      expect(averageOut(rows, '2026-08', months: 2, currency: 'EUR'), 300); // June, July
    });
  });

  group('changePermille', () {
    test('signs and exact values', () {
      expect(changePermille(150, 100), 500);
      expect(changePermille(100, 100), 0);
      expect(changePermille(50, 100), -500);
      expect(changePermille(200, 100), 1000);
      expect(changePermille(0, 100), -1000);
      expect(changePermille(0, -100), 1000);
    });

    test('rounds half away from zero', () {
      expect(changePermille(1, 3), -667); // -666.67
      expect(changePermille(2, 3), -333); // -333.33
      expect(changePermille(4, 3), 333); // 333.33
      expect(changePermille(5, 3), 667); // 666.67
      // exactly half a permille
      expect(changePermille(2001, 2000), 1);
      expect(changePermille(1999, 2000), -1);
      expect(changePermille(2000, 2000), 0);
      expect(changePermille(20001, 20000), 0); // 0.05 permille
    });

    test('before 0 gives null', () {
      expect(changePermille(500, 0), isNull);
      expect(changePermille(0, 0), isNull);
      expect(changePermille(-500, 0), isNull);
    });

    test('negative before (a net refund month) is measured against its size', () {
      expect(changePermille(100, -100), 2000); // from -100 up to +100: +200 %
      expect(changePermille(-150, -100), -500); // fell further
      expect(changePermille(-50, -100), 500);
      expect(changePermille(-100, -100), 0);
    });

    test('large cents stay exact', () {
      expect(changePermille(1500000000, 1000000000), 500);
      expect(changePermille(9007199254, 9007199254), 0);
    });
  });

  group('reviewsIn', () {
    test('start inclusive, end exclusive', () {
      final r = reviewsIn(['2026-05-31', '2026-06-01', '2026-06-15', '2026-06-30', '2026-07-01'], '2026-06-01', '2026-07-01');
      expect(r, ['2026-06-01', '2026-06-15', '2026-06-30']);
    });

    test('unsorted input comes back ascending, duplicates once', () {
      final r = reviewsIn(['2026-06-20', '2026-06-03', '2026-06-20', '2026-06-03', '2026-06-10'], '2026-06-01', '2026-07-01');
      expect(r, ['2026-06-03', '2026-06-10', '2026-06-20']);
    });

    test('bad dates are ignored', () {
      final r = reviewsIn(
          ['', 'abc', '2026-6-3', '2026-02-30', '2026-13-01', '2026-06-1', '2026-06-05 ', '2026-06-05'], '2026-06-01', '2026-07-01');
      expect(r, ['2026-06-05']);
    });

    test('empty input, empty range, reversed range, bad bounds', () {
      expect(reviewsIn(const [], '2026-06-01', '2026-07-01'), isEmpty);
      expect(reviewsIn(['2026-06-05'], '2026-06-05', '2026-06-05'), isEmpty);
      expect(reviewsIn(['2026-06-05'], '2026-07-01', '2026-06-01'), isEmpty);
      expect(reviewsIn(['2026-06-05'], 'x', '2026-07-01'), isEmpty);
      expect(reviewsIn(['2026-06-05'], '2026-06-01', ''), isEmpty);
    });

    test('does not modify its input', () {
      final input = ['2026-06-20', '2026-06-03'];
      reviewsIn(input, '2026-06-01', '2026-07-01');
      expect(input, ['2026-06-20', '2026-06-03']);
    });
  });
}
