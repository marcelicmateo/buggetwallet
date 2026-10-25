// N3 ranges (docs/context/N3_SPEC.md §1 + clarifications). Synthetic data only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart';

DateRange dr(String s, String e) => DateRange(start: s, end: e);

void main() {
  const st = WalletSettings(paydayDay: 10);

  group('DateRange', () {
    test('days, contains, equality', () {
      final r = dr('2026-10-01', '2026-10-31');
      expect(r.days, 31);
      expect(dr('2026-10-05', '2026-10-05').days, 1);
      expect(r.contains('2026-10-01'), isTrue);
      expect(r.contains('2026-10-31'), isTrue);
      expect(r.contains('2026-09-30'), isFalse);
      expect(r.contains('2026-11-01'), isFalse);
      expect(r, dr('2026-10-01', '2026-10-31'));
    });

    test('start after end or a bad date is refused', () {
      expect(() => dr('2026-10-02', '2026-10-01'), throwsArgumentError);
      expect(() => dr('2026-02-30', '2026-03-01'), throwsArgumentError);
      expect(() => dr('2026-10-01', '2026-10'), throwsArgumentError);
    });
  });

  group('rangeFor month kinds', () {
    test('month = the whole calendar month of today', () {
      final r = rangeFor(RangeKind.month, '2026-10-25', st);
      expect(r, dr('2026-10-01', '2026-10-31'));
      expect(rangeLabel(r), '1–31 Oct 2026');
    });

    test('month ends: the 31st and February in a leap year', () {
      expect(rangeFor(RangeKind.month, '2026-12-31', st), dr('2026-12-01', '2026-12-31'));
      expect(rangeFor(RangeKind.month, '2026-01-31', st), dr('2026-01-01', '2026-01-31'));
      final feb = rangeFor(RangeKind.month, '2028-02-29', st);
      expect(feb, dr('2028-02-01', '2028-02-29'));
      expect(feb.days, 29);
      expect(rangeFor(RangeKind.month, '2027-02-14', st), dr('2027-02-01', '2027-02-28'));
    });

    test('months3/6/12 end with the current month, whole months', () {
      expect(rangeFor(RangeKind.months3, '2026-10-25', st), dr('2026-08-01', '2026-10-31'));
      expect(rangeFor(RangeKind.months6, '2026-10-25', st), dr('2026-05-01', '2026-10-31'));
      expect(rangeFor(RangeKind.months12, '2026-10-25', st), dr('2025-11-01', '2026-10-31'));
      expect(rangeFor(RangeKind.months3, '2028-02-10', st), dr('2027-12-01', '2028-02-29'));
      expect(rangeLabel(rangeFor(RangeKind.months3, '2026-10-25', st)), 'Aug–Oct 2026');
      expect(rangeLabel(rangeFor(RangeKind.months3, '2026-01-25', st)), 'Nov 2025 – Jan 2026');
    });

    test('a bad today is refused', () {
      expect(() => rangeFor(RangeKind.month, '2026-13-01', st), throwsArgumentError);
    });
  });

  group('rangeFor payPeriod', () {
    test('from the latest salary to the day before the next payday', () {
      final txs = [row('2026-09-10', 150000, 'Salary'), row('2026-10-12', 150000, 'Salary'), row('2026-10-13', 40000, 'Salary')];
      final r = rangeFor(RangeKind.payPeriod, '2026-10-25', st, txs: txs);
      expect(r, dr('2026-10-12', '2026-11-09'));
      expect(rangeLabel(r), '12 Oct – 9 Nov 2026');
    });

    test('a late salary keeps the running period open until today', () {
      final txs = [row('2026-08-10', 150000, 'Salary'), row('2026-09-10', 150000, 'Salary')];
      expect(rangeFor(RangeKind.payPeriod, '2026-10-20', st, txs: txs), dr('2026-09-10', '2026-10-20'));
      // Before the payday the period ends the day before it.
      expect(rangeFor(RangeKind.payPeriod, '2026-10-05', st, txs: txs), dr('2026-09-10', '2026-10-09'));
    });

    test('after 45 days without salary assumed paydays start new periods (missed payday)', () {
      final txs = [row('2026-07-10', 150000, 'Salary')];
      final r = rangeFor(RangeKind.payPeriod, '2026-10-20', st, txs: txs);
      expect(r, dr('2026-10-10', '2026-11-09'));
      expect(shiftRange(r, RangeKind.payPeriod, -1, st, txs: txs, today: '2026-10-20'), dr('2026-09-10', '2026-10-09'));
      expect(shiftRange(r, RangeKind.payPeriod, -3, st, txs: txs, today: '2026-10-20'), dr('2026-07-10', '2026-08-09'));
    });

    test('foreign salary does not make a payday', () {
      final txs = [row('2026-10-12', 150000, 'Salary', currency: 'USD')];
      expect(rangeFor(RangeKind.payPeriod, '2026-10-25', st, txs: txs), dr('2026-10-10', '2026-11-09'));
    });

    test('no paydays at all: the latest expected payday on or before today', () {
      expect(rangeFor(RangeKind.payPeriod, '2026-10-05', st), dr('2026-09-10', '2026-10-09'));
      expect(rangeFor(RangeKind.payPeriod, '2026-10-10', st), dr('2026-10-10', '2026-11-09'));
      // paydayDay past the month's end is clamped like nextPayday.
      const late = WalletSettings(paydayDay: 28);
      expect(rangeFor(RangeKind.payPeriod, '2027-03-01', late), dr('2027-02-28', '2027-03-27'));
    });
  });

  group('rangeFor custom', () {
    test('from..to, label, future days up to the end of this month', () {
      final r = rangeFor(RangeKind.custom, '2026-11-20', st, from: '2026-10-14', to: '2026-11-13');
      expect(r, dr('2026-10-14', '2026-11-13'));
      expect(r.days, 31);
      expect(rangeLabel(r), '14 Oct – 13 Nov 2026');
      expect(rangeFor(RangeKind.custom, '2026-10-25', st, from: '2026-10-01', to: '2026-10-31').end, '2026-10-31');
      expect(rangeLabel(dr('2025-12-14', '2026-01-13')), '14 Dec 2025 – 13 Jan 2026');
      expect(rangeLabel(dr('2026-10-14', '2026-10-14')), '14 Oct 2026');
    });

    test('refusals: past this month, from > to, over 5 years, bad or missing dates', () {
      expect(() => rangeFor(RangeKind.custom, '2026-10-25', st, from: '2026-10-14', to: '2026-11-01'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, '2026-10-25', st, from: '2026-10-14', to: '2026-10-13'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, '2026-10-25', st, from: '2021-01-01', to: '2026-01-01'), throwsArgumentError);
      expect(rangeFor(RangeKind.custom, '2026-10-25', st, from: '2021-01-01', to: '2025-12-31').days, 1826);
      expect(() => rangeFor(RangeKind.custom, '2026-10-25', st, from: '2026-02-30', to: '2026-03-01'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, '2026-10-25', st, from: '2026-10-01'), throwsArgumentError);
      expect(() => rangeFor(RangeKind.custom, '2026-10-25', st, to: '2026-10-01'), throwsArgumentError);
    });
  });

  group('shiftRange', () {
    const today = '2026-10-25';

    test('months: whole calendar months of the same count, back and forward', () {
      final r = rangeFor(RangeKind.months3, today, st);
      final back = shiftRange(r, RangeKind.months3, -1, st, today: today);
      expect(back, dr('2026-05-01', '2026-07-31'));
      expect(shiftRange(back, RangeKind.months3, 1, st, today: today), r);
      expect(shiftRange(rangeFor(RangeKind.months12, today, st), RangeKind.months12, -1, st, today: today), dr('2024-11-01', '2025-10-31'));
      expect(shiftRange(rangeFor(RangeKind.months6, today, st), RangeKind.months6, -1, st, today: today), dr('2025-11-01', '2026-04-30'));
      expect(shiftRange(dr('2026-01-01', '2026-01-31'), RangeKind.month, 1, st, today: today), dr('2026-02-01', '2026-02-28'));
      expect(shiftRange(dr('2028-03-01', '2028-03-31'), RangeKind.month, -1, st, today: '2028-03-02'), dr('2028-02-01', '2028-02-29'));
      expect(shiftRange(rangeFor(RangeKind.month, today, st), RangeKind.month, -10, st, today: today), dr('2025-12-01', '2025-12-31'));
    });

    test('custom moves by its own length', () {
      final r = dr('2026-10-14', '2026-10-20');
      expect(shiftRange(r, RangeKind.custom, -1, st, today: today), dr('2026-10-07', '2026-10-13'));
      expect(shiftRange(r, RangeKind.custom, -2, st, today: today), dr('2026-09-30', '2026-10-06'));
      expect(shiftRange(dr('2026-09-01', '2026-09-07'), RangeKind.custom, 1, st, today: today), dr('2026-09-08', '2026-09-14'));
    });

    test('pay periods walk the real payday list', () {
      final txs = [
        row('2026-07-13', 150000, 'Salary'),
        row('2026-08-11', 150000, 'Salary'),
        row('2026-09-10', 150000, 'Salary'),
        row('2026-10-12', 150000, 'Salary'),
      ];
      final r = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(r, dr('2026-10-12', '2026-11-09'));
      final back = shiftRange(r, RangeKind.payPeriod, -1, st, txs: txs, today: today);
      expect(back, dr('2026-09-10', '2026-10-11'));
      expect(shiftRange(r, RangeKind.payPeriod, -3, st, txs: txs, today: today), dr('2026-07-13', '2026-08-10'));
      expect(shiftRange(back, RangeKind.payPeriod, 1, st, txs: txs, today: today), r);
      // Before the first salary: expected paydays of the months before.
      expect(shiftRange(r, RangeKind.payPeriod, -4, st, txs: txs, today: today), dr('2026-06-10', '2026-07-12'));
    });

    test('a step must not start after the month of today', () {
      expect(() => shiftRange(rangeFor(RangeKind.month, today, st), RangeKind.month, 1, st, today: today), throwsArgumentError);
      expect(() => shiftRange(rangeFor(RangeKind.months3, today, st), RangeKind.months3, 1, st, today: today), throwsArgumentError);
      expect(() => shiftRange(dr('2026-10-20', '2026-10-31'), RangeKind.custom, 1, st, today: today), throwsArgumentError);
      final txs = [row('2026-09-10', 150000, 'Salary'), row('2026-10-12', 150000, 'Salary')];
      final r = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
      expect(() => shiftRange(r, RangeKind.payPeriod, 1, st, txs: txs, today: today), throwsArgumentError);
    });

    test('forward then back is a round trip; shift 0 is the identity (review fix)', () {
      final txs = [row('2026-08-10', 150000, 'Salary'), row('2026-09-10', 150000, 'Salary')];
      const t = '2026-10-05';
      final cur = rangeFor(RangeKind.payPeriod, t, st, txs: txs);
      expect(cur, dr('2026-09-10', '2026-10-09'));
      final next = shiftRange(cur, RangeKind.payPeriod, 1, st, txs: txs, today: t);
      expect(next, dr('2026-10-10', '2026-11-09'));
      expect(shiftRange(next, RangeKind.payPeriod, -1, st, txs: txs, today: t), cur);
      expect(shiftRange(next, RangeKind.payPeriod, 0, st, txs: txs, today: t), next);
      expect(shiftRange(cur, RangeKind.payPeriod, 0, st, txs: txs, today: t), cur);
      expect(shiftRange(next, RangeKind.payPeriod, -2, st, txs: txs, today: t), dr('2026-08-10', '2026-09-09'));
    });

    test("custom: the end is clamped to the end of today's month (review decision)", () {
      expect(shiftRange(dr('2026-10-16', '2026-10-25'), RangeKind.custom, 1, st, today: today), dr('2026-10-26', '2026-10-31'));
      expect(() => shiftRange(dr('2026-10-22', '2026-10-31'), RangeKind.custom, 1, st, today: today), throwsArgumentError);
    });

    test('a late salary: the next period starts after today', () {
      final txs = [row('2026-08-10', 150000, 'Salary'), row('2026-09-10', 150000, 'Salary')];
      final r = rangeFor(RangeKind.payPeriod, '2026-10-20', st, txs: txs);
      expect(r, dr('2026-09-10', '2026-10-20'));
      // The expected 10 Oct has passed without salary, so the next is 10 Nov: after this month, refused.
      expect(() => shiftRange(r, RangeKind.payPeriod, 1, st, txs: txs, today: '2026-10-20'), throwsArgumentError);
      expect(shiftRange(r, RangeKind.payPeriod, -1, st, txs: txs, today: '2026-10-20'), dr('2026-08-10', '2026-09-09'));
    });
  });
}
