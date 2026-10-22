// The synthetic demo wallet (`integration_test/demo_data.dart`) used by `tools/emulator.sh screens`,
// `tools/build.sh desktop-test screens` and `tools/live.sh start --demo`: seeding it must never throw (B6: a core rule
// once made the seeding fail only in those slow runs).
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import '../integration_test/demo_data.dart';

void main() {
  // Several days, so due dates fall before, on and after a payday (the 10th in the demo settings).
  for (final today in ['2026-10-20', '2026-10-05', '2026-10-09', '2026-12-31', '2027-03-01']) {
    test('the demo wallet seeds without errors ($today)', () {
      final repo = WalletRepo.inMemory(now: () => DateTime.parse('${today}T12:00:00Z').millisecondsSinceEpoch);
      addTearDown(repo.close);
      repo.importBatch(demoBatch(today));
      repo.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
      repo.updateSettings({'categoryBudgets': demoBudgets});
      final st = repo.settings();
      final p = computePeriod(const [], st, const [], today);
      seedDemoPlanned(repo, today, p.end);
      seedDemoBills(repo, today);
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
    final p = computePeriod(const [], repo.settings(), const [], today, bills: repo.recurringBills(), planned: repo.plannedCosts());
    expect(p.duePlanned.map((x) => (x.title, x.coveredByPlan)), [('Demo Gym Club', false), ('Demo Water Utility', true)]);
    expect(p.reservedPlanned, 2900);
  });
}
