// Today's pace label ("ahead of pace" / "behind pace") sits at the right end of its row on a wide window.
// Synthetic wallets only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

WalletController _wallet({required bool behind}) {
  final wc = emptyWallet();
  final today = wc.today(), start = addDays(today, -10);
  wc.repo.updateSettings({'salary': 150000, 'rent': 0, 'loan': 0, 'subs': 0, 'periodStart': start, 'salaryConfirmed': true});
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    NormalizedTransaction(
        id: transactionId(start, 150000, 'Neto placa synthetic', 0),
        source: 'pbz',
        date: start,
        amountMinor: 150000,
        currency: 'EUR',
        bankType: 'Plaća/Mirovina',
        description: 'Neto placa synthetic'),
    if (behind)
      NormalizedTransaction(
          id: transactionId(today, -120000, 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', 0),
          source: 'pbz',
          date: today,
          amountMinor: -120000,
          currency: 'EUR',
          bankType: 'POS plaćanje',
          description: 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
  ]));
  wc.reload();
  return wc;
}

void main() {
  for (final behind in [false, true]) {
    final label = behind ? 'behind pace' : 'ahead of pace';
    testWidgets('"$label" is right-aligned on a wide window', (tester) async {
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: _wallet(behind: behind), openPlan: () {})), size: const Size(1200, 3000));
      expect(tester.takeException(), isNull);
      final text = find.textContaining(label, findRichText: true);
      expect(text, findsOneWidget);
      final used = find.textContaining(' used');
      final rowRight = tester.getTopRight(find.ancestor(of: used, matching: find.byType(Row)).first).dx;
      expect(tester.getTopRight(text).dx, closeTo(rowRight, 1), reason: '$label ends at the row end');
    });
  }
}
