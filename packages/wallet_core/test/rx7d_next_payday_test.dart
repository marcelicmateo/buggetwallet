// RX7d/RX7e: `nextPayday` (dates.dart), rule C (owner-approved 2026-10-30). A period start within 7 days of an
// expected payday (clamped to the month's last day) belongs to it: late = the latest expected payday in
// [start − 7, start], else early = the expected payday in (start, start + 7]; the period then ends on the expected payday
// after it. Any other start (set by hand mid-period, a first run, a salary more than 7 days early or late) keeps the
// old rule: the payday of the month after the start's month. Before RX7d a salary a few days late across a month end
// (28 Feb payday paid 2 Mar) made a ~2-month period. RX7d's rule B ("the first expected payday more than 7 days after
// the start") cut hand-set starts short and let one salary fund two periods (7 Oct with payday 15 ended on 15 Oct).
// All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/src/dates.dart' show paydayIn, previousPayday;
import 'package:wallet_core/wallet_core.dart';

var _n = 0;

Tx _tx(String date, int cents, String category) =>
    Tx(id: 'rx7d-${_n++}', source: 'pbz', date: date, amount: cents, currency: 'EUR', description: 'Synthetic row', category: category);

final _table = CategoryTable.builtIn;

List<CategorizedTx> _cat(List<Tx> rows) => Categorizer(table: _table).expandAll(rows);

/// `[start, end)` of every `periodSummaries` period, oldest first.
List<String> _periods(List<CategorizedTx> txs, WalletSettings st, String today) =>
    [for (final p in periodSummaries(txs, st, today, count: 1000)) '${p.start}..${p.end}'];

bool _isPayday(String d, int pd) => d == paydayIn(monthOf(d), pd);

/// Rule C written another way: day by day.
String _reference(String start, int pd) {
  String? owner;
  for (var k = 0; k <= 7 && owner == null; k++) {
    if (_isPayday(addDays(start, -k), pd)) owner = addDays(start, -k);
  }
  for (var k = 1; k <= 7 && owner == null; k++) {
    if (_isPayday(addDays(start, k), pd)) owner = addDays(start, k);
  }
  if (owner == null) {
    final d = parseIso(start);
    return paydayIn(isoDate(DateTime.utc(d.year, d.month + 1, 1)).substring(0, 7), pd);
  }
  var next = addDays(owner, 1);
  while (!_isPayday(next, pd)) {
    next = addDays(next, 1);
  }
  return next;
}

void main() {
  group('nextPayday (rule C)', () {
    test('a salary late across the month end ends on the next month\'s payday, not the one after (the original bug)', () {
      expect(nextPayday('2027-03-02', 31), '2027-03-31'); // 28 Feb payday (clamped) paid 2 Mar; was 30 Apr
      expect(nextPayday('2027-03-01', 30), '2027-03-30');
      expect(nextPayday('2027-03-02', 28), '2027-03-28');
      expect(nextPayday('2027-05-03', 31), '2027-05-31'); // 30 Apr payday (30-day month) paid 3 May; was 30 Jun
    });

    test('an early salary (up to 7 days before the payday) ends on the payday after it', () {
      expect(nextPayday('2027-03-08', 10), '2027-04-10');
      expect(nextPayday('2027-03-03', 10), '2027-04-10'); // exactly 7 days early
      expect(nextPayday('2027-02-25', 31), '2027-03-31'); // 3 days before the clamped 28 Feb
      expect(nextPayday('2027-01-29', 3), '2027-03-03'); // 5 days before 3 Feb; the old rule gave 3 Feb (5 days)
    });

    test('on time or a few days late in the month', () {
      expect(nextPayday('2027-01-31', 31), '2027-02-28');
      expect(nextPayday('2027-03-10', 10), '2027-04-10');
      expect(nextPayday('2027-03-15', 15), '2027-04-15');
      expect(nextPayday('2026-10-10', 10), '2026-11-10');
      expect(nextPayday('2026-10-12', 10), '2026-11-10');
      expect(nextPayday('2026-10-17', 10), '2026-11-10'); // exactly 7 days late
    });

    test('a start more than 7 days from any expected payday keeps the old rule (month after the start\'s month)', () {
      expect(nextPayday('2026-10-01', 15), '2026-11-15'); // hand-set start (app fixtures)
      expect(nextPayday('2026-10-07', 15), '2026-11-15'); // 8 days early: one period holds the salary
      expect(nextPayday('2027-03-26', 10), '2027-04-10'); // first run 26 Mar
      expect(nextPayday('2027-01-01', 15), '2027-02-15');
      expect(nextPayday('2027-03-02', 10), '2027-04-10'); // 8 days before 10 Mar
      expect(nextPayday('2026-10-18', 10), '2026-11-10'); // 8 days late
      expect(nextPayday('2027-01-08', 31), '2027-02-28'); // 8 days after 31 Dec: old rule (7 Jan → 31 Jan)
      expect(nextPayday('2027-01-07', 31), '2027-01-31');
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
      expect(nextPayday('2027-01-05', 29), '2027-01-29'); // 29 Dec paid 5 Jan (7 days late)
    });

    test('previousPayday: the latest expected payday more than 7 days before the start', () {
      expect(previousPayday('2027-03-02', 31), '2027-01-31'); // late for 28 Feb → the one before it
      expect(previousPayday('2027-03-08', 10), '2027-02-10'); // early for 10 Mar → the one before it
      expect(previousPayday('2027-01-29', 3), '2027-01-03'); // early for 3 Feb
      expect(previousPayday('2026-10-01', 15), '2026-09-15'); // mid-period start
      expect(previousPayday('2027-03-10', 10), '2027-02-10');
      expect(previousPayday('2027-01-02', 31), '2026-11-30');
      expect(paydayIn('2027-02', 31), '2027-02-28');
      expect(paydayIn('2027-04', 31), '2027-04-30');
      expect(paydayIn('2027-04', 10), '2027-04-10');
    });

    test('every date of two years, every payday day: the rule day by day, 8..62 days, an expected payday', () {
      for (var pd = 1; pd <= 31; pd++) {
        for (var d = '2027-01-01'; d.compareTo('2029-01-01') < 0; d = addDays(d, 1)) {
          final end = nextPayday(d, pd);
          expect(end, _reference(d, pd), reason: '$d payday $pd');
          expect(daysBetween(d, end), inInclusiveRange(8, 62), reason: '$d payday $pd → $end');
          expect(_isPayday(end, pd), isTrue, reason: '$d payday $pd → $end');
          // From an expected payday the next one is the next month's.
          expect(nextPayday(end, pd), paydayIn(monthOf(addDays('${monthOf(end)}-01', 32)), pd));
          // Stepping back: an expected payday more than 7 days before, and the period before has no payday inside.
          final prev = previousPayday(d, pd);
          expect(_isPayday(prev, pd), isTrue);
          expect(daysBetween(prev, d), greaterThan(7), reason: '$d payday $pd → $prev');
          expect(_isPayday(previousPayday(end, pd), pd) && nextPayday(previousPayday(end, pd), pd) == end, isTrue);
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
      expect(currentPeriodStart('2026-10-01', 15, '2027-01-20'), '2027-01-15');
    });

    test('a hand-set or 8-days-early start: no new period on the payday inside it', () {
      expect(currentPeriodStart('2026-10-01', 15, '2026-10-20'), '2026-10-01');
      expect(currentPeriodStart('2026-10-07', 15, '2026-10-15'), '2026-10-07');
      expect(currentPeriodStart('2026-10-07', 15, '2026-11-15'), '2026-11-15');
    });

    test('every start of a year and today up to 100 days later: in the period, an expected payday once moved', () {
      for (final pd in [1, 10, 15, 28, 31]) {
        for (var s = '2027-01-01'; s.compareTo('2028-01-01') < 0; s = addDays(s, 1)) {
          for (var k = 0; k <= 100; k += 7) {
            final today = addDays(s, k);
            final c = currentPeriodStart(s, pd, today);
            expect(c.compareTo(today) <= 0 && nextPayday(c, pd).compareTo(today) > 0, isTrue, reason: '$s $pd $today → $c');
            expect(c == s || _isPayday(c, pd), isTrue, reason: '$s $pd $today → $c');
          }
        }
      }
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

    test('early salary: 29 Jan for payday 3 runs to 3 Mar (the old rule gave 5 days)', () {
      const s = WalletSettings(paydayDay: 3, salary: 300000, periodStart: '2027-01-29');
      final p = computePeriod(txs, s, const [], '2027-01-30', table: _table);
      expect(p.end, '2027-03-03');
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

    test('a start 4 days before payday 3 belongs to it: 30 Mar runs to 3 May (its salary lands inside)', () {
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

    test('a salary 8 days early (7 Oct, payday 15) funds one period: still running on 15 Oct, ends 15 Nov', () {
      const s = WalletSettings(paydayDay: 15, salary: 300000, periodStart: '2026-10-07');
      final early = _cat([_tx('2026-10-07', 300000, 'Salary'), _tx('2026-10-12', -2500, 'Groceries')]);
      final p = computePeriod(early, s, const [], '2026-10-15', table: _table);
      expect((p.start, p.end, p.paydayPassed, p.received), ('2026-10-07', '2026-11-15', false, 300000));
      expect(currentPeriodStart('2026-10-07', 15, '2026-10-15'), '2026-10-07'); // no "start new period" yet
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

  group('a saved periodStart: the report\'s running period is computePeriod\'s', () {
    test('insightsWallet: start 1 Oct, payday 15, salary 10 Oct, today 20 Oct → both 1 Oct–15 Nov, running', () {
      const st = WalletSettings(paydayDay: 15, salary: 300000, periodStart: '2026-10-01');
      final txs = _cat([
        _tx('2026-09-15', 300000, 'Salary'),
        _tx('2026-09-20', -1500, 'Groceries'),
        _tx('2026-10-03', -2500, 'Groceries'),
        _tx('2026-10-10', 300000, 'Salary'),
        _tx('2026-10-18', -3500, 'Groceries'),
      ]);
      const today = '2026-10-20';
      final p = computePeriod(txs, st, const [], today, table: _table);
      expect((p.start, p.end, p.paydayPassed), ('2026-10-01', '2026-11-15', false));
      final last = periodReports(txs, st, today, table: _table).last;
      expect((last.start, last.end, last.running), ('2026-10-01', '2026-11-15', true));
      expect(last.income, 300000);
      expect(rangeFor(RangeKind.payPeriod, today, st, txs: txs), DateRange(start: '2026-10-01', end: '2026-11-14'));
    });

    test('a salary on or after computePeriod\'s payday is the next period\'s start, not replaced by the saved start', () {
      // 25 Sep with payday 10 is mid-period (old rule): computePeriod = [25 Sep, 10 Oct); the 10 Oct salary is next.
      const st = WalletSettings(paydayDay: 10, periodStart: '2026-09-25');
      final txs = _cat([_tx('2026-09-10', 300000, 'Salary'), _tx('2026-10-10', 300000, 'Salary')]);
      const today = '2026-10-20';
      expect(computePeriod(txs, st, const [], today, table: _table).end, '2026-10-10');
      expect(_periods(txs, st, today), ['2026-09-10..2026-10-10', '2026-10-10..2026-11-10']);
    });

    test('the payday passed without a salary: extended to today + 1', () {
      const st = WalletSettings(paydayDay: 15, periodStart: '2026-10-01');
      final txs = _cat([_tx('2026-09-15', 300000, 'Salary'), _tx('2026-10-10', 300000, 'Salary')]);
      expect(_periods(txs, st, '2026-11-18').last, '2026-10-01..2026-11-19');
      // With the November salary on its payday it starts the next period.
      final paid = _cat([_tx('2026-09-15', 300000, 'Salary'), _tx('2026-10-10', 300000, 'Salary'), _tx('2026-11-15', 300000, 'Salary')]);
      expect(_periods(paid, st, '2026-11-18').sublist(1), ['2026-10-01..2026-11-15', '2026-11-15..2026-12-15']);
    });

    test('every saved start of a year, salary 0..20 days after it inside the period: the running period is [ps, end)', () {
      for (final pd in [10, 15, 31]) {
        for (var ps = '2027-01-01'; ps.compareTo('2028-01-01') < 0; ps = addDays(ps, 1)) {
          final end = nextPayday(ps, pd);
          final st = WalletSettings(paydayDay: pd, periodStart: ps);
          for (final k in [0, 3, 9, 20]) {
            final s = addDays(ps, k);
            if (s.compareTo(end) >= 0) continue;
            final txs = _cat([_tx(addDays(ps, -35), 300000, 'Salary'), _tx(s, 300000, 'Salary')]);
            for (final today in {s, addDays(end, -1)}) {
              final p = computePeriod(txs, st, const [], today, table: _table);
              final last = periodSummaries(txs, st, today).last;
              expect((last.start, last.end, last.running), (p.start, p.end, true), reason: 'ps $ps payday $pd salary $s today $today');
              expect(p.paydayPassed, isFalse);
            }
          }
        }
      }
    });
  });
}
