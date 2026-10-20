// Every money amount on Today, Spending, Wishlist and Goals uses IBM Plex Mono with tabular figures, and amounts in a list
// share one right edge. SYNTHETIC data only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

final _money = RegExp(r'^[+−-]?\d[\d,.  ]*(\.\d\d)?[  ]€$');

TextStyle? _resolved(WidgetTester tester, Element e) {
  final w = e.widget as Text;
  final base = DefaultTextStyle.of(e);
  return base.style.merge(w.style);
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('${b.name}: money texts are Plex Mono with tabular figures', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = b;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pumpFull(tester, demoWallet(), 1.0, size: const Size(800, 1000));
      var total = 0;
      for (final tab in ['Today', 'Spending', 'Wishlist', 'Goals']) {
        await tapTab(tester, tab);
        final list = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
        if (list.evaluate().isNotEmpty) {
          final pos = tester.state<ScrollableState>(list.first).position;
          // Check at the top and again at the bottom so lazily built rows are covered.
          for (final at in [0.0, pos.maxScrollExtent]) {
            pos.jumpTo(at);
            await tester.pump();
            total += _check(tester, tab);
          }
        } else {
          total += _check(tester, tab);
        }
      }
      expect(total, greaterThan(5), reason: 'found money texts');
    });
  }

  testWidgets('Today hero and stat strip: one narrow gap, no widget between number and sign', (tester) async {
    await pumpFull(tester, demoWallet(), 1.0, size: const Size(800, 1000));
    await tapTab(tester, 'Today');
    for (final scale in [1.0, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pump();
      // The hero is the Text with the biggest font on the page.
      Text? hero;
      for (final e in find.byType(Text).evaluate()) {
        final w = e.widget as Text;
        final s = w.textSpan?.toPlainText() ?? w.data;
        if (s != null && _money.hasMatch(s) && (hero == null || (w.style?.fontSize ?? 0) > (hero.style?.fontSize ?? 0))) hero = w;
      }
      final text = hero!.textSpan?.toPlainText() ?? hero.data!;
      expect('\u00A0'.allMatches(text).length, 1, reason: 'exactly one NBSP in "$text"');
      expect(text, matches(RegExp(r'^[\d,.−-]+\u00A0€$')), reason: 'number, one NBSP, sign');
      // Only spans of the one Text sit between number and sign: it has no Row, WidgetSpan or padding of its own.
      expect(hero.textSpan!.toPlainText(includePlaceholders: false), text);
      final spans = (hero.textSpan! as TextSpan).children!;
      expect(spans.length, 3);
      expect(spans.every((s) => s is TextSpan), isTrue, reason: 'no WidgetSpan');
      expect(find.ancestor(of: find.byWidget(hero), matching: find.byType(FittedBox)), findsWidgets, reason: 'scaleDown kept');
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  testWidgets('transaction amounts share one right edge', (tester) async {
    await pumpFull(tester, demoWallet(), 1.0, size: const Size(800, 1000));
    await tapTab(tester, 'Spending');
    final amounts =
        find.byWidgetPredicate((w) => w is Text && w.data != null && RegExp(r'^[+−-]\d').hasMatch(w.data!) && _money.hasMatch(w.data!));
    // Rows in one list: group by the x of their right edge; the signed amounts of the transaction list must align.
    final xs = [for (var i = 0; i < amounts.evaluate().length; i++) tester.getTopRight(amounts.at(i)).dx];
    if (xs.length >= 2) {
      for (final x in xs) {
        expect(x, closeTo(xs.first, 0.5), reason: 'right edges: $xs');
      }
    }
  });
}

int _check(WidgetTester tester, String tab) {
  var n = 0;
  for (final e in find.byType(Text).evaluate()) {
    final w = e.widget as Text;
    final s = w.data ?? w.textSpan?.toPlainText();
    if (s == null || !_money.hasMatch(s)) continue;
    n++;
    final st = _resolved(tester, e)!;
    expect(st.fontFamily, 'IBM Plex Mono', reason: '$tab: "$s"');
    expect(st.fontFeatures, contains(const FontFeature.tabularFigures()), reason: '$tab: "$s"');
  }
  return n;
}
