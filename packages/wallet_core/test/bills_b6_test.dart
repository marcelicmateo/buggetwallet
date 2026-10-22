// Stage B final fixes, core half (B6, docs/context/BILLS_API.md "Decisions B6"): one reproducing test per bug.
// SYNTHETIC data only: made-up payees, references and amounts.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

const today = '2026-03-01';
final noon = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;

NormalizedBill slip({String ext = 'jir:b6-slip', String? due = '2026-03-10', int total = 4599, String payee = 'Synth Water'}) =>
    NormalizedBill(source: BillSource.receiptQr, externalId: ext, date: '2026-02-27', dueDate: due, total: total, payee: payee);

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => noon));
  tearDown(() => repo.close());

  PlannedCost plannedOf(String billId) =>
      repo.plannedCosts(includeClosed: true).firstWhere((p) => p.id == WalletRepo.billPlannedId(billId));

  PeriodBudget period() => computePeriod([for (final t in repo.transactions()) repo.categorizer().categorize(t)],
      const WalletSettings(salary: 100000, paydayDay: 15, periodStart: '2026-02-15'), const [], today,
      bills: repo.recurringBills(), planned: repo.plannedCosts());

  group('1. a bill confirmed by its cash expense keeps a category', () {
    test('B6 bug: deleting the cash expense of a fixed-category slip reopened it with no category and reserved it twice', () {
      final (id, _) = repo.importBill(slip());
      final txId = repo.addExpenseFromBill(id, category: 'Bills & subscriptions');
      expect(repo.bill(id)!.category, 'Bills & subscriptions', reason: 'the bill takes the expense category');
      repo.deleteTransaction(txId);
      final p = plannedOf(id);
      expect((p.isOpen, p.category, p.coveredByPlan), (true, 'Bills & subscriptions', true));
      final b = period();
      expect(b.reservedPlanned, 0, reason: 'already in the payday plan: listed, not reserved again');
      expect(b.duePlanned.map((p) => p.id), [WalletRepo.billPlannedId(id)]);
      // Every later edit still saves.
      repo.updateBill(id, note: 'synthetic note');
      repo.updateBill(id, warrantyUntil: '2027-02-27');
      expect(repo.bill(id)!.note, 'synthetic note');
    });

    test('a flex cash expense: the reopened slip reserves its total once', () {
      final (id, _) = repo.importBill(slip());
      repo.deleteTransaction(repo.addExpenseFromBill(id, category: 'Bills & one-offs'));
      expect(period().reservedPlanned, 4599);
    });

    test('a bill that has a category keeps it; the expense gets the one passed', () {
      final (id, _) = repo.importBill(slip());
      repo.updateBill(id, category: 'Bills & one-offs');
      final txId = repo.addExpenseFromBill(id, category: 'Groceries');
      expect(repo.bill(id)!.category, 'Bills & one-offs');
      expect(repo.transaction(txId)!.category, 'Groceries');
    });
  });

  group('1. a reopened bill without a category: listed, never reserved; small edits still save', () {
    /// A confirmed bill with no category whose planned row is open: confirmed while paid (no category needed), then
    /// unlinked. Bills confirmed before B5a look the same.
    String uncategorizedOpenBill() {
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-02-28', -4599, 'Nalog', 'SYNTH WATER')]));
      final (id, _) = repo.importBill(slip());
      repo.linkBill(id, repo.transactions().single.id);
      repo.confirmBill(id);
      repo.unlinkBill(id);
      return id;
    }

    test('B6 bug: its planned row reserved the full total with no category; now listed with needsCategory', () {
      final id = uncategorizedOpenBill();
      final p = plannedOf(id);
      expect((p.isOpen, p.category, p.needsCategory), (true, null, true));
      final b = period();
      expect(b.duePlanned.map((p) => p.id), [WalletRepo.billPlannedId(id)]);
      expect(b.reservedPlanned, 0);
    });

    test('B6 bug: a note or warranty edit on it threw "The bill needs a category."; now it saves', () {
      final id = uncategorizedOpenBill();
      repo.updateBill(id, note: 'synthetic note');
      repo.updateBill(id, warrantyUntil: '2027-02-27', returnBy: '2026-03-14');
      repo.updateBill(id, payee: 'Synth Water Co');
      final b = repo.bill(id)!;
      expect((b.note, b.warrantyUntil, b.returnBy, b.payee), ('synthetic note', '2027-02-27', '2026-03-14', 'Synth Water Co'));
    });

    test('an edit of due date or total still needs the category; giving one makes it reserve', () {
      final id = uncategorizedOpenBill();
      expect(() => repo.updateBill(id, total: 5000), throwsA(isA<ArgumentError>().having((e) => e.message, 'm', contains('category'))));
      expect(() => repo.updateBill(id, dueDate: '2026-03-12'), throwsArgumentError);
      expect(repo.bill(id)!.total, 4599);
      repo.updateBill(id, category: 'Bills & one-offs');
      expect(plannedOf(id).needsCategory, isFalse);
      expect(period().reservedPlanned, 4599);
    });

    test('needsCategory is for bill rows only; a manual planned cost is unchanged', () {
      const manual = PlannedCost(id: 'p1', title: 'Synthetic', date: '2026-03-05', amount: 1000);
      const billRow = PlannedCost(id: 'bill:x', title: 'Synthetic', date: '2026-03-05', amount: 1000, source: PlannedSource.bill);
      const blank =
          PlannedCost(id: 'bill:y', title: 'Synthetic', date: '2026-03-05', amount: 1000, category: ' ', source: PlannedSource.bill);
      expect([manual.needsCategory, billRow.needsCategory, blank.needsCategory], [false, true, true]);
      final b = computePeriod(const [], const WalletSettings(salary: 100000, paydayDay: 15, periodStart: '2026-02-15'), const [], today,
          planned: const [manual, billRow, blank]);
      expect(b.reservedPlanned, 1000);
      expect(b.duePlanned, hasLength(3));
    });
  });

  group('2. a slip near payday is reserved once, in the period that pays it', () {
    // Payday on the 1st: the period 2026-10-01 .. 2026-10-31, today 2026-10-28.
    const st = WalletSettings(salary: 100000, paydayDay: 1, periodStart: '2026-10-01');
    const day = '2026-10-28';
    RecurringBill rec(String nextDue, {String category = 'Bills & one-offs'}) => RecurringBill(
        id: 'rec:synth_power',
        payee: 'synth_power',
        label: 'SYNTH POWER',
        category: category,
        expectedAmount: 3000,
        nextDue: nextDue,
        status: 'confirmed');
    PlannedCost row(String due) =>
        PlannedCost(id: 'bill:b6', title: 'Synth Power', date: due, amount: 3100, category: 'Bills & one-offs', source: PlannedSource.bill);

    test('B6 bug: slip due 10-30, recurring cycle 11-02 (next period): the slip is reserved here, not dropped', () {
      final r = rec('2026-11-02');
      final p = row('2026-10-30');
      expect(plannedCoveredBy(p, [r]), r, reason: 'the same payment as far as matching goes');
      final b = computePeriod(const [], st, const [], day, bills: [r], planned: [p]);
      expect(b.dueBills, isEmpty);
      expect(b.reservedBills, 0);
      expect(b.duePlanned.map((p) => p.id), ['bill:b6']);
      expect(b.reservedPlanned, 3100);
      // Upcoming shows it in this period and the recurring occurrence in the next one.
      final now = upcoming(planned: [p], bills: [r], events: const [], from: '2026-10-01', to: '2026-10-31');
      expect(now.map((u) => u.kind), [UpcomingKind.planned]);
      final next = upcoming(planned: [p], bills: [r], events: const [], from: '2026-11-01', to: '2026-11-30');
      expect(next.map((u) => u.kind), [UpcomingKind.bill]);
      expect('BEGIN:VEVENT'.allMatches(plannedIcs([p], [r], from: '2026-10-01', to: '2026-10-31')), hasLength(1));
    });

    test('the other side: recurring cycle 10-31 inside the period reserves it; the slip is listed, not added', () {
      final r = rec('2026-10-31');
      final b = computePeriod(const [], st, const [], day, bills: [r], planned: [row('2026-10-30')]);
      expect((b.reservedBills, b.reservedPlanned), (3000, 0));
      expect(b.duePlanned, hasLength(1));
      final up = upcoming(planned: [row('2026-10-30')], bills: [r], events: const [], from: '2026-10-01', to: '2026-10-31');
      expect(up.map((u) => u.kind), [UpcomingKind.bill]);
    });

    test('symmetric: slip due 11-02 after the period, recurring 10-30 inside: reserved once by the recurring bill', () {
      final r = rec('2026-10-30');
      final b = computePeriod(const [], st, const [], day, bills: [r], planned: [row('2026-11-02')]);
      expect((b.reservedBills, b.reservedPlanned), (3000, 0));
      expect(b.dueBills.single.id, r.id);
      expect(b.duePlanned, isEmpty, reason: 'the slip falls in the next period');
    });

    test('a recurring bill in a fixed category: the fixed plan holds it, the slip is not reserved in either period', () {
      final r = rec('2026-11-02', category: 'Bills & subscriptions');
      final b = computePeriod(const [], st, const [], day, bills: [r], planned: [row('2026-10-30')]);
      expect((b.reservedBills, b.reservedPlanned), (0, 0));
    });

    test('the cycle just paid (before nextDue): the slip for it stays unreserved', () {
      // Paid early on 10-27; the next cycle moved to 11-26. The slip for the paid cycle is due 10-29.
      final r = rec('2026-11-26');
      final b = computePeriod(const [], st, const [], day, bills: [r], planned: [row('2026-10-29')]);
      expect((b.reservedBills, b.reservedPlanned), (0, 0));
      expect(plannedCoverage(row('2026-10-29'), [r])?.occurrence, isNull);
    });
  });
}
