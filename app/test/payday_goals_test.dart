// Payday done pays every goal's monthly amount once per pay period: the contribution row is keyed by goal and period,
// so a second tap (or a second device) in the same period does not pay twice, while a new period does.
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

void main() {
  test('paydayDone pays each goal once per period and again in the next period', () {
    final wc = demoWallet();
    final before = {for (final g in wc.goals) g.id: g.saved};
    final monthly = {for (final g in wc.goals) g.id: g.monthly};
    expect(monthly.values.any((m) => m != 0), isTrue, reason: 'the demo wallet has goals with a monthly amount');

    wc.paydayDone('2026-10-10');
    wc.paydayDone('2026-10-10'); // same period again: no second payment
    for (final g in wc.goals) {
      expect(g.saved, before[g.id]! + monthly[g.id]!, reason: 'goal ${g.id} paid exactly once for 2026-10-10');
    }
    expect(wc.repo.settings().savedFor, '2026-10-10');

    wc.paydayDone('2026-11-12');
    for (final g in wc.goals) {
      expect(g.saved, before[g.id]! + 2 * monthly[g.id]!, reason: 'goal ${g.id} paid once more for 2026-11-12');
    }
  });
}
