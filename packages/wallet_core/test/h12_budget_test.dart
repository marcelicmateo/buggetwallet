// Stage H12 (budget): H1 only rows in the wallet currency count (and the rest is reported, not hidden), H2 the
// past-payday state, the over-budget state, salary paid in parts (samePaydayDays = 7) and the low-income flag.
// Expected values are worked out by hand from the spec. A test of behaviour the build does not have yet skips with
// `BUG: H<n>`. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/h_compat.dart';

const _t = Timeout(Duration(seconds: 30));

var _n = 0;

CategorizedTx _row(String date, int cents, String category, {String currency = 'EUR', bool deleted = false}) => CategorizedTx(
      Tx(
          id: 'h-${_n++}',
          source: 'pbz',
          date: date,
          amount: cents,
          currency: currency,
          description: 'Synthetic $category',
          deleted: deleted),
      category,
      kindOf(category),
    );

// Salary 2000.00, rent 500.00, loan 200.00, subs 50.00: fixed plan 75000, flexible money 125000 for the period.
// The period is 2026-01-15 .. 2026-02-15 (exclusive): 31 days.
const _st = WalletSettings(salary: 200000, rent: 50000, loan: 20000, subs: 5000, periodStart: '2026-01-15');

PeriodBudget _period(List<CategorizedTx> txs, String today, {WalletSettings st = _st}) => computePeriod(txs, st, const [], today);

void main() {
  final h1 = foreignOf(_period(const [], '2026-01-20')) != null;
  final h2 = paydayPassedOf(_period(const [], '2026-01-20')) != null;
  final h1skip = bugUnless(h1, 'H1', 'only rows in settings.currency count; PeriodBudget.foreignByCurrency');
  final h2skip = bugUnless(h2, 'H2', 'PeriodBudget.paydayPassed / overBy / overToday / lowIncome');

  group('the period maths the spec numbers rest on (hand-worked, any build)', () {
    test('salary 2000, fixed 750: flexible 1250, 31 days, plan 40.32 a day, 21 days left on the 25th', () {
      final p = _period([_row('2026-01-20', -3000, 'Groceries')], '2026-01-25');
      expect((p.start, p.end, p.length, p.daysLeft), ('2026-01-15', '2026-02-15', 31, 21));
      expect((p.income, p.fixedPlan, p.flexBudget, p.spent), (200000, 75000, 125000, 3000));
      expect(p.planDaily, 4032); // 125000 / 31 = 4032.26
      expect(p.remaining, 122000);
      expect(p.allowanceToday, ((125000 - 3000) / 21).round());
    }, timeout: _t);

    test('spent today is not taken off the allowance twice', () {
      final p = _period([_row('2026-01-25', -2100, 'Groceries')], '2026-01-25');
      expect(p.spentToday, 2100);
      expect(p.allowanceToday, (125000 / 21).round());
      expect(p.safeToday, (125000 / 21).round() - 2100);
    }, timeout: _t);
  });

  group('H1: only the wallet currency counts', () {
    final base = [
      _row('2026-01-16', -4000, 'Groceries'),
      _row('2026-01-17', 200000, 'Salary'),
      _row('2026-01-18', -1500, 'Eating out'),
    ];
    final foreign = [
      _row('2026-01-16', -5000, 'Groceries', currency: 'USD'),
      _row('2026-01-17', 90000, 'Salary', currency: 'USD'),
      _row('2026-01-19', 2000, 'Groceries', currency: 'USD'), // a refund
      _row('2026-01-19', -7777, 'Shopping', currency: 'GBP'),
      _row('2026-01-20', -900, 'Groceries', currency: 'USD', deleted: true),
    ];

    test('computePeriod: spent, received, extras and today are the EUR-only figures; foreign sums are reported signed by currency', () {
      final only = _period(base, '2026-01-25');
      final both = _period([...base, ...foreign], '2026-01-25');
      expect((both.spent, both.received, both.extras, both.spentToday), (only.spent, only.received, only.extras, only.spentToday));
      expect((both.remaining, both.allowanceToday, both.safeToday, both.planDaily),
          (only.remaining, only.allowanceToday, only.safeToday, only.planDaily));
      expect(foreignOf(both), {'USD': 90000 - 5000 + 2000, 'GBP': -7777}, reason: 'live rows only, signed, deleted left out');
      expect(foreignOf(only), isEmpty);
    }, skip: h1skip, timeout: _t);

    test('the currency is the setting: with USD as the wallet currency the EUR rows are the foreign ones', () {
      const usd = WalletSettings(salary: 200000, periodStart: '2026-01-15', currency: 'USD');
      final p = _period([...base, ...foreign], '2026-01-25', st: usd);
      expect(p.spent, 5000 - 2000, reason: 'USD groceries minus the USD refund');
      expect(foreignOf(p), {'EUR': 200000 - 4000 - 1500, 'GBP': -7777});
    }, skip: h1skip, timeout: _t);

    test('a foreign row alone never makes income', () {
      final p = _period([_row('2026-01-16', 500000, 'Salary', currency: 'USD')], '2026-01-25');
      expect(p.received, 0);
      expect(foreignOf(p), {'USD': 500000});
    }, skip: h1skip, timeout: _t);

    test('periodSummaries gives the same periods, income and out as without the foreign rows (incl. payday detection)', () {
      final rows = [
        _row('2025-12-15', 200000, 'Salary'),
        _row('2025-12-20', -30000, 'Groceries'),
        _row('2026-01-15', 200000, 'Salary'),
        _row('2026-01-20', -40000, 'Groceries'),
      ];
      final noise = [
        _row('2025-12-28', 300000, 'Salary', currency: 'USD'), // would invent a payday
        _row('2026-01-05', -9999, 'Groceries', currency: 'USD'),
        _row('2026-01-22', -123, 'Shopping', currency: 'GBP'),
      ];
      const st = WalletSettings(salary: 200000);
      List<(String, String, int, int, Map<String, int>)> flat(List<CategorizedTx> t) =>
          [for (final s in periodSummaries(t, st, '2026-01-25')) (s.start, s.end, s.income, s.out, s.byCategory)];
      expect(flat([...rows, ...noise]), flat(rows));
    }, skip: h1skip, timeout: _t);

    test('monthSummary, averageByCategory, budgetVsActual and monthlySummaryCsv take a currency and ignore the others', () {
      final rows = [
        _row('2026-01-10', -4000, 'Groceries'),
        _row('2026-01-12', 100000, 'Salary'),
        _row('2025-12-10', -6000, 'Groceries'),
      ];
      final noise = [
        _row('2026-01-11', -9000, 'Groceries', currency: 'USD'),
        _row('2025-12-11', -9000, 'Groceries', currency: 'USD'),
        _row('2026-01-13', 70000, 'Salary', currency: 'USD'),
      ];
      final all = [...rows, ...noise];
      final ms = monthSummaryIn(all, '2026-01', 'EUR')!;
      final ref = monthSummaryIn(rows, '2026-01', 'EUR')!;
      expect((ms.income, ms.out, ms.byCategory), (ref.income, ref.out, ref.byCategory));
      expect(ms.out, 4000);
      expect(foreignOfMonth(ms), {'USD': 70000 - 9000});
      expect(averageByCategoryIn(all, '2026-01', 'EUR'), averageByCategoryIn(rows, '2026-01', 'EUR'));
      expect(averageByCategoryIn(all, '2026-01', 'EUR')!['Groceries'], (6000 / 6).round());
      final b = budgetVsActualIn(all, '2026-01', {'Groceries': 10000}, '2026-01-31', 'EUR')!;
      final r = budgetVsActualIn(rows, '2026-01', {'Groceries': 10000}, '2026-01-31', 'EUR')!;
      expect([for (final l in b.lines) (l.category, l.actual, l.average6)], [for (final l in r.lines) (l.category, l.actual, l.average6)]);
      expect(monthlySummaryCsvIn(all, 'EUR'), monthlySummaryCsvIn(rows, 'EUR'));
    },
        skip: bugUnless(averageByCategoryIn(const [], '2026-01', 'EUR') != null, 'H1', 'currency: on the pure budget and export functions'),
        timeout: _t);

    test('transactionsCsv keeps every currency (an export is a record, not a budget)', () {
      final csv = transactionsCsv([...base, ...foreign]);
      expect(csv.trim().split('\n').length, 1 + base.length + foreign.length - 1, reason: 'header + live rows of every currency');
      expect(csv, contains('77.77'));
    }, timeout: _t);
  });

  group('H2: past payday', () {
    const end = '2026-02-15';
    test('on the payday and after it the state says so; days left is the real count, never clamped up to 1', () {
      for (final (today, passed, left) in [
        ('2026-02-13', false, 2),
        ('2026-02-14', false, 1),
        ('2026-02-15', true, 0),
        ('2026-02-16', true, 0),
        ('2026-03-20', true, 0),
      ]) {
        final p = _period([], today);
        expect(p.end, end);
        expect(paydayPassedOf(p), passed, reason: today);
        expect(p.daysLeft, left, reason: today);
      }
    }, skip: h2skip, timeout: _t);

    test('nothing the screens divide by or show as a daily allowance is zero-divided or negative once the payday passed', () {
      final p = _period([_row('2026-02-10', -80000, 'Groceries')], '2026-02-20');
      expect(p.allowanceToday, greaterThanOrEqualTo(0));
      expect(p.length, greaterThan(0));
      expect(overByOf(p), 0, reason: '1250 - 800 is still positive: not over');
      expect(p.remaining, 125000 - 80000);
    }, skip: h2skip, timeout: _t);

    test('the last day before payday: 1 day left, the allowance is what is left', () {
      final p = _period([_row('2026-02-01', -50000, 'Groceries')], '2026-02-14');
      expect(p.daysLeft, 1);
      expect(p.allowanceToday, 75000);
    }, timeout: _t);

    test('WalletSettings keeps the payday day within 1..28; anything else falls back to 15', () {
      for (final (day, want) in [(1, 1), (15, 15), (28, 28), (0, 15), (-3, 15), (29, 15), (31, 15), (99, 15)]) {
        expect(WalletSettings.fromMap({'paydayDay': day}).paydayDay, want, reason: '$day');
      }
    },
        skip: bugUnless(WalletSettings.fromMap({'paydayDay': 31}).paydayDay == 15, 'H2', 'payday day clamp 1..28 in WalletSettings'),
        timeout: _t);
  });

  group('H2: over budget', () {
    test('flexible money 1250, 1500 spent: remaining -250, overBy 250, never a negative allowance for today', () {
      final p = _period([_row('2026-01-20', -150000, 'Groceries')], '2026-01-25');
      expect(p.remaining, -25000);
      expect(overByOf(p), 25000);
      expect(p.allowanceToday, 0, reason: 'was -1190 (-25000 / 21): a negative allowance is never shown');
    }, skip: h2skip, timeout: _t);

    test('exactly at the limit is not over; one cent past it is', () {
      expect(overByOf(_period([_row('2026-01-20', -125000, 'Groceries')], '2026-01-25')), 0);
      expect(overByOf(_period([_row('2026-01-20', -125001, 'Groceries')], '2026-01-25')), 1);
      expect(overByOf(_period(const [], '2026-01-25')), 0);
    }, skip: h2skip, timeout: _t);

    test('overToday is how far today is over: spent today beyond the day\'s allowance', () {
      final p = _period([_row('2026-01-25', -30000, 'Groceries')], '2026-01-25');
      expect(p.safeToday, (125000 / 21).round() - 30000);
      expect(overTodayOf(p), 30000 - (125000 / 21).round());
      final fine = _period([_row('2026-01-25', -1000, 'Groceries')], '2026-01-25');
      expect(overTodayOf(fine), 0);
    }, skip: h2skip, timeout: _t);

    test('a salary smaller than the fixed costs: flexible money is negative, overBy covers it, the allowance is 0', () {
      const poor = WalletSettings(salary: 50000, rent: 50000, loan: 20000, subs: 5000, periodStart: '2026-01-15');
      final p = _period(const [], '2026-01-25', st: poor);
      expect(p.flexBudget, -25000);
      expect(overByOf(p), 25000);
      expect(p.allowanceToday, 0);
    }, skip: h2skip, timeout: _t);

    test('affordability: over budget (or a plan of zero or less) is Verdict.overBudget, never now', () {
      final over = verdictNamed('overBudget')!;
      const zero = WalletSettings(periodStart: '2026-01-15'); // no salary, no costs: flexible money 0, plan 0 a day
      final p0 = _period(const [], '2026-01-25', st: zero);
      expect(p0.planDaily, 0);
      for (final price in [0, 1, 500]) {
        expect(affordability(price, p0).verdict, over, reason: 'price $price against a plan of 0');
      }
      const poor = WalletSettings(salary: 50000, rent: 50000, loan: 20000, subs: 5000, periodStart: '2026-01-15');
      final pn = _period(const [], '2026-01-25', st: poor);
      expect(pn.planDaily, lessThan(0));
      expect(affordability(0, pn).verdict, over);
      final pOver = _period([_row('2026-01-20', -150000, 'Groceries')], '2026-01-25');
      expect(affordability(100, pOver).verdict, over);
      final fine = _period(const [], '2026-01-25');
      expect(affordability(1000, fine).verdict, Verdict.now);
      expect(affordability(120000, fine).verdict, isNot(over));
    }, skip: bugUnless(verdictNamed('overBudget') != null, 'H2', 'Verdict.overBudget'), timeout: _t);

    test('an affordable purchase is now, a purchase that eats the rest is later (the old verdicts are unchanged)', () {
      final fine = _period(const [], '2026-01-25');
      expect(affordability(1000, fine).verdict, Verdict.now);
      expect(affordability(130000, fine).verdict, Verdict.later);
    }, timeout: _t);
  });

  group('H2: salary paid in parts (samePaydayDays = 7) and the low-income flag', () {
    const received = WalletSettings(salary: 200000, periodStart: '2026-01-15', incomeMode: 'received');
    CategorizedTx part(String date, int cents) => _row(date, cents, 'Salary');

    test('inside the first 7 days income is max(received, salary): a part paid does not shrink the budget, lowIncome stays false', () {
      // Day 0: 1500.00 of 2000.00 has landed.
      final p0 = _period([part('2026-01-15', 150000)], '2026-01-15', st: received);
      expect(p0.received, 150000);
      expect(p0.income, 200000);
      expect(lowIncomeOf(p0), isFalse);
      // Day 6 (the 21st): the second part, 500.00, lands. Still inside the window; both parts are in.
      final p6 = _period([part('2026-01-15', 150000), part('2026-01-21', 50000)], '2026-01-21', st: received);
      expect((p6.received, p6.income), (200000, 200000));
      expect(lowIncomeOf(p6), isFalse);
      // Day 6 again, but the second part has not landed yet: still not shown short.
      final p6short = _period([part('2026-01-15', 150000)], '2026-01-21', st: received);
      expect(p6short.income, 200000);
      expect(lowIncomeOf(p6short), isFalse);
    }, skip: h2skip, timeout: _t);

    test('after the window the received sum rules: a part landing on day 8 is missing before it, counted once it lands', () {
      final only = [part('2026-01-15', 150000)];
      final p8 = _period(only, '2026-01-23', st: received);
      expect(p8.income, 150000, reason: 'day 8, only 1500.00 received');
      expect(lowIncomeOf(p8), isTrue, reason: '75 % of the salary, more than 4 days in');
      final landed = _period([...only, part('2026-01-23', 50000)], '2026-01-23', st: received);
      expect((landed.received, landed.income), (200000, 200000));
      expect(lowIncomeOf(landed), isFalse);
    }, skip: h2skip, timeout: _t);

    test('a received sum above the salary is the income (a bonus is not capped)', () {
      final p = _period([part('2026-01-15', 230000)], '2026-01-23', st: received);
      expect(p.income, 230000);
    }, timeout: _t);

    test('planned mode ignores what was received; received mode with nothing received falls back to the salary', () {
      const planned = WalletSettings(salary: 200000, periodStart: '2026-01-15');
      expect(_period([part('2026-01-15', 150000)], '2026-01-25', st: planned).income, 200000);
      expect(_period(const [], '2026-01-25', st: received).income, 200000);
    }, timeout: _t);

    test('lowIncome: below 90 % of the salary and at least 4 days in; exactly 90 % is fine; nothing received is not low', () {
      const planned = WalletSettings(salary: 200000, periodStart: '2026-01-15');
      for (final st in [planned, received]) {
        bool low(int cents, String today) => lowIncomeOf(_period([part('2026-01-15', cents)], today, st: st))!;
        expect(low(179999, '2026-01-25'), isTrue, reason: st.incomeMode);
        expect(low(180000, '2026-01-25'), isFalse, reason: '${st.incomeMode}: exactly 90 %');
        expect(low(200000, '2026-01-25'), isFalse);
        expect(lowIncomeOf(_period(const [], '2026-01-25', st: st)), isFalse, reason: 'nothing received');
      }
      const none = WalletSettings(periodStart: '2026-01-15');
      expect(lowIncomeOf(_period([part('2026-01-15', 10)], '2026-01-25', st: none)), isFalse, reason: 'no salary set');
    }, skip: h2skip, timeout: _t);
  });
}
