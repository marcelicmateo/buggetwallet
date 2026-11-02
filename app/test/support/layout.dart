// Shared helpers for the layout tests: pump the whole app at a size and text scale, collect every FlutterError (overflow
// included) and scroll each page to its end so every row is painted. SYNTHETIC data only.
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps the whole app at [size] (logical dp) and text [scale].
Future<void> pumpFull(WidgetTester tester, WalletController wc, double scale, {Size size = const Size(320, 640)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(BudgetWalletApp(wc: wc));
  await tester.pump();
}

/// Rows/columns whose children are bigger than they are, named by the text inside them (for the failure message).
final overflowing = <String>{};

void scanFlex(WidgetTester tester) {
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
      overflowing.add('${h ? 'Row' : 'Column'} by ${(sum - (h ? r.size.width : r.size.height)).round()}: ${texts.join(' | ')}');
    }
  }
}

/// Scrolls the visible list to its end, a screen at a time, painting every row on the way.
Future<void> scrollThrough(WidgetTester tester) async {
  scanFlex(tester);
  final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
  if (lists.evaluate().isEmpty) return;
  final list = lists.first;
  for (var i = 0; i < 40; i++) {
    final pos = tester.state<ScrollableState>(list).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 300).clamp(0, pos.maxScrollExtent));
    await tester.pump();
    scanFlex(tester);
  }
}

/// Collects every FlutterError (all overflow sites, not only the first) until [check] is called.
class Errors {
  final List<String> found = [];
  late final FlutterExceptionHandler? _old;
  Errors() {
    _old = FlutterError.onError;
    FlutterError.onError = (d) => found.add('${d.exceptionAsString()}\n${d.informationCollector?.call().join('\n') ?? ''}');
  }

  /// Gives the framework's handler back. A test that fails an `expect` before [check] must still do this (see [withErrors]): with
  /// the collector left in place the binding's own check fails inside the test zone and the test hangs until its timeout.
  void restore() => FlutterError.onError = _old;

  void check() {
    restore();
    final rows = overflowing.toList();
    overflowing.clear();
    expect(found, isEmpty, reason: 'OVERFLOWING:\n${rows.join('\n')}\n\n${found.length} errors, first:\n${found.firstOrNull}');
  }
}

/// Runs [body] with an [Errors] collector and always restores the handler, so a failing `expect` in [body] fails the test at once
/// with its own message instead of hanging until the test timeout.
Future<void> withErrors(Future<void> Function(Errors errors) body) async {
  final errors = Errors();
  try {
    await body(errors);
  } finally {
    errors.restore();
  }
}

/// The shell's navigation: the bottom bar (key `navBar`) or the rail (key `rail`), whichever the window shows.
Finder get navFinder =>
    find.byKey(const ValueKey('navBar')).evaluate().isNotEmpty ? find.byKey(const ValueKey('navBar')) : find.byKey(const ValueKey('rail'));

/// The old tab names (Today, Budget, Bills, Save, Settings) and where they live now (ENG E1): Overview, Explore, Money, Plan › Saving,
/// Settings (the Overview gear on a phone, the rail bottom from 600 dp). The new names (Overview, Money, Explore, Plan) work too.
const _tabNames = {'Today': 'Overview', 'Budget': 'Explore', 'Bills': 'Money', 'Save': 'Plan'};

/// Taps a destination in the bottom bar or the rail, whichever the window shows.
Future<void> tapTab(WidgetTester tester, String label) async {
  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  if (label == 'Settings') {
    if (find.byKey(const ValueKey('rail')).evaluate().isEmpty) {
      await tester.tap(find.descendant(of: navFinder, matching: find.text('Overview')));
      await settle();
      await tester.tap(find.byKey(const ValueKey('openSettings')));
    } else {
      final item = find.descendant(of: navFinder, matching: find.text('Settings'));
      await tester.ensureVisible(item); // the rail scrolls in a short window
      await tester.tap(item);
    }
    return settle();
  }
  final item = find.descendant(of: navFinder, matching: find.text(_tabNames[label] ?? label));
  await tester.ensureVisible(item);
  await tester.tap(item);
  await settle();
  if (label == 'Save') {
    await tester.tap(find.byKey(const ValueKey('planSaving')));
    await settle();
  }
}
