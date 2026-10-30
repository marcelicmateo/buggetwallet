// DD: periodDays — one verdict per day of the pay period for Today's day dots. Every judged day must equal what
// computePeriod(..., today: d) says that day (allowanceToday / spentToday) with the same inputs. All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart' show bigWalletRows;

const _t = Timeout(Duration(seconds: 60));

var _n = 0;

CategorizedTx _row(String date, int cents, String category, {String desc = '', String currency = 'EUR', bool deleted = false}) =>
    CategorizedTx(
      Tx(
          id: 'dd-${_n++}',
          source: 'pbz',
          date: date,
          amount: cents,
          currency: currency,
          description: desc.isEmpty ? 'Synthetic $category' : desc,
          deleted: deleted),
      category,
      kindOf(category),
    );

// Salary 2000.00, rent 500, loan 200, subs 50; period 2026-03-15 .. 2026-04-15 (31 days).
const _st = WalletSettings(salary: 200000, rent: 50000, loan: 20000, subs: 5000, periodStart: '2026-03-15');
const _start = '2026-03-15';
const _end = '2026-04-15';

/// Checks [periodDays] against a per-day [computePeriod] over the whole period and returns the days.
List<PeriodDay> _checked(List<CategorizedTx> txs, String today,
    {WalletSettings st = _st,
    List<Goal> goals = const [],
    List<RecurringBill> bills = const [],
    List<PlannedCost> planned = const [],
    List<CategorizedTx>? matchRows}) {
  final days = periodDays(txs, st, goals, today, bills: bills, planned: planned, table: CategoryTable.builtIn, matchRows: matchRows);
  final p = computePeriod(txs, st, goals, today, bills: bills, planned: planned, table: CategoryTable.builtIn, matchRows: matchRows);
  expect(days.length, p.length, reason: 'one entry per day of the period');
  expect(days.first.date, p.start);
  expect(days.last.date, addDays(p.end, -1));
  for (var i = 0; i < days.length; i++) {
    final d = days[i];
    expect(d.date, addDays(p.start, i), reason: 'ascending, no gaps');
    final judged = p.paydayPassed || d.date.compareTo(today) < 0;
    if (!judged) {
      expect(d.mark, d.date == today ? DayMark.today : DayMark.toCome, reason: d.date);
      expect((d.spent, d.allowance), (0, 0), reason: d.date);
      continue;
    }
    final that = computePeriod(txs, st, goals, d.date, bills: bills, planned: planned, table: CategoryTable.builtIn, matchRows: matchRows);
    expect((d.spent, d.allowance), (that.spentToday, that.allowanceToday), reason: 'day ${d.date}');
    expect(d.mark, that.spentToday > that.allowanceToday ? DayMark.over : DayMark.within, reason: 'day ${d.date}');
  }
  return days;
}

int _count(List<PeriodDay> days, DayMark m) => days.where((d) => d.mark == m).length;

/// A mixed synthetic period: groceries most days, a refund day, a bill paid mid-period, a foreign row and a deleted row.
List<CategorizedTx> _mixed() => [
      _row('2026-03-15', -4200, 'Groceries'),
      _row('2026-03-16', -900, 'Eating out'),
      _row('2026-03-17', -15000, 'Shopping'), // a big day: over
      _row('2026-03-18', -2100, 'Groceries'),
      _row('2026-03-20', 2500, 'Groceries'), // refund only: within
      _row('2026-03-21', -6100, 'Groceries'),
      _row('2026-03-21', 1000, 'Groceries'), // part refund the same day
      _row('2026-03-22', -99999, 'Groceries', currency: 'USD'), // foreign: never counts
      _row('2026-03-23', -50000, 'Groceries', deleted: true), // deleted: never counts
      _row('2026-03-24', -3000, 'Bills & one-offs', desc: 'SYNTH POWER 0000'), // pays the bill below
      _row('2026-03-26', -12000, 'Rent'), // fixed: not flexible spending
      _row('2026-03-27', -4500, 'Groceries'),
      _row('2026-03-29', -800, 'Transport'),
      _row('2026-04-01', -3300, 'Groceries'),
      _row('2026-04-02', -1500, 'Groceries'), // today in most tests
      _row('2026-04-16', -7000, 'Groceries'), // next period
    ];

RecurringBill _bill(String payee) => RecurringBill(
    id: 'rec:dd_power',
    payee: payee,
    label: 'SYNTH POWER',
    category: 'Bills & one-offs',
    expectedAmount: 3000,
    nextDue: '2026-03-24',
    status: 'confirmed');

const _plannedCost = PlannedCost(id: 'p-dd', title: 'Synth gift', date: '2026-03-28', amount: 6000, category: 'Shopping');

void main() {
  group('equal to computePeriod per day', () {
    test('mixed period, today 2026-04-02: bill due mid-period, a planned cost, a refund day, foreign and deleted rows', () {
      final txs = _mixed();
      final payee = merchantKey(txs.firstWhere((t) => t.tx.description.startsWith('SYNTH POWER')).tx);
      final days = _checked(txs, '2026-04-02',
          bills: [_bill(payee)], planned: [_plannedCost], goals: const [Goal(id: 'g', name: 'Synth goal', monthly: 10000)]);
      expect(days.length, 31);
      expect(_count(days, DayMark.today), 1);
      expect(days.firstWhere((d) => d.mark == DayMark.today).date, '2026-04-02');
      expect(_count(days, DayMark.within) + _count(days, DayMark.over), 18, reason: '03-15 .. 04-01 judged');
      expect(_count(days, DayMark.toCome), 12);
      expect(days.firstWhere((d) => d.date == '2026-03-17').mark, DayMark.over);
      final refund = days.firstWhere((d) => d.date == '2026-03-20');
      expect((refund.spent, refund.mark), (-2500, DayMark.within), reason: 'a net refund is within');
      expect(days.firstWhere((d) => d.date == '2026-03-21').spent, 5100, reason: 'net of the same-day refund');
      expect(days.firstWhere((d) => d.date == '2026-03-22').spent, 0, reason: 'the foreign row is left out');
      expect(days.firstWhere((d) => d.date == '2026-03-23').spent, 0, reason: 'the deleted row is left out');
      expect(days.firstWhere((d) => d.date == '2026-03-26').spent, 0, reason: 'fixed rows are not flexible spending');
      // The planned cost is reserved up to its day, then no more: the day's money rises after it.
      final before = days.firstWhere((d) => d.date == '2026-03-28').allowance;
      final after = days.firstWhere((d) => d.date == '2026-03-29').allowance;
      expect(after, greaterThan(before));
    }, timeout: _t);

    test('a bill due mid-period and never paid stays reserved every day', () {
      final days = _checked([_row('2026-03-20', -2000, 'Groceries')], '2026-04-10', bills: [_bill('synth_unpaid_payee')]);
      final plain = periodDays([_row('2026-03-20', -2000, 'Groceries')], _st, const [], '2026-04-10', table: CategoryTable.builtIn);
      for (var i = 0; i < 26; i++) {
        expect(days[i].allowance, lessThan(plain[i].allowance), reason: days[i].date);
      }
    }, timeout: _t);

    test('a day spent exactly at its money is within; one cent more is over', () {
      const day = '2026-03-19';
      final base = [_row('2026-03-16', -3000, 'Groceries')];
      final money = computePeriod(base, _st, const [], day, table: CategoryTable.builtIn).allowanceToday;
      expect(money, greaterThan(0));
      final exact = _checked([...base, _row(day, -money, 'Groceries')], '2026-03-25').firstWhere((d) => d.date == day);
      expect((exact.spent, exact.allowance, exact.mark), (money, money, DayMark.within));
      final oneMore = _checked([...base, _row(day, -money - 1, 'Groceries')], '2026-03-25').firstWhere((d) => d.date == day);
      expect((oneMore.spent, oneMore.allowance, oneMore.mark), (money + 1, money, DayMark.over));
    }, timeout: _t);

    test('over the plan (fixed costs above salary): days with spending are over, days without within', () {
      const st = WalletSettings(salary: 50000, rent: 60000, periodStart: _start);
      final days = _checked([_row('2026-03-16', -100, 'Groceries'), _row('2026-03-18', 300, 'Groceries')], '2026-03-20', st: st);
      expect(days.take(5).map((d) => d.allowance), everyElement(0));
      expect(days.take(5).map((d) => d.mark), [DayMark.within, DayMark.over, DayMark.within, DayMark.within, DayMark.within]);
      expect(days[5].mark, DayMark.today);
    }, timeout: _t);

    test('period start day: only today and days to come; the next day judges the first', () {
      final first = _checked(_mixed(), _start);
      expect(first.first.mark, DayMark.today);
      expect(first.skip(1).map((d) => d.mark), everyElement(DayMark.toCome));
      final second = _checked(_mixed(), '2026-03-16');
      // 125000 / 31 days = 4032 that day; 4200 spent.
      expect((second.first.spent, second.first.allowance, second.first.mark), (4200, 4032, DayMark.over));
      expect(second[1].mark, DayMark.today);
    }, timeout: _t);

    test('payday passed: every day judged, no today, rows from payday on are the next period\'s', () {
      final days = _checked(_mixed(), '2026-04-20');
      expect(days.length, 31);
      expect(_count(days, DayMark.today) + _count(days, DayMark.toCome), 0);
      expect(days.last.date, '2026-04-14');
      final onPayday = _checked(_mixed(), _end);
      expect(onPayday.map((d) => d.mark), isNot(contains(DayMark.today)));
    }, timeout: _t);

    test('no saved periodStart: the period starts today, so nothing is judged yet', () {
      const st = WalletSettings(salary: 200000, rent: 50000);
      final days = _checked(_mixed(), '2026-04-02', st: st);
      expect(days.first.date, '2026-04-02');
      expect(days.first.mark, DayMark.today);
      expect(days.last.date, addDays(nextPayday('2026-04-02', 15), -1), reason: 'the period computePeriod gives for today');
      expect(days.skip(1).map((d) => d.mark), everyElement(DayMark.toCome));
    }, timeout: _t);

    test('a periodStart after today: every day is still to come', () {
      final days = periodDays(_mixed(), _st, const [], '2026-03-10', table: CategoryTable.builtIn);
      expect(days.length, 31);
      expect(days.map((d) => d.mark), everyElement(DayMark.toCome));
    }, timeout: _t);

    test('received income in parts and a landed recurring income (P9) move the day\'s money as computePeriod does', () {
      const st = WalletSettings(salary: 200000, rent: 50000, periodStart: _start, incomeMode: 'received');
      final side = _row('2026-03-25', 30000, 'Extra income', desc: 'SYNTH CLIENT 0000');
      final income = RecurringBill(
          id: 'rec:dd_client',
          payee: merchantKey(side.tx),
          label: 'SYNTH CLIENT',
          category: 'Extra income',
          expectedAmount: 30000,
          nextDue: '2026-03-25',
          status: 'confirmed',
          direction: 'in');
      final txs = [
        _row('2026-03-15', 120000, 'Salary'),
        _row('2026-03-19', 60000, 'Salary'),
        _row('2026-03-23', 40000, 'Salary'), // after the first 7 days: received counts as it is
        side,
        _row('2026-03-27', -500, 'Extra income', desc: 'SYNTH CLIENT 0000'), // a refund counts against it
        ..._mixed(),
      ];
      final days = _checked(txs, '2026-04-05', st: st, bills: [income]);
      expect(days.map((d) => d.allowance).toSet().length, greaterThan(5), reason: 'the money moves over the period');
    }, timeout: _t);

    test('matchRows is passed through as computePeriod uses it', () {
      final txs = _mixed();
      final raw = [...txs, _row('2026-03-30', -3000, 'Bills & one-offs', desc: 'SYNTH POWER 0000', currency: 'USD')];
      final payee = merchantKey(txs.firstWhere((t) => t.tx.description.startsWith('SYNTH POWER')).tx);
      _checked(txs, '2026-04-03', bills: [_bill(payee)], matchRows: raw);
    }, timeout: _t);

    test('random synthetic periods (seeded): every day equals computePeriod', () {
      for (var seed = 1; seed <= 12; seed++) {
        final rnd = Random(seed);
        final txs = <CategorizedTx>[];
        const cats = ['Groceries', 'Eating out', 'Shopping', 'Transport', 'Rent', 'Salary', 'Extra income'];
        for (var k = 0; k < 120; k++) {
          final date = addDays('2026-03-10', rnd.nextInt(40));
          final cat = cats[rnd.nextInt(cats.length)];
          final cents = (rnd.nextInt(10) == 0 ? 1 : -1) * (1 + rnd.nextInt(9000));
          txs.add(_row(date, cents, cat, currency: rnd.nextInt(15) == 0 ? 'USD' : 'EUR', deleted: rnd.nextInt(20) == 0));
        }
        final st = WalletSettings(
            salary: 100000 + rnd.nextInt(150000),
            rent: rnd.nextInt(60000),
            periodStart: _start,
            incomeMode: rnd.nextBool() ? 'received' : 'planned');
        final planned = [
          PlannedCost(
              id: 'p$seed', title: 'Synth', date: addDays(_start, rnd.nextInt(31)), amount: 1 + rnd.nextInt(20000), category: 'Shopping'),
        ];
        _checked(txs, addDays(_start, rnd.nextInt(36)), st: st, planned: planned);
      }
    }, timeout: _t);
  });

  test('fast on a 20k-row wallet: under 100 ms, and equal to computePeriod on it', () {
    const today = '2026-10-30';
    final txs = bigWalletRows(today, days: 2000);
    expect(txs.length, greaterThan(19000));
    const st = WalletSettings(salary: 180000, rent: 55000, loan: 25000, periodStart: '2026-10-15');
    periodDays(txs, st, const [], today, table: CategoryTable.builtIn); // warm-up
    final sw = Stopwatch()..start();
    final days = periodDays(txs, st, const [], today, table: CategoryTable.builtIn);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(100), reason: '${sw.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('periodDays on ${txs.length} rows: ${sw.elapsedMicroseconds} µs');
    for (final d in days.where((d) => d.mark == DayMark.within || d.mark == DayMark.over)) {
      final p = computePeriod(txs, st, const [], d.date, table: CategoryTable.builtIn);
      expect((d.spent, d.allowance), (p.spentToday, p.allowanceToday), reason: d.date);
    }
  }, timeout: _t);
}
