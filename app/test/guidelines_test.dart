// Accessibility guidelines on every tab at 320x640: tap targets (androidTapTargetGuideline: 48 dp) and text contrast.
// One test per (scale, brightness, tab, guideline) so a known failure can be skipped with its widget list. SYNTHETIC data only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

const _tabs = ['Today', 'Spending', 'Wishlist', 'Goals', 'Plan'];

/// Known failures, keyed by the test name; each reason names the failing widgets (Stage I builds against these).
const _known = <String, String>{};

void main() {
  for (final scale in [1.0, 2.0]) {
    for (final b in Brightness.values) {
      for (final tab in _tabs) {
        for (final (gName, guideline) in [('tap targets', androidTapTargetGuideline), ('text contrast', textContrastGuideline)]) {
          final name = '$gName: $tab, scale $scale, ${b.name}';
          testWidgets(name, skip: _known[name] != null, (tester) async {
            tester.platformDispatcher.platformBrightnessTestValue = b;
            addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
            final handle = tester.ensureSemantics();
            await pumpFull(tester, demoWallet(), scale);
            await tapTab(tester, tab);
            try {
              // Check the first screenful, then every 300 dp down the page (only what is on screen is checked).
              final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
              await expectLater(tester, meetsGuideline(guideline));
              if (lists.evaluate().isNotEmpty) {
                final pos = tester.state<ScrollableState>(lists.first).position;
                for (var i = 0; i < 40 && pos.pixels < pos.maxScrollExtent; i++) {
                  pos.jumpTo((pos.pixels + 300).clamp(0, pos.maxScrollExtent));
                  await tester.pump();
                  await expectLater(tester, meetsGuideline(guideline));
                }
              }
            } finally {
              handle.dispose();
            }
          });
        }
      }
    }
  }

  testWidgets('control: the tap target guideline does fail on a 20 dp button', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
                alignment: Alignment.center,
                child: Semantics(button: true, onTap: () {}, label: 'tiny', child: const SizedBox(width: 20, height: 20))))));
    final result = await androidTapTargetGuideline.evaluate(tester);
    handle.dispose();
    expect(result.passed, isFalse);
  });
}
