// Amounts and notes sit at the right end of their rows (SplitRow), and names get the rest of the row instead of half.
// Synthetic wallets only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/goals.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/widgets/common.dart';
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
    // Behind pace here means money spent today beyond today's allowance, so "Over today" outranks "Behind pace" as the one chip.
    final label = behind ? 'Over today' : 'On pace';
    testWidgets('"$label" is one chip with an icon in the hero tile on a wide window', (tester) async {
      await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(_wallet(behind: behind)), openPlan: () {})),
          size: const Size(1200, 3000));
      expect(tester.takeException(), isNull);
      final text = find.text(label);
      expect(text, findsOneWidget);
      final hero = find.byKey(const ValueKey('heroTile'));
      expect(find.descendant(of: hero, matching: text), findsOneWidget);
      expect(find.descendant(of: hero, matching: find.byIcon(behind ? Icons.warning_amber_rounded : Icons.check)), findsOneWidget);
      expect(tester.getTopLeft(text).dx, lessThan(tester.getRect(hero).center.dx), reason: 'the chip sits at the left under the number');
    });
  }

  double rowRight(WidgetTester tester, Finder f) => tester.getTopRight(find.ancestor(of: f, matching: find.byType(Row)).first).dx;

  testWidgets('goal and wishlist amounts end at the row end on a wide window', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: GoalsScreen(wc: wc)), size: const Size(1200, 3000));
    final goal = find.textContaining(' / ').first;
    expect(tester.getTopRight(goal).dx, closeTo(rowRight(tester, goal), 1));
    await pumpApp(tester, Scaffold(body: WishlistScreen(wc: wc)), size: const Size(1200, 3000));
    final price = find.text('120\u00A0€');
    expect(price, findsWidgets);
    expect(tester.getTopRight(price.first).dx, closeTo(rowRight(tester, price.first), 1));
  });

  testWidgets('SplitRow: a short end keeps its width, the start gets the rest; a long end stops at half', (tester) async {
    await pumpApp(
        tester,
        const Scaffold(
            body: SizedBox(
                width: 360,
                child: Column(children: [
                  SplitRow(gap: 8, start: Text('Name', key: Key('s1')), end: Text('1\u00A0€', key: Key('e1'))),
                  SplitRow(gap: 8, start: Text('Name', key: Key('s2')), end: Text('a very long note that has to wrap', key: Key('e2'))),
                ]))),
        size: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('e1'))).width, lessThan(60));
    expect(tester.getTopRight(find.byKey(const Key('e1'))).dx, closeTo(360, 1));
    expect(tester.getSize(find.ancestor(of: find.byKey(const Key('s1')), matching: find.byType(Expanded))).width, greaterThan(280));
    expect(tester.getSize(find.byKey(const Key('e2'))).width, lessThanOrEqualTo(180));
  });
}
