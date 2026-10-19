// Today's delivery-hour panel: shown 14:00–19:00 and on Sundays, amounts in the wallet's currency. Synthetic wallets.
import 'package:budget_wallet/src/screens/today.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

void main() {
  Future<void> pump(WidgetTester tester, DateTime at, {String currency = 'EUR'}) async {
    final wc = demoWallet();
    wc.repo.updateSettings({'currency': currency});
    wc.reload();
    await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => at)), size: const Size(400, 4000));
  }

  testWidgets('shown on a weekday at 15:00, hidden at 10:00', (tester) async {
    await pump(tester, DateTime(2026, 10, 14, 15));
    expect(find.text('After-work delivery hour'), findsOneWidget);
    await pump(tester, DateTime(2026, 10, 14, 10));
    expect(find.text('After-work delivery hour'), findsNothing);
  });

  testWidgets('shown on Sunday morning', (tester) async {
    await pump(tester, DateTime(2026, 10, 18, 9));
    expect(find.text('Sunday delivery hour'), findsOneWidget);
  });

  testWidgets('the typical order uses the wallet currency, not €', (tester) async {
    await pump(tester, DateTime(2026, 10, 14, 15), currency: 'USD');
    expect(find.textContaining('A typical 15\u00A0\$ order'), findsOneWidget);
    expect(find.textContaining('€'), findsNothing);
  });
}
