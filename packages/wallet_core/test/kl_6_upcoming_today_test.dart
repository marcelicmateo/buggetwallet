// KL-A item 6: Upcoming's "Set aside" must equal Today's reserved total (`PeriodBudget.beforePayday`), overdue bill
// cycles included. `reservedCycles` (due date + reserve) and `reservedPlannedRows` (date + amount) already carry every
// item, so the app sums them; these tests pin that they add up exactly. Synthetic data only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

final _st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-03-15', 'paydayDay': 15});

int itemsSum(PeriodBudget p) =>
    p.reservedCycles.fold<int>(0, (s, c) => s + c.reserve) + p.reservedPlannedRows.fold<int>(0, (s, r) => s + r.amount!);

void main() {
  late WalletRepo r;
  setUp(() => r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 20, 10).millisecondsSinceEpoch));
  tearDown(() => r.close());

  PeriodBudget period(String today) =>
      computePeriod(const [], _st, const [], today, bills: r.recurringBills(), planned: r.plannedCosts(), table: r.categoryTable());

  test('overdue cycle, a cycle due later, planned costs: the items sum to beforePayday', () {
    r.addRecurring(
        label: 'Synth overdue', category: 'Bills & one-offs', amount: 3100, intervalDays: 30, firstDue: '2026-03-17', payee: 'synth_a');
    r.addRecurring(
        label: 'Synth later', category: 'Sport & fitness', amount: 2200, intervalDays: 30, firstDue: '2026-04-02', payee: 'synth_b');
    r.addRecurring(
        label: 'Synth fixed', category: 'Bills & subscriptions', amount: 9900, intervalDays: 30, firstDue: '2026-03-25', payee: 'synth_c');
    r.addPlanned(title: 'Synth gift', date: '2026-03-28', amount: 4000, category: 'Shopping');
    r.addPlanned(title: 'Synth fixed cost', date: '2026-03-29', amount: 7000, category: 'Rent');
    r.addPlanned(title: 'Synth no amount', date: '2026-03-30', category: 'Shopping');
    final p = period('2026-03-20');
    expect(p.beforePayday, 3100 + 2200 + 4000, reason: 'fixed categories are in the plan, not reserved again');
    expect(itemsSum(p), p.beforePayday);
    expect(p.beforePaydayCount, p.reservedCycles.length + p.reservedPlannedRows.length);
    final overdue = p.reservedCycles.singleWhere((c) => c.bill.label == 'Synth overdue');
    expect((overdue.due, overdue.reserve), ('2026-03-17', 3100));
    expect(overdue.due.compareTo('2026-03-20') < 0, isTrue, reason: 'overdue: due before today, still reserved');
    expect([for (final row in p.reservedPlannedRows) (row.date, row.amount)], [('2026-03-28', 4000)]);
  });

  test('a short bill reserves every cycle before payday; each is one item', () {
    r.addRecurring(label: 'Synth weekly', category: 'Groceries', amount: 1500, intervalDays: 7, firstDue: '2026-03-18', payee: 'synth_w');
    final p = period('2026-03-20');
    expect(p.reservedCycles.map((c) => c.due), ['2026-03-18', '2026-03-25', '2026-04-01', '2026-04-08']);
    expect(itemsSum(p), p.beforePayday);
    expect(p.beforePayday, 4 * 1500);
  });

  test('nothing due: zero and no items', () {
    final p = period('2026-03-20');
    expect(p.beforePayday, 0);
    expect(p.reservedCycles, isEmpty);
    expect(p.reservedPlannedRows, isEmpty);
  });
}
