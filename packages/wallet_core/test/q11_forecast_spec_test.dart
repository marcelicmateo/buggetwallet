// Stage Q11 spec tests: forecastToPayday. Starts from today's home-currency bank balance, subtracts each unpaid due bill
// occurrence (DueCycle) and planned cost on its date, adds expected income (IncomeCycle) on its date; never guesses daily
// spending. Written from docs/context/STAGE_Q_PLAN.md Q11 (+ Q5 for the trust rule) only. SYNTHETIC data.
// API: forecastToPayday(startCents, today, payday, cycles, planned, incomes, bills) -> List<ForecastPoint(date, cents, cause)>,
// balanceWarnings(...) -> BalanceWarning(kind belowNow|goesBelow|checkBalance).
// The tests read the result only through _at(): the balance after all events dated on or before a day.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _today = '2026-03-10';
const _payday = '2026-03-20';

RecurringBill _bill(int amount, String due, {String? direction}) => RecurringBill(
    id: 'r-$due-$amount',
    payee: 'synthpayee',
    label: 'Synth bill',
    category: 'Shopping',
    expectedAmount: amount,
    nextDue: due,
    status: direction == 'in' ? 'in:confirmed' : 'confirmed',
    direction: direction);

DueCycle _cycle(int amount, String due) => DueCycle(bill: _bill(amount, due), due: due, reserve: amount, paid: 0);
IncomeCycle _income(int amount, String due) => IncomeCycle(bill: _bill(amount, due, direction: 'in'), due: due, amount: amount);
PlannedCost _planned(int amount, String date) => PlannedCost(
    id: 'p-$date-$amount',
    title: 'Synth fee',
    date: date,
    amount: amount,
    category: 'Shopping',
    source: PlannedSource.manual,
    status: PlannedStatus.open);

List<ForecastPoint> _fc({
  int start = 100000,
  List<DueCycle> cycles = const [],
  List<PlannedCost> planned = const [],
  List<IncomeCycle> incomes = const [],
  String today = _today,
  String payday = _payday,
}) =>
    forecastToPayday(startCents: start, today: today, payday: payday, cycles: cycles, planned: planned, incomes: incomes, bills: const []);

/// The balance after every event dated on or before [day]; the start value before the first event.
int _at(List<ForecastPoint> f, String day, {int start = 100000}) {
  var v = start;
  for (final p in f) {
    if (p.date.compareTo(day) <= 0) v = p.cents;
  }
  return v;
}

void main() {
  test('no events: the balance stays at the start to the end', () {
    final f = _fc();
    expect(_at(f, '2026-03-19'), 100000);
    for (final p in f) {
      expect(p.cents, 100000);
    }
  });

  test('a bill drops the balance on its due date, not before', () {
    final f = _fc(cycles: [_cycle(30000, '2026-03-14')]);
    expect(_at(f, '2026-03-13'), 100000);
    expect(_at(f, '2026-03-14'), 70000);
    expect(_at(f, '2026-03-19'), 70000);
  });

  test('a planned cost drops the balance on its date', () {
    final f = _fc(planned: [_planned(4500, '2026-03-12')]);
    expect(_at(f, '2026-03-11'), 100000);
    expect(_at(f, '2026-03-12'), 95500);
  });

  test('expected income raises the balance on its date', () {
    final f = _fc(incomes: [_income(25000, '2026-03-18')]);
    expect(_at(f, '2026-03-17'), 100000);
    expect(_at(f, '2026-03-18'), 125000);
  });

  test('events combine in date order; several on one day apply together', () {
    final f = _fc(
      cycles: [_cycle(30000, '2026-03-14'), _cycle(1000, '2026-03-16')],
      planned: [_planned(4500, '2026-03-14')],
      incomes: [_income(25000, '2026-03-16')],
    );
    expect(_at(f, '2026-03-14'), 100000 - 30000 - 4500);
    expect(_at(f, '2026-03-16'), 100000 - 30000 - 4500 - 1000 + 25000);
    expect(_at(f, '2026-03-19'), 89500);
    // dates never go backwards
    for (var i = 1; i < f.length; i++) {
      expect(f[i].date.compareTo(f[i - 1].date), greaterThanOrEqualTo(0));
    }
  });

  test('the balance can go negative: the forecast shows it, it does not clamp', () {
    final f = _fc(start: 10000, cycles: [_cycle(30000, '2026-03-14')]);
    expect(_at(f, '2026-03-14', start: 10000), -20000);
  });

  test('payday boundary: an event on the payday itself belongs to the next period and is left out; the day before is in', () {
    final f = _fc(cycles: [_cycle(30000, '2026-03-19'), _cycle(77000, _payday)]);
    expect(_at(f, '2026-03-19'), 70000);
    expect(_at(f, _payday), 70000);
    expect(_at(f, '2026-03-31'), 70000);
  });

  test('an event dated today counts; one before today (already due, not paid) is not invented on a past date', () {
    final f = _fc(planned: [_planned(2000, _today)]);
    expect(_at(f, _today), 98000);
  });

  test('payday on or before today: nothing to forecast beyond the start', () {
    final f = _fc(today: '2026-03-20', payday: '2026-03-20', cycles: [_cycle(30000, '2026-03-20')]);
    for (final p in f) {
      expect(p.cents, 100000);
    }
  });

  test('payday across a month and year end', () {
    final f = _fc(today: '2026-12-28', payday: '2027-01-15', cycles: [_cycle(5000, '2027-01-02'), _cycle(9000, '2027-01-15')]);
    expect(_at(f, '2027-01-02'), 95000);
    expect(_at(f, '2027-01-14'), 95000);
    expect(_at(f, '2027-01-15'), 95000);
  });

  test('no daily-spending guess: with no events the line is flat whatever the days left', () {
    final f = _fc(today: '2026-03-01', payday: '2026-03-31');
    expect({for (final p in f) p.cents}, {100000});
  });

  test('foreign currencies are left out: bills paid in another currency never reach dueCycles(currency: home)', () {
    final bill = _bill(30000, '2026-03-14');
    const usdRow = CategorizedTx(
        Tx(id: 'u1', source: 'pbz', date: '2026-03-14', amount: -30000, currency: 'USD', description: 'Synth payee'),
        'Shopping',
        BudgetKind.flex);
    final due = dueCycles([bill], [usdRow], '2026-03-10', _payday, currency: 'EUR');
    // the bill is still due (a USD row never pays it); what matters here is that the forecast is fed only home-currency money
    final f = _fc(cycles: due);
    expect(_at(f, '2026-03-19'), 70000);
  });

  test('overdue: a bill due before today is taken off today; overdue income is not counted on', () {
    final f = _fc(cycles: [_cycle(30000, '2026-03-05')], incomes: [_income(25000, '2026-03-06')]);
    expect(_at(f, _today), 70000);
    expect(_at(f, '2026-03-19'), 70000);
  });

  test('the first point is the start (today, no cause); other points name their cause', () {
    final f = _fc(cycles: [_cycle(30000, '2026-03-14')]);
    expect((f.first.date, f.first.cents, f.first.cause), (_today, 100000, null));
    expect(f.last.cause, 'Synth bill');
  });

  group('balanceWarnings (per account)', () {
    // Opened 9 days ago: trusted by its opening date alone (rows before the opening date are only used to attribute bills).
    const acc = Account(id: 'a1', name: 'Main', source: 'pbz', currency: 'EUR', opening: 10000, openingDate: '2026-03-01');
    const old = Account(id: 'a1', name: 'Main', source: 'pbz', currency: 'EUR', opening: 10000, openingDate: '2026-01-01');
    const other = Account(id: 'a2', name: 'Card', source: 'revolut', currency: 'EUR', opening: 500000, openingDate: '2026-03-01');

    RecurringBill billPaidFrom(String? lastPaidTx, int amount, String due) => RecurringBill(
        id: 'rb-$due',
        payee: 'synthpayee',
        label: 'Synth rent',
        category: 'Shopping',
        expectedAmount: amount,
        nextDue: due,
        status: 'confirmed',
        lastPaidTx: lastPaidTx);

    List<BalanceWarning> warn({
      required List<Account> accounts,
      required List<Tx> rows,
      required List<DueCycle> cycles,
      List<IncomeCycle> incomes = const [],
      Map<String, BankCheck>? checks,
      String today = _today,
    }) =>
        balanceWarnings(
            accounts: accounts,
            balances: accountBalances(accounts, rows),
            rows: rows,
            cycles: cycles,
            incomes: incomes,
            today: today,
            payday: _payday,
            checks: checks ?? const {},
            currency: 'EUR');

    DueCycle cycleOf(RecurringBill b, int amount) => DueCycle(bill: b, due: b.nextDue, reserve: amount, paid: 0);
    const paidRow = Tx(id: 'old-pay', source: 'pbz', date: '2026-02-12', amount: -30000, description: 'Synth rent');

    test('a bill whose last paying row came from this account\'s source takes it below zero: goesBelow at the bill', () {
      final b = billPaidFrom('old-pay', 30000, '2026-03-14');
      final w = warn(accounts: [acc], rows: [paidRow], cycles: [cycleOf(b, 30000)]);
      expect(w.single.kind, BalanceWarningKind.goesBelow);
      expect(w.single.date, '2026-03-14');
      expect(w.single.cause, 'Synth rent');
    });
    test('a bill with no known paying row is never charged to an account', () {
      final b = billPaidFrom(null, 30000, '2026-03-14');
      expect(warn(accounts: [acc], rows: const [], cycles: [cycleOf(b, 30000)]), isEmpty);
    });
    test('a bill last paid from another source is not charged to this account', () {
      final b = billPaidFrom('old-pay', 30000, '2026-03-14');
      final w = warn(
          accounts: [acc, other],
          rows: [const Tx(id: 'old-pay', source: 'revolut', date: '2026-02-12', amount: -30000, description: 'Synth rent')],
          cycles: [cycleOf(b, 30000)]);
      expect(w, isEmpty, reason: 'a1 is not charged; a2 has plenty');
    });
    test('planned costs are never attributed to an account', () {
      final w = balanceWarnings(
          accounts: [acc],
          balances: accountBalances([acc], const []),
          rows: const [],
          cycles: const [],
          planned: [_planned(50000, '2026-03-12')],
          incomes: const [],
          today: _today,
          payday: _payday,
          checks: const {},
          currency: 'EUR');
      expect(w, isEmpty);
    });
    test('already below zero now: belowNow with the balance', () {
      final rows = [const Tx(id: 'x1', source: 'pbz', date: '2026-03-05', amount: -25000, description: 'Synth')];
      final w = warn(accounts: [acc], rows: rows, cycles: const []);
      expect(w.single.kind, BalanceWarningKind.belowNow);
      expect(w.single.cents, -15000);
    });
    test('untrusted balance (no check, opening long ago): checkBalance only, never a below-zero warning', () {
      final rows = [const Tx(id: 'x1', source: 'pbz', date: '2026-03-05', amount: -25000, description: 'Synth')];
      final w = warn(accounts: [old], rows: rows, cycles: const []);
      expect(w.single.kind, BalanceWarningKind.checkBalance);
    });
    test('a check 36 days old is untrusted: checkBalance; 35 days old is trusted', () {
      const old36 = {'a1': BankCheck(date: '2026-02-02', bankCents: 10000, appCents: 10000)};
      const old35 = {'a1': BankCheck(date: '2026-02-03', bankCents: 10000, appCents: 10000)};
      expect(warn(accounts: [old], rows: const [], cycles: const [], checks: old36).single.kind, BalanceWarningKind.checkBalance);
      expect(warn(accounts: [old], rows: const [], cycles: const [], checks: old35), isEmpty);
    });
    test('cash accounts and other-currency accounts get no warning', () {
      const cash = Account(id: 'c1', name: 'Cash', currency: 'EUR', opening: -500, openingDate: '2026-01-01');
      const usd = Account(id: 'u1', name: 'USD', source: 'pbz', currency: 'USD', opening: -500, openingDate: '2026-01-01');
      expect(warn(accounts: [cash, usd], rows: const [], cycles: const [], checks: const {}), isEmpty);
    });
    test('income attributed by its landing row can keep the account above zero', () {
      final b = billPaidFrom('old-pay', 30000, '2026-03-14');
      const inc = RecurringBill(
          id: 'ri',
          payee: 'synthpay',
          label: 'Synth pay',
          category: 'Extra income',
          expectedAmount: 40000,
          nextDue: '2026-03-12',
          status: 'in:confirmed',
          direction: 'in',
          lastPaidTx: 'old-in');
      const inRow = Tx(id: 'old-in', source: 'pbz', date: '2026-02-12', amount: 40000, description: 'Synth pay');
      final w = warn(
          accounts: [acc],
          rows: [paidRow, inRow],
          cycles: [cycleOf(b, 30000)],
          incomes: [const IncomeCycle(bill: inc, due: '2026-03-12', amount: 40000)]);
      expect(w.where((x) => x.kind == BalanceWarningKind.goesBelow), isEmpty);
    });
  });
}
