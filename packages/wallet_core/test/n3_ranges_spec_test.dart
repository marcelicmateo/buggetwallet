// Stage N3 spec tests: date ranges (docs/context/N3_SPEC.md §1). Written from the spec only. Synthetic data.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

const today = '2026-10-25';
const st = WalletSettings(); // paydayDay 15, EUR

DateRange r(String a, String b) => DateRange(start: a, end: b);

(String, String) se(DateRange x) => (x.start, x.end);

/// Salary rows (one per date) so that [detectPaydays] finds those paydays.
List<CategorizedTx> salaries(List<String> dates) => [for (final d in dates) ct(d, 150000, 'Salary')];

void main() {
  group('DateRange', () {
    test('days is inclusive', () {
      expect(r('2026-10-01', '2026-10-31').days, 31);
      expect(r('2026-10-05', '2026-10-05').days, 1);
      expect(r('2024-02-01', '2024-02-29').days, 29);
    });

    test('contains is inclusive at both ends and false outside', () {
      final x = r('2026-10-05', '2026-10-10');
      expect(x.contains('2026-10-05'), isTrue);
      expect(x.contains('2026-10-10'), isTrue);
      expect(x.contains('2026-10-07'), isTrue);
      expect(x.contains('2026-10-04'), isFalse);
      expect(x.contains('2026-10-11'), isFalse);
    });

    test('equality, hashCode and toString', () {
      expect(r('2026-10-01', '2026-10-31'), r('2026-10-01', '2026-10-31'));
      expect(r('2026-10-01', '2026-10-31').hashCode, r('2026-10-01', '2026-10-31').hashCode);
      expect(r('2026-10-01', '2026-10-31') == r('2026-10-01', '2026-10-30'), isFalse);
      expect(r('2026-10-01', '2026-10-31').toString(), contains('2026-10-01'));
    });

    test('a bad date is refused', () {
      expect(() => r('2026-02-30', '2026-03-01'), throwsArgumentError);
      expect(() => r('x', '2026-03-01'), throwsArgumentError);
    });

    test('start after end is refused', () {
      expect(() => r('2026-10-11', '2026-10-10'), throwsArgumentError);
    });
  });

  group('rangeFor calendar kinds', () {
    test('month is the calendar month of today', () {
      expect(se(rangeFor(RangeKind.month, today, st)), ('2026-10-01', '2026-10-31'));
    });

    test('months3 / 6 / 12 end with the month of today (partial month included)', () {
      expect(se(rangeFor(RangeKind.months3, today, st)), ('2026-08-01', '2026-10-31'));
      expect(se(rangeFor(RangeKind.months6, today, st)), ('2026-05-01', '2026-10-31'));
      expect(se(rangeFor(RangeKind.months12, today, st)), ('2025-11-01', '2026-10-31'));
    });

    test('month ends: 31st, 30th, February in a leap and a common year', () {
      expect(rangeFor(RangeKind.month, '2026-01-01', st).end, '2026-01-31');
      expect(rangeFor(RangeKind.month, '2026-04-30', st).end, '2026-04-30');
      expect(rangeFor(RangeKind.month, '2024-02-10', st).end, '2024-02-29');
      expect(rangeFor(RangeKind.month, '2026-02-10', st).end, '2026-02-28');
      expect(rangeFor(RangeKind.month, '2100-02-10', st).end, '2100-02-28'); // 2100 is not a leap year
      expect(rangeFor(RangeKind.month, '2000-02-10', st).end, '2000-02-29');
    });

    test('today on the last day of the month stays in that month', () {
      expect(se(rangeFor(RangeKind.months3, '2026-12-31', st)), ('2026-10-01', '2026-12-31'));
    });

    test('N months cross the year boundary', () {
      expect(se(rangeFor(RangeKind.months3, '2026-01-15', st)), ('2025-11-01', '2026-01-31'));
      expect(se(rangeFor(RangeKind.months12, '2026-01-15', st)), ('2025-02-01', '2026-01-31'));
    });

    test('months6 ending in February of a leap year', () {
      expect(se(rangeFor(RangeKind.months6, '2024-02-29', st)), ('2023-09-01', '2024-02-29'));
    });
  });

  group('rangeFor payPeriod', () {
    test('start is the last payday, end the day before the next one', () {
      final txs = salaries(['2026-08-15', '2026-09-15', '2026-10-15']);
      expect(se(rangeFor(RangeKind.payPeriod, today, st, txs: txs)), ('2026-10-15', '2026-11-14'));
    });

    test('before this month payday the previous period is current', () {
      final txs = salaries(['2026-08-15', '2026-09-15', '2026-10-15']);
      expect(se(rangeFor(RangeKind.payPeriod, '2026-10-10', st, txs: txs)), ('2026-09-15', '2026-10-14'));
    });

    test('the payday itself starts the new period', () {
      final txs = salaries(['2026-09-15', '2026-10-15']);
      expect(rangeFor(RangeKind.payPeriod, '2026-10-15', st, txs: txs).start, '2026-10-15');
    });

    test('an early real salary (14th) moves the period', () {
      final txs = salaries(['2026-09-15', '2026-10-14']);
      expect(se(rangeFor(RangeKind.payPeriod, today, st, txs: txs)), ('2026-10-14', '2026-11-14'));
    });

    test('across a missed payday the assumed payday day carries on', () {
      // Salary in August only: no September and no October salary row. detectPaydays assumes 15 Sep and 15 Oct.
      final txs = salaries(['2026-08-14']);
      final x = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(x.start, detectPaydays(txs, st, today).last);
      expect(se(x), ('2026-10-15', '2026-11-14'));
    });

    test('a late salary keeps the period open: end is never before today', () {
      final txs = salaries(['2026-09-15']); // October salary not in yet, 40 days is not a missed payday
      final x = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(x.start, '2026-09-15');
      expect(x.end.compareTo(today) >= 0, isTrue);
    });

    test('with no paydays the latest expected payday on or before today starts it', () {
      expect(se(rangeFor(RangeKind.payPeriod, today, st)), ('2026-10-15', '2026-11-14'));
      expect(se(rangeFor(RangeKind.payPeriod, '2026-10-10', st)), ('2026-09-15', '2026-10-14'));
      expect(rangeFor(RangeKind.payPeriod, '2026-10-15', st).start, '2026-10-15');
    });

    test('with no paydays and payday day 28 in a short month the start is a real date', () {
      final x = rangeFor(RangeKind.payPeriod, '2026-03-05', const WalletSettings(paydayDay: 28));
      expect(x.start, '2026-02-28');
    });

    test('it agrees with detectPaydays for any txs', () {
      final txs = salaries(['2026-06-16', '2026-07-15', '2026-09-12']);
      final x = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(x.start, detectPaydays(txs, st, today).last);
      expect(x.contains(today), isTrue);
    });

    test('a salary in another currency does not set a payday', () {
      const foreign =
          CategorizedTx(Tx(id: 'usd-1', source: 'pbz', date: '2026-10-20', amount: 150000, currency: 'USD'), 'Salary', BudgetKind.income);
      final txs = [
        ...salaries(['2026-09-15', '2026-10-15']),
        foreign
      ];
      expect(rangeFor(RangeKind.payPeriod, today, st, txs: txs).start, '2026-10-15');
    });
  });

  group('rangeFor custom', () {
    test('returns from..to', () {
      expect(se(rangeFor(RangeKind.custom, today, st, from: '2026-03-02', to: '2026-04-09')), ('2026-03-02', '2026-04-09'));
    });

    test('a single day is allowed', () {
      expect(rangeFor(RangeKind.custom, today, st, from: '2026-03-02', to: '2026-03-02').days, 1);
    });

    test('to may reach the end of the month of today but not past it', () {
      expect(rangeFor(RangeKind.custom, today, st, from: '2026-10-01', to: '2026-10-31').end, '2026-10-31');
      expect(rangeFor(RangeKind.custom, today, st, from: '2026-10-01', to: '2026-10-26').end, '2026-10-26');
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-10-01', to: '2026-11-01'), throwsArgumentError);
    });

    test('from after the end of the month of today is refused', () {
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-11-02', to: '2026-11-05'), throwsArgumentError);
    });

    test('from > to is refused', () {
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-04-10', to: '2026-04-09'), throwsArgumentError);
    });

    test('a span over 5 years is refused, a 3 year one is fine', () {
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2020-01-01', to: '2026-10-25'), throwsArgumentError);
      expect(rangeFor(RangeKind.custom, today, st, from: '2023-01-01', to: '2026-10-25').days, greaterThan(1000));
    });

    test('5 years: 2021-01-01..2025-12-31 is fine, ..2026-01-01 is refused', () {
      expect(rangeFor(RangeKind.custom, today, st, from: '2021-01-01', to: '2025-12-31').start, '2021-01-01');
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2021-01-01', to: '2026-01-01'), throwsArgumentError);
    });

    test('invalid dates are refused', () {
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-02-30', to: '2026-03-01'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-02-01', to: 'tomorrow'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-13-01', to: '2026-03-01'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, today, st, from: '', to: '2026-03-01'), throwsArgumentError);
    });

    test('from and to are both required', () {
      expect(() => rangeFor(RangeKind.custom, today, st), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-03-01'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, today, st, to: '2026-03-01'), throwsArgumentError);
    });

    test('Feb 29 is a valid date in a leap year only', () {
      expect(rangeFor(RangeKind.custom, today, st, from: '2024-02-29', to: '2024-03-01').days, 2);
      expect(() => rangeFor(RangeKind.custom, today, st, from: '2026-02-29', to: '2026-03-01'), throwsArgumentError);
    });
  });

  group('shiftRange', () {
    test('month back and the leap February', () {
      expect(se(shiftRange(r('2026-10-01', '2026-10-31'), RangeKind.month, -1, st, today: today)), ('2026-09-01', '2026-09-30'));
      expect(se(shiftRange(r('2024-03-01', '2024-03-31'), RangeKind.month, -1, st, today: today)), ('2024-02-01', '2024-02-29'));
      expect(se(shiftRange(r('2026-10-01', '2026-10-31'), RangeKind.month, -8, st, today: today)), ('2026-02-01', '2026-02-28'));
    });

    test('month back across a year', () {
      expect(se(shiftRange(r('2026-01-01', '2026-01-31'), RangeKind.month, -1, st, today: today)), ('2025-12-01', '2025-12-31'));
    });

    test('months3 Aug-Oct back is May-Jul, and forward again', () {
      final back = shiftRange(r('2026-08-01', '2026-10-31'), RangeKind.months3, -1, st, today: today);
      expect(se(back), ('2026-05-01', '2026-07-31'));
      expect(se(shiftRange(back, RangeKind.months3, 1, st, today: today)), ('2026-08-01', '2026-10-31'));
    });

    test('months6 and months12 move by their own count', () {
      expect(se(shiftRange(r('2026-05-01', '2026-10-31'), RangeKind.months6, -1, st, today: today)), ('2025-11-01', '2026-04-30'));
      expect(se(shiftRange(r('2025-11-01', '2026-10-31'), RangeKind.months12, -1, st, today: today)), ('2024-11-01', '2025-10-31'));
    });

    test('several steps at once and zero steps', () {
      expect(se(shiftRange(r('2026-08-01', '2026-10-31'), RangeKind.months3, -2, st, today: today)), ('2026-02-01', '2026-04-30'));
      expect(se(shiftRange(r('2026-08-01', '2026-10-31'), RangeKind.months3, 0, st, today: today)), ('2026-08-01', '2026-10-31'));
    });

    test('back then forward is the identity for months', () {
      final base = r('2026-10-01', '2026-10-31');
      final there = shiftRange(base, RangeKind.month, -5, st, today: today);
      expect(se(shiftRange(there, RangeKind.month, 5, st, today: today)), se(base));
    });

    test('forward past the month of today is refused', () {
      expect(() => shiftRange(r('2026-10-01', '2026-10-31'), RangeKind.month, 1, st, today: today), throwsArgumentError);
      expect(() => shiftRange(r('2026-08-01', '2026-10-31'), RangeKind.months3, 1, st, today: today), throwsArgumentError);
      expect(() => shiftRange(r('2026-05-01', '2026-07-31'), RangeKind.months3, 2, st, today: today), throwsArgumentError);
    });

    test('pay periods follow the real payday list', () {
      final txs = salaries(['2026-08-15', '2026-09-12', '2026-10-15']);
      final cur = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(se(cur), ('2026-10-15', '2026-11-14'));
      final prev = shiftRange(cur, RangeKind.payPeriod, -1, st, today: today, txs: txs);
      expect(se(prev), ('2026-09-12', '2026-10-14'));
      expect(se(shiftRange(cur, RangeKind.payPeriod, -2, st, today: today, txs: txs)), ('2026-08-15', '2026-09-11'));
      expect(se(shiftRange(prev, RangeKind.payPeriod, 1, st, today: today, txs: txs)), ('2026-10-15', '2026-11-14'));
    });

    test('pay periods extrapolate past the ends of the payday list', () {
      final txs = salaries(['2026-09-15', '2026-10-15']);
      final cur = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(se(shiftRange(cur, RangeKind.payPeriod, -3, st, today: today, txs: txs)), ('2026-07-15', '2026-08-14'));
    });

    test('a pay period shift past the month of today is refused', () {
      final txs = salaries(['2026-09-15', '2026-10-15']);
      final cur = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(() => shiftRange(cur, RangeKind.payPeriod, 1, st, today: today, txs: txs), throwsArgumentError);
    });

    test('pay periods across a missed payday stay adjacent', () {
      final txs = salaries(['2026-08-14']); // Sep and Oct paydays are assumed
      final cur = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      final prev = shiftRange(cur, RangeKind.payPeriod, -1, st, today: today, txs: txs);
      expect(prev.end, addDays(cur.start, -1));
      expect(prev.start, '2026-09-15');
    });

    test('custom moves by its own length in days', () {
      final x = shiftRange(r('2026-10-01', '2026-10-10'), RangeKind.custom, -1, st, today: today);
      expect(se(x), ('2026-09-21', '2026-09-30'));
      expect(x.days, 10);
      expect(se(shiftRange(r('2026-10-01', '2026-10-10'), RangeKind.custom, 1, st, today: today)), ('2026-10-11', '2026-10-20'));
    });

    test('custom forward: start may stay in the month of today, not leave it', () {
      expect(shiftRange(r('2026-10-11', '2026-10-20'), RangeKind.custom, 1, st, today: today).start, '2026-10-21');
      // Review decision: the end is clamped to the end of today's month, as rangeFor(custom) requires.
      expect(se(shiftRange(r('2026-10-16', '2026-10-25'), RangeKind.custom, 1, st, today: today)), ('2026-10-26', '2026-10-31'));
      expect(() => shiftRange(r('2026-10-26', '2026-10-31'), RangeKind.custom, 1, st, today: today), throwsArgumentError);
    });
  });

  group('rangeLabel', () {
    test('a calendar month', () {
      expect(rangeLabel(r('2026-10-01', '2026-10-31')), '1–31 Oct 2026');
    });

    test('several whole months', () {
      expect(rangeLabel(r('2026-08-01', '2026-10-31')), 'Aug–Oct 2026');
    });

    test('a single day', () {
      expect(rangeLabel(r('2026-10-14', '2026-10-14')), '14 Oct 2026');
    });

    test('across years', () {
      expect(rangeLabel(r('2025-12-14', '2026-01-13')), '14 Dec 2025 – 13 Jan 2026');
      expect(rangeLabel(r('2025-11-01', '2026-01-31')), 'Nov 2025 – Jan 2026');
    });

    test('an arbitrary span', () {
      expect(rangeLabel(r('2026-10-14', '2026-11-13')), '14 Oct – 13 Nov 2026');
    });
  });
}
