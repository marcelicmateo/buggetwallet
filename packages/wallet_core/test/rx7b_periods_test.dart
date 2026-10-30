// RX7b: one definition of the pay periods for the report. Every row, review and skipped wish belongs to exactly one
// period; the running period holds today (a late salary keeps it running); Σ periodDaySpend over the days up to today
// equals each period's flex; a saved periodStart up to 20 days before the period's salary starts the running period
// where computePeriod's does. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _n = 0;

Tx _tx(String date, int cents, String category, {String currency = 'EUR', bool deleted = false}) => Tx(
    id: 'rx7b-${_n++}',
    source: 'pbz',
    date: date,
    amount: cents,
    currency: currency,
    description: 'Synthetic row',
    category: category,
    deleted: deleted);

final _table = CategoryTable.builtIn;
List<CategorizedTx> _cat(List<Tx> rows) => Categorizer(table: _table).expandAll(rows);

String _min(String a, String b) => a.compareTo(b) <= 0 ? a : b;
int _utc(String iso) => parseIso(iso).millisecondsSinceEpoch;

/// The identities every report list must keep (see the file header).
void _checkIdentities(List<CategorizedTx> txs, WalletSettings st, String today) {
  final reports = periodReports(txs, st, today, table: _table);
  expect(reports, isNotEmpty);
  // Contiguous, half-open, the last one running and holding today.
  for (var i = 0; i + 1 < reports.length; i++) {
    expect(reports[i].end, reports[i + 1].start, reason: 'gap after ${reports[i].start}');
    expect(reports[i].running, isFalse);
    expect(reports[i].start.compareTo(reports[i].end), lessThan(0));
  }
  final run = reports.last;
  expect(run.running, isTrue);
  expect(run.start.compareTo(today), lessThanOrEqualTo(0));
  expect(run.end.compareTo(today), greaterThan(0), reason: 'the running period must hold today');
  // Σ heatmap == flex, for past and running periods.
  final tomorrow = addDays(today, 1);
  for (final r in reports) {
    final days = periodDaySpend(txs, st, r.start, _min(r.end, tomorrow), table: _table);
    expect(days.fold<int>(0, (s, d) => s + d.spent), r.flex, reason: '${r.start}..${r.end}');
  }
  // Every counted row (home currency, live, from the first start up to today) is in exactly one period, and the
  // period sums add up to the rows' sums.
  var income = 0, out = 0;
  for (final t in txs) {
    if (!t.tx.live || t.tx.currency != st.currency) continue;
    if (t.date.compareTo(reports.first.start) < 0 || t.date.compareTo(today) > 0) continue;
    final holders = reports.where((r) => t.date.compareTo(r.start) >= 0 && t.date.compareTo(r.end) < 0);
    expect(holders.length, 1, reason: 'row ${t.date}');
    switch (t.kind) {
      case BudgetKind.income || BudgetKind.extra:
        income += t.amount;
      case BudgetKind.fixed || BudgetKind.flex:
        out -= t.amount;
      case BudgetKind.transfer:
        break;
    }
  }
  expect(reports.fold<int>(0, (s, r) => s + r.income), income);
  expect(reports.fold<int>(0, (s, r) => s + r.out), out);
}

void main() {
  group('late salary', () {
    // paydayDay 10; the owner started the September period on the 10th, the salary landed on the 12th; it is
    // 13 Oct and the October salary is not in (detectPaydays assumes none within 45 days).
    const st = WalletSettings(paydayDay: 10, periodStart: '2026-09-10');
    const today = '2026-10-13';
    final rows = [
      _tx('2026-08-10', 200000, 'Salary'),
      _tx('2026-08-20', -5000, 'Groceries'),
      _tx('2026-09-09', -1000, 'Groceries'), // the August period's last day
      _tx('2026-09-10', -2000, 'Groceries'), // Today's period: in the running report
      _tx('2026-09-11', -3000, 'Groceries'),
      _tx('2026-09-12', 200000, 'Salary'),
      _tx('2026-09-13', -60000, 'Rent'),
      _tx('2026-10-09', -4000, 'Groceries'),
      _tx('2026-10-10', -5000, 'Groceries'), // past the expected payday: still the running period
      _tx('2026-10-13', -6000, 'Groceries'), // today
      _tx('2026-10-14', -7000, 'Groceries'), // after today: in no total yet
    ];
    final txs = _cat(rows);
    final reports = periodReports(txs, st, today, table: _table);

    test('the running period starts with Today\'s period and runs until tomorrow', () {
      expect(
          [for (final r in reports) '${r.start}..${r.end}:${r.running}'], ['2026-08-10..2026-09-10:false', '2026-09-10..2026-10-14:true']);
      expect(reports.last.start, computePeriod(txs, st, const [], today, table: _table).start);
    });

    test('rows of 10–13 Oct are in the running flex; the August period ends the day before the saved start', () {
      expect((reports.first.income, reports.first.flex, reports.first.fixed), (200000, 6000, 0));
      expect((reports.last.income, reports.last.flex, reports.last.fixed), (200000, 2000 + 3000 + 4000 + 5000 + 6000, 60000));
    });

    test('Σ heatmap == flex, every row in one period', () => _checkIdentities(txs, st, today));

    test('a review or skipped wish dated 11–13 Oct lands in the running period, the boundary day in one only', () {
      final reviews = ['2026-09-09', '2026-09-10', '2026-10-11', '2026-10-13'];
      expect([
        for (final r in reports) reviewsIn(reviews, r.start, r.end)
      ], [
        ['2026-09-09'],
        ['2026-09-10', '2026-10-11', '2026-10-13'],
      ]);
      final wishes = [
        for (final d in ['2026-09-10', '2026-10-12'])
          WishItem(id: d, name: 'Synthetic', price: 1000, added: 0, status: 'skipped', decided: _utc(d)),
      ];
      final counts = [for (final r in reports) savedByWaiting(wishes, fromMillis: _utc(r.start), toMillis: _utc(r.end)).count];
      expect(counts, [0, 2]);
    });

    test('without the saved start the running period starts on the salary and still holds today', () {
      const raw = WalletSettings(paydayDay: 10);
      final r = periodReports(txs, raw, today, table: _table);
      expect([for (final p in r) '${p.start}..${p.end}'], ['2026-08-10..2026-09-12', '2026-09-12..2026-10-14']);
      _checkIdentities(txs, raw, today);
    });

    test('once the October salary lands, the running period ends there and the next one starts', () {
      final more = _cat([...rows, _tx('2026-10-15', 200000, 'Salary')]);
      final r = periodReports(more, st, '2026-10-16', table: _table);
      expect([for (final p in r) '${p.start}..${p.end}:${p.running}'],
          ['2026-08-10..2026-09-10:false', '2026-09-10..2026-10-15:false', '2026-10-15..2026-11-10:true']);
      _checkIdentities(more, st, '2026-10-16');
    });
  });

  group('saved periodStart before the period\'s first salary row', () {
    // The owner started the period on the expected payday (10 Oct); the salary landed on the 12th.
    const st = WalletSettings(paydayDay: 10, periodStart: '2026-10-10');
    const today = '2026-10-20';
    final txs = _cat([
      _tx('2026-09-10', 200000, 'Salary'),
      _tx('2026-09-20', -8000, 'Groceries'),
      _tx('2026-10-09', -1000, 'Groceries'),
      _tx('2026-10-10', -2000, 'Groceries'),
      _tx('2026-10-11', -3000, 'Shopping'),
      _tx('2026-10-12', 200000, 'Salary'),
      _tx('2026-10-15', -4000, 'Groceries'),
    ]);

    test('the report starts with the chip (computePeriod) and 10–11 Oct are in it', () {
      final r = periodReports(txs, st, today, table: _table);
      expect([for (final p in r) '${p.start}..${p.end}'], ['2026-09-10..2026-10-10', '2026-10-10..2026-11-10']);
      expect(r.last.start, computePeriod(txs, st, const [], today, table: _table).start);
      expect((r.first.flex, r.last.flex, r.last.income), (9000, 9000, 200000));
      _checkIdentities(txs, st, today);
    });

    test('periodSummaries and categoryByPeriod use the same periods', () {
      final s = periodSummaries(txs, st, today);
      final c = categoryByPeriod('Groceries', txs, st, today, table: _table);
      expect([for (final p in s) p.start], ['2026-09-10', '2026-10-10']);
      expect([for (final p in c) (p.start, p.end, p.spent)], [('2026-09-10', '2026-10-10', 9000), ('2026-10-10', '2026-11-10', 6000)]);
    });

    test('a saved start more than 20 days before the salary, or after it, leaves the detected paydays', () {
      // 21 days before: a period of its own (detectPaydays does not group it), so it is not moved.
      const early = WalletSettings(paydayDay: 10, periodStart: '2026-09-21');
      expect([for (final p in periodSummaries(txs, early, today)) p.start], ['2026-09-10', '2026-10-12']);
      // After the salary: not used (it would move the salary row into the period before).
      const after = WalletSettings(paydayDay: 10, periodStart: '2026-10-14');
      expect([for (final p in periodSummaries(txs, after, today)) p.start], ['2026-09-10', '2026-10-12']);
      _checkIdentities(txs, early, today);
      _checkIdentities(txs, after, today);
    });

    test('a saved start of an older period starts that period (Today still names it), nothing else moves', () {
      // Saved 2 days before the September salary; October's salary has landed since (Today offers a new month).
      const old = WalletSettings(paydayDay: 10, periodStart: '2026-09-08');
      final r = periodReports(txs, old, today, table: _table);
      expect([for (final p in r) '${p.start}..${p.end}'], ['2026-09-08..2026-10-12', '2026-10-12..2026-11-10']);
      expect(r.first.start, computePeriod(txs, old, const [], today, table: _table).start);
      expect((r.first.flex, r.last.flex), (8000 + 1000 + 2000 + 3000, 4000));
      _checkIdentities(txs, old, today);
    });

    test('a saved start in the future is ignored', () {
      const future = WalletSettings(paydayDay: 10, periodStart: '2026-10-05');
      expect([for (final p in periodSummaries(txs, future, '2026-10-04')) p.start], ['2026-09-10']);
    });
  });

  group('payday on the 29–31 clamp', () {
    // paydayDay 31: the expected payday after 31 Jan is 28 Feb (clamped); the salary is late (2 Mar).
    const st = WalletSettings(paydayDay: 31);
    final rows = [
      _tx('2027-01-31', 200000, 'Salary'),
      _tx('2027-02-10', -3000, 'Groceries'),
      _tx('2027-02-28', -4000, 'Groceries'),
      _tx('2027-03-01', -5000, 'Groceries'),
    ];

    test('before the late salary: running until tomorrow, past the clamped payday', () {
      final txs = _cat(rows);
      final r = periodReports(txs, st, '2027-03-01', table: _table);
      expect([for (final p in r) '${p.start}..${p.end}'], ['2027-01-31..2027-03-02']);
      expect(r.single.flex, 12000);
      _checkIdentities(txs, st, '2027-03-01');
    });

    test('on the clamped payday itself the period still runs to 28 Feb + 1 day', () {
      final txs = _cat(rows);
      final r = periodReports(txs, st, '2027-02-27', table: _table);
      expect([for (final p in r) '${p.start}..${p.end}'], ['2027-01-31..2027-02-28']);
      final r2 = periodReports(txs, st, '2027-02-28', table: _table);
      expect([for (final p in r2) '${p.start}..${p.end}'], ['2027-01-31..2027-03-01']);
      _checkIdentities(txs, st, '2027-02-28');
    });

    test('a saved start on the clamped payday starts the running period there', () {
      const saved = WalletSettings(paydayDay: 31, periodStart: '2027-02-28');
      final txs = _cat([...rows, _tx('2027-03-02', 200000, 'Salary'), _tx('2027-03-03', -1000, 'Groceries')]);
      final r = periodReports(txs, saved, '2027-03-05', table: _table);
      expect([for (final p in r) '${p.start}..${p.end}'], ['2027-01-31..2027-02-28', '2027-02-28..2027-03-31']);
      expect(r.last.start, computePeriod(txs, saved, const [], '2027-03-05', table: _table).start);
      expect((r.first.flex, r.last.flex, r.last.income), (3000, 4000 + 5000 + 1000, 200000));
      _checkIdentities(txs, saved, '2027-03-05');
    });
  });

  group('past periods unchanged on the P8 fixture', () {
    // The P8 rows (p8_reports_test.dart) without the split: salary on the 15th, no saved start.
    const st = WalletSettings();
    const today = '2026-10-20';
    final txs = _cat([
      _tx('2026-08-15', 200000, 'Salary'),
      _tx('2026-08-16', -60000, 'Rent'),
      _tx('2026-08-20', -12000, 'Groceries'),
      _tx('2026-08-25', 1000, 'Groceries'),
      _tx('2026-09-01', 5000, 'Extra income'),
      _tx('2026-09-15', 200000, 'Salary'),
      _tx('2026-09-16', -60000, 'Rent'),
      _tx('2026-09-18', -35000, 'Groceries'),
      _tx('2026-09-19', -20000, 'Internal transfer'),
      _tx('2026-09-20', -10000, 'Shopping', currency: 'USD'),
      _tx('2026-09-21', -9999, 'Groceries', deleted: true),
      _tx('2026-10-15', 200000, 'Salary'),
      _tx('2026-10-16', -4000, 'Groceries'),
      _tx('2026-10-21', -7000, 'Groceries'),
    ]);

    test('the same periods and totals as the detected paydays give, with or without a matching saved start', () {
      String v(PeriodReport r) => '${r.start} ${r.end} ${r.running} ${r.income} ${r.fixed} ${r.flex}';
      const want = [
        '2026-08-15 2026-09-15 false 205000 60000 11000',
        '2026-09-15 2026-10-15 false 200000 60000 35000',
        '2026-10-15 2026-11-15 true 200000 0 4000',
      ];
      expect([for (final r in periodReports(txs, st, today, table: _table)) v(r)], want);
      // A saved start on the salary day (the usual "Start new month") changes nothing.
      expect([for (final r in periodReports(txs, const WalletSettings(periodStart: '2026-10-15'), today, table: _table)) v(r)], want);
      expect(detectPaydays(txs, st, today), ['2026-08-15', '2026-09-15', '2026-10-15']);
      _checkIdentities(txs, st, today);
    });

    test('a saved start two days before the last salary moves only the last boundary', () {
      const saved = WalletSettings(periodStart: '2026-10-13');
      final r = periodReports(txs, saved, today, table: _table);
      expect([for (final p in r) p.start], ['2026-08-15', '2026-09-15', '2026-10-13']);
      expect((r[0].income, r[0].out), (205000, 71000)); // the first past period is untouched
      expect(r[1].end, '2026-10-13');
      _checkIdentities(txs, saved, today);
    });
  });
}
