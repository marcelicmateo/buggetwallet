// Q11 balance forecast to payday and the Q5 red warnings (docs/context/STAGE_Q_PLAN.md). Exact cents, no daily
// spending guess, exact attribution. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _today = '2026-01-20', _payday = '2026-02-15';

RecurringBill _bill(String id,
        {String label = 'Synthetic bill', String? lastPaidTx, String payee = 'synthetic_bill', bool income = false}) =>
    RecurringBill(
      id: id,
      payee: payee,
      label: label,
      category: income ? 'Extra income' : 'Shopping',
      expectedAmount: 1000,
      nextDue: '2026-01-25',
      status: 'confirmed',
      lastPaidTx: lastPaidTx,
      direction: income ? RecurringBill.directionIn : null,
    );

DueCycle _cycle(String id, String due, int reserve, {String? label, String? lastPaidTx}) =>
    DueCycle(bill: _bill(id, label: label ?? id, lastPaidTx: lastPaidTx), due: due, reserve: reserve, paid: 0);

IncomeCycle _income(String id, String due, int cents, {String? lastPaidTx}) =>
    IncomeCycle(bill: _bill(id, label: id, lastPaidTx: lastPaidTx, income: true), due: due, amount: cents);

PlannedCost _planned(String id, String date, int? cents,
        {PlannedStatus status = PlannedStatus.open, PlannedSource source = PlannedSource.manual, String? title}) =>
    PlannedCost(id: id, title: title ?? id, date: date, amount: cents, status: status, source: source);

List<ForecastPoint> _f(
        {int start = 100000,
        List<DueCycle> cycles = const [],
        List<PlannedCost> planned = const [],
        List<IncomeCycle> incomes = const []}) =>
    forecastToPayday(
        startCents: start, today: _today, payday: _payday, cycles: cycles, planned: planned, incomes: incomes, bills: const []);

Account _acc(String id, String? source, {String currency = 'EUR', String openingDate = '2026-01-10', int opening = 0}) =>
    Account(id: id, name: 'Synthetic $id', source: source, currency: currency, opening: opening, openingDate: openingDate);

AccountBalance _bal(Account a, int cents, {String? duplicateOf}) =>
    AccountBalance(account: a, balance: cents, rowsCounted: 0, duplicateOf: duplicateOf);

void main() {
  group('forecastToPayday', () {
    test('no events: the start point only', () {
      expect(_f(), [const ForecastPoint(_today, 100000, null)]);
    });

    test('bills on their date (an overdue one today), planned costs and incomes; payday and past dates left out', () {
      final f = _f(cycles: [
        _cycle('rent', '2026-01-25', 30000),
        _cycle('late', '2026-01-10', 5000), // overdue, unpaid: today
        _cycle('paid', '2026-01-28', 0), // nothing left to pay
        _cycle('onPayday', _payday, 7000), // the next period's
        _cycle('after', '2026-03-01', 7000), // a long bill due after payday
      ], planned: [
        _planned('trip', '2026-01-28', 20000),
        _planned('gone', '2026-01-19', 999), // before today: in spending already
        _planned('closed', '2026-01-30', 999, status: PlannedStatus.paid),
        _planned('noAmount', '2026-01-30', null),
        _planned('payday', _payday, 999),
      ], incomes: [
        _income('gig', '2026-02-01', 50000),
        _income('lateGig', '2026-01-18', 9999), // overdue income: never counted on
        _income('paydayGig', _payday, 9999),
      ]);
      expect([
        for (final p in f) (p.date, p.cents, p.cause, p.delta)
      ], [
        (_today, 100000, null, 0),
        (_today, 95000, 'late', -5000),
        ('2026-01-25', 65000, 'rent', -30000),
        ('2026-01-28', 45000, 'trip', -20000),
        ('2026-02-01', 95000, 'gig', 50000),
      ]);
      expect(f[2].causeId, 'rent');
      expect(f[3].causeId, 'trip');
    });

    test('one day: money out before money in', () {
      final f = _f(start: 1000, cycles: [_cycle('b', '2026-01-25', 3000)], incomes: [_income('i', '2026-01-25', 5000)]);
      expect([for (final p in f) p.cents], [1000, -2000, 3000]);
    });

    test('a bill slip its recurring cycle already holds is subtracted once', () {
      final key = merchantKey(const Tx(id: '', source: 'bill', date: '', amount: 0, description: 'Synthetic Power Co'));
      final b = RecurringBill(
          id: 'rec:power',
          payee: key,
          label: 'Power',
          category: 'Shopping',
          expectedAmount: 4000,
          nextDue: '2026-01-25',
          status: 'confirmed');
      final slip = _planned('bill:x', '2026-01-26', 4100, source: PlannedSource.bill, title: 'Synthetic Power Co');
      final f = forecastToPayday(
          startCents: 10000,
          today: _today,
          payday: _payday,
          cycles: [DueCycle(bill: b, due: '2026-01-25', reserve: 4000, paid: 0)],
          planned: [slip],
          incomes: const [],
          bills: [b]);
      expect([for (final p in f) p.cents], [10000, 6000]);
      // Without the cycle the slip counts.
      final alone = forecastToPayday(
          startCents: 10000, today: _today, payday: _payday, cycles: const [], planned: [slip], incomes: const [], bills: [b]);
      expect([for (final p in alone) p.cents], [10000, 5900]);
    });

    // Review fix 5: `bills` is required, so the slip of a cycle just paid (no longer in the cycles) is known.
    test('the slip of a bill cycle just paid is not subtracted again', () {
      final key = merchantKey(const Tx(id: '', source: 'bill', date: '', amount: 0, description: 'Synthetic Power Co'));
      // Paid on 25 January: nextDue moved on to 24 February (after payday 15 February), so no cycle is due.
      final b = RecurringBill(
          id: 'rec:power',
          payee: key,
          label: 'Power',
          category: 'Shopping',
          expectedAmount: 4000,
          nextDue: '2026-02-24',
          status: 'confirmed');
      final slip = _planned('bill:x', '2026-01-26', 4100, source: PlannedSource.bill, title: 'Synthetic Power Co');
      final f = forecastToPayday(
          startCents: 10000, today: _today, payday: _payday, cycles: const [], planned: [slip], incomes: const [], bills: [b]);
      expect([for (final p in f) p.cents], [10000]);
    });

    test('forecastAfterAllowance: the last point minus allowance × days left', () {
      final f = _f(cycles: [_cycle('rent', '2026-01-25', 30000)]);
      expect(forecastAfterAllowance(f, allowance: 1000, daysLeft: 26), 70000 - 26000);
      expect(forecastAfterAllowance(f, allowance: -5, daysLeft: 26), 70000);
      expect(forecastAfterAllowance(f, allowance: 1000, daysLeft: 0), 70000);
      expect(forecastAfterAllowance(const [], allowance: 1000, daysLeft: 1), -1000);
    });
  });

  group('balanceWarnings', () {
    final pbz = _acc('a1', 'pbz'), rev = _acc('a2', 'revolut'), cash = _acc('c', null);
    final rows = [
      const Tx(id: 'paidPbz', source: 'pbz', date: '2025-12-25', amount: -30000),
      const Tx(id: 'paidRev', source: 'revolut', date: '2025-12-25', amount: -1000),
      const Tx(id: 'landPbz', source: 'pbz', date: '2026-01-01', amount: 20000),
      const Tx(id: 'cashRow', source: 'manual', date: '2025-12-25', amount: -500, manual: true),
    ];

    List<BalanceWarning> w(List<AccountBalance> balances,
            {List<DueCycle> cycles = const [],
            List<IncomeCycle> incomes = const [],
            Map<String, BankCheck> checks = const {},
            List<Account>? accounts}) =>
        balanceWarnings(
            accounts: accounts ?? [for (final b in balances) b.account],
            balances: balances,
            rows: rows,
            cycles: cycles,
            incomes: incomes,
            today: _today,
            payday: _payday,
            checks: checks,
            currency: 'EUR');

    test('an untrusted balance only asks for a check, even when it is below zero', () {
      final stale = _acc('a1', 'pbz', openingDate: '2025-12-01'); // 50 days
      final out = w([_bal(stale, -100)]);
      expect(out.single.kind, BalanceWarningKind.checkBalance);
      expect(out.single.cents, isNull);
      // A check within 35 days that the rows match (−30000 + 20000 by 15 January) makes it trusted.
      final ok = w([_bal(stale, -100)], checks: {'a1': const BankCheck(date: '2026-01-15', bankCents: -10000, appCents: -10000)});
      expect(ok.single.kind, BalanceWarningKind.belowNow);
      expect(ok.single.cents, -100);
      // Review fix 1: a stored match the rows no longer give is not trusted.
      final stored = w([_bal(stale, -100)], checks: {'a1': const BankCheck(date: '2026-01-15', bankCents: 7, appCents: 7)});
      expect(stored.single.kind, BalanceWarningKind.checkBalance);
    });

    test('goes below zero on the bill paid from this account, with the cause', () {
      final out =
          w([_bal(pbz, 20000), _bal(rev, 20000)], cycles: [_cycle('rent', '2026-01-28', 30000, label: 'Rent', lastPaidTx: 'paidPbz')]);
      expect(out, hasLength(1));
      final x = out.single;
      expect((x.account.id, x.kind, x.date, x.cause, x.causeId, x.cents),
          ('a1', BalanceWarningKind.goesBelow, '2026-01-28', 'Rent', 'rent', -10000));
    });

    test('an income landing on this account before the bill keeps it above zero', () {
      final out = w([_bal(pbz, 20000)],
          cycles: [_cycle('rent', '2026-01-28', 30000, lastPaidTx: 'paidPbz')],
          incomes: [_income('gig', '2026-01-25', 20000, lastPaidTx: 'landPbz')]);
      expect(out, isEmpty);
    });

    test('attribution is exact: a bill with no known paying row, or paid from another account, or by hand, warns nowhere', () {
      expect(w([_bal(pbz, 100)], cycles: [_cycle('x', '2026-01-28', 30000)]), isEmpty);
      expect(w([_bal(pbz, 100)], cycles: [_cycle('x', '2026-01-28', 30000, lastPaidTx: 'paidRev')]), isEmpty);
      expect(w([_bal(pbz, 100)], cycles: [_cycle('x', '2026-01-28', 30000, lastPaidTx: 'cashRow')]), isEmpty);
      expect(w([_bal(pbz, 100)], cycles: [_cycle('x', '2026-01-28', 30000, lastPaidTx: 'notHere')]), isEmpty);
      // The same bill paid from Revolut warns on Revolut only.
      final out = w([_bal(pbz, 100), _bal(rev, 100)], cycles: [_cycle('x', '2026-01-28', 30000, lastPaidTx: 'paidRev')]);
      expect(out.single.account.id, 'a2');
    });

    test('below zero now; cash, other currencies, duplicates and deleted accounts get no warning', () {
      final usd = _acc('u', 'revolut', currency: 'USD');
      final dup = _acc('a9', 'pbz');
      const gone = Account(id: 'g', name: 'S', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-01-10', deleted: true);
      final out = w([_bal(pbz, -1), _bal(cash, -500), _bal(usd, -100), _bal(dup, -100, duplicateOf: 'a1'), _bal(gone, -100)]);
      expect([for (final x in out) (x.account.id, x.kind)], [('a1', BalanceWarningKind.belowNow)]);
    });

    test('exactly zero is not below zero; a bill due on payday is the next period', () {
      expect(w([_bal(pbz, 30000)], cycles: [_cycle('rent', '2026-01-28', 30000, lastPaidTx: 'paidPbz')]), isEmpty);
      expect(w([_bal(pbz, 0)]), isEmpty);
      expect(w([_bal(pbz, 100)], cycles: [_cycle('rent', _payday, 30000, lastPaidTx: 'paidPbz')]), isEmpty);
    });
  });
}
