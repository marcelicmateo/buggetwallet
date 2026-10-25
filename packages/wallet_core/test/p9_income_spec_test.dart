// Stage P9 spec tests, pure half: detection of recurring income, landing, computePeriod (expected / landed income).
// Written from docs/context/P9_SPEC.md only. All data is SYNTHETIC (made-up payees, amounts).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

/// A bank row of [desc]; [cents] > 0 is money in, < 0 money out.
Tx row(String date, int cents,
        {String desc = 'Quorvant Payout', String? id, String currency = 'EUR', bool manual = false, bool deleted = false}) =>
    Tx(
      id: id ?? 'p9-${_seq++}',
      source: manual ? 'manual' : 'pbz',
      date: date,
      amount: cents,
      currency: currency,
      bankType: 'Ostalo',
      description: desc,
      manual: manual,
      deleted: deleted,
    );

CategorizedTx cat(Tx t, String category) => CategorizedTx(t, category, kindOf(category));

String keyOf(String desc) => merchantKey(row('2026-01-01', 100, desc: desc));

final quorvant = keyOf('Quorvant Payout');
final zorblex = keyOf('Zorblex Club');

/// Inflow rows of [desc] starting on [first], each [gaps] days after the one before.
List<CategorizedTx> inflows(String first, List<int> gaps,
    {String desc = 'Quorvant Payout', int cents = 30000, String category = 'Extra income', String currency = 'EUR'}) {
  var d = first;
  final out = [cat(row(d, cents, desc: desc, currency: currency), category)];
  for (final g in gaps) {
    d = addDays(d, g);
    out.add(cat(row(d, cents, desc: desc, currency: currency), category));
  }
  return out;
}

List<RecurringBill> detect(List<CategorizedTx> rows, [String today = '2026-03-20']) => detectRecurring(rows, today: today, currency: 'EUR');

RecurringBill income(
  String nextDue,
  int cents, {
  int interval = 30,
  int? min,
  int? max,
  String status = 'confirmed',
  String? lastPaidTx,
  String? payee,
  String id = 'recin:quorvant_payout',
}) =>
    RecurringBill(
      id: id,
      payee: payee ?? quorvant,
      label: 'Quorvant Payout',
      category: 'Extra income',
      expectedAmount: cents,
      intervalDays: interval,
      nextDue: nextDue,
      status: status,
      lastPaidTx: lastPaidTx,
      minAmount: min,
      maxAmount: max,
      direction: 'in',
    );

List<CategorizedTx> outflows() => [
      for (final d in ['2026-01-10', '2026-02-10', '2026-03-10']) cat(row(d, -2000, desc: 'Zorblex Club'), 'Shopping'),
    ];

void main() {
  test('the test payee keys are what the incomes below use', () {
    expect(quorvant, 'quorvant_payout');
    expect(zorblex, 'zorblex_club');
  });

  group('RecurringBill.isIncome', () {
    test('direction in is an income; null and out are bills', () {
      expect(income('2026-03-10', 30000).isIncome, isTrue);
      const plain = RecurringBill(id: 'rec:a', payee: 'a', label: 'A', category: 'Shopping', expectedAmount: 100, nextDue: '2026-03-10');
      expect(plain.isIncome, isFalse);
      const out = RecurringBill(
          id: 'rec:a', payee: 'a', label: 'A', category: 'Shopping', expectedAmount: 100, nextDue: '2026-03-10', direction: 'out');
      expect(out.isIncome, isFalse);
    });
  });

  group('detectRecurring: income', () {
    test('three monthly inflows of kind extra give one income candidate recin:<payee>', () {
      final c = detect(inflows('2026-01-10', [31, 28]));
      expect(c, hasLength(1));
      final b = c.single;
      expect(b.id, 'recin:quorvant_payout');
      expect(b.payee, quorvant);
      expect(b.isIncome, isTrue);
      expect(b.direction, 'in');
      expect(b.status, 'candidate');
      expect(b.expectedAmount, 30000);
      expect(b.intervalDays, 30);
      expect(b.nextDue, '2026-04-09');
      expect(b.category, 'Extra income');
    });

    test('row minimum minus one: two monthly inflows give nothing', () {
      expect(detect(inflows('2026-02-10', [28])), isEmpty);
    });

    test('weekly: four inflows 7 days apart are an income, three are not', () {
      final four = detect(inflows('2026-02-20', [7, 7, 7]));
      expect(four.single.intervalDays, 7);
      expect(four.single.id, 'recin:quorvant_payout');
      expect(detect(inflows('2026-02-27', [7, 7])), isEmpty);
    });

    test('weekly tolerance is one day: gaps 8 and 6 pass, a gap of 9 or 5 breaks the chain', () {
      expect(detect(inflows('2026-02-10', [8, 6, 7])).single.intervalDays, 7);
      expect(detect(inflows('2026-02-10', [9, 7, 7])), isEmpty);
      expect(detect(inflows('2026-02-10', [7, 5, 7])), isEmpty);
    });

    test('the 10 percent band holds for incomes: 33000 around 30000 passes, 33001 does not', () {
      List<CategorizedTx> withLast(int last) => [
            cat(row('2026-01-10', 30000), 'Extra income'),
            cat(row('2026-02-10', 30000), 'Extra income'),
            cat(row('2026-03-10', last), 'Extra income'),
          ];
      expect(detect(withLast(33000)), hasLength(1));
      expect(detect(withLast(33001)), isEmpty);
      expect(detect(withLast(27000)), hasLength(1));
      expect(detect(withLast(26999)), isEmpty);
    });

    test('salary-kind inflows are not detected', () {
      expect(detect(inflows('2026-01-10', [31, 28], desc: 'Acme Payroll', category: 'Salary')), isEmpty);
    });

    test('internal transfer inflows are not detected', () {
      expect(detect(inflows('2026-01-10', [31, 28], category: 'Internal transfer')), isEmpty);
    });

    test('foreign currency inflows and hand-added inflows are not detected', () {
      expect(detect(inflows('2026-01-10', [31, 28], currency: 'USD')), isEmpty);
      final manual = [
        for (final d in ['2026-01-10', '2026-02-10', '2026-03-10']) cat(row(d, 30000, manual: true), 'Extra income'),
      ];
      expect(detect(manual), isEmpty);
    });

    test('deleted inflows do not count', () {
      final rows = inflows('2026-01-10', [31, 28]);
      final gone = cat(row('2026-03-10', 30000, deleted: true), 'Extra income');
      expect(detect([rows[0], rows[1], gone]), isEmpty);
    });

    test('a one-off inflow of the same payee between the regular ones breaks the chain', () {
      final rows = [
        ...inflows('2026-01-10', [31, 28]),
        cat(row('2026-03-14', 30000), 'Extra income')
      ];
      expect(detect(rows), isEmpty);
    });

    test('bills detection is unchanged: outflows give rec:<payee> with no income direction', () {
      final c = detect(outflows());
      expect(c.single.id, 'rec:zorblex_club');
      expect(c.single.isIncome, isFalse);
      expect(c.single.expectedAmount, 2000);
    });

    test('inflows never produce a bill and outflows never produce an income', () {
      expect(detect(inflows('2026-01-10', [31, 28])).where((b) => !b.isIncome), isEmpty);
      expect(detect(outflows()).where((b) => b.isIncome), isEmpty);
    });

    test('a payee with both a bill and an income gets rec:<payee> and recin:<payee>', () {
      final rows = [
        ...outflows(),
        ...inflows('2026-01-12', [31, 28], desc: 'Zorblex Club', cents: 45000),
      ];
      final c = detect(rows);
      expect(c.map((b) => b.id).toSet(), {'rec:zorblex_club', 'recin:zorblex_club'});
      final bill = c.singleWhere((b) => b.id == 'rec:zorblex_club');
      final inc = c.singleWhere((b) => b.id == 'recin:zorblex_club');
      expect((bill.isIncome, bill.expectedAmount), (false, 2000));
      expect((inc.isIncome, inc.expectedAmount), (true, 45000));
    });

    test('the result is the same whatever the input order', () {
      final rows = inflows('2026-01-10', [31, 28]);
      final a = detect(rows), b = detect(rows.reversed.toList());
      expect(a.map((x) => x.id), b.map((x) => x.id));
      expect(a.single.nextDue, b.single.nextDue);
      expect(a.single.expectedAmount, b.single.expectedAmount);
    });
  });

  group('planRecurringPayments: income lands on a positive row', () {
    RecurringPayments plan(List<RecurringBill> bills, List<Tx> rows) => planRecurringPayments(bills, rows, currency: 'EUR');

    test('a positive row of the payee within tolerance of nextDue lands it', () {
      final p = plan([income('2026-03-20', 30000)], [row('2026-03-19', 31000, id: 'in1')]);
      expect(p.paidBy['recin:quorvant_payout']?.id, 'in1');
    });

    test('tolerance is 3 days for a monthly income: 03-23 lands it, 03-24 does not', () {
      expect(plan([income('2026-03-20', 30000)], [row('2026-03-23', 30000, id: 'x')]).paidBy, isNotEmpty);
      expect(plan([income('2026-03-20', 30000)], [row('2026-03-24', 30000, id: 'x')]).paidBy, isEmpty);
    });

    test('an outflow of the payee does not land an income', () {
      expect(plan([income('2026-03-20', 30000)], [row('2026-03-20', -30000)]).paidBy, isEmpty);
    });

    test('a row of another payee never lands it, whatever the amount', () {
      expect(plan([income('2026-03-20', 30000)], [row('2026-03-20', 30000, desc: 'Other Employer')]).paidBy, isEmpty);
    });

    test('an amount outside the band does not land it; a range widens what lands', () {
      expect(plan([income('2026-03-20', 30000)], [row('2026-03-20', 40000)]).paidBy, isEmpty);
      expect(plan([income('2026-03-20', 30000, min: 20000, max: 40000)], [row('2026-03-20', 40000, id: 'r')]).paidBy, isNotEmpty);
      expect(plan([income('2026-03-20', 30000, min: 20000, max: 40000)], [row('2026-03-20', 40001)]).paidBy, isEmpty);
    });

    test('a bill of the same payee is not paid by an inflow', () {
      const bill = RecurringBill(
          id: 'rec:quorvant_payout',
          payee: 'quorvant_payout',
          label: 'Q',
          category: 'Shopping',
          expectedAmount: 30000,
          nextDue: '2026-03-20',
          status: 'confirmed');
      expect(plan([bill], [row('2026-03-20', 30000)]).paidBy, isEmpty);
    });
  });

  group('computePeriod with recurring income', () {
    // Period 2026-02-15 .. 2026-03-15; today 2026-03-01.
    final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
    PeriodBudget period(List<RecurringBill> bills, {List<CategorizedTx> txs = const [], String today = '2026-03-01', WalletSettings? s}) =>
        computePeriod(txs, s ?? st, const [], today, bills: bills, table: CategoryTable.builtIn);

    CategorizedTx landed(String date, int cents, {String desc = 'Quorvant Payout', String id = 'land', String currency = 'EUR'}) =>
        cat(row(date, cents, desc: desc, id: id, currency: currency), 'Extra income');

    final base = period(const []);

    test('baseline has no income lines', () {
      expect(base.landedIncome, 0);
      expect(base.expectedIncome, isEmpty);
    });

    test('expected before landing: flexBudget unchanged, listed in expectedIncome, never added', () {
      final p = period([income('2026-03-10', 30000)]);
      expect(p.flexBudget, base.flexBudget);
      expect(p.landedIncome, 0);
      expect(p.expectedIncome, hasLength(1));
      final e = p.expectedIncome.single;
      expect(e.bill.id, 'recin:quorvant_payout');
      expect(e.due, '2026-03-10');
      expect(e.amount, 30000);
    });

    test('an income reserves nothing', () {
      final p = period([income('2026-03-10', 30000)]);
      expect(p.reservedBills, 0);
      expect(p.remaining, base.remaining);
    });

    test('a range shows its low end as expected', () {
      final p = period([income('2026-03-10', 30000, min: 20000, max: 40000)]);
      expect(p.expectedIncome.single.amount, 20000);
      expect(p.flexBudget, base.flexBudget);
    });

    test('an income due on payday is not listed for this period, one the day before is', () {
      expect(period([income('2026-03-15', 30000)]).expectedIncome, isEmpty);
      expect(period([income('2026-03-14', 30000)]).expectedIncome, hasLength(1));
    });

    test('after landing: flexBudget plus the ACTUAL landed amount, not the expected one', () {
      final bill = income('2026-04-09', 30000, lastPaidTx: 'land'); // refreshed: next cycle, last row recorded
      final p = period([bill], txs: [landed('2026-03-01', 31250)]);
      expect(p.landedIncome, 31250);
      expect(p.flexBudget, base.flexBudget + 31250);
      expect(p.expectedIncome, isEmpty);
    });

    test('landed income raises the money for spending; spent is unchanged and the rest follows', () {
      final spend = cat(row('2026-02-20', -4000, desc: 'Zorblex Club'), 'Shopping');
      final p = period([income('2026-04-09', 30000, lastPaidTx: 'land')], txs: [landed('2026-03-01', 30000), spend]);
      final q = period(const [], txs: [spend]);
      expect(p.spent, q.spent);
      expect(p.remaining, q.remaining + 30000);
      expect(p.planDaily, ((q.flexBudget + 30000) / q.length).round());
    });

    test('a landed row of another payee is not counted', () {
      final p = period([income('2026-03-10', 30000)], txs: [landed('2026-03-01', 30000, desc: 'Other Employer')]);
      expect(p.landedIncome, 0);
      expect(p.flexBudget, base.flexBudget);
    });

    test('an unconfirmed (candidate) income does not count a landed row', () {
      final p = period([income('2026-03-10', 30000, status: 'candidate')], txs: [landed('2026-03-01', 30000)]);
      expect(p.landedIncome, 0);
      expect(p.flexBudget, base.flexBudget);
      expect(p.expectedIncome, isEmpty);
    });

    test('a dismissed income does not count and is not listed', () {
      final p = period([income('2026-03-10', 30000, status: 'dismissed')], txs: [landed('2026-03-01', 30000)]);
      expect(p.landedIncome, 0);
      expect(p.flexBudget, base.flexBudget);
      expect(p.expectedIncome, isEmpty);
    });

    test('a foreign currency row of the payee is not counted', () {
      final p = period([income('2026-03-10', 30000)], txs: [landed('2026-03-01', 30000, currency: 'USD')]);
      expect(p.landedIncome, 0);
      expect(p.flexBudget, base.flexBudget);
    });

    test('a transfer row of the payee is not counted', () {
      final p = period([income('2026-03-10', 30000)], txs: [cat(row('2026-03-01', 30000), 'Internal transfer')]);
      expect(p.landedIncome, 0);
      expect(p.flexBudget, base.flexBudget);
    });

    test('a salary-kind row of the payee is not counted', () {
      final p = period([income('2026-03-10', 30000)], txs: [cat(row('2026-03-01', 30000), 'Salary')]);
      expect(p.landedIncome, 0);
    });

    test('an outflow of the payee is not counted', () {
      final p = period([income('2026-03-10', 30000)], txs: [cat(row('2026-03-01', -3000), 'Extra income')]);
      expect(p.landedIncome, 0);
    });

    test('a deleted row of the payee is not counted', () {
      final gone = cat(row('2026-03-01', 30000, deleted: true), 'Extra income');
      expect(period([income('2026-03-10', 30000)], txs: [gone]).landedIncome, 0);
    });

    test('a row dated before the period start is not counted', () {
      expect(period([income('2026-03-10', 30000)], txs: [landed('2026-02-14', 30000)]).landedIncome, 0);
    });

    test('a row dated after payday counts in the next period, not this one', () {
      final bill = income('2026-04-14', 30000, lastPaidTx: 'land');
      final onPayday = landed('2026-03-15', 30000);
      // Today is past payday (03-15): the old period ends on 03-14, the row on payday belongs to the next one.
      final old = period([bill], txs: [onPayday], today: '2026-03-20');
      expect(old.landedIncome, 0);
      expect(old.flexBudget, period(const [], today: '2026-03-20').flexBudget);
      final next = period([bill],
          txs: [onPayday],
          today: '2026-03-20',
          s: WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-03-15', 'paydayDay': 15}));
      expect(next.landedIncome, 30000);
    });

    test('two landed rows of the payee add up; extras keep every row, the one-off stays out of landedIncome', () {
      final other = landed('2026-02-25', 5000, desc: 'Some Gift', id: 'gift');
      final p = period([income('2026-04-09', 30000, lastPaidTx: 'land')],
          txs: [landed('2026-02-20', 30000), landed('2026-03-01', 1500, id: 'l2'), other]);
      // Lead decision (P9 review): only rows that fit the income's band land it; the 1500 row is a one-off for the goals.
      expect(p.landedIncome, 30000);
      expect(p.flexBudget, base.flexBudget + 30000);
      expect(p.extras, 36500, reason: 'extras still lists every extra row, the goals path subtracts landedIncome');
      expect(p.extras - p.landedIncome, 6500, reason: 'what goes into goals is only the one-offs');
    });

    test('flexBudget is raised once: by the landed amount, not by landed plus extras', () {
      final p = period([income('2026-04-09', 30000, lastPaidTx: 'land')], txs: [landed('2026-03-01', 30000)]);
      expect(p.flexBudget - base.flexBudget, 30000);
    });

    test('two confirmed incomes of different payees count separately', () {
      final other = income('2026-04-09', 10000, payee: zorblex, id: 'recin:zorblex_club');
      final p = period([income('2026-04-09', 30000), other],
          txs: [landed('2026-03-01', 30000), landed('2026-02-28', 9000, desc: 'Zorblex Club', id: 'z')]);
      expect(p.landedIncome, 39000);
      // A row dated after today has not landed yet (rows count up to today).
      final later = period([income('2026-04-09', 30000), other],
          txs: [landed('2026-03-01', 30000), landed('2026-03-02', 9000, desc: 'Zorblex Club', id: 'z')]);
      expect(later.landedIncome, 30000);
    });

    test('identity: no confirmed income gives every number as today', () {
      void same(PeriodBudget a, PeriodBudget b) {
        expect(a.flexBudget, b.flexBudget);
        expect(a.income, b.income);
        expect(a.extras, b.extras);
        expect(a.received, b.received);
        expect(a.spent, b.spent);
        expect(a.spentToday, b.spentToday);
        expect(a.remaining, b.remaining);
        expect(a.allowanceToday, b.allowanceToday);
        expect(a.allowanceTomorrow, b.allowanceTomorrow);
        expect(a.safeToday, b.safeToday);
        expect(a.planDaily, b.planDaily);
        expect(a.reservedBills, b.reservedBills);
        expect(a.dueCycles.length, b.dueCycles.length);
        expect(a.dueBills.length, b.dueBills.length);
        expect(a.lowIncome, b.lowIncome);
        expect(a.landedIncome, b.landedIncome);
        expect(a.expectedIncome.length, b.expectedIncome.length);
      }

      final txs = [landed('2026-03-01', 30000), cat(row('2026-02-20', -4000, desc: 'Zorblex Club'), 'Shopping')];
      final without = period(const [], txs: txs);
      same(period([income('2026-03-10', 30000, status: 'candidate')], txs: txs), without);
      same(period([income('2026-03-10', 30000, status: 'dismissed')], txs: txs), without);
      expect(without.landedIncome, 0);
    });

    test('an ordinary bill next to an income: the bill still reserves, the income only adds when landed', () {
      const bill = RecurringBill(
          id: 'rec:zorblex_club',
          payee: 'zorblex_club',
          label: 'Zorblex Club',
          category: 'Shopping',
          expectedAmount: 1000,
          nextDue: '2026-03-05',
          status: 'confirmed');
      final p = period([bill, income('2026-04-09', 30000, lastPaidTx: 'land')], txs: [landed('2026-03-01', 30000)]);
      expect(p.reservedBills, 1000);
      expect(p.flexBudget, base.flexBudget - 1000 + 30000);
    });
  });
}
