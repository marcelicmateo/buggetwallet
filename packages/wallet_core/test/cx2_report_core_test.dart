// CX2 report core: PeriodBudget.aboveSalary and periodDaySpend (the report heatmap's spending per day, no verdict).
// periodDaySpend must use exactly spentToday's rows (pinned against periodDays / computePeriod), and its sum over a
// past pay period must equal that period's PeriodReport.flex. All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart' show bigWalletRows;

var _n = 0;

Tx _tx(String date, int cents, String? category,
        {String currency = 'EUR',
        bool deleted = false,
        String source = 'pbz',
        bool manual = false,
        String? matchedTo,
        bool matchPending = false,
        String? transferTo,
        TxKind? kindHint,
        String? id}) =>
    Tx(
        id: id ?? 'cx2-${_n++}',
        source: source,
        date: date,
        amount: cents,
        currency: currency,
        description: 'Synthetic row',
        category: category,
        deleted: deleted,
        manual: manual,
        matchedTo: matchedTo,
        matchPending: matchPending,
        transferTo: transferTo,
        kindHint: kindHint);

const _flexK = 'kcccccccccccc'; // a custom flex main tag
const _fixedK = 'kdddddddddddd'; // a custom fixed main tag
final _table = CategoryTable.from(const [
  CategoryRow(id: _flexK, name: 'Hobby', kind: BudgetKind.flex, position: 40),
  CategoryRow(id: _fixedK, name: 'Childcare', kind: BudgetKind.fixed, position: 41),
]);

const _st = WalletSettings(salary: 200000, rent: 60000, periodStart: '2026-10-15'); // paydayDay 15, EUR

/// The wallet's rows, expanded (P6) with splits and IOU links, as the app passes them.
class _Wallet {
  final List<Tx> rows = [];
  final Map<String, List<SplitPart>> splits = {};
  final Set<String> iou = {};

  Tx add(Tx t) {
    rows.add(t);
    return t;
  }

  void split(String date, List<SplitPart> parts) {
    final t = add(_tx(date, parts.fold(0, (s, p) => s + p.amount), 'Groceries'));
    splits[t.id] = parts;
  }

  void transfer(String date, int cents) {
    final a = 'tr-${_n++}', b = 'tr-${_n++}';
    add(_tx(date, -cents, null, id: a, transferTo: b, kindHint: TxKind.ownTransfer));
    add(_tx(date, cents, null, id: b, source: 'revolut', transferTo: a, kindHint: TxKind.ownTransfer));
  }

  /// A hand-added entry replaced by its bank row: only the bank row counts.
  void replaced(String date, int cents, String category) {
    final bank = add(_tx(date, cents, category));
    add(_tx(date, cents, category, source: 'manual', manual: true, matchedTo: bank.id));
  }

  List<CategorizedTx> expanded() => Categorizer(table: _table, splits: splits, iouTx: iou).expandAll(rows);
}

/// Every kind of row the spending rule must sort, over 2026-07-01 .. 2026-11-14, salary on the 15th.
List<CategorizedTx> _syntheticWallet() {
  final w = _Wallet();
  final rnd = Random(20261030);
  const flexCats = ['Groceries', 'Eating out', _flexK, 'Shopping'];
  for (var d = '2026-07-01'; d.compareTo('2026-11-15') < 0; d = addDays(d, 1)) {
    if (d == '2026-10-17') continue; // a refund-only day, below
    final day = dayOf(d);
    if (day == 15 && d.compareTo('2026-11-01') < 0) w.add(_tx(d, 200000, 'Salary'));
    if (day == 16) w.add(_tx(d, -60000, 'Rent'));
    if (day == 20) w.add(_tx(d, -8000, _fixedK));
    for (var k = rnd.nextInt(4); k > 0; k--) {
      w.add(_tx(d, -(100 + rnd.nextInt(9900)), flexCats[rnd.nextInt(flexCats.length)]));
    }
    switch (rnd.nextInt(12)) {
      case 0:
        w.add(_tx(d, 100 + rnd.nextInt(3000), 'Groceries')); // a refund
      case 1:
        w.split(d, const [SplitPart(amount: -3000, category: 'Groceries'), SplitPart(amount: -2000, category: _fixedK)]);
      case 2:
        w.split(d, const [SplitPart(amount: -1500, category: _flexK), SplitPart(amount: -500, category: 'Eating out')]);
      case 3:
        w.transfer(d, 10000 + rnd.nextInt(5000));
      case 4:
        w.iou.add(w.add(_tx(d, -2500, 'To people')).id); // IOU-linked: a transfer
      case 5:
        w.add(_tx(d, -1999, 'Groceries', currency: 'USD'));
      case 6:
        w.add(_tx(d, -777, 'Shopping', deleted: true));
      case 7:
        w.replaced(d, -1234, 'Eating out');
      case 8:
        w.add(_tx(d, -650, 'Groceries', source: 'manual', manual: true, matchedTo: 'not-here-yet', matchPending: true));
      case 9:
        w.add(_tx(d, 5000, 'Extra income'));
      case 10:
        w.add(_tx(d, -4500, 'Bills & subscriptions'));
      default:
        break;
    }
  }
  w.add(_tx('2026-10-17', 1200, 'Groceries')); // net refund day
  return w.expanded();
}

void main() {
  group('PeriodBudget.aboveSalary', () {
    PeriodBudget p(List<Tx> rows, {WalletSettings st = _st, String today = '2026-10-25'}) =>
        computePeriod(Categorizer(table: _table).expandAll(rows), st, const [], today, table: _table);

    test('salary 0: nothing is above plan, whatever came in', () {
      final b = p([_tx('2026-10-15', 150000, 'Salary')], st: const WalletSettings(periodStart: '2026-10-15'));
      expect(b.received, 150000);
      expect(b.salary, 0);
      expect(b.aboveSalary, 0);
    });

    test('received below, equal to and above the salary', () {
      expect(p([_tx('2026-10-15', 150000, 'Salary')]).aboveSalary, 0);
      expect(p([_tx('2026-10-15', 200000, 'Salary')]).aboveSalary, 0);
      final b = p([_tx('2026-10-15', 200000, 'Salary'), _tx('2026-10-18', 30001, 'Salary')]);
      expect(b.salary, 200000);
      expect(b.aboveSalary, 30001);
    });

    test('income in another currency, extras, deleted rows and other periods never count', () {
      final rows = [
        _tx('2026-10-15', 200000, 'Salary'),
        _tx('2026-10-16', 90000, 'Salary', currency: 'USD'),
        _tx('2026-10-17', 50000, 'Extra income'),
        _tx('2026-10-18', 40000, 'Salary', deleted: true),
        _tx('2026-10-10', 70000, 'Salary'), // previous period
      ];
      final b = p(rows);
      expect(b.received, 200000);
      expect(b.foreignByCurrency, {'USD': 90000});
      expect(b.aboveSalary, 0);
      expect(p([...rows, _tx('2026-10-19', 1000, 'Salary')]).aboveSalary, 1000);
    });

    test("incomeMode 'received', first days: compares the real received, not the income counted", () {
      const st = WalletSettings(salary: 200000, periodStart: '2026-10-15', incomeMode: 'received');
      final short = p([_tx('2026-10-15', 120000, 'Salary')], st: st, today: '2026-10-17');
      expect(short.income, 200000, reason: 'salary parts still arriving');
      expect(short.aboveSalary, 0);
      final more = p([_tx('2026-10-15', 120000, 'Salary'), _tx('2026-10-16', 130000, 'Salary')], st: st, today: '2026-10-17');
      expect(more.income, 250000);
      expect(more.aboveSalary, 50000);
    });

    test('a PeriodBudget made without a salary reports 0', () {
      const b = PeriodBudget(
          start: '2026-10-15',
          end: '2026-11-15',
          length: 31,
          daysLeft: 20,
          received: 500000,
          extras: 0,
          income: 500000,
          goalMonthly: 0,
          fixedPlan: 0,
          flexBudget: 500000,
          spent: 0,
          spentToday: 0,
          remaining: 500000,
          allowanceToday: 0,
          safeToday: 0,
          planDaily: 0,
          elapsed: 0.3,
          fixedPaid: {});
      expect(b.aboveSalary, 0);
    });
  });

  group('periodDaySpend: the rows', () {
    test('one day by hand: only live, home-currency flex rows and parts count, refunds net', () {
      final w = _Wallet();
      const d = '2026-10-16';
      w.add(_tx(d, -1000, 'Groceries'));
      w.add(_tx(d, 300, 'Groceries')); // refund
      w.split(d, const [SplitPart(amount: -3000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Rent')]);
      w.transfer(d, 10000);
      w.iou.add(w.add(_tx(d, -700, 'To people')).id);
      w.add(_tx(d, -999, 'Groceries', currency: 'USD'));
      w.add(_tx(d, -400, 'Groceries', deleted: true));
      w.add(_tx(d, -250, _flexK));
      w.add(_tx(d, -800, _fixedK));
      w.add(_tx(d, -60000, 'Rent'));
      w.replaced(d, -1500, 'Eating out');
      w.add(_tx(d, -650, 'Groceries', source: 'manual', manual: true, matchedTo: 'not-here-yet', matchPending: true));
      w.add(_tx(d, 5000, 'Extra income'));
      w.add(_tx(d, 200000, 'Salary'));
      w.add(_tx('2026-10-15', -111, 'Groceries'));
      w.add(_tx('2026-10-18', -222, 'Groceries')); // on `end`: outside
      final txs = w.expanded();
      final days = periodDaySpend(txs, _st, '2026-10-15', '2026-10-18', table: _table);
      expect(days, const [DaySpend('2026-10-15', 111), DaySpend(d, 1000 - 300 + 3000 + 250 + 1500 + 650), DaySpend('2026-10-17', 0)]);
      final p = computePeriod(txs, _st, const [], d, table: _table);
      expect(days[1].spent, p.spentToday);
    });

    test('a net refund day is negative', () {
      final txs = Categorizer(table: _table).expandAll([_tx('2026-10-16', -500, 'Groceries'), _tx('2026-10-16', 2000, _flexK)]);
      expect(periodDaySpend(txs, _st, '2026-10-16', '2026-10-17', table: _table), const [DaySpend('2026-10-16', -1500)]);
    });

    test('bounds: start >= end is empty, bad dates throw, 1000 days at most, ascending without gaps', () {
      expect(periodDaySpend(const [], _st, '2026-10-15', '2026-10-15', table: _table), isEmpty);
      expect(periodDaySpend(const [], _st, '2026-10-16', '2026-10-15', table: _table), isEmpty);
      expect(() => periodDaySpend(const [], _st, '2026-02-30', '2026-03-15', table: _table), throwsArgumentError);
      expect(() => periodDaySpend(const [], _st, '2026-02-15', '15.3.2026', table: _table), throwsArgumentError);
      final long = periodDaySpend(const [], _st, '2020-01-01', '2030-01-01', table: _table);
      expect(long.length, 1000);
      expect(long.last.date, addDays('2020-01-01', 999));
      final feb = periodDaySpend(const [], _st, '2028-02-15', '2028-03-15', table: _table);
      expect(feb.length, 29);
      for (var i = 0; i < feb.length; i++) {
        expect(feb[i], DaySpend(addDays('2028-02-15', i), 0));
      }
    });

    test('DaySpend value semantics', () {
      expect(const DaySpend('2026-10-15', 5), const DaySpend('2026-10-15', 5));
      expect(const DaySpend('2026-10-15', 5).hashCode, const DaySpend('2026-10-15', 5).hashCode);
      expect(const DaySpend('2026-10-15', 5), isNot(const DaySpend('2026-10-15', -5)));
      expect(const DaySpend('2026-10-15', 5), isNot(const DaySpend('2026-10-16', 5)));
      expect(const DaySpend('2026-10-15', -5).toString(), 'DaySpend(2026-10-15, -5)');
    });
  });

  group('periodDaySpend against periodDays and periodReports', () {
    final txs = _syntheticWallet();

    for (final today in ['2026-10-15', '2026-10-20', '2026-11-03', '2026-11-20']) {
      test('current period, today $today: every judged day equals periodDays / spentToday', () {
        final p = computePeriod(txs, _st, const [], today, table: _table);
        final dots = periodDays(txs, _st, const [], today, table: _table);
        final spend = periodDaySpend(txs, _st, p.start, p.end, table: _table);
        expect(spend.map((d) => d.date), dots.map((d) => d.date));
        var judged = 0;
        for (var i = 0; i < dots.length; i++) {
          if (dots[i].mark != DayMark.within && dots[i].mark != DayMark.over) continue;
          judged++;
          expect(spend[i].spent, dots[i].spent, reason: dots[i].date);
        }
        expect(judged, p.paydayPassed ? p.length : daysBetween(p.start, today));
        // Spot checks straight against computePeriod.
        for (final i in [0, 2, 5, 12, 25]) {
          final d = spend[i].date;
          expect(spend[i].spent, computePeriod(txs, _st, const [], d, table: _table).spentToday, reason: d);
        }
        if (p.paydayPassed) expect(spend.fold(0, (s, d) => s + d.spent), p.spent);
      });
    }

    test('the wallet holds the cases the rule must sort (guards the test itself)', () {
      final spend = periodDaySpend(txs, _st, '2026-10-15', '2026-11-15', table: _table);
      expect(spend.firstWhere((d) => d.date == '2026-10-17').spent, -1200);
      expect(spend.where((d) => d.spent > 0).length, greaterThan(15));
      expect(txs.where((t) => t.parts > 0).length, greaterThan(4));
      expect(txs.where((t) => t.iou).length, greaterThan(2));
      expect(txs.where((t) => t.tx.transferTo != null).length, greaterThan(4));
      expect(txs.where((t) => t.tx.currency == 'USD').length, greaterThan(2));
      expect(txs.where((t) => !t.tx.live).length, greaterThan(4));
      expect(txs.where((t) => t.category == _flexK).length, greaterThan(10));
    });

    test('past periods: Σ spent == PeriodReport.flex; running: Σ up to today == flex', () {
      const today = '2026-10-20';
      final reports = periodReports(txs, _st, today, table: _table);
      expect(reports.length, 4);
      for (final r in reports) {
        final spend = periodDaySpend(txs, _st, r.start, r.end, table: _table);
        final total = spend.fold(0, (s, d) => s + d.spent);
        if (!r.running) {
          expect(r.flex, isNot(0));
          expect(total, r.flex, reason: '${r.start}..${r.end}');
          continue;
        }
        final soFar = periodDaySpend(txs, _st, r.start, addDays(today, 1), table: _table).fold(0, (s, d) => s + d.spent);
        expect(soFar, r.flex);
        expect(total, isNot(r.flex), reason: 'the report leaves out the rows after today');
      }
    });
  });

  test('perf: a 20k-row wallet, one pay period, well under 20 ms', () {
    const today = '2026-10-20';
    final rows = bigWalletRows(today, days: 2000);
    expect(rows.length, greaterThan(18000));
    const st = WalletSettings(salary: 200000, periodStart: '2026-10-15');
    periodDaySpend(rows, st, '2026-09-15', '2026-10-15', table: CategoryTable.builtIn); // warm-up
    var best = 1 << 30;
    for (var k = 0; k < 3; k++) {
      final sw = Stopwatch()..start();
      final days = periodDaySpend(rows, st, '2026-09-15', '2026-10-15', table: CategoryTable.builtIn);
      sw.stop();
      expect(days.length, 30);
      if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
    }
    expect(best, lessThan(20000), reason: 'best of 3: $best µs');
  });
}
