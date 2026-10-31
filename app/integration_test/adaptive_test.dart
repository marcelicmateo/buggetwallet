// Adaptive layout on a desktop window: screenshots of every tab and the Add expense dialog at 1280x800, 1920x1080 and
// 800x1280, plus the rail, shortcuts and window resizing on the real app. Desktop only (a resized phone view hangs the
// screenshot). Run: tools/build.sh desktop-test adaptive -> dist/screens/linux/adaptive/<size>-<screen>.png
import 'package:budget_wallet/src/controller.dart' show TagsDb;
import 'package:budget_wallet/src/layout.dart';
import 'package:budget_wallet/src/platform.dart';
import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/tag_detail.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart' show BudgetKind;

import 'demo_data.dart';
import 'support/harness.dart';

const _tabs = ['Today', 'Budget', 'Bills', 'Save', 'Settings'];

Future<void> _resize(WidgetTester t, Size s) async {
  t.view.physicalSize = s * t.view.devicePixelRatio;
  await t.pumpAndSettle();
}

void main() {
  if (isAndroid) {
    test('adaptive: desktop windows only', () {},
        skip: 'a resized phone view hangs the screenshot: run with tools/build.sh desktop-test adaptive');
    return;
  }
  Harness.init();
  Harness.private(texts: ['Synthetic wish', 'Synthetic goal'], cents: [98765, 12345]);

  for (final (w, h) in const [(1280.0, 800.0), (1920.0, 1080.0), (800.0, 1280.0)]) {
    final name = '${w.toInt()}x${h.toInt()}';
    itest('adaptive $name: every tab and the Add expense dialog', (t) async {
      final wc = await Harness.start(t);
      wc.repo.importBatch(demoBatch(wc.today()));
      wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10, 'salaryConfirmed': true});
      wc.saveGoal(name: 'Synthetic goal', target: 98765 * 10, saved: 12345, monthly: 9876);
      wc.saveGoal(name: 'Synthetic goal two', target: 120000, saved: 0, monthly: 10000);
      wc.addWish('Synthetic wish', 98765);
      // An extra tag on the newest spending rows, so the tag dashboard has something to show.
      final tag = await wc.addTag('Synthetic trip');
      final newest = wc.txs.where((x) => x.amount < 0 && x.kind != BudgetKind.transfer).toList()..sort((a, b) => b.date.compareTo(a.date));
      for (final x in newest.take(5)) {
        await wc.setPaymentTag(x.tx.id, tag, true);
      }
      await _resize(t, Size(w, h));
      final kind = sizeFor(w);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(rail(t).extended, kind == LayoutSize.expanded);
      expect(find.byType(NavigationBar), findsNothing);
      for (final tab in _tabs) {
        await goTab(t, tab);
        await Harness.shot(t, '$name-${tab.toLowerCase()}');
      }
      // Budget › Plan and the pay-period report (RX7), the other wide dashboards.
      await goTab(t, 'Budget');
      await tapVisible(t, find.byKey(const ValueKey('budgetPlan')));
      await Harness.shot(t, '$name-plan');
      await tapVisible(t, find.byKey(const ValueKey('budgetSpending')));
      await tapVisible(t, find.byKey(const ValueKey('periodBadgeTap')));
      expect(find.byKey(const ValueKey('reportKept')), findsOneWidget);
      await Harness.shot(t, '$name-period-report');
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      // Budget's transaction list is the right column on a wide window, below the charts otherwise.
      await goTab(t, 'Budget');
      await scrollTo(t, find.textContaining('All transactions in'), SpendingScreen);
      expect(find.textContaining('All transactions in'), findsOneWidget);
      t.state<ScrollableState>(pageList(SpendingScreen)).position.jumpTo(0);
      await t.pumpAndSettle();
      // Insights: four graphs with their range controls, then a category's detail on top of it
      await tapVisible(t, find.byKey(const ValueKey('insightsOpen')));
      await Harness.shot(t, '$name-insights');
      await tapVisible(t, find.byKey(const ValueKey('rangeChip_spending_months12')));
      await Harness.shot(t, '$name-insights-12months');
      await tapVisible(t, find.byKey(const ValueKey('rangeBack_spending')));
      final shareRow =
          find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('shareRow_')).first;
      await scrollTo(t, find.byKey(const ValueKey('insightPanel_share')), InsightsScreen);
      await tapVisible(t, shareRow);
      expect(find.byType(CategoryDetailScreen), findsOneWidget);
      await Harness.shot(t, '$name-category-detail');
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      // The tag's detail (RX8) from the tags panel of Insights.
      await scrollTo(t, find.byKey(const ValueKey('insightPanel_tags')), InsightsScreen);
      await tapVisible(t, find.byKey(ValueKey('tagRow_$tag')));
      expect(find.byType(TagDetailScreen), findsOneWidget);
      await Harness.shot(t, '$name-tag-detail');
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      expect(find.byType(InsightsScreen), findsNothing);
      await goTab(t, 'Today');
      await tapVisible(t, find.descendant(of: find.byType(TodayScreen), matching: find.text('Add expense')));
      expect(find.byType(Dialog), findsOneWidget);
      await Harness.shot(t, '$name-dialog-add-expense');
      await t.tap(find.byTooltip(hasKeyboard ? 'Close (Esc)' : 'Close'));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await Harness.checkLog();
    });
  }

  itest('adaptive: Ctrl+1..5, Ctrl+N and resizing across the boundaries on the real app', (t) async {
    final wc = await Harness.start(t);
    wc.repo.importBatch(demoBatch(wc.today()));
    await _resize(t, const Size(1280, 800));
    // The hidden pages are built one by one while the app is idle (HomeShell), a frame each: pump until they are all there.
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pumpAndSettle();
    final plan = t.state(find.byType(SettingsScreen, skipOffstage: false));
    final spending = t.state(find.byType(SpendingScreen, skipOffstage: false));

    Future<void> ctrl(LogicalKeyboardKey k) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(k);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
    }

    await ctrl(LogicalKeyboardKey.digit5);
    expect(find.byType(SettingsScreen), findsOneWidget);
    await ctrl(LogicalKeyboardKey.digit2);
    expect(find.byType(SpendingScreen), findsOneWidget);
    await ctrl(LogicalKeyboardKey.keyN);
    expect(find.byType(AddExpenseSheet), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsNothing, reason: 'Esc closes the dialog');

    for (final s in const [Size(360, 800), Size(800, 1280), Size(1920, 1080), Size(360, 800)]) {
      await _resize(t, s);
      expect(identical(t.state(find.byType(SettingsScreen, skipOffstage: false)), plan), isTrue, reason: 'Settings at $s');
      expect(identical(t.state(find.byType(SpendingScreen, skipOffstage: false)), spending), isTrue, reason: 'Spending at $s');
    }
    expect(find.byType(NavigationBar), findsOneWidget);
    await Harness.checkLog();
  });
}

NavigationRail rail(WidgetTester t) => t.widget<NavigationRail>(find.byType(NavigationRail));
