// Ledger theme on every tab: three window sizes, both brightnesses, no error/overflow, bar vs rail, no Card, square Panels.
// SYNTHETIC data only.
import 'package:budget_wallet/src/layout.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

const _sizes = <Size>[Size(360, 800), Size(800, 1000), Size(1280, 800)];
const _tabs = ['Today', 'Spending', 'Wishlist', 'Goals', 'Plan'];

void main() {
  for (final size in _sizes) {
    for (final b in Brightness.values) {
      final name = '${size.width.toInt()}x${size.height.toInt()} ${b.name}';
      testWidgets('$name: tabs scroll through, right navigation, no Card, square Panels', (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = b;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final errors = Errors();
        await pumpFull(tester, demoWallet(), 1.0, size: size);
        expect(tester.takeException(), isNull);
        final compact = sizeFor(size.width) == LayoutSize.compact;
        expect(find.byType(NavigationBar), compact ? findsOneWidget : findsNothing);
        expect(find.byType(NavigationRail), compact ? findsNothing : findsOneWidget);
        expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, b);

        for (final tab in _tabs) {
          await tapTab(tester, tab);
          await scrollThrough(tester);
          expect(tester.takeException(), isNull, reason: tab);
          expect(find.byType(Card), findsNothing, reason: '$tab has a Card');
          for (final p in find.byType(Panel).evaluate()) {
            // The Panel's own box (the first DecoratedBox under it). Tags, chips and fields inside it keep their own 2 px radius.
            final own = find.descendant(of: find.byElementPredicate((e) => e == p), matching: find.byType(DecoratedBox)).evaluate().first;
            final dec = (own.widget as DecoratedBox).decoration;
            if (dec is BoxDecoration) expect(dec.borderRadius, anyOf(isNull, BorderRadius.zero), reason: '$tab Panel radius');
          }
        }
        errors.check();
      });
    }
  }
}
