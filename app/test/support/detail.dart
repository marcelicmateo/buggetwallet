// Readers for the detail dashboards (RX8): the hero figure is one `Text.rich` (number, narrow gap, sign) keyed by `detailTotal` /
// `tagDetailTotal`, so a test reads its plain text instead of looking for a child `Text`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plain text of the hero figure with key [key].
String heroText(WidgetTester t, String key) {
  final w = t.widget<Text>(find.byKey(ValueKey(key)));
  return w.textSpan?.toPlainText() ?? w.data!;
}

/// The hero figure [key] showing exactly [text].
Finder heroIs(String key, String text) =>
    find.byWidgetPredicate((w) => w is Text && w.key == ValueKey(key) && (w.textSpan?.toPlainText() ?? w.data) == text);

/// [text] inside the tile [key] (a `StatTile`, a chip).
Finder inTile(String key, String text) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(text));
