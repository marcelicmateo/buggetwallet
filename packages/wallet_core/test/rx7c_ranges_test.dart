// RX7c: Insights' pay-period ranges (`rangeFor(payPeriod)`, `shiftRange`) use exactly the periods of `periodSummaries`
// (one rule, `payPeriodStarts` + `runningPeriodEnd` in periods.dart): every range is `[start, end − 1]` of its period,
// the running one never ends before today, and stepping back/forward walks the same list. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _n = 0;

Tx _tx(String date, int cents, String category, {String currency = 'EUR'}) =>
    Tx(id: 'rx7c-${_n++}', source: 'pbz', date: date, amount: cents, currency: currency, description: 'Synthetic row', category: category);

List<CategorizedTx> _cat(List<Tx> rows) => Categorizer(table: CategoryTable.builtIn).expandAll(rows);

/// The inclusive ranges of `periodSummaries` (all of them), oldest first.
List<DateRange> _expected(List<CategorizedTx> txs, WalletSettings st, String today) => [
      for (final p in periodSummaries(txs, st, today, count: 1000)) DateRange(start: p.start, end: addDays(p.end, -1)),
    ];

DateRange _shift(DateRange r, int steps, List<CategorizedTx> txs, WalletSettings st, String today) =>
    shiftRange(r, RangeKind.payPeriod, steps, st, txs: txs, today: today);

/// rangeFor == the running period; one step at a time back to the first period and forward again; k steps at once
/// land on the same period; one step before the first period ends the day before it starts (contiguous).
void _checkWalk(List<CategorizedTx> txs, WalletSettings st, String today) {
  final want = _expected(txs, st, today);
  expect(want, isNotEmpty);
  final last = want.length - 1;
  final running = rangeFor(RangeKind.payPeriod, today, st, txs: txs);
  expect(running, want.last);
  expect(running.contains(today), isTrue, reason: 'the running range holds today');

  var r = running;
  for (var i = last - 1; i >= 0; i--) {
    r = _shift(r, -1, txs, st, today);
    expect(r, want[i], reason: 'back to period $i');
  }
  for (var i = 1; i <= last; i++) {
    r = _shift(r, 1, txs, st, today);
    expect(r, want[i], reason: 'forward to period $i');
  }
  for (var k = 1; k <= last; k++) {
    expect(_shift(running, -k, txs, st, today), want[last - k], reason: '$k steps back at once');
    expect(_shift(want[last - k], k, txs, st, today), want.last, reason: '$k steps forward at once');
  }
  final before = _shift(want.first, -1, txs, st, today);
  expect(before.end, addDays(want.first.start, -1));
}

void main() {
  group('late salary (saved start on the expected payday, no October salary yet)', () {
    const st = WalletSettings(paydayDay: 10, periodStart: '2026-09-10');
    const today = '2026-10-13';
    final txs = _cat([
      _tx('2026-07-10', 200000, 'Salary'),
      _tx('2026-08-10', 200000, 'Salary'),
      _tx('2026-08-20', -5000, 'Groceries'),
      _tx('2026-09-12', 200000, 'Salary'), // two days late: the saved start (10 Sep) starts the period
      _tx('2026-10-09', -4000, 'Groceries'),
    ]);

    test('the running range starts on the saved start and runs to today, as the report', () {
      expect(rangeFor(RangeKind.payPeriod, today, st, txs: txs), DateRange(start: '2026-09-10', end: today));
      expect(_expected(txs, st, today).map((r) => '$r'),
          ['DateRange(2026-07-10..2026-08-09)', 'DateRange(2026-08-10..2026-09-09)', 'DateRange(2026-09-10..2026-10-13)']);
    });

    test('walks the same list', () => _checkWalk(txs, st, today));

    test('a step forward from the late running period would start on the next expected payday after today (refused)', () {
      final running = rangeFor(RangeKind.payPeriod, '2026-10-11', st, txs: txs);
      expect(running, DateRange(start: '2026-09-10', end: '2026-10-11'));
      expect(() => _shift(running, 1, txs, st, '2026-10-11'), throwsArgumentError); // 10 Nov: after this month
    });

    test('once the salary lands the running period ends there and the next starts on it', () {
      const later = '2026-10-15';
      final more = _cat([
        _tx('2026-07-10', 200000, 'Salary'),
        _tx('2026-08-10', 200000, 'Salary'),
        _tx('2026-09-12', 200000, 'Salary'),
        _tx('2026-10-14', 200000, 'Salary'),
      ]);
      expect(rangeFor(RangeKind.payPeriod, later, st, txs: more), DateRange(start: '2026-10-14', end: '2026-11-09'));
      expect(_shift(rangeFor(RangeKind.payPeriod, later, st, txs: more), -1, more, st, later),
          DateRange(start: '2026-09-10', end: '2026-10-13'));
      _checkWalk(more, st, later);
    });
  });

  group('saved periodStart before the salary of the running period', () {
    const st = WalletSettings(paydayDay: 10, periodStart: '2026-10-10');
    const today = '2026-10-20';
    final txs = _cat([
      _tx('2026-08-11', 200000, 'Salary'),
      _tx('2026-09-10', 200000, 'Salary'),
      _tx('2026-10-12', 200000, 'Salary'),
      _tx('2026-10-15', -4000, 'Groceries'),
    ]);

    test('the range starts on the saved start, not on the salary (the old rule started on 12 Oct)', () {
      expect(rangeFor(RangeKind.payPeriod, today, st, txs: txs), DateRange(start: '2026-10-10', end: '2026-11-09'));
      expect(_shift(rangeFor(RangeKind.payPeriod, today, st, txs: txs), -1, txs, st, today),
          DateRange(start: '2026-09-10', end: '2026-10-09'));
    });

    test('walks the same list', () => _checkWalk(txs, st, today));

    test('a saved start more than 20 days before the salary or after it changes nothing', () {
      for (final ps in ['2026-09-21', '2026-10-13']) {
        final s = WalletSettings(paydayDay: 10, periodStart: ps);
        expect(rangeFor(RangeKind.payPeriod, today, s, txs: txs).start, '2026-10-12');
        _checkWalk(txs, s, today);
      }
    });

    test('a saved start in the future is ignored', () {
      const s = WalletSettings(paydayDay: 10, periodStart: '2026-10-25');
      expect(rangeFor(RangeKind.payPeriod, today, s, txs: txs).start, '2026-10-12');
      _checkWalk(txs, s, today);
    });
  });

  group('payday on the 29–31 clamp', () {
    const st = WalletSettings(paydayDay: 31);
    final rows = [
      _tx('2026-11-30', 200000, 'Salary'),
      _tx('2026-12-31', 200000, 'Salary'),
      _tx('2027-01-31', 200000, 'Salary'),
      _tx('2027-02-10', -3000, 'Groceries'),
    ];
    final txs = _cat(rows);

    test('before the clamped payday: running to the day before 28 Feb', () {
      expect(rangeFor(RangeKind.payPeriod, '2027-02-20', st, txs: txs), DateRange(start: '2027-01-31', end: '2027-02-27'));
      _checkWalk(txs, st, '2027-02-20');
    });

    test('on the clamped payday and after it, salary late: the running range ends today', () {
      for (final today in ['2027-02-28', '2027-03-01', '2027-03-05']) {
        expect(rangeFor(RangeKind.payPeriod, today, st, txs: txs), DateRange(start: '2027-01-31', end: today));
        _checkWalk(txs, st, today);
      }
    });

    test('the salary lands on 2 Mar: the late period ends on 1 Mar; the new one runs to the day before the March payday', () {
      // RX7d: 2 Mar is February's (28 Feb) salary, late, so nextPayday = 31 Mar (was 30 Apr), as periodSummaries and
      // computePeriod use.
      final more = _cat([...rows, _tx('2027-03-02', 200000, 'Salary')]);
      expect(rangeFor(RangeKind.payPeriod, '2027-03-05', st, txs: more), DateRange(start: '2027-03-02', end: '2027-03-30'));
      _checkWalk(more, st, '2027-03-05');
    });
  });

  group('no salary rows', () {
    final txs = _cat([_tx('2026-09-15', -3000, 'Groceries'), _tx('2026-10-15', -4000, 'Groceries')]);

    test('a saved start and assumed paydays after 45 days: the periods of periodSummaries', () {
      const st = WalletSettings(paydayDay: 5, periodStart: '2026-08-05');
      const today = '2026-10-20';
      expect(_expected(txs, st, today).map((r) => '$r'),
          ['DateRange(2026-08-05..2026-09-04)', 'DateRange(2026-09-05..2026-10-04)', 'DateRange(2026-10-05..2026-11-04)']);
      _checkWalk(txs, st, today);
    });

    test('nothing saved: no periodSummaries; the range is the latest expected payday on or before today', () {
      const st = WalletSettings(paydayDay: 25);
      expect(periodSummaries(txs, st, '2026-10-20'), isEmpty);
      final r = rangeFor(RangeKind.payPeriod, '2026-10-20', st, txs: txs);
      expect(r, DateRange(start: '2026-09-25', end: '2026-10-24'));
      expect(_shift(r, -1, txs, st, '2026-10-20'), DateRange(start: '2026-08-25', end: '2026-09-24'));
    });
  });

  test('foreign-currency salary and the expanded or whole list give the same ranges as the report', () {
    const st = WalletSettings(paydayDay: 15);
    const today = '2026-10-20';
    final rows = [
      _tx('2026-08-15', 200000, 'Salary'),
      _tx('2026-09-01', 50000, 'Salary', currency: 'USD'),
      _tx('2026-09-16', 200000, 'Salary'),
      _tx('2026-10-15', 200000, 'Salary'),
    ];
    _checkWalk(_cat(rows), st, today);
    final cz = Categorizer(table: CategoryTable.builtIn);
    final whole = [for (final t in rows) cz.categorize(t)];
    expect(rangeFor(RangeKind.payPeriod, today, st, txs: whole), rangeFor(RangeKind.payPeriod, today, st, txs: _cat(rows)));
  });
}
