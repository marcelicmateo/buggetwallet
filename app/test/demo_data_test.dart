// The synthetic demo wallet (`integration_test/demo_data.dart`) used by `tools/emulator.sh screens`,
// `tools/build.sh desktop-test screens` and `tools/live.sh start --demo`: seeding it must never throw (B6: a core rule
// once made the seeding fail only in those slow runs).
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import '../integration_test/demo_data.dart';

void main() {
  // Several days, so due dates fall before, on and after a payday (the 10th in the demo settings).
  for (final today in ['2026-10-20', '2026-10-05', '2026-10-09', '2026-12-31', '2027-03-01']) {
    test('the demo wallet seeds without errors ($today)', () async {
      final repo = WalletRepo.inMemory(now: () => DateTime.parse('${today}T12:00:00Z').millisecondsSinceEpoch);
      addTearDown(repo.close);
      repo.importBatch(demoBatch(today));
      repo.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
      for (final MapEntry(:key, :value) in demoBudgets.entries) {
        repo.setCategoryBudget(key, value);
      }
      final st = repo.settings();
      final p = computePeriod(const [], st, const [], today, table: CategoryTable.builtIn);
      seedDemoPlanned(repo, today, p.end);
      seedDemoBills(repo, today);
      await seedDemoAccounts(repo, today);
      seedDemoIous(repo, today);
      expect(repo.ious(), hasLength(2));
      expect(repo.accounts(), hasLength(3));
      seedDemoSplit(repo);
      expect(repo.splits(), hasLength(1));
      final bills = repo.bills();
      expect(bills, hasLength(4));
      expect(bills.where((b) => b.dueDate != null).every((b) => b.category != null), isTrue);
      expect(parseIcs(demoIcs(today), calendarId: 'demo', from: today, to: addDays(today, 30)).events, hasLength(2));
    });
  }

  test('the water slip is covered by the plan and the gym slip is reserved', () {
    const today = '2026-10-20';
    final repo = WalletRepo.inMemory(now: () => DateTime.parse('${today}T12:00:00Z').millisecondsSinceEpoch);
    addTearDown(repo.close);
    repo.importBatch(demoBatch(today));
    repo.updateSettings({'salary': 140000, 'paydayDay': 10, 'periodStart': '2026-10-10'});
    seedDemoBills(repo, today);
    final p = computePeriod(const [], repo.settings(), const [], today,
        bills: repo.recurringBills(), planned: repo.plannedCosts(), table: repo.categoryTable());
    expect(p.duePlanned.map((x) => (x.title, x.coveredByPlan)), [('Demo Gym Club', false), ('Demo Water Utility', true)]);
    expect(p.reservedPlanned, 2900);
  });

  test('the demo wallet has one confirmed monthly side income, landed this period once its day has passed', () {
    const today = '2026-10-20';
    final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => DateTime.parse('${today}T12:00:00'));
    addTearDown(wc.dispose);
    wc.repo.importBatch(demoBatch(today));
    wc.repo.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
    seedDemoBills(wc.repo, today);
    wc.reload();
    final incomes = wc.expectedIncomes();
    expect(incomes.map((b) => (b.confirmed, b.expectedAmount)), [(true, 15000)]);
    expect(wc.period().landedIncome, 15000);
    expect(wc.period().expectedIncome, isEmpty);
  });

  test('the demo wallet has a running pay period on every day of two months (screenshots never show an ended period)', () {
    for (var day = DateTime.utc(2026, 10, 1); day.isBefore(DateTime.utc(2026, 12, 1)); day = day.add(const Duration(days: 1))) {
      final today = isoDate(day);
      final wc =
          WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => DateTime.parse('${today}T12:00:00'));
      addTearDown(wc.dispose);
      wc.repo.importBatch(demoBatch(today));
      wc.repo.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
      wc.reload();
      expect(wc.period().paydayPassed, isFalse, reason: today);
    }
  });
}
