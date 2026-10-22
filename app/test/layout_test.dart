// Every screen at 320x640 dp with text scale 2.0 (and the default scale): no overflow or other FlutterError.
// Overflow errors are reported when a widget paints, so each tab is scrolled through to the end.
// All data is SYNTHETIC.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('every tab fits 320 dp at text scale $scale', (tester) async {
      final wc = demoWallet();
      final errors = Errors();
      await pumpFull(tester, wc, scale);
      await scrollThrough(tester);
      for (final tab in ['Spending', 'Wishlist', 'Goals', 'Plan', 'Today']) {
        await tapTab(tester, tab);
        await scrollThrough(tester);
      }
      errors.check();
      expect(tester.takeException(), isNull);
    });

    testWidgets('onboarding fits 320 dp at text scale $scale', (tester) async {
      final wc = emptyWallet(withKey: false);
      final errors = Errors();
      await pumpFull(tester, wc, scale);
      await scrollThrough(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('joinStart')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('joinStart')));
      await tester.pump();
      await scrollThrough(tester);
      errors.check();
      expect(tester.takeException(), isNull);
    });
  }
}
