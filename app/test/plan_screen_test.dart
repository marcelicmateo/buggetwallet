// Plan screen: the numbers form. All data is SYNTHETIC.
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

Finder _field(String label) => find.widgetWithText(TextField, label);

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save numbers'));
  await tester.tap(find.text('Save numbers'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 4)); // toast and the controller's sync debounce
}

void main() {
  testWidgets('rent cash threshold is editable in Plan and changes categorisation', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
    expect(wc.txs.where((t) => t.amount == -55000).single.category, 'Rent');
    final f = _field('Cash withdrawal counts as rent from');
    await tester.ensureVisible(f);
    expect(tester.widget<TextField>(f).controller!.text, '500');
    await tester.enterText(f, '600');
    await _save(tester);
    expect(wc.settings.rentCashThreshold, 60000);
    expect(wc.txs.where((t) => t.amount == -55000).single.category, 'Cash');
  });
}
