// Stage NP: projectedReserves = what the next pay period will set aside. SYNTHETIC data only: invented payees and
// made-up amounts.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

String key(String desc) => merchantKey(Tx(id: 'k', source: 'pbz', date: '2026-01-01', amount: -1, description: desc));

NormalizedTransaction pay(String date, int cents, String desc) => n(date, -cents, 'POS plaćanje', desc);

RecurringBill bill(String id, String nextDue,
        {int amount = 5000,
        int interval = 30,
        String category = 'Shopping',
        String? payee,
        String? endsOn,
        String? lastPaidTx,
        String status = 'confirmed',
        String? direction}) =>
    RecurringBill(
        id: id,
        payee: payee ?? key('Payee $id'),
        label: 'Bill $id',
        category: category,
        expectedAmount: amount,
        intervalDays: interval,
        nextDue: nextDue,
        status: status,
        endsOn: endsOn,
        lastPaidTx: lastPaidTx,
        manual: true,
        direction: direction);

PlannedCost planned(String id, String date, int? amount,
        {String category = 'Shopping', PlannedSource source = PlannedSource.manual, String? title}) =>
    PlannedCost(
        id: id,
        title: title ?? 'Plan $id',
        date: date,
        amount: amount,
        category: category,
        source: source,
        sourceRef: source == PlannedSource.bill ? id.substring(5) : null);

WalletSettings settings(String start, {int payday = 10}) =>
    WalletSettings.fromMap({'salary': 300000, 'periodStart': start, 'paydayDay': payday});

PeriodReserves project(String start, String end, List<RecurringBill> bills,
        {List<PlannedCost> plans = const [], List<CategorizedTx> txs = const [], Map<String, String> aliases = const {}}) =>
    projectedReserves(
        start: start,
        end: end,
        bills: bills,
        txs: txs,
        planned: plans,
        currency: 'EUR',
        table: CategoryTable.builtIn,
        payeeAliases: aliases);

/// The period that runs from [start] on [start], with [bills] as they stand then.
PeriodBudget running(String start, List<RecurringBill> bills,
        {int payday = 10,
        List<PlannedCost> plans = const [],
        List<CategorizedTx> txs = const [],
        Map<String, String> aliases = const {}}) =>
    computePeriod(txs, settings(start, payday: payday), const [], start,
        bills: bills, planned: plans, table: CategoryTable.builtIn, payeeAliases: aliases);

List<String> cycleKeys(Iterable<DueCycle> cs) => [for (final c in cs) '${c.bill.id}@${c.due}'];

void main() {
  group('the key identity: the projection equals the period once it starts', () {
    late WalletRepo r;
    var now = DateTime.utc(2026, 10, 20, 12).millisecondsSinceEpoch;
    setUp(() {
      now = DateTime.utc(2026, 10, 20, 12).millisecondsSinceEpoch;
      r = WalletRepo.inMemory(now: () => now);
    });
    tearDown(() => r.close());

    ImportBatch batch(List<NormalizedTransaction> rows) => ImportBatch(source: 'pbz', transactions: rows);
    List<CategorizedTx> cats() {
      final cz = r.categorizer();
      return [for (final t in r.transactions()) cz.categorize(t)];
    }

    test('mixed bills, slips and planned costs: total and count match computePeriod on the new start', () {
      const start = '2026-11-10', today = '2026-10-20';
      final end = nextPayday(start, 10);
      expect(end, '2026-12-10');
      // Current period 10 Oct .. 10 Nov, today 20 Oct.
      final monthly = r.addRecurring(
          label: 'Zorblex', category: 'Shopping', amount: 5000, intervalDays: 30, firstDue: '2026-10-25', payee: key('Zorblex Club'));
      final weekly = r.addRecurring(
          label: 'Gym', category: 'Sport & fitness', amount: 1500, intervalDays: 7, firstDue: '2026-10-22', payee: key('Quorvant Gym'));
      final quarterly = r.addRecurring(
          label: 'Insurance',
          category: 'Car & transport',
          amount: 30000,
          intervalDays: 91,
          firstDue: '2026-11-01',
          payee: key('Brindle Cover'));
      final yearly = r.addRecurring(
          label: 'Licence',
          category: 'Car & transport',
          amount: 60000,
          intervalDays: 365,
          firstDue: '2027-03-01',
          payee: key('Tarnwick Roads'));
      final instalment = r.addRecurring(
          label: 'Bike',
          category: 'Shopping',
          amount: 20000,
          intervalDays: 30,
          firstDue: '2026-10-28',
          payee: key('Velomax Bikes'),
          instalments: 2);
      final fixed = r.addRecurring(
          label: 'Power',
          category: 'Bills & subscriptions',
          amount: 6000,
          intervalDays: 30,
          firstDue: '2026-10-15',
          payee: key('Lumora Power'));
      r.addRecurring(
          label: 'Side job',
          category: 'Extra income',
          amount: 50000,
          intervalDays: 30,
          firstDue: '2026-10-25',
          payee: key('Ostrel Studio'),
          direction: RecurringBill.directionIn);
      // History of the running period: the fixed bill's first cycle is already paid.
      r.importBatch(batch([pay('2026-10-15', 6000, 'Lumora Power'), pay('2026-10-18', 2500, 'Groceries Market')]));
      r.refreshRecurring(today);
      expect(r.recurringBills().singleWhere((b) => b.id == fixed).nextDue, '2026-11-14');

      final plans = [
        planned('p1', '2026-11-15', 4000), // reserves
        planned('p2', '2026-11-20', 90000, category: 'Rent'), // fixed category: covered by the plan
        planned('bill:aaa', '2026-11-25', 5000, source: PlannedSource.bill, title: 'Zorblex Club'), // the monthly bill's cycle holds it
        planned('bill:bbb', '2026-11-18', 2500, source: PlannedSource.bill, title: 'Nimbro Repairs'), // no recurring bill: reserves
        planned('p5', '2026-12-10', 1000), // on payday: next period's
        planned('p6', '2026-11-05', 1000), // this period's
        planned('p7', '2026-11-16', null), // no amount
      ];
      final projected = projectedReserves(
          start: start, end: end, bills: r.recurringBills(), txs: cats(), planned: plans, currency: 'EUR', table: r.categoryTable());
      // Monthly 24 Nov, weekly 12/19/26 Nov + 3 Dec, the instalment's last cycle 27 Nov, both long bills held; the fixed
      // bill is covered; the income never counts.
      expect(projected.total, 5000 + 4 * 1500 + 30000 + 60000 + 20000 + 4000 + 2500);
      expect(projected.count, 10);
      expect(cycleKeys(projected.cycles), [
        '$quarterly@2026-11-01',
        '$weekly@2026-11-12',
        '$weekly@2026-11-19',
        '$monthly@2026-11-24',
        '$weekly@2026-11-26',
        '$instalment@2026-11-27',
        '$weekly@2026-12-03',
        '$yearly@2027-03-01',
      ]);
      expect([for (final p in projected.planned) p.id], ['p1', 'bill:bbb']);

      // The period starts: every cycle due before the start is paid on its date (the fixed bill's next is 14 Nov).
      now = DateTime.utc(2026, 11, 10, 12).millisecondsSinceEpoch;
      r.importBatch(batch([
        pay('2026-10-22', 1500, 'Quorvant Gym'),
        pay('2026-10-25', 5000, 'Zorblex Club'),
        pay('2026-10-28', 20000, 'Velomax Bikes'),
        pay('2026-10-29', 1500, 'Quorvant Gym'),
        pay('2026-11-01', 30000, 'Brindle Cover'),
        pay('2026-11-05', 1500, 'Quorvant Gym'),
      ]));
      r.refreshRecurring(start);
      final p =
          computePeriod(cats(), settings(start), const [], start, bills: r.recurringBills(), planned: plans, table: r.categoryTable());
      expect(p.end, end);
      expect(p.beforePayday, projected.total);
      expect(p.beforePaydayCount, projected.count);
      expect([for (final c in p.reservedCycles) '${c.bill.id}:${c.reserve}']..sort(),
          [for (final c in projected.cycles) '${c.bill.id}:${c.reserve}']..sort());
      expect([for (final x in p.reservedPlannedRows) x.id], [for (final x in projected.planned) x.id]);
    });
  });

  group('edge cases', () {
    test('a monthly bill on the start and again on end - 1 of a 31-day period holds one cycle', () {
      const start = '2026-12-10';
      final end = nextPayday(start, 10);
      expect(end, '2027-01-10');
      final b = bill('m', '2026-11-10');
      expect(billOccurrences(b, start, '2027-01-09'), ['2026-12-10', '2027-01-09']);
      final pr = project(start, end, [b]);
      expect(cycleKeys(pr.cycles), ['m@2026-12-10']);
      expect(pr.total, 5000);
      final p = running(start, [b.copyWith(nextDue: '2026-12-10')]);
      expect((p.beforePayday, p.beforePaydayCount), (pr.total, pr.count));
    });

    test('a bill due exactly on the period end is not held', () {
      final pr = project('2026-11-10', '2026-12-10', [bill('m', '2026-12-10'), bill('w', '2026-12-10', interval: 7)]);
      expect(pr.count, 0);
      expect(pr.total, 0);
    });

    test('an overdue bill of the running period is assumed paid, not carried', () {
      // Weekly, overdue since 20 Oct: dueCycles alone would hold the overdue cycle too.
      final b = bill('w', '2026-10-20', amount: 1000, interval: 7);
      final pr = project('2026-11-10', '2026-12-10', [b, bill('m', '2026-10-12')]);
      expect(cycleKeys(pr.cycles), ['w@2026-11-10', 'm@2026-11-11', 'w@2026-11-17', 'w@2026-11-24', 'w@2026-12-01', 'w@2026-12-08']);
      expect(pr.total, 5 * 1000 + 5000);
      final p = running('2026-11-10', [b.copyWith(nextDue: '2026-11-10'), bill('m', '2026-11-11')]);
      expect((p.beforePayday, p.beforePaydayCount), (pr.total, pr.count));
    });

    test('a long bill already paid this period is still held for its next cycle', () {
      final row = ct('2026-10-01', -60000, 'Car & transport');
      final b = bill('y', '2027-10-01', amount: 60000, interval: 365, lastPaidTx: row.tx.id);
      final pr = project('2026-11-10', '2026-12-10', [b], txs: [row]);
      expect(cycleKeys(pr.cycles), ['y@2027-10-01']);
      expect(pr.total, 60000);
      final p = running('2026-11-10', [b], txs: [row]);
      expect((p.beforePayday, p.beforePaydayCount), (pr.total, pr.count));
    });

    test('a long bill in a fixed category is still held (never covered by a plan line)', () {
      final pr =
          project('2026-11-10', '2026-12-10', [bill('q', '2027-01-15', amount: 30000, interval: 91, category: 'Bills & subscriptions')]);
      expect(pr.total, 30000);
    });

    test('an income never sets anything aside, nor do unconfirmed or finished bills', () {
      final pr = project('2026-11-10', '2026-12-10', [
        bill('i', '2026-11-20', amount: 50000, category: 'Extra income', direction: RecurringBill.directionIn),
        bill('c', '2026-11-20', status: 'candidate'),
        bill('f', '2026-11-20', endsOn: '2026-09-01'),
      ]);
      expect(pr.count, 0);
      expect(pr.total, 0);
    });

    test('an instalment plan whose last cycle is in the running period holds nothing next period', () {
      // Last due 28 Oct, so endsBy = 12 Nov: the next date (27 Nov) is past it.
      final b = bill('e', '2026-10-28', amount: 20000, endsOn: '2026-10-28');
      final pr = project('2026-11-10', '2026-12-10', [b]);
      expect(pr.count, 0);
      final after = b.copyWith(nextDue: '2026-11-27');
      expect(after.finished, isTrue);
      final p = running('2026-11-10', [after]);
      expect((p.beforePayday, p.beforePaydayCount), (0, 0));
    });

    test('no bills and no planned costs: nothing', () {
      final pr = project('2026-11-10', '2026-12-10', const []);
      expect((pr.count, pr.total), (0, 0));
      expect(pr.cycles, isEmpty);
      expect(pr.planned, isEmpty);
    });

    test('a period across the end of January into February', () {
      const start = '2027-01-31';
      final end = nextPayday(start, settings(start, payday: 31).paydayDay);
      expect(end, '2027-02-28');
      final bills = [
        bill('m', '2026-12-31'), // 30 Jan, then 1 Mar: no cycle in this 28-day period
        bill('n', '2027-01-27', amount: 4000), // 26 Feb
        bill('w', '2027-01-30', amount: 700, interval: 7), // 6, 13, 20, 27 Feb
      ];
      final pr = project(start, end, bills, plans: [planned('p', '2027-02-27', 1200), planned('q', '2027-02-28', 900)]);
      expect(cycleKeys(pr.cycles), ['w@2027-02-06', 'w@2027-02-13', 'w@2027-02-20', 'n@2027-02-26', 'w@2027-02-27']);
      expect(pr.total, 4 * 700 + 4000 + 1200);
      final p = running(
          start, [bill('m', '2027-03-01'), bill('n', '2027-02-26', amount: 4000), bill('w', '2027-02-06', amount: 700, interval: 7)],
          payday: 31, plans: [planned('p', '2027-02-27', 1200), planned('q', '2027-02-28', 900)]);
      expect(p.end, end);
      expect((p.beforePayday, p.beforePaydayCount), (pr.total, pr.count));
    });

    test('a slip near a cycle that has no date in the period is covered as the period will see it', () {
      // 25-day period 26 Mar .. 20 Apr; the bill was due 24 Mar (paid), next 23 Apr. A slip on 26 Mar is the paid cycle.
      final b = bill('m', '2026-03-24', payee: key('Zorblex Club'));
      final slip = planned('bill:s1', '2026-03-26', 5000, source: PlannedSource.bill, title: 'Zorblex Club');
      final pr = project('2026-03-26', '2026-04-20', [b], plans: [slip]);
      expect(pr.count, 0);
      final p = running('2026-03-26', [b.copyWith(nextDue: '2026-04-23')], payday: 20, plans: [slip]);
      expect(p.end, '2026-04-20');
      expect(p.reservedPlannedRows, isEmpty);
    });

    test('payee aliases change the coverage exactly as in computePeriod', () {
      final b = bill('m', '2026-10-25', payee: key('Zorblex Club'));
      final slip = planned('bill:s2', '2026-11-25', 5000, source: PlannedSource.bill, title: 'Zorblx Clb');
      final aliases = {key('Zorblx Clb'): key('Zorblex Club')};
      final without = project('2026-11-10', '2026-12-10', [b], plans: [slip]);
      final withAlias = project('2026-11-10', '2026-12-10', [b], plans: [slip], aliases: aliases);
      expect((without.count, without.total), (2, 10000));
      expect((withAlias.count, withAlias.total), (1, 5000));
      final after = b.copyWith(nextDue: '2026-11-24');
      final p0 = running('2026-11-10', [after], plans: [slip]);
      final p1 = running('2026-11-10', [after], plans: [slip], aliases: aliases);
      expect((p0.beforePayday, p0.beforePaydayCount), (without.total, without.count));
      expect((p1.beforePayday, p1.beforePaydayCount), (withAlias.total, withAlias.count));
    });

    test('parts already paid towards a next-period cycle lower its reserve, as in computePeriod', () {
      // A manual monthly bill due 15 Nov with a part paid on 5 Nov (in its parts window, after the last payment).
      const part = CategorizedTx(
          Tx(id: 'part1', source: 'pbz', date: '2026-11-05', amount: -2000, description: 'Zorblex Club'), 'Shopping', BudgetKind.flex);
      final b = bill('m', '2026-10-16', payee: key('Zorblex Club'));
      final pr = project('2026-11-10', '2026-12-10', [b], txs: [part]);
      expect(cycleKeys(pr.cycles), ['m@2026-11-15']);
      expect(pr.total, 3000);
      final p = running('2026-11-10', [b.copyWith(nextDue: '2026-11-15')], txs: [part]);
      expect((p.beforePayday, p.beforePaydayCount), (pr.total, pr.count));
    });
  });

  group('bad dates', () {
    test('start not before end or a bad date is an ArgumentError', () {
      for (final (s, e) in [
        ('2026-11-10', '2026-11-10'),
        ('2026-12-10', '2026-11-10'),
        ('2026-13-01', '2026-12-10'),
        ('2026-11-10', 'soon'),
        ('', '2026-12-10'),
      ]) {
        expect(() => project(s, e, [bill('m', '2026-11-20')]), throwsArgumentError, reason: '$s .. $e');
      }
    });
  });
}
