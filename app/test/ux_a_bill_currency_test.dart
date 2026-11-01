// UX-A: a bill in another currency shows its own currency everywhere (search row, items, "adds X as a cash expense"), not the wallet's.
// All data is SYNTHETIC.
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/bills.dart';
import 'support/wallet.dart';

Finder k(String key) => find.byKey(ValueKey(key));

NormalizedBill usdBill() => const NormalizedBill(
    source: BillSource.hub3,
    externalId: 'usd1',
    date: '2026-10-18',
    total: 4560,
    currency: 'USD',
    payee: 'Synthetic Hosting',
    description: 'Hosting',
    items: [BillItem(name: 'Server', amount: 4560)]);

void main() {
  testWidgets('search shows a USD bill total in dollars', (t) async {
    final wc = emptyWallet();
    wc.repo.importBill(usdBill());
    wc.reload();
    await pumpApp(t, Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {})));
    await t.enterText(k('searchField'), 'hosting');
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.text('45.60 \$'), findsOneWidget);
    expect(find.textContaining('€'), findsNothing);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('the bill sheet shows items in the bill currency', (t) async {
    final wc = emptyWallet();
    final (id, _) = wc.repo.importBill(usdBill());
    wc.reload();
    await pumpApp(t,
        Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => openBill(c, wc, id), child: const Text('open'))))),
        size: const Size(400, 1600));
    await t.tap(find.text('open'));
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('45.60 \$'), findsWidgets);
    await t.pump(const Duration(seconds: 4));
  });
}
