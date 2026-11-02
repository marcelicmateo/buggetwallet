// J3 mutation-testing gaps in budget.dart, periods.dart and loan.dart: boundaries and balance rules written from the
// money meaning (SYNTHETIC data only). Each group says which kind of mutant it pins down.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

var _seq = 0;

Tx _row(String date, int cents, {String desc = 'Zorblex Gig', String currency = 'EUR'}) =>
    Tx(id: 'j3-${_seq++}', source: 'pbz', date: date, amount: cents, currency: currency, bankType: 'Ostalo', description: desc);

CategorizedTx _cat(Tx t, String category) => CategorizedTx(t, category, kindOf(category));

RecurringBill _bill(
  String id,
  String nextDue, {
  int cents = 10000,
  int interval = 30,
  String status = 'confirmed',
  String? lastPaidTx,
  String? endsOn,
  bool income = false,
  String label = 'Bill',
  String? payee,
}) =>
    RecurringBill(
      id: id,
      payee: payee ?? 'payee-$id',
      label: label,
      category: income ? 'Extra income' : 'Bills & one-offs',
      expectedAmount: cents,
      intervalDays: interval,
      nextDue: nextDue,
      status: status,
      lastPaidTx: lastPaidTx,
      endsOn: endsOn,
      direction: income ? RecurringBill.directionIn : null,
    );

PeriodBudget _pb({
  int extras = 0,
  int landed = 0,
  int remaining = 0,
  int safeToday = 0,
  int flexBudget = 10000,
  int spent = 0,
  int planDaily = 1000,
  int daysLeft = 10,
  bool paydayPassed = false,
}) =>
    PeriodBudget(
      start: '2026-03-01',
      end: '2026-03-11',
      length: 10,
      daysLeft: daysLeft,
      paydayPassed: paydayPassed,
      received: 0,
      extras: extras,
      income: 0,
      goalMonthly: 0,
      fixedPlan: 0,
      flexBudget: flexBudget,
      spent: spent,
      spentToday: 0,
      remaining: remaining,
      allowanceToday: 0,
      safeToday: safeToday,
      planDaily: planDaily,
      elapsed: 0,
      fixedPaid: const {},
      landedIncome: landed,
    );

void main() {
  group('PeriodBudget getters and defaults', () {
    test('a budget built with the required fields only has the neutral defaults', () {
      final p = _pb();
      expect(p.lowIncome, isFalse);
      expect(p.reservedPlanned, 0);
      expect(p.reservedBills, 0);
      expect(p.paydayPassed, isFalse);
      expect(p.foreignByCurrency, isEmpty);
      expect(p.goalTakenOut, 0);
    });

    test('extrasForGoals = extras - landed, never negative, equal at the boundary', () {
      expect(_pb(extras: 1000, landed: 0).extrasForGoals, 1000);
      expect(_pb(extras: 1000, landed: 300).extrasForGoals, 700);
      expect(_pb(extras: 1000, landed: 1000).extrasForGoals, 0);
      expect(_pb(extras: 1000, landed: 1500).extrasForGoals, 0);
      expect(_pb(extras: -500, landed: 0).extrasForGoals, 0);
    });

    test('overBy and overToday are 0 when there is room, and the overshoot when there is none', () {
      for (final r in [500, 1, 0]) {
        expect(_pb(remaining: r, safeToday: r).overBy, 0, reason: '$r');
        expect(_pb(remaining: r, safeToday: r).overToday, 0, reason: '$r');
      }
      expect(_pb(remaining: -1, safeToday: -1).overBy, 1);
      expect(_pb(remaining: -300, safeToday: -700).overBy, 300);
      expect(_pb(remaining: -300, safeToday: -700).overToday, 700);
      expect(_pb(remaining: -1, safeToday: -1).overToday, 1);
    });
  });

  group('affordability: the 75 % line', () {
    // 10 days left, 10 000 flexible, nothing spent, plan 1 000 a day: the line is a new daily of exactly 750.
    test('a new daily allowance of exactly 75 % of the plan is still "now"; one cent less a day is "tight"', () {
      final exact = affordability(2500, _pb()); // left 7 500 / 10 = 750
      expect((exact.verdict, exact.newDaily), (Verdict.now, 750));
      final below = affordability(2510, _pb()); // left 7 490 / 10 = 749
      expect((below.verdict, below.newDaily), (Verdict.tight, 749));
    });

    test('a price that uses up everything is later, never now', () {
      expect(affordability(10000, _pb()).verdict, Verdict.later);
      expect(affordability(10001, _pb()).verdict, Verdict.later);
    });
  });

  group('dueCycles: which bills hold money', () {
    const none = RecurringPayments({});
    List<DueCycle> cycles(List<RecurringBill> bs, {List<CategorizedTx> txs = const [], RecurringPayments pay = none}) =>
        dueCycles(bs, txs, '2026-03-01', '2026-04-01', payments: pay, currency: 'EUR');

    test('a plain confirmed bill in the period is listed (control)', () {
      expect(cycles([_bill('a', '2026-03-10')]).length, 1);
    });

    test('an income, a candidate, a finished bill and a bill without a date never reserve money', () {
      expect(cycles([_bill('a', '2026-03-10', income: true)]), isEmpty);
      expect(cycles([_bill('a', '2026-03-10', status: 'candidate')]), isEmpty);
      expect(cycles([_bill('a', '2026-03-10', status: 'dismissed')]), isEmpty);
      expect(cycles([_bill('a', '2026-03-10', endsOn: '2026-01-01')]), isEmpty); // ended long ago
      expect(cycles([_bill('a', 'not-a-date')]), isEmpty);
    });

    test('a monthly bill due on the payday itself (end, exclusive) is not in this period', () {
      expect(cycles([_bill('a', '2026-04-01')]), isEmpty);
      expect(cycles([_bill('a', '2026-03-31')]).length, 1);
    });

    test('parts paid keep lowering the reserve while the match window is open, up to and including the period start', () {
      // interval 30: tolerance 3. Window closes nextDue + 3.
      final parts = RecurringPayments({}, parts: {
        'a': [_row('2026-02-20', -4000)]
      });
      final open = cycles([_bill('a', '2026-02-26')], pay: parts).single; // window closes 03-01 = start: still open
      expect((open.paid, open.reserve), (4000, 6000));
      final closed = cycles([_bill('a', '2026-02-25')], pay: parts).single; // closed 02-28: parts no longer count
      expect((closed.paid, closed.reserve), (0, 10000));
    });

    test('an overpaid cycle reserves 0 (not 1); an exactly paid one too', () {
      final parts = RecurringPayments({}, parts: {
        'a': [_row('2026-03-02', -15000)]
      });
      final c = cycles([_bill('a', '2026-03-05')], pay: parts).single;
      expect((c.paid, c.reserve), (15000, 0));
      final exact = RecurringPayments({}, parts: {
        'a': [_row('2026-03-02', -10000)]
      });
      expect(cycles([_bill('a', '2026-03-05')], pay: exact).single.reserve, 0);
    });

    test('a long bill paid by a row reserves 0 and shows what was paid; unpaid it is held in full', () {
      final paid = RecurringPayments({'a': _row('2026-03-02', -12000)});
      final c = cycles([_bill('a', '2026-09-01', cents: 12000, interval: 365)], pay: paid).single;
      expect((c.reserve, c.paid), (0, 12000));
      final open = cycles([_bill('a', '2026-09-01', cents: 12000, interval: 365)]).single;
      expect((open.reserve, open.paid), (12000, 0));
    });

    test('a monthly bill whose last payment row is dated on or after the period start is paid; earlier or unknown is not', () {
      final onStart = _cat(_row('2026-03-01', -10000), 'Bills & one-offs');
      final before = _cat(_row('2026-02-28', -10000), 'Bills & one-offs');
      expect(cycles([_bill('a', '2026-03-10', lastPaidTx: onStart.tx.id)], txs: [onStart]), isEmpty);
      expect(cycles([_bill('a', '2026-03-10', lastPaidTx: before.tx.id)], txs: [before]).length, 1);
      expect(cycles([_bill('a', '2026-03-10', lastPaidTx: 'gone')], txs: [before]).length, 1);
      expect(cycles([_bill('a', '2026-03-10')], txs: [onStart]).length, 1);
    });

    test('a weekly bill lists every occurrence from the period start on, whatever its distance from nextDue', () {
      // start 03-01, end 03-12.
      List<String> dues(String nextDue) => [
            for (final c
                in dueCycles([_bill('w', nextDue, interval: 7)], const [], '2026-03-01', '2026-03-12', payments: none, currency: 'EUR'))
              c.due
          ];
      expect(dues('2026-02-15'), ['2026-02-15', '2026-03-01', '2026-03-08']); // 14 days behind: the grid hits the start day
      expect(dues('2026-02-14'), ['2026-02-14', '2026-03-07']); // 15 days behind
      expect(dues('2026-02-22'), ['2026-02-22', '2026-03-01', '2026-03-08']); // 7 days behind
      expect(dues('2026-03-01'), ['2026-03-01', '2026-03-08']); // not behind at all
    });
  });

  group('duePlanned: which planned costs reserve money', () {
    PlannedCost p(String id, String date, {int? amount = 5000, PlannedStatus status = PlannedStatus.open, bool deleted = false}) =>
        PlannedCost(id: id, title: id, date: date, amount: amount, status: status, deleted: deleted);
    List<String> ids(List<PlannedCost> xs) => [for (final x in duePlanned(xs, '2026-03-10', '2026-03-15')) x.id];

    test('open, with an amount, dated from today to the day before payday', () {
      expect(ids([p('today', '2026-03-10'), p('last', '2026-03-14')]), ['today', 'last']);
    });

    test('every one of the other cases reserves nothing', () {
      expect(ids([p('past', '2026-03-09')]), isEmpty); // yesterday: the real row is in spending
      expect(ids([p('payday', '2026-03-15')]), isEmpty); // the payday itself belongs to the next period
      expect(ids([p('paid', '2026-03-12', status: PlannedStatus.paid)]), isEmpty);
      expect(ids([p('skipped', '2026-03-12', status: PlannedStatus.skipped)]), isEmpty);
      expect(ids([p('deleted', '2026-03-12', deleted: true)]), isEmpty);
      expect(ids([p('noamount', '2026-03-12', amount: null)]), isEmpty);
      expect(ids([p('zero', '2026-03-12', amount: 0)]), isEmpty);
      expect(ids([p('negative', '2026-03-12', amount: -500)]), isEmpty);
    });
  });

  group('expectedIncomeCycles', () {
    final zorblex = merchantKey(_row('2026-01-01', 1));
    RecurringBill inc(String id, String nextDue, {int cents = 50000, int interval = 30, String label = 'Zorblex Gig'}) =>
        _bill(id, nextDue, cents: cents, interval: interval, income: true, label: label, payee: zorblex);
    List<IncomeCycle> expected(List<RecurringBill> bs, List<CategorizedTx> txs, {String start = '2026-03-01', String end = '2026-04-01'}) =>
        expectedIncomeCycles(bs, txs, start, end, currency: 'EUR');
    List<String> dues(List<IncomeCycle> cs) => [for (final c in cs) c.due];

    test('an income with no expected amount lists nothing', () {
      expect(expected([inc('a', '2026-03-10', cents: 0)], const []), isEmpty);
      expect(expected([inc('a', '2026-03-10', cents: 1)], const []).length, 1);
    });

    test('only a payment in the wallet currency lands a cycle', () {
      final eur = _cat(_row('2026-03-10', 50000), 'Extra income');
      final usd = _cat(_row('2026-03-10', 50000, currency: 'USD'), 'Extra income');
      expect(expected([inc('a', '2026-03-10')], [eur]), isEmpty);
      expect(dues(expected([inc('a', '2026-03-10')], [usd])), ['2026-03-10']);
    });

    test('the landing window opens half an interval before the due date (15 days for monthly) and closes after the tolerance', () {
      Tx on(String d) => _row(d, 50000);
      expect(expected([inc('a', '2026-03-20')], [_cat(on('2026-03-05'), 'Extra income')]), isEmpty); // 15 days early
      expect(dues(expected([inc('a', '2026-03-20')], [_cat(on('2026-03-04'), 'Extra income')])), ['2026-03-20']); // 16
      expect(expected([inc('a', '2026-03-20')], [_cat(on('2026-03-23'), 'Extra income')]), isEmpty); // tolerance 3
      expect(dues(expected([inc('a', '2026-03-20')], [_cat(on('2026-03-24'), 'Extra income')])), ['2026-03-20']);
    });

    test('a payment of the wrong size, a negative one or a transfer does not land the cycle', () {
      expect(dues(expected([inc('a', '2026-03-10')], [_cat(_row('2026-03-10', 20000), 'Extra income')])), ['2026-03-10']);
      expect(dues(expected([inc('a', '2026-03-10')], [_cat(_row('2026-03-10', -50000), 'Extra income')])), ['2026-03-10']);
      expect(dues(expected([inc('a', '2026-03-10')], [_cat(_row('2026-03-10', 50000), 'Internal transfer')])), ['2026-03-10']);
    });

    test('cycles are the due dates from the period start up to before its end: overdue and landed ones are left out', () {
      final weekly = inc('a', '2026-02-20', cents: 5000, interval: 7);
      expect(dues(expected([weekly], const [], start: '2026-03-01', end: '2026-03-15')), ['2026-03-06', '2026-03-13']);
      final landed = _cat(_row('2026-03-06', 5000), 'Extra income');
      expect(dues(expected([weekly], [landed], start: '2026-03-01', end: '2026-03-15')), ['2026-03-13']);
    });

    test('a cycle due on the payday itself belongs to the next period', () {
      final weekly = inc('a', '2026-03-06', cents: 5000, interval: 7);
      expect(dues(expected([weekly], const [], start: '2026-03-01', end: '2026-03-13')), ['2026-03-06']);
      expect(dues(expected([weekly], const [], start: '2026-03-01', end: '2026-03-14')), ['2026-03-06', '2026-03-13']);
    });

    test('a daily income over a long span stops at the 100-cycle guard', () {
      final daily = inc('a', '2026-01-01', cents: 100, interval: 1);
      final cs = expected([daily], const [], start: '2026-01-01', end: '2026-12-31');
      expect(cs.length, 100);
      expect(cs.last.due, '2026-04-10');
    });

    test('order is by due date first, then label, then id', () {
      final z = inc('z', '2026-03-05', label: 'Same');
      final a = inc('a', '2026-03-10', label: 'Same');
      expect([
        for (final c in expected([a, z], const [])) c.bill.id
      ], [
        'z',
        'a'
      ]); // due date beats id
      final b1 = inc('a', '2026-03-05', label: 'B');
      final a1 = inc('b', '2026-03-05', label: 'A');
      expect([
        for (final c in expected([b1, a1], const [])) c.bill.id
      ], [
        'b',
        'a'
      ]); // label beats id
      final x = inc('x', '2026-03-05', label: 'Same');
      final y = inc('y', '2026-03-05', label: 'Same');
      expect([
        for (final c in expected([y, x], const [])) c.bill.id
      ], [
        'x',
        'y'
      ]);
    });
  });

  group('computePeriod: landed income', () {
    final zorblex = merchantKey(_row('2026-01-01', 1));
    final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
    PeriodBudget period(List<RecurringBill> bills, List<CategorizedTx> txs) =>
        computePeriod(txs, st, const [], '2026-03-01', bills: bills, table: CategoryTable.builtIn);
    RecurringBill inc(String status) => RecurringBill(
          id: RecurringBill.incomeIdFor(zorblex),
          payee: zorblex,
          label: 'Zorblex Gig',
          category: 'Extra income',
          expectedAmount: 25000,
          nextDue: '2026-03-22',
          status: status,
          direction: RecurringBill.directionIn,
        );
    final pay = _cat(_row('2026-02-20', 25000), 'Extra income');

    test('a confirmed income turns its landed payment into spending money; flex = base + landed', () {
      final base = period(const [], [pay]);
      final p = period([inc('confirmed')], [pay]);
      expect(p.landedIncome, 25000);
      expect(p.flexBudget, base.flexBudget + 25000);
      expect(p.extrasForGoals, base.extrasForGoals - 25000);
    });

    test('an unconfirmed income changes nothing: its payee payments stay extras for the goals', () {
      final base = period(const [], [pay]);
      final p = period([inc('candidate')], [pay]);
      expect(p.landedIncome, 0);
      expect(p.flexBudget, base.flexBudget);
      expect(p.extrasForGoals, base.extrasForGoals);
    });
  });

  group('budgetProposals: a budget of 0 counts as empty', () {
    test('0 and missing fill an empty field; a different non-zero value is a change; an equal one is left out', () {
      final r = budgetProposals({'A': 0, 'B': 500, 'C': 700}, {'A': 100, 'B': 500, 'C': 900, 'D': 300});
      expect([
        for (final x in r) (x.category, x.current, x.suggested)
      ], [
        ('A', null, 100),
        ('D', null, 300),
        ('C', 700, 900),
      ]);
      expect([for (final x in r) x.fillsEmpty], [true, true, false]);
    });
  });

  group('reviewState: the categories step counts spending rows only', () {
    test('fixed and flex rows of the last 7 days without an own category count; income, transfer and extra rows do not', () {
      final rows = [
        ct('2026-10-25', -50000, 'Rent'),
        ct('2026-10-26', -2000, 'Groceries'),
        ct('2026-10-26', 150000, 'Salary'),
        ct('2026-10-26', -3000, 'Internal transfer'),
        ct('2026-10-26', 4000, 'Extra income'),
      ];
      final s = reviewState(rows, const WalletSettings(), const [], const {}, today: '2026-10-27');
      expect(s.steps.firstWhere((x) => x.id == 'categories').count, 2);
    });
  });

  group('loanLeft', () {
    test('a loan of 1 cent is still a loan', () {
      final l = loanLeft(const WalletSettings(loan: 1, loanEnd: '2026-10', paydayDay: 15), '2026-10-01')!;
      expect((l.payments, l.cents), (1, 1));
      expect(loanLeft(const WalletSettings(loan: 0, loanEnd: '2026-10', paydayDay: 15), '2026-10-01'), isNull);
    });

    test('payments x loan = cents, and the count falls by one on the day after each payday', () {
      const st = WalletSettings(loan: 12345, loanEnd: '2027-02', paydayDay: 1);
      var last = 100;
      for (final d in ['2026-12-31', '2027-01-01', '2027-01-02', '2027-02-01', '2027-02-02']) {
        final l = loanLeft(st, d);
        final n = l?.payments ?? 0;
        expect(n, lessThanOrEqualTo(last), reason: d);
        expect(l?.cents ?? 0, n * 12345, reason: d);
        last = n;
      }
      expect(loanLeft(st, '2027-01-01')!.payments, 2); // Jan 1 (today) and Feb 1
      expect(loanLeft(st, '2027-01-02')!.payments, 1);
      expect(loanLeft(st, '2027-02-02'), isNull);
    });
  });

  group('periods', () {
    test('savingsRate: null without income, a fraction with it (even 1 cent), negative when out exceeds income', () {
      PeriodSummary s(int income, int out) =>
          PeriodSummary(start: '2026-03-01', end: '2026-04-01', income: income, out: out, byCategory: const {}, running: false);
      expect(s(0, 500).savingsRate, isNull);
      expect(s(1, 0).savingsRate, 1.0);
      expect(s(100, 150).savingsRate, -0.5);
      expect(s(200, 50).savingsRate, 0.75);
    });

    test('a hand-set period start on today is a payday when no salary came yet; one tomorrow is not', () {
      const day = '2026-03-10';
      expect(detectPaydays(const [], const WalletSettings(periodStart: day, paydayDay: 10), day), [day]);
      expect(detectPaydays(const [], const WalletSettings(periodStart: '2026-03-11', paydayDay: 10), day), isEmpty);
    });

    test('assumed paydays stop short of 20 days before the next real salary (the boundary day is dropped)', () {
      final txs = [ct('2026-01-15', 150000, 'Salary'), ct('2026-05-05', 150000, 'Salary')];
      // Assumed: 02-15, 03-15, 04-15; 05-05 minus 20 days = 04-15 is cut off.
      expect(
          detectPaydays(txs, const WalletSettings(paydayDay: 15), '2026-05-10'), ['2026-01-15', '2026-02-15', '2026-03-15', '2026-05-05']);
    });

    test('after the last salary assumed paydays run up to and including today', () {
      final txs = [ct('2026-01-15', 150000, 'Salary')];
      expect(detectPaydays(txs, const WalletSettings(paydayDay: 15), '2026-03-15'), ['2026-01-15', '2026-02-15', '2026-03-15']);
      expect(detectPaydays(txs, const WalletSettings(paydayDay: 15), '2026-03-14'), ['2026-01-15', '2026-02-15']);
    });

    test('trendNet with a zero or negative window is all null (no division by zero)', () {
      final ps = [
        for (var i = 0; i < 4; i++)
          PeriodSummary(
              start: '2026-0${i + 1}-01', end: '2026-0${i + 2}-01', income: 1000, out: 400, byCategory: const {}, running: i == 3),
      ];
      expect(trendNet(ps, window: 0), everyElement(isNull));
      expect(trendNet(ps, window: -2), everyElement(isNull));
      expect(trendNet(ps, window: 1), [600, 600, 600, null]); // a window of one is the period itself
      expect(trendNet(ps, window: 2), [null, 600, 600, null]);
    });
  });
}
