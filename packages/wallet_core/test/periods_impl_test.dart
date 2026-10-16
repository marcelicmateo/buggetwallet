// Implementation tests for pay periods (periods.dart). All data here is synthetic.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

var _seq = 0;

/// A categorized transaction with an explicit kind.
CategorizedTx tx(String date, int cents, Kind kind, {String? category, bool deleted = false}) => CategorizedTx(
      Tx(id: 't${_seq++}', source: 'pbz', date: date, amount: cents, deleted: deleted),
      category ?? switch (kind) { Kind.income => 'Salary', Kind.extra => 'Extra income', Kind.fixed => 'Rent', Kind.flex => 'Groceries', Kind.transfer => 'Internal transfer' },
      kind,
    );

List<CategorizedTx> fromBatch(ImportBatch b) {
  final cz = Categorizer();
  return [
    for (final t in b.transactions)
      cz.categorize(Tx(id: t.id, source: t.source, date: t.date, amount: t.amountMinor, bankType: t.bankType, description: t.description)),
  ];
}

const st = WalletSettings(paydayDay: 15);

void main() {
  group('paydays', () {
    test('salary parts within 20 days are one payday', () {
      final txs = [
        tx('2026-01-10', 50000, Kind.income),
        tx('2026-01-14', 40000, Kind.income),
        tx('2026-01-30', 10000, Kind.income), // 20 days after the 10th: same payday
        tx('2026-02-11', 90000, Kind.income),
      ];
      expect(detectPaydays(txs, st, '2026-02-20'), ['2026-01-10', '2026-02-11']);
    });

    test('ignores deleted salary, future salary and transfers', () {
      final txs = [
        tx('2026-01-12', 90000, Kind.income),
        tx('2026-02-12', 90000, Kind.income, deleted: true),
        tx('2026-02-13', 90000, Kind.transfer),
        tx('2026-03-12', 90000, Kind.income), // after today
      ];
      expect(detectPaydays(txs, st, '2026-03-01'), ['2026-01-12', '2026-02-15']);
    });

    test('missing salary: paydays assumed on paydayDay until the next real one', () {
      final txs = [tx('2026-01-12', 90000, Kind.income), tx('2026-04-13', 90000, Kind.income)];
      expect(detectPaydays(txs, st, '2026-04-20'), ['2026-01-12', '2026-02-15', '2026-03-15', '2026-04-13']);
    });

    test('missing salary at the end: assumed until today, clamped to month end', () {
      final txs = [tx('2026-01-12', 90000, Kind.income)];
      expect(detectPaydays(txs, const WalletSettings(paydayDay: 31), '2026-03-31'), ['2026-01-12', '2026-02-28', '2026-03-31']);
      // 45 days or fewer: nothing assumed yet
      expect(detectPaydays(txs, st, '2026-02-26'), ['2026-01-12']);
      expect(detectPaydays(txs, st, '2026-02-27'), ['2026-01-12', '2026-02-15']);
    });

    test('hand-set period start counts when more than 20 days after the last payday', () {
      final txs = [tx('2026-01-12', 90000, Kind.income)];
      expect(detectPaydays(txs, const WalletSettings(periodStart: '2026-02-10'), '2026-02-20'), ['2026-01-12', '2026-02-10']);
      expect(detectPaydays(txs, const WalletSettings(periodStart: '2026-01-25'), '2026-02-20'), ['2026-01-12']);
      expect(detectPaydays(txs, const WalletSettings(periodStart: '2026-02-25'), '2026-02-20'), ['2026-01-12']); // after today
      expect(detectPaydays(const [], const WalletSettings(periodStart: '2026-02-10'), '2026-02-20'), ['2026-02-10']);
    });
  });

  group('periodSummaries', () {
    test('no paydays and no period start: empty', () {
      expect(periodSummaries([tx('2026-01-05', -1000, Kind.flex)], st, '2026-01-20'), isEmpty);
    });

    test('sums per period, running last, transfers and later rows ignored', () {
      final txs = [
        tx('2026-01-05', -999, Kind.flex), // before the first payday
        tx('2026-01-12', 100000, Kind.income),
        tx('2026-01-13', -40000, Kind.fixed, category: 'Rent'),
        tx('2026-01-20', -2500, Kind.flex, category: 'Groceries'),
        tx('2026-01-21', 500, Kind.flex, category: 'Groceries'), // refund
        tx('2026-01-22', -20000, Kind.transfer),
        tx('2026-02-01', 3000, Kind.extra),
        tx('2026-02-11', 100000, Kind.income),
        tx('2026-02-12', -150000, Kind.flex, category: 'Shopping'),
        tx('2026-02-12', -7777, Kind.flex, deleted: true),
        tx('2026-02-25', -1000, Kind.flex), // after today
      ];
      final ps = periodSummaries(txs, st, '2026-02-20');
      expect(ps.length, 2);
      final a = ps[0], b = ps[1];
      expect([a.start, a.end, a.running], ['2026-01-12', '2026-02-11', false]);
      expect([a.income, a.out, a.net], [103000, 42000, 61000]);
      expect(a.byCategory, {'Rent': 40000, 'Groceries': 2000});
      expect(a.savingsRate, closeTo(61000 / 103000, 1e-9));
      expect([b.start, b.end, b.running], ['2026-02-11', '2026-03-15', true]);
      expect([b.income, b.out, b.net], [100000, 150000, -50000]);
      expect(b.savingsRate, closeTo(-0.5, 1e-9));
    });

    test('savings rate is null without income', () {
      final ps = periodSummaries([tx('2026-01-15', -1000, Kind.flex)], const WalletSettings(periodStart: '2026-01-10'), '2026-01-20');
      expect(ps.single.income, 0);
      expect(ps.single.savingsRate, isNull);
    });

    test('keeps the last [count] periods', () {
      final txs = [for (var m = 1; m <= 9; m++) tx('2026-0$m-12', 100000, Kind.income)];
      final ps = periodSummaries(txs, st, '2026-09-20', count: 4);
      expect(ps.map((p) => p.start), ['2026-06-12', '2026-07-12', '2026-08-12', '2026-09-12']);
      expect(ps.last.running, isTrue);
      expect(ps.where((p) => p.running).length, 1);
    });

    test('works on imported synthetic data', () {
      final ps = periodSummaries(fromBatch(january), st, '2026-01-31');
      expect(ps.single.start, '2026-01-15');
      expect(ps.single.income, 180000); // salary + tax refund
      expect(ps.single.out, 55000 + 2340 + 25000 + 33); // ATM (rent), Lidl, loan, fee; Revolut top-up is a transfer
    });
  });

  group('trendNet', () {
    PeriodSummary p(int net, {bool running = false}) =>
        PeriodSummary(start: '2026-01-01', end: '2026-02-01', income: net > 0 ? net : 0, out: net > 0 ? 0 : -net, byCategory: const {}, running: running);

    test('rolling average over completed periods, null for running', () {
      final ps = [p(100), p(200), p(-100), p(401), p(50, running: true)];
      expect(trendNet(ps), [null, null, 67, 167, null]);
      expect(trendNet(ps, window: 1), [100, 200, -100, 401, null]);
      expect(trendNet(const []), isEmpty);
    });
  });

  group('savingsOverview', () {
    test('completed periods only', () {
      final ps = [
        const PeriodSummary(start: 'a', end: 'b', income: 100000, out: 80000, byCategory: {}, running: false),
        const PeriodSummary(start: 'b', end: 'c', income: 100000, out: 110000, byCategory: {}, running: false),
        const PeriodSummary(start: 'c', end: 'd', income: 0, out: 5000, byCategory: {}, running: true),
      ];
      final o = savingsOverview(ps);
      expect([o.periods, o.saved, o.net, o.income], [2, 1, 10000, 200000]);
      expect(o.savingsRate, closeTo(0.05, 1e-9));
      expect(savingsOverview(const []).savingsRate, isNull);
    });
  });
}
