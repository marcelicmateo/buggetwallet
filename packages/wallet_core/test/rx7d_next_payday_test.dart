// RX7d: `nextPayday` (dates.dart) = the first expected payday more than `earlySalaryDays` (7) days after the start. A
// start up to 7 days before an expected payday is that payday's early salary; any other start belongs to the latest
// expected payday on or before it (on time, late, also across a month or year end, or set by hand mid-period). Before
// RX7d it was "the payday of the month after the start's month", so a salary landing a few days late across a month
// end made a ~2-month period. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/src/dates.dart' show paydayIn, paydayOf, previousPayday;
import 'package:wallet_core/wallet_core.dart';

var _n = 0;

Tx _tx(String date, int cents, String category) =>
    Tx(id: 'rx7d-${_n++}', source: 'pbz', date: date, amount: cents, currency: 'EUR', description: 'Synthetic row', category: category);

final _table = CategoryTable.builtIn;

List<CategorizedTx> _cat(List<Tx> rows) => Categorizer(table: _table).expandAll(rows);

/// `[start, end)` of every `periodSummaries` period, oldest first.
List<String> _periods(List<CategorizedTx> txs, WalletSettings st, String today) =>
    [for (final p in periodSummaries(txs, st, today, count: 1000)) '${p.start}..${p.end}'];

void main() {
  group('nextPayday', () {
    test('a salary late across the month end ends on the next month\'s payday, not the one after', () {
      expect(nextPayday('2027-03-02', 31), '2027-03-31'); // 28 Feb payday (clamped) paid 2 Mar; was 30 Apr
      expect(nextPayday('2027-03-01', 30), '2027-03-30');
      expect(nextPayday('2027-03-02', 28), '2027-03-28');
      expect(nextPayday('2027-05-03', 31), '2027-05-31'); // 30 Apr payday (30-day month) paid 3 May; was 30 Jun
    });

    test('an early salary (up to 7 days before the payday) ends on the payday after it', () {
      expect(nextPayday('2027-03-08', 10), '2027-04-10');
      expect(nextPayday('2027-03-03', 10), '2027-04-10'); // exactly 7 days early
      expect(nextPayday('2027-02-25', 31), '2027-03-31'); // 3 days before the clamped 28 Feb
    });

    test('on time', () {
      expect(nextPayday('2027-01-31', 31), '2027-02-28');
      expect(nextPayday('2027-03-10', 10), '2027-04-10');
      expect(nextPayday('2027-03-15', 15), '2027-04-15');
    });

    test('payday 29/30/31 clamps in February and in 30-day months', () {
      expect(nextPayday('2027-01-29', 29), '2027-02-28');
      expect(nextPayday('2027-02-28', 29), '2027-03-29');
      expect(nextPayday('2027-01-30', 30), '2027-02-28');
      expect(nextPayday('2027-02-28', 30), '2027-03-30');
      expect(nextPayday('2027-02-28', 31), '2027-03-31');
      expect(nextPayday('2027-03-31', 31), '2027-04-30');
      expect(nextPayday('2027-04-30', 31), '2027-05-31');
      expect(nextPayday('2028-01-31', 30), '2028-02-29'); // leap year
      expect(nextPayday('2028-02-29', 31), '2028-03-31');
    });

    test('December → January', () {
      expect(nextPayday('2027-01-02', 31), '2027-01-31'); // 31 Dec payday paid 2 Jan; was 28 Feb
      expect(nextPayday('2027-01-03', 28), '2027-01-28');
      expect(nextPayday('2026-12-29', 3), '2027-02-03'); // 5 days early for 3 Jan
      expect(nextPayday('2026-12-31', 31), '2027-01-31');
    });

    test('a start more than 7 days before the payday ends on that payday (hand-set or first run mid-period)', () {
      expect(nextPayday('2027-03-02', 10), '2027-03-10'); // 8 days before: was 10 Apr
      expect(nextPayday('2027-03-26', 10), '2027-04-10'); // first run 26 Mar: 15-day period
      expect(nextPayday('2027-03-20', 10), '2027-04-10');
    });

    test('known limit: a start within 7 days before the payday counts as that payday\'s early salary', () {
      // A first run (periodStart = today) on 30 Mar with payday 3 gets a period to 3 May, as 5 Mar with payday 10
      // always did (to 10 Apr).
      expect(nextPayday('2027-03-30', 3), '2027-05-03');
      expect(nextPayday('2027-03-05', 10), '2027-04-10');
    });

    test('the payday a start belongs to and the one before it', () {
      expect(paydayOf('2027-03-02', 31), '2027-02-28');
      expect(paydayOf('2027-03-08', 10), '2027-03-10');
      expect(paydayOf('2027-03-02', 10), '2027-02-10');
      expect(paydayOf('2027-03-10', 10), '2027-03-10');
      expect(previousPayday('2027-03-02', 31), '2027-01-31');
      expect(previousPayday('2027-03-08', 10), '2027-02-10');
      expect(paydayIn('2027-02', 31), '2027-02-28');
      expect(paydayIn('2027-04', 31), '2027-04-30');
      expect(paydayIn('2027-04', 10), '2027-04-10');
    });

    test('every date of two years: the period is 8..38 days and its end is an expected payday', () {
      for (final pd in [1, 3, 10, 15, 28, 29, 30, 31]) {
        for (var d = '2027-01-01'; d.compareTo('2029-01-01') < 0; d = addDays(d, 1)) {
          final end = nextPayday(d, pd);
          final len = daysBetween(d, end);
          expect(len, inInclusiveRange(8, 38), reason: '$d payday $pd → $end');
          expect(end, paydayIn(monthOf(end), pd));
          expect(nextPayday(end, pd), paydayIn(monthOf(addDays('${monthOf(end)}-01', 32)), pd));
        }
      }
    });
  });

  group('currentPeriodStart', () {
    test('from a late salary: the latest expected payday on or before today', () {
      expect(currentPeriodStart('2027-03-02', 31, '2027-03-30'), '2027-03-02');
      expect(currentPeriodStart('2027-03-02', 31, '2027-04-10'), '2027-03-31'); // was 2 Mar (no payday seen until 30 Apr)
      expect(currentPeriodStart('2027-03-02', 31, '2027-06-15'), '2027-05-31');
    });

    test('several missed paydays in one step, across the year', () {
      expect(currentPeriodStart('2026-11-12', 10, '2027-04-09'), '2027-03-10');
      expect(currentPeriodStart('2027-01-02', 31, '2027-03-01'), '2027-02-28');
    });
  });

  group('computePeriod and periodDays: the 2 Mar late salary', () {
    const st = WalletSettings(paydayDay: 31, salary: 300000, periodStart: '2027-03-02');
    final txs = _cat([_tx('2027-03-02', 300000, 'Salary'), _tx('2027-03-04', -2500, 'Groceries')]);

    test('one month: ends 31 Mar, 29 days, the flexible money spread over them', () {
      final p = computePeriod(txs, st, const [], '2027-03-05', table: _table);
      expect(p.start, '2027-03-02');
      expect(p.end, '2027-03-31');
      expect(p.length, 29);
      expect(p.daysLeft, 26);
      expect(p.paydayPassed, isFalse);
      expect(p.planDaily, (p.flexBudget / 29).round());
    });

    test('the payday passes on 31 Mar', () {
      final p = computePeriod(txs, st, const [], '2027-03-31', table: _table);
      expect(p.paydayPassed, isTrue);
      expect(p.daysLeft, 0);
    });

    test('periodDays has one day per day of [2 Mar, 31 Mar)', () {
      final days = periodDays(txs, st, const [], '2027-03-05', table: _table);
      expect(days.length, 29);
      expect(days.first.date, '2027-03-02');
      expect(days.last.date, '2027-03-30');
    });

    test('early salary: 8 Mar for payday 10 runs to 10 Apr', () {
      const s = WalletSettings(paydayDay: 10, salary: 300000, periodStart: '2027-03-08');
      final p = computePeriod(txs, s, const [], '2027-03-09', table: _table);
      expect(p.end, '2027-04-10');
      expect(p.length, 33);
    });

    test('on time: 31 Jan with payday 31 runs to 28 Feb', () {
      const s = WalletSettings(paydayDay: 31, salary: 300000, periodStart: '2027-01-31');
      final p = computePeriod(txs, s, const [], '2027-02-05', table: _table);
      expect(p.end, '2027-02-28');
      expect(p.length, 28);
    });

    test('first run on 26 Mar with payday 10 (no salary yet): to 10 Apr, 15 days', () {
      const s = WalletSettings(paydayDay: 10, salary: 300000, periodStart: '2027-03-26');
      final p = computePeriod(txs, s, const [], '2027-03-26', table: _table);
      expect(p.end, '2027-04-10');
      expect(p.length, 15);
    });

    test('known limit: first run on 30 Mar with payday 3 runs to 3 May', () {
      const s = WalletSettings(paydayDay: 3, salary: 300000, periodStart: '2027-03-30');
      final p = computePeriod(txs, s, const [], '2027-03-30', table: _table);
      expect(p.end, '2027-05-03');
      expect(p.length, 34);
    });

    test('December → January late salary', () {
      const s = WalletSettings(paydayDay: 31, salary: 300000, periodStart: '2027-01-02');
      final p = computePeriod(txs, s, const [], '2027-01-05', table: _table);
      expect(p.end, '2027-01-31');
      expect(p.length, 29);
    });
  });

  group('periodSummaries, periodReports and rangeFor: one-month periods', () {
    const st = WalletSettings(paydayDay: 31);
    final rows = [
      _tx('2026-12-31', 300000, 'Salary'),
      _tx('2027-01-31', 300000, 'Salary'),
      _tx('2027-03-02', 300000, 'Salary'), // February's salary, late
      _tx('2027-03-04', -2500, 'Groceries'),
    ];
    final txs = _cat(rows);

    test('the running period from the late salary ends on 31 Mar', () {
      expect(_periods(txs, st, '2027-03-10'), ['2026-12-31..2027-01-31', '2027-01-31..2027-03-02', '2027-03-02..2027-03-31']);
      final reports = periodReports(txs, st, '2027-03-10', table: _table);
      expect(reports.last.start, '2027-03-02');
      expect(reports.last.end, '2027-03-31');
      expect(reports.last.running, isTrue);
    });

    test('rangeFor ends the day before 31 Mar; stepping on lands on the April period', () {
      final r = rangeFor(RangeKind.payPeriod, '2027-03-10', st, txs: txs);
      expect(r, DateRange(start: '2027-03-02', end: '2027-03-30'));
      expect(shiftRange(r, RangeKind.payPeriod, 1, st, txs: txs, today: '2027-03-10'), DateRange(start: '2027-03-31', end: '2027-04-29'));
    });

    test('March salary missing on 10 Apr: the running period still holds today (late salary)', () {
      expect(_periods(txs, st, '2027-04-10').last, '2027-03-02..2027-04-11');
    });

    test('the first start a late salary: one step back is the January payday period, not a 2-day one', () {
      final only = _cat([_tx('2027-03-02', 300000, 'Salary')]);
      final r = rangeFor(RangeKind.payPeriod, '2027-03-10', st, txs: only);
      expect(r, DateRange(start: '2027-03-02', end: '2027-03-30'));
      expect(shiftRange(r, RangeKind.payPeriod, -1, st, txs: only, today: '2027-03-10'), DateRange(start: '2027-01-31', end: '2027-03-01'));
    });

    test('December → January late salary: one-month running period', () {
      final dec = _cat([_tx('2026-11-30', 300000, 'Salary'), _tx('2027-01-02', 300000, 'Salary')]);
      expect(_periods(dec, st, '2027-01-10'), ['2026-11-30..2027-01-02', '2027-01-02..2027-01-31']);
      expect(rangeFor(RangeKind.payPeriod, '2027-01-10', st, txs: dec), DateRange(start: '2027-01-02', end: '2027-01-30'));
    });
  });
}
