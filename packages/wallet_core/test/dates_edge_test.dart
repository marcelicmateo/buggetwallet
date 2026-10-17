// Date and pay-period edge cases: month ends, leap years, DST weekends, year boundaries, paydayDay 29-31.
// Expected values are worked out by hand from a calendar. All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart' show fuzzIterations, fuzzSeed;
import 'support/synthetic.dart';

int _lastDay(int y, int m) => DateTime.utc(y, m + 1, 0).day;

void main() {
  group('nextPayday', () {
    test('paydayDay 29-31 clamps to the month end', () {
      expect(nextPayday('2026-01-31', 31), '2026-02-28');
      expect(nextPayday('2026-01-29', 29), '2026-02-28');
      expect(nextPayday('2026-01-30', 30), '2026-02-28');
      expect(nextPayday('2026-02-28', 31), '2026-03-31');
      expect(nextPayday('2026-03-31', 31), '2026-04-30');
      expect(nextPayday('2026-04-30', 31), '2026-05-31');
      expect(nextPayday('2026-08-31', 31), '2026-09-30');
    });

    test('leap years: Feb 29 in 2028, not in 2027 or 2100; 2000 was a leap year', () {
      expect(nextPayday('2028-01-31', 31), '2028-02-29');
      expect(nextPayday('2028-01-29', 29), '2028-02-29');
      expect(nextPayday('2027-01-29', 29), '2027-02-28');
      expect(nextPayday('2028-02-29', 29), '2028-03-29');
      expect(nextPayday('2028-02-29', 31), '2028-03-31');
      expect(nextPayday('2100-01-31', 30), '2100-02-28');
      expect(nextPayday('2000-01-31', 30), '2000-02-29');
    });

    test('year boundary', () {
      expect(nextPayday('2026-12-15', 15), '2027-01-15');
      expect(nextPayday('2026-12-31', 31), '2027-01-31');
      expect(nextPayday('2026-11-30', 31), '2026-12-31');
    });

    test('a start late in the month still moves to the NEXT month (no skipped or repeated month)', () {
      expect(nextPayday('2026-01-31', 15), '2026-02-15');
      expect(nextPayday('2026-01-01', 15), '2026-02-15');
      expect(nextPayday('2026-01-14', 15), '2026-02-15');
    });

    test('property: lands in the following month on min(paydayDay, month length)', () {
      final r = Random(fuzzSeed(31));
      for (var i = 0; i < fuzzIterations(2000); i++) {
        final d = addDays('1999-12-01', r.nextInt(365 * 102));
        final day = 1 + r.nextInt(31);
        final got = parseIso(nextPayday(d, day));
        final from = parseIso(d);
        final wantMonth = DateTime.utc(from.year, from.month + 1, 1);
        expect((got.year, got.month), (wantMonth.year, wantMonth.month), reason: '$d $day');
        expect(got.day, min(day, _lastDay(wantMonth.year, wantMonth.month)), reason: '$d $day');
      }
    });
  });

  group('day arithmetic', () {
    test('DST weekends (EU: 29 Mar and 25 Oct 2026; US: 8 Mar, 1 Nov) are ordinary days', () {
      expect(daysBetween('2026-03-28', '2026-03-30'), 2);
      expect(daysBetween('2026-10-24', '2026-10-26'), 2);
      expect(daysBetween('2026-03-07', '2026-03-09'), 2);
      expect(daysBetween('2026-10-31', '2026-11-02'), 2);
      expect(addDays('2026-03-29', 1), '2026-03-30');
      expect(addDays('2026-10-25', 1), '2026-10-26');
      expect(addDays('2026-10-26', -1), '2026-10-25');
      expect(isoDate(DateTime(2026, 3, 29, 2, 30)), '2026-03-29');
      expect(isoDate(DateTime(2026, 10, 25, 23, 59)), '2026-10-25');
    });

    test('month ends, leap days and year ends', () {
      expect(addDays('2028-02-28', 1), '2028-02-29');
      expect(addDays('2027-02-28', 1), '2027-03-01');
      expect(addDays('2026-12-31', 1), '2027-01-01');
      expect(addDays('2027-01-01', -1), '2026-12-31');
      expect(daysBetween('2028-01-01', '2029-01-01'), 366);
      expect(daysBetween('2027-01-01', '2028-01-01'), 365);
      expect(daysBetween('2026-03-15', '2026-02-15'), -28);
      expect(monthOf('2028-02-29'), '2028-02');
      expect(monthsEnding('2027-01', 3), ['2026-11', '2026-12', '2027-01']);
      expect(monthsEnding('2026-12', 13).first, '2025-12');
      expect(monthsEnding('2026-05', 0), isEmpty);
    });

    test('property: addDays and daysBetween agree, and round-trip', () {
      final r = Random(fuzzSeed(7));
      for (var i = 0; i < fuzzIterations(3000); i++) {
        final d = addDays('1990-01-01', r.nextInt(365 * 120));
        final k = r.nextInt(2001) - 1000;
        final e = addDays(d, k);
        expect(daysBetween(d, e), k, reason: '$d $k');
        expect(addDays(e, -k), d, reason: '$d $k');
        expect(isoDate(parseIso(d)), d);
        expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(e), isTrue, reason: e);
      }
    });
  });

  group('safe to spend around the calendar', () {
    const goals = <Goal>[];
    WalletSettings st(String start, int day) => WalletSettings(salary: 310000, rent: 0, periodStart: start, paydayDay: day);

    test('a period over the March DST change has 31 days', () {
      final p = computePeriod(const [], st('2026-03-15', 15), goals, '2026-03-29');
      expect((p.end, p.length, p.daysLeft), ('2026-04-15', 31, 17));
    });

    test('over the year end', () {
      final p = computePeriod(
          [ct('2026-12-31', -1000, 'Groceries'), ct('2027-01-01', -2000, 'Groceries')], st('2026-12-12', 12), goals, '2027-01-01');
      expect((p.end, p.length, p.daysLeft, p.spent, p.spentToday), ('2027-01-12', 31, 11, 3000, 2000));
    });

    test('February in a leap year with paydayDay 29/30/31', () {
      expect(computePeriod(const [], st('2028-01-29', 29), goals, '2028-02-01').length, 31); // to Feb 29
      expect(computePeriod(const [], st('2028-01-31', 31), goals, '2028-02-01').end, '2028-02-29');
      expect(computePeriod(const [], st('2028-02-29', 31), goals, '2028-03-01').end, '2028-03-31');
      expect(computePeriod(const [], st('2027-01-30', 30), goals, '2027-02-01').end, '2027-02-28');
    });

    test('payday day itself and the last day of the period', () {
      final first = computePeriod(const [], st('2026-01-15', 15), goals, '2026-01-15');
      expect((first.daysLeft, first.length), (31, 31));
      expect(first.allowanceToday, (310000 / 31).round());
      final last = computePeriod(const [], st('2026-01-15', 15), goals, '2026-02-14');
      expect(last.daysLeft, 1);
      expect(last.allowanceToday, 310000, reason: 'everything unspent is available on the last day');
      expect(last.elapsed, 1.0);
    });
  });

  group('pay periods around the calendar', () {
    test('salary on the 31st/1st across months: one payday each, periods are contiguous', () {
      final txs = [
        ct('2026-01-31', 100000, 'Salary'),
        ct('2026-03-01', 100000, 'Salary'), // 29 days later: a new payday (> 20 days)
        ct('2026-03-31', 100000, 'Salary'),
      ];
      final ps = periodSummaries(txs, const WalletSettings(paydayDay: 31), '2026-04-10');
      expect(ps.map((p) => (p.start, p.end)).toList(),
          [('2026-01-31', '2026-03-01'), ('2026-03-01', '2026-03-31'), ('2026-03-31', '2026-04-30')]);
    });

    test('missing salary over a leap February with paydayDay 31: assumed Feb 29, then Mar 31', () {
      final ps = periodSummaries([ct('2028-01-31', 100000, 'Salary')], const WalletSettings(paydayDay: 31), '2028-04-05');
      expect(ps.map((p) => p.start).toList(), ['2028-01-31', '2028-02-29', '2028-03-31']);
      expect(ps.last.end, '2028-04-30');
    });

    test('salary parts over the new year are one payday', () {
      final txs = [ct('2026-12-28', 100000, 'Salary'), ct('2027-01-04', 20000, 'Salary'), ct('2027-01-10', -500, 'Groceries')];
      final ps = periodSummaries(txs, const WalletSettings(paydayDay: 28), '2027-01-12');
      expect(ps.single.start, '2026-12-28');
      expect((ps.single.income, ps.single.out, ps.single.end), (120000, 500, '2027-01-28'));
    });
  });
}
