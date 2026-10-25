// Stage P9 builder tests: recurring income paths beyond the spec tests (goals extras, Upcoming/ICS, short incomes,
// refresh per direction, edit rules). SYNTHETIC data only (made-up payees and amounts).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

var _seq = 0;

Tx row(String date, int cents, {String desc = 'Zorblex Gig', String? id}) => Tx(
      id: id ?? 'b9-${_seq++}',
      source: 'pbz',
      date: date,
      amount: cents,
      currency: 'EUR',
      bankType: 'Ostalo',
      description: desc,
    );

CategorizedTx cat(Tx t, String category) => CategorizedTx(t, category, kindOf(category));

final zorblex = merchantKey(row('2026-01-01', 1));

RecurringBill inc(String nextDue, int cents, {int interval = 30, String status = 'confirmed', String? lastPaidTx}) => RecurringBill(
      id: RecurringBill.incomeIdFor(zorblex),
      payee: zorblex,
      label: 'Zorblex Gig',
      category: 'Extra income',
      expectedAmount: cents,
      intervalDays: interval,
      nextDue: nextDue,
      status: status,
      lastPaidTx: lastPaidTx,
      direction: RecurringBill.directionIn,
    );

void main() {
  // Period 2026-02-15 .. 2026-03-15.
  final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
  PeriodBudget period(List<RecurringBill> bills, List<CategorizedTx> txs, {String today = '2026-03-01'}) =>
      computePeriod(txs, st, const [], today, bills: bills, table: CategoryTable.builtIn);

  group('computePeriod', () {
    test('extrasForGoals leaves out the landed income; a one-off stays for the goals', () {
      final landed = cat(row('2026-02-20', 25000), 'Extra income');
      final oneOff = cat(row('2026-02-22', 7000, desc: 'Quorvant Refund'), 'Extra income');
      final p = period([inc('2026-03-22', 25000, lastPaidTx: landed.tx.id)], [landed, oneOff]);
      expect((p.extras, p.landedIncome, p.extrasForGoals), (32000, 25000, 7000));
      final none = period(const [], [landed, oneOff]);
      expect((none.landedIncome, none.extrasForGoals), (0, 32000));
      expect(p.flexBudget, none.flexBudget + 25000);
    });

    test('a weekly income lists every cycle left in the period; none is added', () {
      final p = period([inc('2026-02-20', 5000, interval: 7)], const []);
      expect([for (final c in p.expectedIncome) c.due], ['2026-02-20', '2026-02-27', '2026-03-06', '2026-03-13']);
      expect(p.flexBudget, period(const [], const []).flexBudget);
      expect(p.reservedBills, 0);
      expect(p.dueCycles, isEmpty);
    });

    test('a cycle whose row landed but is not recorded yet is not expected any more; the row counts', () {
      final landed = cat(row('2026-02-21', 5000), 'Extra income');
      final p = period([inc('2026-02-20', 5000, interval: 7)], [landed]);
      expect([for (final c in p.expectedIncome) c.due], ['2026-02-28', '2026-03-07', '2026-03-14']);
      expect(p.landedIncome, 5000);
    });

    test('an overdue cycle from before the period start is not listed; the next one in the period is', () {
      expect([
        for (final c in period([inc('2026-02-10', 5000)], const []).expectedIncome) c.due
      ], [
        '2026-03-12'
      ]);
      expect(period([inc('2026-02-10', 5000, interval: 91)], const []).expectedIncome, isEmpty);
    });

    test('an income passed as a bill with a long interval holds nothing', () {
      final p = period([inc('2026-06-01', 90000, interval: 91)], const []);
      expect((p.reservedBills, p.dueCycles.length, p.expectedIncome.length), (0, 0, 0));
    });
  });

  group('lists of bills ignore incomes', () {
    test('upcoming and plannedIcs list no income occurrence', () {
      final b = inc('2026-03-20', 25000);
      expect(upcoming(planned: const [], bills: [b], events: const [], from: '2026-03-01', to: '2026-04-30'), isEmpty);
      expect(plannedIcs(const [], [b], from: '2026-03-01', to: '2026-04-30'), isNot(contains('Zorblex')));
    });

    test('dueBills never holds an income', () {
      expect(dueBills([inc('2026-03-01', 25000)], const [], '2026-02-15', '2026-03-15'), isEmpty);
    });
  });

  group('repo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch));
    tearDown(() => r.close());
    final key =
        merchantKey(const Tx(id: 'x', source: 'pbz', date: '2026-01-01', amount: 1, bankType: 'Ostalo', description: 'Zorblex Gig 2026'));
    String addIn() => r.addRecurring(
        label: 'Gig', category: 'Extra income', amount: 25000, intervalDays: 30, firstDue: '2026-03-20', payee: key, direction: 'in');

    test('two live incomes of one payee are refused; a bill of it is not', () {
      addIn();
      expect(addIn, throwsArgumentError);
      expect(r.addRecurring(label: 'Gig fee', category: 'Shopping', amount: 900, intervalDays: 30, firstDue: '2026-03-20', payee: key),
          isNotEmpty);
    });

    test('an income keeps an extra category and takes no end date on edit', () {
      final id = addIn();
      expect(() => r.updateRecurring(id, category: 'Shopping'), throwsArgumentError);
      expect(() => r.updateRecurring(id, category: 'Salary'), throwsArgumentError);
      expect(() => r.updateRecurring(id, endsOn: '2026-09-20'), throwsArgumentError);
      r.updateRecurring(id, minAmount: 20000, maxAmount: 30000);
      final b = r.recurringBills().singleWhere((x) => x.id == id);
      expect((b.isIncome, b.hasRange), (true, true));
    });

    test('a manual income does not hide the payee\'s detected bill', () {
      addIn();
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in ['2026-01-10', '2026-02-10', '2026-03-10']) n(d, -1500, 'POS plaćanje', 'Zorblex Gig 2026'),
        for (final d in ['2026-01-12', '2026-02-12', '2026-03-12']) n(d, 25000, 'Ostalo', 'Zorblex Gig 2026'),
      ]));
      final ids = [for (final b in r.recurringBills()) b.id];
      expect(ids, contains(RecurringBill.idFor(key)));
      expect(ids, isNot(contains(RecurringBill.incomeIdFor(key)))); // the manual income stands for it
    });

    test('a detected income candidate carries direction in on its creation op and reads Extra income', () {
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in ['2026-01-12', '2026-02-12', '2026-03-12']) n(d, 25000, 'Ostalo', 'Zorblex Gig 2026'),
      ]));
      final id = RecurringBill.incomeIdFor(key);
      final op = r.pendingOps().map((o) => o.$2).firstWhere((o) => o.entity == 'recurring' && o.id == id);
      expect(op.fields['direction'], 'in');
      expect(op.fields.containsKey('status'), isFalse);
      expect(r.recurringBills().singleWhere((b) => b.id == id).category, 'Extra income');
    });
  });
}
