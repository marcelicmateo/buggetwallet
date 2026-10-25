// Stage N3 spec tests: graph data and drill-down (docs/context/N3_SPEC.md §2-§4). Written from the spec only.
// Synthetic data. Amounts are cents; expenses negative (CategorizedTx), as in the rest of wallet_core.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const eur = 'EUR';

int _seq = 0;

/// A categorized row with its own description, currency and id.
CategorizedTx row(String date, int cents, String category,
    {String desc = 'POS SYNTHETIC SHOP', String currency = eur, String? id, bool deleted = false, String source = 'pbz', String? note}) {
  return CategorizedTx(
    Tx(
        id: id ?? 'n3-${_seq++}',
        source: source,
        date: date,
        amount: cents,
        currency: currency,
        description: desc,
        deleted: deleted,
        note: note,
        manual: source == 'manual'),
    category,
    kindOf(category),
  );
}

DateRange r(String a, String b) => DateRange(start: a, end: b);

const today = '2026-10-25';
final oct = r('2026-10-01', '2026-10-31');

void main() {
  group('spendingByMonth', () {
    test('one bar per overlapping month, empty months included, ascending', () {
      final txs = [row('2026-08-20', -1000, 'Groceries'), row('2026-10-03', -2500, 'Eating out')];
      final bars = spendingByMonth(txs, r('2026-08-01', '2026-10-31'), today: today, currency: eur);
      expect(bars.map((b) => b.month), ['2026-08', '2026-09', '2026-10']);
      expect(bars.map((b) => b.spent), [1000, 0, 2500]);
    });

    test('days outside the range are excluded from partial months', () {
      final txs = [
        row('2026-08-10', -100, 'Groceries'), // before the range
        row('2026-08-15', -200, 'Groceries'), // first day
        row('2026-10-20', -300, 'Groceries'), // last day
        row('2026-10-21', -400, 'Groceries'), // after
      ];
      final bars = spendingByMonth(txs, r('2026-08-15', '2026-10-20'), today: today, currency: eur);
      expect(bars.map((b) => b.spent), [200, 0, 300]);
      expect(bars[0].partial, isTrue);
      expect(bars[1].partial, isFalse);
      expect(bars[2].partial, isTrue);
    });

    test('the current month is partial even when the range covers all of it', () {
      final bars = spendingByMonth(const [], oct, today: today, currency: eur);
      expect(bars.single.partial, isTrue);
      expect(spendingByMonth(const [], oct, today: '2026-11-03', currency: eur).single.partial, isFalse);
    });

    test('whole months inside the range are not partial', () {
      final bars = spendingByMonth([row('2026-02-28', -500, 'Shopping')], r('2026-01-01', '2026-03-31'), today: today, currency: eur);
      expect(bars.map((b) => b.partial), [false, false, false]);
      expect(bars[1].spent, 500);
    });

    test('month ends: the last day of a leap February counts, the 1st of March does not', () {
      final txs = [row('2024-02-29', -700, 'Shopping'), row('2024-03-01', -900, 'Shopping')];
      final bars = spendingByMonth(txs, r('2024-02-01', '2024-02-29'), today: today, currency: eur);
      expect(bars.length, 1);
      expect(bars.single.month, '2024-02');
      expect(bars.single.spent, 700);
      expect(bars.single.partial, isFalse);
    });

    test('a range ending on the 30th of a 31-day month is partial', () {
      final bars = spendingByMonth([row('2026-10-31', -100, 'Groceries')], r('2026-10-01', '2026-10-30'), today: today, currency: eur);
      expect(bars.single.spent, 0);
      expect(bars.single.partial, isTrue);
    });

    test('refunds are subtracted, transfers, income and deleted rows count nowhere', () {
      final txs = [
        row('2026-10-02', -1000, 'Groceries'),
        row('2026-10-03', 300, 'Groceries'), // refund
        row('2026-10-04', -5000, 'Internal transfer'),
        row('2026-10-05', 150000, 'Salary'),
        row('2026-10-06', 2000, 'Extra income'),
        row('2026-10-07', -900, 'Groceries', deleted: true),
      ];
      expect(spendingByMonth(txs, oct, today: today, currency: eur).single.spent, 700);
    });

    test('fixed and flex both count', () {
      final txs = [row('2026-10-02', -30000, 'Rent'), row('2026-10-03', -1000, 'Groceries')];
      expect(spendingByMonth(txs, oct, today: today, currency: eur).single.spent, 31000);
    });

    test('foreign-currency rows are left out', () {
      final txs = [row('2026-10-02', -1000, 'Groceries'), row('2026-10-03', -9999, 'Groceries', currency: 'USD')];
      expect(spendingByMonth(txs, oct, today: today, currency: eur).single.spent, 1000);
    });

    test('matches monthSummary for a full month', () {
      final txs = [
        row('2026-10-02', -1234, 'Groceries'),
        row('2026-10-09', -777, 'Eating out'),
        row('2026-10-09', 100, 'Eating out'),
        row('2026-10-31', -5, 'Cash'),
      ];
      expect(spendingByMonth(txs, oct, today: today, currency: eur).single.spent, monthSummary(txs, '2026-10', currency: eur).out);
    });

    test('no rows gives zero bars, not an empty list', () {
      final bars = spendingByMonth(const [], r('2026-08-01', '2026-09-30'), today: today, currency: eur);
      expect(bars.map((b) => (b.month, b.spent)), [('2026-08', 0), ('2026-09', 0)]);
    });

    test('a range across a year boundary', () {
      final bars = spendingByMonth(
          [row('2025-12-31', -100, 'Groceries'), row('2026-01-01', -200, 'Groceries')], r('2025-12-01', '2026-01-31'),
          today: today, currency: eur);
      expect(bars.map((b) => b.month), ['2025-12', '2026-01']);
      expect(bars.map((b) => b.spent), [100, 200]);
    });
  });

  group('categoryShare', () {
    test('slices, total and permille', () {
      final txs = [
        row('2026-10-02', -5000, 'Groceries'),
        row('2026-10-03', -3000, 'Eating out'),
        row('2026-10-04', -2000, 'Shopping'),
      ];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.total, 10000);
      expect(s.slices.map((x) => x.category), ['Groceries', 'Eating out', 'Shopping']);
      expect(s.slices.map((x) => x.spent), [5000, 3000, 2000]);
      expect(s.slices.map((x) => x.permille), [500, 300, 200]);
    });

    test('largest remainder: 1, 2, 4 cents give 571, 286, 143', () {
      final txs = [row('2026-10-02', -1, 'Cash'), row('2026-10-02', -2, 'Shopping'), row('2026-10-02', -4, 'Groceries')];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.slices.map((x) => x.permille), [571, 286, 143]);
    });

    test('permille always sums to exactly 1000', () {
      for (final amounts in [
        [1, 1, 1],
        [1, 1, 1, 1, 1, 1, 1],
        [333, 333, 334],
        [999999, 1, 1],
        [7, 11, 13, 17, 19, 23],
      ]) {
        final cats = ['Groceries', 'Eating out', 'Shopping', 'Cash', 'To people', 'Bank fees', 'Health & care'];
        final txs = [for (var i = 0; i < amounts.length; i++) row('2026-10-05', -amounts[i], cats[i])];
        final s = categoryShare(txs, oct, currency: eur);
        expect(s.slices.fold<int>(0, (a, x) => a + x.permille), 1000, reason: '$amounts');
        expect(s.total, amounts.fold<int>(0, (a, b) => a + b));
        for (final x in s.slices) {
          // never more than one permille away from the exact share
          expect((x.permille - x.spent * 1000 ~/ s.total).abs() <= 1, isTrue, reason: '$amounts');
        }
      }
    });

    test('one category takes all 1000', () {
      final s = categoryShare([row('2026-10-02', -123, 'Groceries')], oct, currency: eur);
      expect(s.slices.single.permille, 1000);
    });

    test('ties are ordered by name', () {
      final txs = [row('2026-10-02', -100, 'Eating out'), row('2026-10-02', -100, 'Cash'), row('2026-10-02', -300, 'Shopping')];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.slices.map((x) => x.category), ['Shopping', 'Cash', 'Eating out']);
    });

    test('categories with net spending of zero or less are left out of slices and total', () {
      final txs = [
        row('2026-10-02', -1000, 'Groceries'),
        row('2026-10-03', -1000, 'Cash'),
        row('2026-10-04', 1000, 'Cash'), // fully refunded: net 0
        row('2026-10-05', 500, 'Shopping'), // refund only: net -500
      ];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.slices.map((x) => x.category), ['Groceries']);
      expect(s.total, 1000);
      expect(s.slices.single.permille, 1000);
    });

    test('refunds reduce a slice', () {
      final txs = [row('2026-10-02', -1000, 'Groceries'), row('2026-10-03', 250, 'Groceries'), row('2026-10-04', -750, 'Shopping')];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.total, 1500);
      expect(s.slices.map((x) => x.spent), [750, 750]);
      expect(s.slices.map((x) => x.category), ['Groceries', 'Shopping']);
    });

    test('transfers, income and deleted rows count nowhere', () {
      final txs = [
        row('2026-10-02', -4000, 'Internal transfer'),
        row('2026-10-02', -4000, 'Loan received'),
        row('2026-10-03', 90000, 'Salary'),
        row('2026-10-04', -800, 'Groceries', deleted: true),
        row('2026-10-05', -100, 'Groceries'),
      ];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.total, 100);
      expect(s.slices.map((x) => x.category), ['Groceries']);
    });

    test('foreign rows are left out and reported, signed, by currency; transfers are not reported', () {
      final txs = [
        row('2026-10-02', -1000, 'Groceries'),
        row('2026-10-03', -5000, 'Groceries', currency: 'USD'),
        row('2026-10-04', -700, 'Eating out', currency: 'USD'),
        row('2026-10-05', -300, 'Shopping', currency: 'GBP'),
        row('2026-10-06', -800, 'Internal transfer', currency: 'GBP'),
        row('2026-10-07', -999, 'Shopping', currency: 'CHF', deleted: true),
      ];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.total, 1000);
      expect(s.foreignByCurrency, {'USD': -5700, 'GBP': -300});
    });

    test('rows outside the range are excluded', () {
      final txs = [row('2026-09-30', -100, 'Groceries'), row('2026-11-01', -100, 'Groceries'), row('2026-10-01', -50, 'Cash')];
      final s = categoryShare(txs, oct, currency: eur);
      expect(s.total, 50);
      expect(s.slices.single.category, 'Cash');
    });

    test('empty range: no slices, total 0, no foreign', () {
      final s = categoryShare(const [], oct, currency: eur);
      expect(s.slices, isEmpty);
      expect(s.total, 0);
      expect(s.foreignByCurrency, isEmpty);
    });

    test('the slices equal monthSummary.byCategory for one month', () {
      final txs = [
        row('2026-10-02', -1234, 'Groceries'),
        row('2026-10-03', -77, 'Groceries'),
        row('2026-10-09', -5000, 'Rent'),
        row('2026-10-10', 300, 'Eating out'),
        row('2026-10-11', -900, 'Eating out'),
      ];
      final by = monthSummary(txs, '2026-10', currency: eur).byCategory;
      final s = categoryShare(txs, oct, currency: eur);
      expect({
        for (final x in s.slices) x.category: x.spent
      }, {
        for (final e in by.entries)
          if (e.value > 0) e.key: e.value
      });
    });
  });

  group('incomeVsSpending', () {
    test('income, extra, spent and net per month', () {
      final txs = [
        row('2026-10-02', 150000, 'Salary'),
        row('2026-10-03', 5000, 'Extra income'),
        row('2026-10-04', -20000, 'Groceries'),
        row('2026-10-05', -30000, 'Rent'),
        row('2026-10-06', 2000, 'Groceries'), // refund
      ];
      final m = incomeVsSpending(txs, oct, today: today, currency: eur).single;
      expect(m.month, '2026-10');
      expect(m.income, 150000);
      expect(m.extra, 5000);
      expect(m.spent, 48000);
      expect(m.net, 107000);
      expect(m.net, m.income + m.extra - m.spent);
    });

    test('net can be negative', () {
      final m = incomeVsSpending([row('2026-10-04', -1000, 'Groceries')], oct, today: today, currency: eur).single;
      expect((m.income, m.extra, m.spent, m.net), (0, 0, 1000, -1000));
    });

    test('empty months appear with zeros; order ascending; partial flag', () {
      final txs = [row('2026-08-20', 100000, 'Salary'), row('2026-10-02', -500, 'Cash')];
      final ms = incomeVsSpending(txs, r('2026-08-15', '2026-10-31'), today: today, currency: eur);
      expect(ms.map((m) => m.month), ['2026-08', '2026-09', '2026-10']);
      expect((ms[1].income, ms[1].extra, ms[1].spent, ms[1].net), (0, 0, 0, 0));
      expect(ms[0].partial, isTrue);
      expect(ms[1].partial, isFalse);
      expect(ms[2].partial, isTrue); // the current month is always partial
    });

    test('days outside the range are excluded', () {
      final txs = [row('2026-08-14', 100000, 'Salary'), row('2026-08-15', 7, 'Salary'), row('2026-08-31', -3, 'Cash')];
      final m = incomeVsSpending(txs, r('2026-08-15', '2026-08-31'), today: today, currency: eur).single;
      expect((m.income, m.spent), (7, 3));
    });

    test('transfers, deleted and foreign rows count nowhere', () {
      final txs = [
        row('2026-10-02', 50000, 'Internal transfer'),
        row('2026-10-02', -50000, 'Internal transfer'),
        row('2026-10-03', 90000, 'Salary', currency: 'USD'),
        row('2026-10-04', 90000, 'Salary', deleted: true),
        row('2026-10-05', -1000, 'Groceries', currency: 'USD'),
      ];
      final m = incomeVsSpending(txs, oct, today: today, currency: eur).single;
      expect((m.income, m.extra, m.spent, m.net), (0, 0, 0, 0));
    });

    test('spent agrees with spendingByMonth', () {
      final txs = [
        row('2026-09-02', -11, 'Groceries'),
        row('2026-09-03', 4, 'Groceries'),
        row('2026-10-02', -222, 'Rent'),
        row('2026-10-02', 9000, 'Salary'),
      ];
      final range = r('2026-09-01', '2026-10-31');
      expect(incomeVsSpending(txs, range, today: today, currency: eur).map((m) => m.spent),
          spendingByMonth(txs, range, today: today, currency: eur).map((b) => b.spent));
    });
  });

  group('budgetVsActualSeries', () {
    const budgets = {'Groceries': 30000, 'Eating out': 10000};

    test('budgeted, actual and over per month; the current month is included', () {
      final txs = [
        row('2026-09-05', -35000, 'Groceries'), // 5000 over
        row('2026-09-06', -4000, 'Eating out'),
        row('2026-09-07', -9000, 'Shopping'), // no budget: ignored
        row('2026-10-05', -10000, 'Groceries'),
      ];
      final s = budgetVsActualSeries(txs, r('2026-09-01', '2026-10-31'), budgets, today: today, currency: eur);
      expect(s.map((m) => m.month), ['2026-09', '2026-10']);
      expect((s[0].budgeted, s[0].actual, s[0].over), (40000, 39000, 5000));
      expect((s[1].budgeted, s[1].actual, s[1].over), (40000, 10000, 0));
    });

    test('over sums per category: an under-spent category does not offset an over-spent one', () {
      final txs = [row('2026-09-05', -40000, 'Groceries'), row('2026-09-06', -1000, 'Eating out')];
      final m = budgetVsActualSeries(txs, r('2026-09-01', '2026-09-30'), budgets, today: today, currency: eur).single;
      expect(m.actual, 41000);
      expect(m.budgeted, 40000);
      expect(m.over, 10000); // not max(0, 41000 - 40000)
    });

    test('a month without spending still shows the budget', () {
      final m = budgetVsActualSeries(const [], r('2026-08-01', '2026-08-31'), budgets, today: today, currency: eur).single;
      expect((m.budgeted, m.actual, m.over), (40000, 0, 0));
    });

    test('a spending exactly at the budget is not over', () {
      final m = budgetVsActualSeries([row('2026-09-02', -30000, 'Groceries')], r('2026-09-01', '2026-09-30'), budgets,
              today: today, currency: eur)
          .single;
      expect(m.over, 0);
    });

    test('refunds reduce actual; transfers and foreign rows do not count', () {
      final txs = [
        row('2026-09-02', -4000, 'Eating out'),
        row('2026-09-03', 1000, 'Eating out'),
        row('2026-09-04', -9000, 'Eating out', currency: 'USD'),
        row('2026-09-05', -9000, 'Internal transfer'),
      ];
      final m = budgetVsActualSeries(txs, r('2026-09-01', '2026-09-30'), budgets, today: today, currency: eur).single;
      expect(m.actual, 3000);
    });

    test('no budgets gives zeros', () {
      final m = budgetVsActualSeries([row('2026-09-02', -4000, 'Eating out')], r('2026-09-01', '2026-09-30'), const {},
              today: today, currency: eur)
          .single;
      expect((m.budgeted, m.actual, m.over), (0, 0, 0));
    });

    test('a month equals budgetVsActual for that month', () {
      final txs = [row('2026-09-02', -41000, 'Groceries'), row('2026-09-03', -2000, 'Eating out')];
      final m = budgetVsActualSeries(txs, r('2026-09-01', '2026-09-30'), budgets, today: today, currency: eur).single;
      final b = budgetVsActual(txs, '2026-09', budgets, today: today, currency: eur);
      expect(m.actual, b.lines.where((l) => l.budget != null).fold<int>(0, (a, l) => a + l.actual));
    });
  });

  group('merchantsIn', () {
    test('groups rows of one merchant, newest label, count and last date', () {
      final txs = [
        row('2026-10-02', -1000, 'Groceries', desc: 'POS LIDL ZAGREB 123'),
        row('2026-10-12', -2000, 'Groceries', desc: 'POS LIDL ZAGREB 456'),
        row('2026-10-05', -1500, 'Groceries', desc: 'POS KONZUM SPLIT'),
      ];
      final m = merchantsIn('Groceries', txs, oct, currency: eur);
      expect(m.map((x) => x.spent), [3000, 1500]);
      expect(m[0].key, merchantKey(txs[0].tx));
      expect(m[0].key, merchantKey(txs[1].tx));
      expect(m[0].count, 2);
      expect(m[0].lastDate, '2026-10-12');
      expect(m[0].label, startsWith('LIDL ZAGREB'));
      expect(m[0].label, endsWith('456')); // the latest row's description
      expect(m[1].count, 1);
      expect(m[1].lastDate, '2026-10-05');
    });

    test('only rows of that resolved category, in range, live, home currency', () {
      final txs = [
        row('2026-10-02', -1000, 'Groceries', desc: 'POS LIDL ZAGREB'),
        row('2026-10-02', -9000, 'Shopping', desc: 'POS LIDL ZAGREB'),
        row('2026-09-30', -9000, 'Groceries', desc: 'POS LIDL ZAGREB'),
        row('2026-10-03', -9000, 'Groceries', desc: 'POS LIDL ZAGREB', deleted: true),
        row('2026-10-04', -9000, 'Groceries', desc: 'POS LIDL ZAGREB', currency: 'USD'),
      ];
      final m = merchantsIn('Groceries', txs, oct, currency: eur);
      expect(m.single.spent, 1000);
      expect(m.single.count, 1);
    });

    test('refunds are subtracted from the merchant', () {
      final txs = [row('2026-10-02', -3000, 'Shopping', desc: 'POS HM ZAGREB'), row('2026-10-09', 1000, 'Shopping', desc: 'POS HM ZAGREB')];
      expect(merchantsIn('Shopping', txs, oct, currency: eur).single.spent, 2000);
    });

    test('ordered by spent descending, then by label', () {
      final txs = [
        row('2026-10-02', -2000, 'Eating out', desc: 'POS BBB GRILL'),
        row('2026-10-03', -2000, 'Eating out', desc: 'POS AAA GRILL'),
        row('2026-10-04', -5000, 'Eating out', desc: 'POS CCC GRILL'),
      ];
      final m = merchantsIn('Eating out', txs, oct, currency: eur);
      expect(m.map((x) => x.label), ['CCC GRILL', 'AAA GRILL', 'BBB GRILL']);
    });

    test('rows without a merchant key are grouped as Other', () {
      // A description of digits only has no merchant name left once digits are removed.
      final txs = [
        row('2026-10-02', -400, 'Cash', desc: '12345'),
        row('2026-10-03', -600, 'Cash', desc: '98765'),
        row('2026-10-04', -100, 'Cash', desc: 'POS ATM TEST ULICA'),
      ];
      final m = merchantsIn('Cash', txs, oct, currency: eur);
      final other = m.singleWhere((x) => x.key == '');
      expect(other.label, 'Other');
      expect(other.spent, 1000);
      expect(other.count, 2);
      expect(m.length, 2);
    });

    test('manual rows without a note are Other; with a note they are named by it', () {
      final txs = [
        row('2026-10-02', -400, 'Cash', source: 'manual'),
        row('2026-10-03', -600, 'Cash', source: 'manual', note: ''),
        row('2026-10-04', -100, 'Cash', source: 'manual', note: 'Farmers market'),
      ];
      final m = merchantsIn('Cash', txs, oct, currency: eur);
      final other = m.singleWhere((x) => x.key == '');
      expect((other.label, other.spent, other.count), ('Other', 1000, 2));
      expect(m.length, 2);
      expect(m.singleWhere((x) => x.key != '').label, 'Farmers market');
    });

    test('the label comes from the newest row; on the same date the higher id wins', () {
      final txs = [
        row('2026-10-05', -100, 'Groceries', desc: 'POS LIDL ZAGREB 111', id: 'a1'),
        row('2026-10-05', -100, 'Groceries', desc: 'POS LIDL ZAGREB 222', id: 'a2'),
      ];
      expect(merchantsIn('Groceries', txs, oct, currency: eur).single.label, merchantName(txs[1].tx));
      expect(merchantsIn('Groceries', txs.reversed.toList(), oct, currency: eur).single.label, merchantName(txs[1].tx));
    });

    test('empty when the category has no spending', () {
      expect(merchantsIn('Games & apps', [row('2026-10-02', -1, 'Cash')], oct, currency: eur), isEmpty);
    });

    test('merchant totals add up to the category slice', () {
      final txs = [
        for (var i = 1; i <= 9; i++) row('2026-10-0$i', -(i * 137), 'Groceries', desc: 'POS SHOP${i % 3} ZAGREB'),
        row('2026-10-10', 111, 'Groceries', desc: 'POS SHOP1 ZAGREB'),
      ];
      final total = merchantsIn('Groceries', txs, oct, currency: eur).fold<int>(0, (a, m) => a + m.spent);
      expect(total, categoryShare(txs, oct, currency: eur).slices.single.spent);
    });
  });

  group('rowsFor', () {
    final txs = [
      row('2026-10-02', -1000, 'Groceries', desc: 'POS LIDL ZAGREB', id: 'a'),
      row('2026-10-12', -2000, 'Groceries', desc: 'POS LIDL ZAGREB', id: 'b'),
      row('2026-10-15', 700, 'Groceries', desc: 'POS LIDL ZAGREB', id: 'c'), // refund
      row('2026-10-05', -1500, 'Groceries', desc: 'POS KONZUM SPLIT', id: 'd'),
      row('2026-10-06', -321, 'Groceries', desc: '555', id: 'e'),
      row('2026-10-07', -9000, 'Shopping', desc: 'POS LIDL ZAGREB', id: 'f'),
      row('2026-09-30', -9000, 'Groceries', desc: 'POS LIDL ZAGREB', id: 'g'),
      row('2026-10-08', -9000, 'Groceries', desc: 'POS LIDL ZAGREB', id: 'h', deleted: true),
      row('2026-10-09', -9000, 'Groceries', desc: 'POS LIDL ZAGREB', id: 'i', currency: 'USD'),
    ];

    test('newest first, only the merchant live rows in the range', () {
      final key = merchantKey(txs[0].tx);
      final rows = rowsFor('Groceries', key, txs, oct, currency: eur);
      expect(rows.map((x) => x.tx.id), ['c', 'b', 'a']);
    });

    test('signed amounts sum to exactly -spent of the merchant total', () {
      final m = merchantsIn('Groceries', txs, oct, currency: eur);
      expect(m, isNotEmpty);
      for (final t in m) {
        final rows = rowsFor('Groceries', t.key, txs, oct, currency: eur);
        expect(rows.fold<int>(0, (a, x) => a + x.amount), -t.spent, reason: t.key);
      }
    });

    test('a null merchant gives the whole category, summing to the slice', () {
      final rows = rowsFor('Groceries', null, txs, oct, currency: eur);
      expect(rows.map((x) => x.tx.id), ['c', 'b', 'e', 'd', 'a']);
      final slice = categoryShare(txs, oct, currency: eur).slices.singleWhere((s) => s.category == 'Groceries');
      expect(rows.fold<int>(0, (a, x) => a + x.amount), -slice.spent);
    });

    test('the Other group is reachable with the key empty string', () {
      final rows = rowsFor('Groceries', '', txs, oct, currency: eur);
      expect(rows.map((x) => x.tx.id), ['e']);
    });

    test('an unknown merchant or category gives no rows', () {
      expect(rowsFor('Groceries', 'nobody', txs, oct, currency: eur), isEmpty);
      expect(rowsFor('Cash', null, txs, oct, currency: eur), isEmpty);
    });
  });

  group('merchantTrend', () {
    test('per-month spending of one merchant, empty months included', () {
      final txs = [
        row('2026-08-05', -1000, 'Groceries', desc: 'POS LIDL ZAGREB'),
        row('2026-10-03', -2000, 'Groceries', desc: 'POS LIDL ZAGREB'),
        row('2026-10-04', -5000, 'Groceries', desc: 'POS KONZUM SPLIT'),
        row('2026-09-04', -5000, 'Shopping', desc: 'POS LIDL ZAGREB'),
        row('2026-10-05', -5000, 'Groceries', desc: 'POS LIDL ZAGREB', currency: 'USD'),
      ];
      final bars = merchantTrend('Groceries', merchantKey(txs[0].tx), txs, r('2026-08-01', '2026-10-31'), today: today, currency: eur);
      expect(bars.map((b) => b.month), ['2026-08', '2026-09', '2026-10']);
      expect(bars.map((b) => b.spent), [1000, 0, 2000]);
    });

    test('partial months follow the range, refunds are subtracted', () {
      final txs = [
        row('2026-08-20', -1000, 'Groceries', desc: 'POS LIDL ZAGREB'),
        row('2026-08-25', 400, 'Groceries', desc: 'POS LIDL ZAGREB'),
        row('2026-08-10', -777, 'Groceries', desc: 'POS LIDL ZAGREB'), // before the range
      ];
      final bars = merchantTrend('Groceries', merchantKey(txs[0].tx), txs, r('2026-08-15', '2026-09-30'), today: today, currency: eur);
      expect(bars[0].spent, 600);
      expect(bars[0].partial, isTrue);
      expect(bars[1].partial, isFalse);
    });
  });

  group('compareCategory', () {
    test('this month, last month and the 6-month average before', () {
      final txs = [
        row('2026-10-03', -5000, 'Groceries'),
        row('2026-09-10', -4000, 'Groceries'),
        row('2026-04-10', -600, 'Groceries'),
        row('2026-03-10', -99999, 'Groceries'), // 7 months back: outside the 6
        row('2026-11-01', -99999, 'Groceries'), // after the month
        row('2026-10-04', -88888, 'Shopping'), // other category
      ];
      final c = compareCategory('Groceries', txs, '2026-10', currency: eur);
      expect(c.thisMonth, 5000);
      expect(c.lastMonth, 4000);
      expect(c.average6, 767); // (4000 + 600) / 6 = 766.67
    });

    test('average divides by 6 even when most months are empty, and agrees with averageByCategory', () {
      final txs = [row('2026-07-01', -600, 'Cash')];
      final c = compareCategory('Cash', txs, '2026-10', currency: eur);
      expect(c.average6, 100);
      expect(c.average6, averageByCategory(txs, '2026-10', currency: eur)['Cash']);
    });

    test('across a year boundary', () {
      final txs = [row('2026-01-15', -700, 'Cash'), row('2025-12-31', -300, 'Cash'), row('2025-08-01', -9000, 'Cash')];
      final c = compareCategory('Cash', txs, '2026-01', currency: eur);
      expect(c.thisMonth, 700);
      expect(c.lastMonth, 300);
      expect(c.average6, 50); // Aug 2025 is 5 months before Jan 2026? (Jul..Dec 2025) 300 / 6
    });

    test('an unknown or unused category is all zero', () {
      final c = compareCategory('Games & apps', [row('2026-10-03', -5000, 'Groceries')], '2026-10', currency: eur);
      expect((c.thisMonth, c.lastMonth, c.average6), (0, 0, 0));
    });

    test('refunds reduce, foreign and deleted rows are ignored', () {
      final txs = [
        row('2026-10-03', -5000, 'Groceries'),
        row('2026-10-04', 1000, 'Groceries'),
        row('2026-10-05', -5000, 'Groceries', currency: 'USD'),
        row('2026-09-05', -5000, 'Groceries', deleted: true),
      ];
      final c = compareCategory('Groceries', txs, '2026-10', currency: eur);
      expect(c.thisMonth, 4000);
      expect(c.lastMonth, 0);
    });
  });

  group('biggestRows', () {
    test('largest spending rows first by absolute amount, limited', () {
      final txs = [
        row('2026-10-02', -500, 'Groceries', id: 'a'),
        row('2026-10-03', -30000, 'Rent', id: 'b'),
        row('2026-10-04', -9000, 'Shopping', id: 'c'),
        row('2026-10-05', -100, 'Cash', id: 'd'),
      ];
      expect(biggestRows(txs, oct, limit: 3, currency: eur).map((x) => x.tx.id), ['b', 'c', 'a']);
      expect(biggestRows(txs, oct, limit: 1, currency: eur).map((x) => x.tx.id), ['b']);
      expect(biggestRows(txs, oct, currency: eur).length, 4); // default limit 10, fewer rows
    });

    test('the default limit is 10', () {
      final txs = [for (var i = 1; i <= 15; i++) row('2026-10-${i.toString().padLeft(2, '0')}', -i * 10, 'Groceries')];
      expect(biggestRows(txs, oct, currency: eur).length, 10);
    });

    test('ties are broken by newest date, then id (deterministic whatever the input order)', () {
      final a = row('2026-10-02', -1000, 'Groceries', id: 'x1');
      final b = row('2026-10-09', -1000, 'Groceries', id: 'x2');
      final c = row('2026-10-09', -1000, 'Shopping', id: 'x3');
      final d = row('2026-10-05', -1000, 'Cash', id: 'x4');
      final one = biggestRows([a, b, c, d], oct, currency: eur).map((x) => x.tx.id).toList();
      final two = biggestRows([d, c, b, a], oct, currency: eur).map((x) => x.tx.id).toList();
      expect(one, two);
      expect(one.take(2).toSet(), {'x2', 'x3'}); // newest date first
      expect(one[2], 'x4');
      expect(one[3], 'x1');
    });

    test('income, transfers, deleted, foreign and out-of-range rows are not listed', () {
      final txs = [
        row('2026-10-02', 900000, 'Salary', id: 'in'),
        row('2026-10-02', -900000, 'Internal transfer', id: 'tr'),
        row('2026-10-02', -900000, 'Groceries', id: 'del', deleted: true),
        row('2026-10-02', -900000, 'Groceries', id: 'usd', currency: 'USD'),
        row('2026-09-30', -900000, 'Groceries', id: 'old'),
        row('2026-11-01', -900000, 'Groceries', id: 'new'),
        row('2026-10-31', -1, 'Groceries', id: 'ok'),
      ];
      expect(biggestRows(txs, oct, currency: eur).map((x) => x.tx.id), ['ok']);
    });
  });

  group('performance', () {
    test('every function over a 10k-row wallet and months12 stays far under the loose bound', () {
      final cats = ['Groceries', 'Eating out', 'Shopping', 'Cash', 'Rent', 'Car & transport', 'Health & care', 'Salary'];
      final txs = <CategorizedTx>[];
      var d = DateTime.utc(2025, 11, 1);
      for (var i = 0; i < 10000; i++) {
        final day = d.add(Duration(days: i % 365));
        final date = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
        final cat = cats[i % cats.length];
        txs.add(row(date, cat == 'Salary' ? 150000 : -(100 + i % 9000), cat, desc: 'POS SHOP${i % 40} CITY', id: 'perf-$i'));
      }
      final range = r('2025-11-01', '2026-10-31');
      final watch = Stopwatch()..start();
      spendingByMonth(txs, range, today: today, currency: eur);
      categoryShare(txs, range, currency: eur);
      incomeVsSpending(txs, range, today: today, currency: eur);
      budgetVsActualSeries(txs, range, {'Groceries': 30000, 'Shopping': 10000}, today: today, currency: eur);
      final m = merchantsIn('Groceries', txs, range, currency: eur);
      rowsFor('Groceries', m.first.key, txs, range, currency: eur);
      merchantTrend('Groceries', m.first.key, txs, range, today: today, currency: eur);
      compareCategory('Groceries', txs, '2026-10', currency: eur);
      biggestRows(txs, range, currency: eur);
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });
}
