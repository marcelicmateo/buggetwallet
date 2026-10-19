// Every screen at 320x640 dp with text scale 2.0 (and the default scale): no overflow or other FlutterError.
// Overflow errors are reported when a widget paints, so each tab is scrolled through to the end.
// All data is SYNTHETIC.
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

Future<void> _pumpFull(WidgetTester tester, WalletController wc, double scale) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(BudgetWalletApp(wc: wc));
  await tester.pump();
}

/// Rows/columns whose children are bigger than they are, named by the text inside them (for the failure message).
final _overflowing = <String>{};
void _scan(WidgetTester tester) {
  for (final e in find.byWidgetPredicate((w) => w is Flex).evaluate()) {
    final r = e.renderObject;
    if (r is! RenderFlex || !r.hasSize) continue;
    final h = r.direction == Axis.horizontal;
    var sum = 0.0;
    r.visitChildren((c) {
      if (c is RenderBox && c.hasSize) sum += h ? c.size.width : c.size.height;
    });
    if (sum > (h ? r.size.width : r.size.height) + 0.5) {
      final texts = find
          .descendant(of: find.byElementPredicate((x) => x == e), matching: find.byType(RichText))
          .evaluate()
          .map((t) => (t.widget as RichText).text.toPlainText())
          .take(4);
      _overflowing.add('${h ? 'Row' : 'Column'} by ${(sum - (h ? r.size.width : r.size.height)).round()}: ${texts.join(' | ')}');
    }
  }
}

/// Scrolls the visible list to its end, a screen at a time, painting every row on the way.
Future<void> _scrollThrough(WidgetTester tester) async {
  _scan(tester);
  final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
  if (lists.evaluate().isEmpty) return;
  final list = lists.first;
  for (var i = 0; i < 40; i++) {
    final pos = tester.state<ScrollableState>(list).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 300).clamp(0, pos.maxScrollExtent));
    await tester.pump();
    _scan(tester);
  }
}

/// Collects every FlutterError (all overflow sites, not only the first) until [check] is called.
class _Errors {
  final List<String> found = [];
  late final FlutterExceptionHandler? _old;
  _Errors() {
    _old = FlutterError.onError;
    FlutterError.onError = (d) => found.add('${d.exceptionAsString()}\n${d.informationCollector?.call().join('\n') ?? ''}');
  }
  void check() {
    FlutterError.onError = _old;
    final rows = _overflowing.toList();
    _overflowing.clear();
    expect(found, isEmpty, reason: 'OVERFLOWING:\n${rows.join('\n')}\n\n${found.length} errors, first:\n${found.firstOrNull}');
  }
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('every tab fits 320 dp at text scale $scale', (tester) async {
      final wc = demoWallet();
      final errors = _Errors();
      await _pumpFull(tester, wc, scale);
      await _scrollThrough(tester);
      for (final tab in ['Spending', 'Wishlist', 'Goals', 'Plan', 'Today']) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await _scrollThrough(tester);
      }
      errors.check();
      expect(tester.takeException(), isNull);
    });

    testWidgets('onboarding fits 320 dp at text scale $scale', (tester) async {
      final wc = emptyWallet(withKey: false);
      final errors = _Errors();
      await _pumpFull(tester, wc, scale);
      await _scrollThrough(tester);
      await tester.ensureVisible(find.text('Join my wallet from another device'));
      await tester.pump();
      await tester.tap(find.text('Join my wallet from another device'));
      await tester.pump();
      await _scrollThrough(tester);
      errors.check();
      expect(tester.takeException(), isNull);
    });
  }
}
