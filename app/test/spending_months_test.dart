// The month chips on Spending scroll sideways: the selected chip is always fully inside the row. All data is SYNTHETIC.
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

final _selected = find.byWidgetPredicate((w) => w is ChoiceChip && w.selected);

/// Fails unless the chip lies inside the scrolling row that holds it.
void _expectFullyVisible(WidgetTester tester, Finder chip) {
  final row = find.ancestor(of: chip, matching: find.byType(SingleChildScrollView)).first;
  final c = tester.getRect(chip), r = tester.getRect(row);
  expect(c.left, greaterThanOrEqualTo(r.left - 0.5), reason: 'left edge of $c in $r');
  expect(c.right, lessThanOrEqualTo(r.right + 0.5), reason: 'right edge of $c in $r');
}

void main() {
  for (final (name, size) in const [('360 dp', Size(360, 800)), ('wide window', Size(1500, 900)), ('320 dp', Size(320, 800))]) {
    testWidgets('$name: the current month chip is fully visible and an older month scrolls into view', (tester) async {
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: demoWallet())), size: size);
      await tester.pumpAndSettle();
      expect(_selected, findsOneWidget);
      expect(find.descendant(of: _selected, matching: find.textContaining('(now)')), findsOneWidget);
      _expectFullyVisible(tester, _selected);

      // The oldest month: scrolled into view when chosen (it may start off screen after scrolling to the newest).
      final chips = find.byType(ChoiceChip);
      final oldest = chips.first;
      await tester.ensureVisible(oldest);
      await tester.pumpAndSettle();
      await tester.tap(oldest);
      await tester.pumpAndSettle();
      expect(_selected, findsOneWidget);
      expect(find.descendant(of: _selected, matching: find.textContaining('(now)')), findsNothing);
      _expectFullyVisible(tester, _selected);

      // The newest again.
      await tester.ensureVisible(chips.last);
      await tester.pumpAndSettle();
      await tester.tap(chips.last);
      await tester.pumpAndSettle();
      expect(find.descendant(of: _selected, matching: find.textContaining('(now)')), findsOneWidget);
      _expectFullyVisible(tester, _selected);
    });
  }

  testWidgets('choosing a month scrolls only the chip row, never the page', (tester) async {
    await pumpApp(tester, Scaffold(body: SpendingScreen(wc: demoWallet())), size: const Size(360, 800));
    await tester.pumpAndSettle();
    final page = find.byWidgetPredicate((w) => w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical).first;
    await tester.drag(page, const Offset(0, -150));
    await tester.pumpAndSettle();
    final pos = tester.state<ScrollableState>(page).position;
    final before = pos.pixels;
    expect(before, greaterThan(0));

    final chips = find.byType(ChoiceChip);
    final row = find.ancestor(of: chips.first, matching: find.byType(SingleChildScrollView)).first;
    await tester.drag(row, const Offset(600, 0)); // the row alone: back to the oldest month
    await tester.pumpAndSettle();
    expect(pos.pixels, before, reason: 'a sideways drag of the row leaves the page where it was');
    await tester.tap(chips.first);
    await tester.pumpAndSettle();
    _expectFullyVisible(tester, _selected);
    expect(pos.pixels, before, reason: 'revealing the chosen chip must not move the page');
  });
}
