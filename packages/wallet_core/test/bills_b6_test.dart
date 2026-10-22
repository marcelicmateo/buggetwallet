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
}
