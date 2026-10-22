// The goal-target and waiting totals come from the controller, not from the widgets. SYNTHETIC data only.
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

void main() {
  test('goalTargetTotal sums every goal target', () {
    final wc = demoWallet();
    expect(wc.goalTargetTotal, 300000 + 120000);
    expect(emptyWallet().goalTargetTotal, 0);
  });

  test('waitingTotal sums wishes still cooling off, not the ready or decided ones', () {
    final wc = demoWallet();
    expect(wc.waitingTotal, 12000);
    expect(emptyWallet().waitingTotal, 0);
  });

  test('waitingTotal uses the injected clock, like the Wishlist split (wc.now)', () {
    final wc = habitsWallet();
    final now = wc.now.millisecondsSinceEpoch;
    final cooling = wc.wish.where((w) => w.status == 'waiting' && w.hoursLeft(wc.settings.coolHours, now) > 0);
    expect(wc.waitingTotal, cooling.fold<int>(0, (a, w) => a + w.price));
    expect(wc.now, budgetToday);
  });
}
