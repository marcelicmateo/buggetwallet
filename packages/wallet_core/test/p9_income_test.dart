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
      // The landed 02-20 cycle is hidden; the later ones stay on the nextDue grid (refresh re-anchors them).
      expect([for (final c in p.expectedIncome) c.due], ['2026-02-27', '2026-03-06', '2026-03-13']);
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
      expect(op.fields['status'], 'in:candidate'); // never the column default 'candidate' an old build would list
      expect(r.recurringBills().singleWhere((b) => b.id == id).category, 'Extra income');
    });

    // Review 3: a build before P9 drops `direction` and knows only candidate/confirmed/dismissed.
    test('an income is stored under in: statuses an older build never lists, reserves or pays', () {
      final id = addIn();
      String raw() => r.db.select('SELECT status FROM recurring WHERE id = ?', [id]).first['status'] as String;
      expect(raw(), 'in:confirmed');
      r.dismissRecurring(id);
      expect(raw(), 'in:dismissed');
      expect(r.recurringBills().where((b) => b.id == id), isEmpty);
      r.confirmRecurring(id);
      expect(raw(), 'in:confirmed');
      final b = r.recurringBills().singleWhere((x) => x.id == id);
      expect((b.status, b.confirmed, b.isIncome), ('confirmed', true, true));
      // A bill keeps the plain values.
      final bill =
          r.addRecurring(label: 'Gig fee', category: 'Shopping', amount: 900, intervalDays: 30, firstDue: '2026-03-20', payee: key);
      expect(r.db.select('SELECT status FROM recurring WHERE id = ?', [bill]).first['status'], 'confirmed');
    });

    test('a row with an in: status and no direction (an older build\'s snapshot) reads as an income', () {
      final b = RecurringBill.fromRow({
        'id': 'recin:x',
        'payee': 'x',
        'category': 'Extra income',
        'expected_amount': 100,
        'next_due': '2026-03-20',
        'status': 'in:candidate'
      });
      expect((b.isIncome, b.status, b.confirmed), (true, 'candidate', false));
    });

    test('undeleteRecurring brings a bill or an income back as it was; unknown id refused; live row writes nothing', () {
      final inc = addIn();
      final bill =
          r.addRecurring(label: 'Gig fee', category: 'Shopping', amount: 900, intervalDays: 30, firstDue: '2026-03-20', payee: key);
      for (final id in [inc, bill]) {
        final before = r.recurringBills().singleWhere((b) => b.id == id);
        r.deleteRecurring(id);
        expect(r.recurringBills().where((b) => b.id == id), isEmpty);
        r.undeleteRecurring(id);
        final after = r.recurringBills().singleWhere((b) => b.id == id);
        expect((after.isIncome, after.status, after.nextDue, after.expectedAmount),
            (before.isIncome, before.status, before.nextDue, before.expectedAmount));
      }
      final ops = r.pendingOps().length;
      r.undeleteRecurring(inc);
      expect(r.pendingOps(), hasLength(ops));
      expect(() => r.undeleteRecurring('rec:nope'), throwsArgumentError);
    });

    test('a deleted detected income is not re-created by detection; undelete brings it back as a candidate', () {
      final rows = [
        for (final d in ['2026-01-12', '2026-02-12', '2026-03-12']) n(d, 25000, 'Ostalo', 'Zorblex Gig 2026')
      ];
      r.importBatch(ImportBatch(source: 'pbz', transactions: rows));
      final id = RecurringBill.incomeIdFor(key);
      r.deleteRecurring(id);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-03-13', 100, 'Ostalo', 'Other Payer')]));
      r.refreshRecurring('2026-03-15');
      expect(r.recurringBills(includeDismissed: true).where((b) => b.id == id), isEmpty);
      r.undeleteRecurring(id);
      final b = r.recurringBills().singleWhere((x) => x.id == id);
      expect((b.isIncome, b.status), (true, 'candidate'));
    });

    // Review 4: a missed income is not expected for ever.
    test('refresh moves a confirmed income on once due + tolerance passed with no landing', () {
      r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-01-05', -100, 'POS plaćanje', 'Quorvant Shop')]));
      final id = r.addRecurring(
          label: 'Gig', category: 'Extra income', amount: 25000, intervalDays: 30, firstDue: '2026-02-01', payee: key, direction: 'in');
      r.refreshRecurring('2026-03-15');
      // 02-01 + 3 and 03-03 + 3 passed; 04-02 is the next one.
      expect(r.recurringBills().singleWhere((b) => b.id == id).nextDue, '2026-04-02');
      r.refreshRecurring('2026-03-15');
      expect(r.recurringBills().singleWhere((b) => b.id == id).nextDue, '2026-04-02');
    });
  });

  group('review fixes', () {
    test('1: a one-off of the payee outside the band stays an extra for the goals', () {
      final pay = cat(row('2026-02-20', 25000), 'Extra income');
      final bonus = cat(row('2026-02-25', 200000), 'Extra income');
      final p = period([inc('2026-03-22', 25000, lastPaidTx: pay.tx.id)], [pay, bonus]);
      expect((p.landedIncome, p.extrasForGoals), (25000, 200000));
      expect(p.flexBudget, period(const [], [pay, bonus]).flexBudget + 25000);
    });

    test('1: a range widens what lands', () {
      final pay = cat(row('2026-02-20', 40000), 'Extra income');
      const ranged = RecurringBill(
          id: 'recin:r',
          payee: 'zorblex_gig',
          label: 'Gig',
          category: 'Extra income',
          expectedAmount: 25000,
          minAmount: 20000,
          maxAmount: 40000,
          nextDue: '2026-03-22',
          status: 'confirmed',
          direction: 'in');
      expect(ranged.payee, zorblex);
      expect(period([ranged], [pay]).landedIncome, 40000);
    });

    test('2: a refund at the payee lowers the landed income, floored at 0; extrasForGoals never negative', () {
      final pay = cat(row('2026-02-20', 25000), 'Extra income');
      final back = cat(row('2026-02-27', -5000), 'Extra income');
      final p = period([inc('2026-03-22', 25000, lastPaidTx: pay.tx.id)], [pay, back]);
      expect((p.extras, p.landedIncome, p.extrasForGoals), (20000, 20000, 0));
      final only = period([inc('2026-03-22', 25000)], [back]);
      expect((only.extras, only.landedIncome, only.extrasForGoals), (-5000, 0, 0));
      expect(only.flexBudget, period(const [], [back]).flexBudget);
    });

    test('4: a cycle that landed early (within half an interval before due) is not expected', () {
      final early = cat(row('2026-02-26', 25000), 'Extra income');
      expect(period([inc('2026-03-10', 25000)], [early]).expectedIncome, isEmpty);
      // Too early (more than half an interval before), or out of band: still expected.
      final tooEarly = cat(row('2026-02-15', 25000), 'Extra income');
      expect(period([inc('2026-03-10', 25000)], [tooEarly]).expectedIncome, hasLength(1));
      final small = cat(row('2026-03-01', 1000), 'Extra income');
      expect(period([inc('2026-03-10', 25000)], [small]).expectedIncome, hasLength(1));
    });

    test('5: suggestBillCategory never takes an income\'s category; bill history shows an income\'s landed months', () {
      const slip = Bill(id: 'b1', payee: 'Zorblex Gig', date: '2026-03-01', total: 900, currency: 'EUR');
      final b = inc('2026-03-22', 25000);
      expect(suggestBillCategory(slip, recurring: [b], txs: const []), isNot('Extra income'));
      final rows = [
        for (final d in ['2026-01-20', '2026-02-20']) row(d, 25000),
        row('2026-02-21', -300)
      ];
      final h = billHistory(b, rows, const [], today: '2026-03-01', months: 3, currency: 'EUR');
      expect({for (final m in h) m.month: m.paid}, {'2026-03': 0, '2026-02': 25000, '2026-01': 25000});
    });

    test('6: a split income payment counts only its extra part', () {
      final t = row('2026-02-20', 25000);
      final extraPart = CategorizedTx(t, 'Extra income', BudgetKind.extra, amount: 23000, part: 0, parts: 2);
      final flexPart = CategorizedTx(t, 'Shopping', BudgetKind.flex, amount: 2000, part: 1, parts: 2);
      final p = period([inc('2026-03-22', 25000, lastPaidTx: t.id)], [extraPart, flexPart]);
      expect(p.landedIncome, 23000);
      expect(p.extrasForGoals, 0);
    });
  });
}
