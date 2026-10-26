// Accessibility on every tab at 320x640: tap targets (androidTapTargetGuideline), text contrast, and a minimum font size (12 dp).
// One test per (wallet, scale, brightness, tab, check) so a known failure can be skipped with its widget list. SYNTHETIC data only.
//
// What the Flutter guidelines cannot see, and the probes below add:
//  - MinimumTapTargetGuideline skips nodes touching the view or a scrollable edge, and Material's padded tap target inflates
//    smaller buttons to 48 dp by construction. The sweep checks the first screen and every 300 dp down the page.
//  - textContrastGuideline compares colours only; font size is the `smallText` probe (RichText below 12 dp, eyebrows excepted).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

const _tabs = ['Today', 'Budget', 'Bills', 'Save', 'Settings'];
const _minFont = 12.0;

/// Known failures, keyed by the test name; each reason names the failing widgets (Stage I builds against these).
const _known = <String, String>{};

/// Text below [_minFont] on screen: "size 'text'" per run. Eyebrows (ALL CAPS with letter spacing) and icon glyphs are excepted.
Set<String> smallText(WidgetTester tester) {
  final found = <String>{};
  for (final e in find.byType(RichText).evaluate()) {
    final r = e.renderObject;
    if (r is! RenderParagraph) continue;
    void walk(InlineSpan span, TextStyle? inherited) {
      final style = span is TextSpan && span.style != null ? (inherited?.merge(span.style) ?? span.style) : inherited;
      if (span is TextSpan) {
        final t = span.text;
        final size = style?.fontSize;
        final eyebrow = t != null && t == t.toUpperCase() && (style?.letterSpacing ?? 0) > 0;
        if (t != null && t.trim().isNotEmpty && size != null && size < _minFont && !eyebrow && style?.fontFamily != 'MaterialIcons') {
          found.add("$size '$t'");
        }
        for (final c in span.children ?? const <InlineSpan>[]) {
          walk(c, style);
        }
      }
    }

    walk(r.text, null);
  }
  return found;
}

typedef _Check = Future<void> Function(WidgetTester tester);

Future<void> _sweep(WidgetTester tester, _Check check) async {
  final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
  await check(tester);
  if (lists.evaluate().isNotEmpty) {
    final pos = tester.state<ScrollableState>(lists.first).position;
    for (var i = 0; i < 40 && pos.pixels < pos.maxScrollExtent; i++) {
      pos.jumpTo((pos.pixels + 300).clamp(0, pos.maxScrollExtent));
      await tester.pump();
      await check(tester);
    }
  }
}

void main() {
  final wallets = {'demo': demoWallet, 'habits (bill confirmed)': () => habitsWallet(confirmBill: true)};
  final checks = <String, _Check>{
    'tap targets': (t) => expectLater(t, meetsGuideline(androidTapTargetGuideline)),
    'text contrast': (t) => expectLater(t, meetsGuideline(textContrastGuideline)),
    'font size': (t) async => expect(smallText(t), isEmpty, reason: 'text below $_minFont dp'),
  };
  for (final MapEntry(key: wName, value: makeWallet) in wallets.entries) {
    for (final scale in [1.0, 2.0]) {
      for (final b in Brightness.values) {
        for (final tab in _tabs) {
          for (final MapEntry(key: cName, value: check) in checks.entries) {
            final name = '$cName: $wName, $tab, scale $scale, ${b.name}';
            // testWidgets' skip is a bool: a group takes the reason text.
            group(name, skip: _known[name], () {
              testWidgets('check', (tester) async {
                tester.platformDispatcher.platformBrightnessTestValue = b;
                addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
                final handle = tester.ensureSemantics();
                await pumpFull(tester, makeWallet(), scale);
                await tapTab(tester, tab);
                try {
                  await _sweep(tester, check);
                } finally {
                  handle.dispose();
                  // Let the controller's timers (sync debounce, day check) run out before the tree goes.
                  await tester.pumpWidget(const SizedBox.shrink());
                  await tester.pump(const Duration(minutes: 6));
                }
              });
            });
          }
        }
      }
    }
  }

  testWidgets('control: the tap target guideline does fail on a 20 dp button', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(child: Semantics(button: true, onTap: () {}, label: 'tiny', child: const SizedBox(width: 20, height: 20))))));
    final result = await androidTapTargetGuideline.evaluate(tester);
    handle.dispose();
    expect(result.passed, isFalse);
  });

  testWidgets('control: the contrast guideline does fail on pale grey text on white', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(child: Text('pale', style: TextStyle(fontSize: 20, color: Colors.grey.shade300))))));
    final result = await textContrastGuideline.evaluate(tester);
    handle.dispose();
    expect(result.passed, isFalse);
  });

  testWidgets('control: the font probe finds 11 dp text and ignores an eyebrow and 12 dp text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Column(children: [
      Text('small', style: TextStyle(fontSize: 11)),
      Text('EYEBROW', style: TextStyle(fontSize: 10, letterSpacing: 1.2)),
      Text('fine', style: TextStyle(fontSize: 12)),
    ])));
    expect(smallText(tester), {"11.0 'small'"});
  });
}
