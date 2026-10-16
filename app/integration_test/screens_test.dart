// Screenshots of every tab with the synthetic demo wallet. Run on the emulator: tools/emulator.sh screens
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'demo_data.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every tab with a synthetic wallet', (tester) async {
    final wc = await WalletController.load();
    if (!wc.hasWallet) await wc.createWallet();
    wc.repo.importBatch(demoBatch(wc.today()));
    wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});

    await tester.pumpWidget(BudgetWalletApp(wc: wc));
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-today');

    for (final (i, tab) in ['Spending', 'Wishlist', 'Goals', 'Plan'].indexed) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
      await tester.pumpAndSettle();
      await binding.takeScreenshot('${i + 2}-${tab.toLowerCase()}');
    }
  });
}
